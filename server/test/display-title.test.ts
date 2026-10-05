import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import type { DashboardEnv } from "../src/index";
import { normalizeDisplayTitle } from "../src/dashboard/display-title";
import { runDashboardMaintenance, type MaintenanceEnv } from "../src/dashboard/maintenance";
import worker from "./worker";
import migration0006 from "../migrations/0006_display_title.sql?raw";

const bindings = env as unknown as DashboardEnv;

async function postEvent(body: Record<string, unknown>, flag?: string) {
  const ctx = createExecutionContext();
  const response = await worker.fetch(
    new Request("https://worker.example/dashboard/events", {
      method: "POST",
      headers: { Authorization: "Bearer test-auth-token", "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }),
    { ...bindings, DASHBOARD_STORE_MESSAGE: flag },
    ctx,
  );
  await waitOnExecutionContext(ctx);
  return response;
}

async function get(path: string, flag?: string) {
  const ctx = createExecutionContext();
  const response = await worker.fetch(
    new Request(`https://worker.example/dashboard${path}`, {
      headers: { Authorization: "Bearer test-auth-token" },
    }),
    { ...bindings, DASHBOARD_STORE_MESSAGE: flag },
    ctx,
  );
  await waitOnExecutionContext(ctx);
  return response;
}

let sequence = 0;
function payload(source: string, sessionId: string, event: string, extra: Record<string, unknown> = {}) {
  sequence += 1;
  return {
    protocol_version: 1,
    source,
    session_id: sessionId,
    project: "/repo/demo",
    host: "example-host",
    event,
    event_id: `title-${source}-${sessionId}-${sequence}`,
    occurred_at: 1_800_000_000_000 + sequence,
    ...extra,
  };
}

async function sessionRow(key: string) {
  return bindings.DB.prepare("SELECT state, display_title FROM dashboard_sessions WHERE key = ?")
    .bind(key)
    .first<{ state: string; display_title: string | null }>();
}

async function transitionRows(key: string) {
  const { results } = await bindings.DB.prepare(
    "SELECT id, from_state, to_state, display_title FROM dashboard_transitions WHERE session_key = ? ORDER BY id ASC",
  )
    .bind(key)
    .all<{ id: number; from_state: string | null; to_state: string; display_title: string | null }>();
  return results ?? [];
}

async function eventRow(eventId: string) {
  return bindings.DB.prepare("SELECT display_title, raw FROM dashboard_events WHERE event_id = ?")
    .bind(eventId)
    .first<{ display_title: string | null; raw: string }>();
}

const WAITING_EVENT: Record<string, string> = {
  "claude-code": "Notification",
  grok: "Notification",
  codex: "UserInputRequest",
  devin: "UserInputRequest",
  antigravity: "UserInputRequest",
};

describe("normalizeDisplayTitle", () => {
  it("문자열이 아니거나 null이거나 비어 있으면 null이다", () => {
    expect(normalizeDisplayTitle(123)).toBeNull();
    expect(normalizeDisplayTitle({ title: "x" })).toBeNull();
    expect(normalizeDisplayTitle(null)).toBeNull();
    expect(normalizeDisplayTitle(undefined)).toBeNull();
    expect(normalizeDisplayTitle("")).toBeNull();
    expect(normalizeDisplayTitle("   ")).toBeNull();
  });

  it("연속 공백을 하나로 접고 앞뒤를 자른다", () => {
    expect(normalizeDisplayTitle("  a\n b\t c  ")).toBe("a b c");
  });

  it("제어문자(Cc)와 서식 문자(Cf)를 제거한다", () => {
    expect(normalizeDisplayTitle("알림\u0007그룹\u200b 제목")).toBe("알림그룹 제목");
  });

  it("120 유니코드 코드포인트로 자른다(astral 문자도 코드포인트 단위)", () => {
    const normalized = normalizeDisplayTitle("\u{10400}".repeat(121));
    expect(Array.from(normalized!).length).toBe(120);
    expect(normalized).toBe("\u{10400}".repeat(120));
  });
});

describe("display_title 수집과 노출", () => {
  beforeEach(async () => {
    await bindings.DB.batch(
      ["dashboard_events", "dashboard_sessions", "dashboard_transitions", "dashboard_seen", "dashboard_push_log"].map(
        (table) => bindings.DB.prepare(`DELETE FROM ${table}`),
      ),
    );
  });

  it.each(Object.keys(WAITING_EVENT))("%s 세션의 제목이 이벤트·세션·전이·sync·history까지 실린다", async (source) => {
    const sessionId = `five-${source}`;
    const key = `${source}:${sessionId}`;
    const waiting = WAITING_EVENT[source]!;

    expect(
      (await postEvent(payload(source, sessionId, "UserPromptSubmit", { display_title: "첫 작업" }), "1")).status,
    ).toBe(200);
    expect((await postEvent(payload(source, sessionId, waiting, { display_title: "첫 작업" }), "1")).status).toBe(200);

    const events = await bindings.DB.prepare(
      "SELECT event, display_title FROM dashboard_events WHERE session_key = ? ORDER BY id ASC",
    )
      .bind(key)
      .all<{ event: string; display_title: string | null }>();
    expect(events.results?.map((row) => [row.event, row.display_title])).toEqual([
      ["UserPromptSubmit", "첫 작업"],
      [waiting, "첫 작업"],
    ]);

    expect((await sessionRow(key))?.display_title).toBe("첫 작업");

    const transitions = await transitionRows(key);
    expect(transitions.length).toBe(2);
    expect(transitions.every((t) => t.display_title === "첫 작업")).toBe(true);

    const reset = (await (await get("/sync", "1")).json()) as {
      sessions: { key: string; display_title: string | null }[];
    };
    expect(reset.sessions.find((s) => s.key === key)?.display_title).toBe("첫 작업");
    const delta = (await (await get("/sync?since=0", "1")).json()) as {
      transitions: { session_key: string; display_title: string | null }[];
    };
    const own = delta.transitions.filter((t) => t.session_key === key);
    expect(own.length).toBe(2);
    expect(own.every((t) => t.display_title === "첫 작업")).toBe(true);

    const history = (await (await get(`/events?session_key=${encodeURIComponent(key)}`, "1")).json()) as {
      events: { event: string; display_title: string | null }[];
    };
    expect(history.events.every((e) => e.display_title === "첫 작업")).toBe(true);
  });

  it("비정규화 제목은 저장 전에 정규화된다", async () => {
    const key = "claude-code:normalize";
    await postEvent(
      payload("claude-code", "normalize", "UserPromptSubmit", { display_title: "  두  줄\n제목\u200b  " }),
      "1",
    );
    expect((await sessionRow(key))?.display_title).toBe("두 줄 제목");
  });

  it("같은 상태로 제목만 바뀌면 세션 제목은 갱신되지만 전이는 늘지 않고, 다음 실제 전이가 새 제목을 싣는다", async () => {
    const key = "claude-code:same-state";
    await postEvent(payload("claude-code", "same-state", "UserPromptSubmit", { display_title: "작업 A" }), "1");
    await postEvent(payload("claude-code", "same-state", "UserPromptSubmit", { display_title: "작업 B" }), "1");

    expect((await sessionRow(key))?.display_title).toBe("작업 B");
    expect((await transitionRows(key)).length).toBe(1);

    await postEvent(payload("claude-code", "same-state", "Notification", { display_title: "작업 B" }), "1");
    const transitions = await transitionRows(key);
    expect(transitions.map((t) => [t.to_state, t.display_title])).toEqual([
      ["working", "작업 A"],
      ["waiting_input", "작업 B"],
    ]);
  });

  it("제목을 싣지 않은 상태 이벤트는 현재 제목을 지운다(이월이 아니라 대입)", async () => {
    const key = "claude-code:clears";
    await postEvent(payload("claude-code", "clears", "UserPromptSubmit", { display_title: "작업 A" }), "1");
    expect((await sessionRow(key))?.display_title).toBe("작업 A");

    await postEvent(payload("claude-code", "clears", "Stop"), "1");
    expect((await sessionRow(key))?.display_title).toBeNull();
    const transitions = await transitionRows(key);
    expect(transitions.map((t) => [t.to_state, t.display_title])).toEqual([
      ["working", "작업 A"],
      ["done", null],
    ]);
  });

  it("중복·순서 역행·ended 가드는 제목도 함께 막는다", async () => {
    const key = "claude-code:guards";
    const first = payload("claude-code", "guards", "UserPromptSubmit", { display_title: "작업 A" });
    await postEvent(first, "1");

    const dup = await postEvent({ ...first, display_title: "작업 X" }, "1");
    expect((await dup.json() as Record<string, unknown>).duplicate).toBe(true);
    expect((await sessionRow(key))?.display_title).toBe("작업 A");

    await postEvent(payload("claude-code", "guards", "Stop", { occurred_at: 1, display_title: "작업 Y" }), "1");
    expect((await sessionRow(key))?.display_title).toBe("작업 A");
    expect((await sessionRow(key))?.state).toBe("working");

    await postEvent(payload("claude-code", "guards", "SessionEnd", { display_title: "끝" }), "1");
    expect((await sessionRow(key))?.state).toBe("ended");
    expect((await sessionRow(key))?.display_title).toBe("끝");
    await postEvent(payload("claude-code", "guards", "UserPromptSubmit", { display_title: "부활?" }), "1");
    expect((await sessionRow(key))?.display_title).toBe("끝");
    expect((await sessionRow(key))?.state).toBe("ended");
  });

  it.each([undefined, "0"])("서버 저장 opt-in이 %s이면 새로 들어온 제목은 저장하지 않는다", async (flag) => {
    const key = "claude-code:private";
    const canary = "title-canary-4471";
    const titled = payload("claude-code", "private", "UserPromptSubmit", { display_title: canary });
    await postEvent(titled, flag);
    await postEvent(payload("claude-code", "private", "Notification", { display_title: canary }), flag);

    const row = await eventRow(titled.event_id);
    expect(row?.display_title).toBeNull();
    expect(row?.raw).not.toContain(canary);
    expect(JSON.parse(row!.raw)).not.toHaveProperty("display_title");

    expect((await sessionRow(key))?.display_title).toBeNull();
    expect((await transitionRows(key)).every((t) => t.display_title === null)).toBe(true);

    const reset = (await (await get("/sync", flag)).json()) as {
      sessions: { key: string; display_title: string | null }[];
    };
    expect(reset.sessions.find((s) => s.key === key)?.display_title).toBeNull();
    expect(JSON.stringify(reset.sessions)).not.toContain(canary);
  });

  it("raw가 4096바이트를 넘게 잘려도 재생은 전용 컬럼의 제목을 복원하고, ack가 만든 전이도 같은 제목을 단다", async () => {
    const key = "claude-code:rebuild-title";
    await postEvent(
      payload("claude-code", "rebuild-title", "UserPromptSubmit", {
        display_title: "긴 작업",
        raw: "x".repeat(5000),
      }),
      "1",
    );
    await postEvent(
      payload("claude-code", "rebuild-title", "Notification", { display_title: "긴 작업" }),
      "1",
    );
    expect((await sessionRow(key))?.state).toBe("waiting_input");

    const ackCtx = createExecutionContext();
    const ack = await worker.fetch(
      new Request(`https://worker.example/dashboard/sessions/${encodeURIComponent(key)}/ack`, {
        method: "POST",
        headers: { Authorization: "Bearer test-auth-token" },
      }),
      { ...bindings, DASHBOARD_STORE_MESSAGE: "1" },
      ackCtx,
    );
    await waitOnExecutionContext(ackCtx);
    expect(ack.status).toBe(200);

    const before = await transitionRows(key);
    expect(before[before.length - 1]?.display_title).toBe("긴 작업");
    const storedRaw = (await bindings.DB.prepare(
      "SELECT raw FROM dashboard_events WHERE session_key = ? AND event = 'UserPromptSubmit'",
    )
      .bind(key)
      .first<{ raw: string }>())?.raw;
    expect(() => JSON.parse(storedRaw!)).toThrow();

    await worker.fetch(
      new Request("https://worker.example/dashboard/admin/rebuild", {
        method: "POST",
        headers: { Authorization: "Bearer test-auth-token" },
      }),
      bindings,
      createExecutionContext(),
    );

    expect((await sessionRow(key))?.display_title).toBe("긴 작업");
    const after = await transitionRows(key);
    expect(after.map((t) => t.display_title)).toEqual(before.map((t) => t.display_title));
  });

  it("display_title 컬럼을 생략하고 삽입한 행의 제목은 NULL이다", async () => {
    const now = Date.now();
    await bindings.DB.prepare(
      `INSERT INTO dashboard_sessions
         (key, source, session_id, project, host, state, last_event, last_message, last_occurred_at, created_at, updated_at)
       VALUES ('generic:legacy-row', 'generic', 'legacy-row', '', NULL, 'done', 'Stop', NULL, ?, ?, ?)`,
    )
      .bind(now, now, now)
      .run();
    await bindings.DB.prepare(
      `INSERT INTO dashboard_transitions
         (session_key, from_state, to_state, source, project, host, message, occurred_at, created_at)
       VALUES ('generic:legacy-row', NULL, 'done', 'generic', NULL, NULL, NULL, ?, ?)`,
    )
      .bind(now, now)
      .run();

    expect((await sessionRow("generic:legacy-row"))?.display_title).toBeNull();
    expect((await transitionRows("generic:legacy-row"))[0]?.display_title).toBeNull();

    for (const table of ["dashboard_events", "dashboard_sessions", "dashboard_transitions"]) {
      expect(migration0006).toContain(`ALTER TABLE ${table} ADD COLUMN display_title TEXT`);
    }
  });

  it("stalled 유지관리 전이는 제목을 이어 받되 저장 opt-in이 꺼져 있으면 싣지 않는다", async () => {
    const key = "claude-code:stall-title";
    await postEvent(payload("claude-code", "stall-title", "UserPromptSubmit", { display_title: "멈춘 작업" }), "1");
    await bindings.DB.prepare("UPDATE dashboard_sessions SET last_progress_at = 1 WHERE key = ?").bind(key).run();

    const maintenanceEnv: MaintenanceEnv = {
      ...bindings,
      DASHBOARD_STALL_MS: "1",
      DASHBOARD_STORE_MESSAGE: "1",
    } as MaintenanceEnv;
    await runDashboardMaintenance(maintenanceEnv, Date.now());
    const transitions = await transitionRows(key);
    expect(transitions[transitions.length - 1]?.to_state).toBe("stalled");
    expect(transitions[transitions.length - 1]?.display_title).toBe("멈춘 작업");

    await bindings.DB.prepare(
      "UPDATE dashboard_sessions SET state = 'working', last_progress_at = 1 WHERE key = ?",
    )
      .bind(key)
      .run();
    await runDashboardMaintenance(
      { ...bindings, DASHBOARD_STALL_MS: "1", DASHBOARD_STORE_MESSAGE: "0" } as MaintenanceEnv,
      Date.now(),
    );
    const after = await transitionRows(key);
    expect(after[after.length - 1]?.to_state).toBe("stalled");
    expect(after[after.length - 1]?.display_title).toBeNull();
  });
});
