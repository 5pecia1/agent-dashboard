import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "./worker";
import { authHeaders, eventPayload } from "./fixtures";

interface WorkerEnv {
  DB: D1Database;
  AUTH_TOKEN?: string;
  DASHBOARD_STORE_MESSAGE?: string;
}

interface WorkerExport {
  fetch(request: Request, env: unknown, ctx: ExecutionContext): Response | Promise<Response>;
}

const app = worker as unknown as WorkerExport;
const baseEnv = env as unknown as WorkerEnv;
const testEnv = env as unknown as { DB: D1Database };

interface HistoryEventRow {
  id: number;
  session_key: string;
  source: string;
  event: string;
  message: string | null;
  received_at: number;
}

interface HistoryPage {
  events: HistoryEventRow[];
  has_more: boolean;
  next_before_id: number | null;
}

async function fetchHistory(
  query = "",
  init: { env?: WorkerEnv; headers?: Record<string, string> } = {},
): Promise<{ status: number; json: HistoryPage }> {
  const ctx = createExecutionContext();
  const response = await app.fetch(
    new Request(`http://dashboard.test/dashboard/events${query}`, {
      headers: init.headers ?? authHeaders(),
    }),
    init.env ?? baseEnv,
    ctx,
  );
  await waitOnExecutionContext(ctx);
  return { status: response.status, json: (await response.json()) as HistoryPage };
}

const FIXED_RECEIVED_AT = 1_700_000_000_000;

async function insertEventRow(
  sessionKey: string,
  event: string,
  message: string | null,
  receivedAt: number = FIXED_RECEIVED_AT,
): Promise<number> {
  const row = await testEnv.DB.prepare(
    `INSERT INTO dashboard_events (session_key, source, event, message, received_at)
     VALUES (?, 'claude-code', ?, ?, ?) RETURNING id`,
  )
    .bind(sessionKey, event, message, receivedAt)
    .first<{ id: number }>();
  return row!.id;
}

async function insertBulk(sessionKey: string, count: number): Promise<void> {
  await testEnv.DB.prepare(
    `WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < ?)
     INSERT INTO dashboard_events (session_key, source, event, message, received_at)
     SELECT ?, 'claude-code', 'Notification', 'bulk-' || n, ? FROM seq`,
  )
    .bind(count, sessionKey, FIXED_RECEIVED_AT)
    .run();
}

describe("GET /dashboard/events 저장 이력", () => {
  it("기본 limit 200과 before_id 커서로 전체 이력을 겹침·누락 없이 끝까지 읽는다", async () => {
    const key = "hist:page";
    const enc = encodeURIComponent(key);
    const promptId = await insertEventRow(key, "UserPromptSubmit", "첫 발언");
    await insertBulk(key, 204);
    await insertEventRow("hist:other", "Notification", "다른 세션");

    const first = await fetchHistory(`?session_key=${enc}`);
    expect(first.status).toBe(200);
    expect(first.json.events.length).toBe(200);
    expect(first.json.has_more).toBe(true);
    const ids = first.json.events.map((e) => e.id);
    expect(ids).toEqual([...ids].sort((a, b) => b - a));
    expect(first.json.next_before_id).toBe(ids[ids.length - 1]);
    expect(first.json.events.every((e) => e.session_key === key)).toBe(true);
    for (const e of first.json.events) expect("raw" in e).toBe(false);

    await insertEventRow(key, "Notification", "새 이벤트", FIXED_RECEIVED_AT + 1);
    const second = await fetchHistory(`?session_key=${enc}&before_id=${first.json.next_before_id}`);
    expect(second.status).toBe(200);
    expect(second.json.events.length).toBe(5);
    expect(second.json.has_more).toBe(false);
    expect(second.json.next_before_id).toBeNull();
    const secondIds = new Set(second.json.events.map((e) => e.id));
    expect(secondIds.has(promptId)).toBe(true);
    for (const id of ids) expect(secondIds.has(id)).toBe(false);
    expect(second.json.events.every((e) => e.message !== "새 이벤트")).toBe(true);
  });

  it("kind=prompts는 최근 페이지가 아니라 저장 이력 전체에서 발언만 골라 준다", async () => {
    const key = "hist:prompts";
    const enc = encodeURIComponent(key);
    const oldPromptId = await insertEventRow(key, "UserPromptSubmit", "오래된 발언");
    await insertBulk(key, 209);

    const all = await fetchHistory(`?session_key=${enc}`);
    expect(all.json.events.length).toBe(200);
    expect(all.json.events.some((e) => e.event === "UserPromptSubmit")).toBe(false);

    const prompts = await fetchHistory(`?session_key=${enc}&kind=prompts`);
    expect(prompts.status).toBe(200);
    expect(prompts.json.events.map((e) => e.id)).toEqual([oldPromptId]);
    expect(prompts.json.events[0]!.message).toBe("오래된 발언");
    expect(prompts.json.has_more).toBe(false);
    expect(prompts.json.next_before_id).toBeNull();

    const explicit = await fetchHistory(`?session_key=${enc}&kind=all&limit=3`);
    expect(explicit.status).toBe(200);
    expect(explicit.json.events.length).toBe(3);
  });

  it("kind=prompts도 before_id 커서로 다음 페이지를 넘긴다", async () => {
    const key = "hist:prompt-page";
    const enc = encodeURIComponent(key);
    for (const message of ["발언1", "발언2", "발언3"]) {
      await insertEventRow(key, "UserPromptSubmit", message);
      await insertEventRow(key, "Notification", null);
    }

    const first = await fetchHistory(`?session_key=${enc}&kind=prompts&limit=2`);
    expect(first.status).toBe(200);
    expect(first.json.events.map((e) => e.message)).toEqual(["발언3", "발언2"]);
    expect(first.json.has_more).toBe(true);

    const second = await fetchHistory(
      `?session_key=${enc}&kind=prompts&limit=2&before_id=${first.json.next_before_id}`,
    );
    expect(second.status).toBe(200);
    expect(second.json.events.map((e) => e.message)).toEqual(["발언1"]);
    expect(second.json.has_more).toBe(false);
    expect(second.json.next_before_id).toBeNull();
  });

  it("limit은 양의 안전 정수만 받는다 - 이상한 값은 기본 200, 1000 초과는 1000으로 자른다", async () => {
    const key = "hist:limits";
    const enc = encodeURIComponent(key);
    await insertBulk(key, 205);
    for (const bad of ["-1", "0", "NaN", "1.5", "abc"]) {
      const res = await fetchHistory(`?session_key=${enc}&limit=${bad}`);
      expect(res.status, `limit=${bad}`).toBe(200);
      expect(res.json.events.length, `limit=${bad}는 기본 200으로 되돌아간다`).toBe(200);
    }

    const bigKey = "hist:limits-big";
    await insertBulk(bigKey, 1005);
    const clamped = await fetchHistory(`?session_key=${encodeURIComponent(bigKey)}&limit=5000`);
    expect(clamped.status).toBe(200);
    expect(clamped.json.events.length).toBe(1000);
    expect(clamped.json.has_more).toBe(true);
  });

  it("잘못된 before_id와 kind는 400을 돌려준다", async () => {
    for (const bad of ["", "0", "-1", "1.5", "text", "9007199254740993"]) {
      const res = await fetchHistory(`?before_id=${bad}`);
      expect(res.status, `before_id=${bad}`).toBe(400);
    }
    const kind = await fetchHistory("?kind=bogus");
    expect(kind.status).toBe(400);
  });

  it("빈 이력은 빈 페이지를 200으로 돌려준다", async () => {
    const res = await fetchHistory("?session_key=hist:never-existed");
    expect(res.status).toBe(200);
    expect(res.json).toEqual({ events: [], has_more: false, next_before_id: null });
  });

  it("인증 헤더가 없으면 401을 그대로 돌려준다", async () => {
    const res = await fetchHistory("", { headers: {} });
    expect(res.status).toBe(401);
  });

  it("DASHBOARD_STORE_MESSAGE=0으로 수집된 이벤트는 이력에서 message가 null이다", async () => {
    const noStoreEnv: WorkerEnv = { ...baseEnv, DASHBOARD_STORE_MESSAGE: "0" };
    const ctx = createExecutionContext();
    const post = await app.fetch(
      new Request("http://dashboard.test/dashboard/events", {
        method: "POST",
        headers: { "content-type": "application/json", ...authHeaders() },
        body: JSON.stringify(
          eventPayload({
            source: "claude-code",
            session_id: "privacy",
            event: "UserPromptSubmit",
            event_id: "hist-privacy-1",
            occurred_at: Date.now(),
            message: "이 본문은 저장되면 안 된다",
          }),
        ),
      }),
      noStoreEnv,
      ctx,
    );
    await waitOnExecutionContext(ctx);
    expect(post.status).toBe(200);

    const res = await fetchHistory(`?session_key=${encodeURIComponent("claude-code:privacy")}`);
    expect(res.status).toBe(200);
    expect(res.json.events.length).toBe(1);
    expect(res.json.events[0]!.message).toBeNull();
  });

  it("DELETE /dashboard/sessions/:key는 보존 예외 대상인 발언까지 함께 지운다", async () => {
    const key = "hist-del:s1";
    await testEnv.DB.prepare(
      `INSERT INTO dashboard_sessions
         (key, source, session_id, project, host, state, last_event, last_message, created_at, updated_at)
       VALUES (?, 'claude-code', 's1', '', NULL, 'working', 'UserPromptSubmit', NULL, 1, 1)`,
    )
      .bind(key)
      .run();
    await insertEventRow(key, "UserPromptSubmit", "지워질 발언");

    const ctx = createExecutionContext();
    const res = await app.fetch(
      new Request(`http://dashboard.test/dashboard/sessions/${encodeURIComponent(key)}`, {
        method: "DELETE",
        headers: authHeaders(),
      }),
      baseEnv,
      ctx,
    );
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(200);

    const after = await fetchHistory(`?session_key=${encodeURIComponent(key)}`);
    expect(after.status).toBe(200);
    expect(after.json.events).toEqual([]);
  });
});
