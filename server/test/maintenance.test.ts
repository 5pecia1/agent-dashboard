import { createExecutionContext, createScheduledController, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "./worker";
import { runDashboardMaintenance, type MaintenanceEnv } from "../src/dashboard/maintenance";
import { authHeaders, eventPayload } from "./fixtures";

/**
 * T06 완료 판정 (a)(b)(c): cron 유지관리(stalled 스윕 + 보존 정리).
 *
 * auth-cors.test.ts와 같은 이유로 `exports`(cloudflare:workers)가 아니라 src/index.ts의
 * default export를 직접 쓴다 - DASHBOARD_STALL_MS를 이 파일에서만 5초로 낮춰야 하는데,
 * `exports`로 얻는 워커는 넘긴 env를 무시하고 원본 바인딩(wrangler.jsonc의 300000ms)을 쓴다.
 */

interface WorkerEnv {
  DB: D1Database;
  AUTH_TOKEN?: string;
  DASHBOARD_STALL_MS?: string;
}

interface WorkerExport {
  fetch(request: Request, env: unknown, ctx: ExecutionContext): Response | Promise<Response>;
  scheduled(controller: ScheduledController, env: unknown, ctx: ExecutionContext): Promise<void> | void;
}

const app = worker as unknown as WorkerExport;
const baseEnv = env as unknown as WorkerEnv;
// 완료 판정(a)이 요구하는 값: DASHBOARD_STALL_MS=5초.
const stallEnv: WorkerEnv = { ...baseEnv, DASHBOARD_STALL_MS: "5000" };
const testEnv = env as unknown as { DB: D1Database };

async function postEvent(body: Record<string, unknown>): Promise<{ status: number; json: Record<string, unknown> }> {
  const ctx = createExecutionContext();
  const request = new Request("http://dashboard.test/dashboard/events", {
    method: "POST",
    headers: { "content-type": "application/json", ...authHeaders() },
    body: JSON.stringify(body),
  });
  const response = await app.fetch(request, stallEnv, ctx);
  await waitOnExecutionContext(ctx);
  return { status: response.status, json: (await response.json()) as Record<string, unknown> };
}

async function runCron(now = new Date()): Promise<void> {
  const controller = createScheduledController({ scheduledTime: now, cron: "0 * * * *" });
  const ctx = createExecutionContext();
  await app.scheduled(controller, stallEnv, ctx);
  await waitOnExecutionContext(ctx);
}

interface SessionRow {
  state: string;
  last_progress_at: number | null;
}

async function getSession(key: string): Promise<SessionRow | null> {
  return testEnv.DB.prepare("SELECT state, last_progress_at FROM dashboard_sessions WHERE key = ?")
    .bind(key)
    .first<SessionRow>();
}

async function countTransitions(sessionKey: string, toState: string): Promise<number> {
  const row = await testEnv.DB.prepare(
    "SELECT COUNT(*) AS n FROM dashboard_transitions WHERE session_key = ? AND to_state = ?",
  )
    .bind(sessionKey, toState)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

describe("cron 유지관리: stalled 스윕", () => {
  const source = "claude-code";
  const sessionId = "cron-stall";
  const key = `${source}:${sessionId}`;

  it("완료 판정(a): DASHBOARD_STALL_MS=5초 + working 세션이 6초 조용하면 cron 1회에 stalled·전이 1행", async () => {
    // eventPayload()의 occurred_at 기본값은 contract.event_payload.example의 고정 예시 시각이다
    // (실제 벽시계와 무관한 과거 값) - 이 테스트는 아래에서 last_occurred_at을 "지금(Date.now())
    // 기준 6초 전"으로 직접 되돌리므로, 그 비교가 의미 있으려면 이벤트들의 occurred_at도 실제
    // 지금 시각대여야 한다(안 그러면 5-b 순서 역행 방어에 걸려 버린다). 그래서 모든 postEvent
    // 호출에 occurred_at: Date.now()를 명시한다.
    const started = await postEvent(
      eventPayload({
        source, session_id: sessionId, event: "SessionStart",
        event_id: `${key}-start`, occurred_at: Date.now(),
      }),
    );
    expect(started.json.state).toBe("idle");
    const working = await postEvent(
      eventPayload({
        source, session_id: sessionId, event: "UserPromptSubmit",
        event_id: `${key}-prompt-1`, occurred_at: Date.now(),
      }),
    );
    expect(working.json.state).toBe("working");

    // "6초 조용했다"를 흉내 낸다: last_progress_at을 6초 전으로 되돌린다(DASHBOARD_STALL_MS=5000보다
    // 크다). stalled 판정은 last_progress_at(서버 시계)만 본다 - last_occurred_at(클라이언트
    // 시계)은 건드리지 않는다.
    await testEnv.DB.prepare("UPDATE dashboard_sessions SET last_progress_at = ? WHERE key = ?")
      .bind(Date.now() - 6000, key)
      .run();

    expect(await countTransitions(key, "stalled")).toBe(0);

    await runCron();

    const session = await getSession(key);
    expect(session?.state).toBe("stalled");
    // cron 1회 = 전이 정확히 1행(중복 스윕이 아니다).
    expect(await countTransitions(key, "stalled")).toBe(1);
  });

  it("완료 판정(b): UserPromptSubmit로 working 복귀 후 재-stalled에도 전이 중복이 없다", async () => {
    // 이전 테스트에서 이 세션은 이미 stalled다. 실제 이벤트가 오면 즉시 벗어난다
    // (routes.ts: current.state==='stalled' !== 'ended'이므로 REVIVAL_EVENT 제약도 걸리지 않는다).
    const recovered = await postEvent(
      eventPayload({
        source, session_id: sessionId, event: "UserPromptSubmit",
        event_id: `${key}-prompt-2`, occurred_at: Date.now(),
      }),
    );
    expect(recovered.json.state).toBe("working");

    // 복귀 직후 cron을 바로 돌려도(last_progress_at이 방금 갱신됐으므로 - UserPromptSubmit은
    // 상태 변경 이벤트라 진척이다) 재-stalled가 되면 안 된다.
    await runCron();
    let session = await getSession(key);
    expect(session?.state).toBe("working");
    expect(await countTransitions(key, "stalled")).toBe(1); // 그대로 1행 - 늘지 않았다

    // 다시 6초 조용해진 것을 흉내 낸다.
    await testEnv.DB.prepare("UPDATE dashboard_sessions SET last_progress_at = ? WHERE key = ?")
      .bind(Date.now() - 6000, key)
      .run();
    await runCron();

    session = await getSession(key);
    expect(session?.state).toBe("stalled");
    // 재-stalled는 "새 전이"이지 첫 stalled 전이의 중복이 아니다 - 총 2행(working->stalled가 두 번).
    expect(await countTransitions(key, "stalled")).toBe(2);

    // 이미 stalled인 세션에 cron을 또 돌려도(last_progress_at이 그대로) 전이가 더 늘지 않는다
    // (state='working' 조건에 안 걸려 SELECT 후보에서 아예 빠진다 - 중복 적재 방지의 핵심).
    await runCron();
    session = await getSession(key);
    expect(session?.state).toBe("stalled");
    expect(await countTransitions(key, "stalled")).toBe(2);
  });
});

describe("cron 유지관리: 보존 정리", () => {
  const OLD_EVENT_KEY = "retention:old-event";
  const OLD_SESSION_KEY = "retention:old-session";
  const OLD_TRANSITION_KEY = "retention:old-transition";
  const DAY_MS = 24 * 60 * 60 * 1000;

  it("완료 판정(c): 보존 기간을 넘긴 행이 정리되고 pruned_below_id가 올라간다", async () => {
    const now = Date.now();

    // dashboard_events: 기본 보존 7일. 40일 전 이벤트를 하나 심는다.
    await testEnv.DB.prepare(
      `INSERT INTO dashboard_events (session_key, source, event, message, received_at, event_id, occurred_at, host, raw)
       VALUES (?, 'generic', 'PostToolUse', NULL, ?, NULL, ?, NULL, NULL)`,
    )
      .bind(OLD_EVENT_KEY, now - 40 * DAY_MS, now - 40 * DAY_MS)
      .run();

    // dashboard_sessions: state='ended' 스코프, 기본 보존 7일. 10일 전에 끝난 세션.
    await testEnv.DB.prepare(
      `INSERT INTO dashboard_sessions
         (key, source, session_id, project, host, state, last_event, last_message, last_occurred_at, created_at, updated_at)
       VALUES (?, 'generic', 'old-session', '', NULL, 'ended', 'SessionEnd', NULL, ?, ?, ?)`,
    )
      .bind(OLD_SESSION_KEY, now - 10 * DAY_MS, now - 10 * DAY_MS, now - 10 * DAY_MS)
      .run();

    // dashboard_transitions: 기본 보존 7일. 40일 전 전이.
    const insertedTransition = await testEnv.DB.prepare(
      `INSERT INTO dashboard_transitions
         (session_key, from_state, to_state, source, project, host, message, occurred_at, created_at)
       VALUES (?, NULL, 'done', 'generic', NULL, NULL, NULL, ?, ?)
       RETURNING id`,
    )
      .bind(OLD_TRANSITION_KEY, now - 40 * DAY_MS, now - 40 * DAY_MS)
      .first<{ id: number }>();

    const prunedBefore = await testEnv.DB.prepare(
      "SELECT value FROM dashboard_meta WHERE key = 'pruned_below_id'",
    ).first<{ value: string }>();
    const eventsBefore = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_events").first<{
      n: number;
    }>();
    const sessionsBefore = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_sessions").first<{
      n: number;
    }>();
    const transitionsBefore = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_transitions").first<{
      n: number;
    }>();

    await runCron();

    const eventRow = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_events WHERE session_key = ?")
      .bind(OLD_EVENT_KEY)
      .first<{ n: number }>();
    expect(eventRow?.n).toBe(0); // 낡은 이벤트는 지워졌다

    const sessionRow = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_sessions WHERE key = ?")
      .bind(OLD_SESSION_KEY)
      .first<{ n: number }>();
    expect(sessionRow?.n).toBe(0); // 낡은 종료 세션도 지워졌다

    const transitionRow = await testEnv.DB.prepare(
      "SELECT COUNT(*) AS n FROM dashboard_transitions WHERE session_key = ?",
    )
      .bind(OLD_TRANSITION_KEY)
      .first<{ n: number }>();
    expect(transitionRow?.n).toBe(0); // 낡은 전이도 지워졌다

    const eventsAfter = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_events").first<{ n: number }>();
    const sessionsAfter = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_sessions").first<{
      n: number;
    }>();
    const transitionsAfter = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_transitions").first<{
      n: number;
    }>();
    // 행 감소: 전체 카운트가 줄었다(정리 대상이 아닌 최근 행들은 그대로 남아 있다).
    expect(eventsAfter!.n).toBeLessThan(eventsBefore!.n);
    expect(sessionsAfter!.n).toBeLessThan(sessionsBefore!.n);
    expect(transitionsAfter!.n).toBeLessThan(transitionsBefore!.n);

    const prunedAfter = await testEnv.DB.prepare(
      "SELECT value FROM dashboard_meta WHERE key = 'pruned_below_id'",
    ).first<{ value: string }>();
    // pruned_below_id 상승: 방금 지운 전이의 id보다 커야 한다(그 아래로는 다 사라졌다는 경계).
    expect(Number(prunedAfter?.value)).toBeGreaterThan(Number(prunedBefore?.value ?? 0));
    expect(Number(prunedAfter?.value)).toBeGreaterThan(insertedTransition!.id);
  });

  it("보존 기간이 지나 지워지는 종료 세션의 dashboard_seen 행도 함께 지워진다(maintenance.ts pruneRetention)", async () => {
    // OLD_SESSION_KEY와 같은 조건(state='ended', updated_at이 세션 보존 기간을 넘김)을 새
    // 세션에 다시 만든다 - 위 테스트가 이미 OLD_SESSION_KEY를 지워 버렸으므로 키를 새로 쓴다.
    const key = "retention:old-session-with-seen";
    const now = Date.now();
    await testEnv.DB.prepare(
      `INSERT INTO dashboard_sessions
         (key, source, session_id, project, host, state, last_event, last_message, last_occurred_at, created_at, updated_at)
       VALUES (?, 'generic', 'old-session-with-seen', '', NULL, 'ended', 'SessionEnd', NULL, ?, ?, ?)`,
    )
      .bind(key, now - 10 * DAY_MS, now - 10 * DAY_MS, now - 10 * DAY_MS)
      .run();
    await testEnv.DB.prepare("INSERT INTO dashboard_seen (session_key, seen_transition_id) VALUES (?, NULL)")
      .bind(key)
      .run();
    expect(await count("SELECT COUNT(*) AS n FROM dashboard_seen WHERE session_key = ?", key)).toBe(1);

    await runCron();

    expect(await count("SELECT COUNT(*) AS n FROM dashboard_sessions WHERE key = ?", key)).toBe(0);
    // 세션이 지워질 때 dashboard_seen도 같이 지워진다(pruneRetention이 세션을 지우기 전에
    // 먼저 지운다 - 순서가 뒤바뀌면 서브쿼리가 대상을 못 찾는다는 게 maintenance.ts의 주석).
    expect(await count("SELECT COUNT(*) AS n FROM dashboard_seen WHERE session_key = ?", key)).toBe(0);
  });

  it("세션이 이미 사라진 고아 dashboard_seen 행도 cron이 매 주기 정리한다(안전망)", async () => {
    // 세션 행 자체가 애초에 없는(두 삭제 경로 중 어느 쪽도 거치지 않은) dashboard_seen 행을
    // 직접 심어 고아 상태를 흉내 낸다.
    const orphanKey = "retention:orphan-seen";
    await testEnv.DB.prepare("INSERT INTO dashboard_seen (session_key, seen_transition_id) VALUES (?, 42)")
      .bind(orphanKey)
      .run();
    expect(await count("SELECT COUNT(*) AS n FROM dashboard_sessions WHERE key = ?", orphanKey)).toBe(0);
    expect(await count("SELECT COUNT(*) AS n FROM dashboard_seen WHERE session_key = ?", orphanKey)).toBe(1);

    await runCron();

    expect(await count("SELECT COUNT(*) AS n FROM dashboard_seen WHERE session_key = ?", orphanKey)).toBe(0);
  });
});

async function count(sql: string, ...binds: unknown[]): Promise<number> {
  const row = await testEnv.DB.prepare(sql)
    .bind(...binds)
    .first<{ n: number }>();
  return Number(row?.n ?? 0);
}

async function readHookRevs(): Promise<Record<string, { rev: string | null; at: number }>> {
  const row = await testEnv.DB.prepare("SELECT value FROM dashboard_meta WHERE key = 'hook_revs'").first<{
    value: string | null;
  }>();
  return row?.value ? JSON.parse(row.value) : {};
}

async function writeHookRevs(entries: Record<string, { rev: string | null; at: number }>): Promise<void> {
  await testEnv.DB.prepare(
    `INSERT INTO dashboard_meta (key, value) VALUES ('hook_revs', ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
  )
    .bind(JSON.stringify(entries))
    .run();
}

describe("cron 유지관리: dashboard_meta.hook_revs 원장 만료(훅 구버전 배너)", () => {
  const DAY_MS = 24 * 60 * 60 * 1000;

  it("30일 넘게 오래된 항목은 지워진다", async () => {
    const now = Date.now();
    await writeHookRevs({
      "old-host": { rev: "aaaaaaaa", at: now - 31 * DAY_MS },
      "fresh-host": { rev: "bbbbbbbb", at: now - 1 * DAY_MS },
    });

    await runCron(new Date(now));

    const after = await readHookRevs();
    expect(after["old-host"]).toBeUndefined();
    expect(after["fresh-host"]).toEqual({ rev: "bbbbbbbb", at: now - 1 * DAY_MS });
  });

  it("32개를 넘으면 오래된 것부터 잘라 32개로 자른다", async () => {
    const now = Date.now();
    const entries: Record<string, { rev: string | null; at: number }> = {};
    // 40개를 심는다 - at을 서로 다르게 줘서(0번이 가장 오래됨) 오름차순 절단 순서를 검증한다.
    for (let i = 0; i < 40; i++) {
      entries[`host-${i}`] = { rev: "cccccccc", at: now - (40 - i) * 1000 };
    }
    await writeHookRevs(entries);

    await runCron(new Date(now));

    const after = await readHookRevs();
    expect(Object.keys(after).length).toBe(32);
    // 가장 최신 32개(host-8..host-39)만 남고, 가장 오래된 8개(host-0..host-7)는 잘려나간다.
    for (let i = 0; i < 8; i++) expect(after[`host-${i}`]).toBeUndefined();
    for (let i = 8; i < 40; i++) expect(after[`host-${i}`]).toBeDefined();
  });

  it("만료·절단 대상이 없으면(변화가 없으면) 값을 다시 쓰지 않는다", async () => {
    const now = Date.now();
    await writeHookRevs({ "stable-host": { rev: "dddddddd", at: now - 1 * DAY_MS } });

    const before = await testEnv.DB.prepare(
      "SELECT value FROM dashboard_meta WHERE key = 'hook_revs'",
    ).first<{ value: string }>();

    await runCron(new Date(now));

    const after = await testEnv.DB.prepare("SELECT value FROM dashboard_meta WHERE key = 'hook_revs'").first<{
      value: string;
    }>();
    // 아무것도 안 지워졌으니 저장된 JSON 문자열 자체가 바이트 단위로 그대로다(다시 쓰지 않았다는 증거).
    expect(after?.value).toBe(before?.value);
  });
});

describe("cron 유지관리: 이벤트 7일 보존 + 사용자 발언 예외", () => {
  const DAY_MS = 24 * 60 * 60 * 1000;
  const NOW = 1_800_000_000_000;

  const maintenanceEnv = (extra: Record<string, string> = {}): MaintenanceEnv =>
    ({ ...baseEnv, ...extra }) as unknown as MaintenanceEnv;

  async function insertSession(
    key: string,
    source: string,
    state: string,
    updatedAt: number,
    lastProgressAt: number | null = null,
  ): Promise<void> {
    await testEnv.DB.prepare(
      `INSERT INTO dashboard_sessions
         (key, source, session_id, project, host, state, last_event, last_message, created_at, updated_at, last_progress_at)
       VALUES (?, ?, ?, '', NULL, ?, 'SessionStart', NULL, ?, ?, ?)`,
    )
      .bind(key, source, key, state, updatedAt, updatedAt, lastProgressAt)
      .run();
  }

  async function insertEvent(
    sessionKey: string,
    source: string,
    event: string,
    receivedAt: number,
    occurredAt: number | null = null,
  ): Promise<void> {
    await testEnv.DB.prepare(
      `INSERT INTO dashboard_events (session_key, source, event, message, received_at, occurred_at)
       VALUES (?, ?, ?, NULL, ?, ?)`,
    )
      .bind(sessionKey, source, event, receivedAt, occurredAt)
      .run();
  }

  it("기본 보존 7일: 3일과 정확히 7일 경계의 이벤트는 남고 10일은 지워진다", async () => {
    const key = "retention2:age";
    await insertSession(key, "generic", "working", NOW, NOW);
    await insertEvent(key, "generic", "PostToolUse", NOW - 3 * DAY_MS, NOW - 90 * DAY_MS);
    await insertEvent(key, "generic", "PostToolUse", NOW - 7 * DAY_MS);
    await insertEvent(key, "generic", "PostToolUse", NOW - 10 * DAY_MS);

    await runDashboardMaintenance(maintenanceEnv(), NOW);

    const { results } = await testEnv.DB.prepare(
      "SELECT received_at FROM dashboard_events WHERE session_key = ?",
    )
      .bind(key)
      .all<{ received_at: number }>();
    const kept = (results ?? []).map((row) => row.received_at);
    expect(kept).toContain(NOW - 3 * DAY_MS);
    expect(kept).toContain(NOW - 7 * DAY_MS);
    expect(kept).not.toContain(NOW - 10 * DAY_MS);
  });

  it("살아있는 세션의 90일 전 UserPromptSubmit은 상태·source와 무관하게 남는다", async () => {
    const liveStates = ["idle", "working", "waiting_input", "done", "stalled"];
    const sources = ["claude-code", "codex", "devin"];
    for (const state of liveStates) {
      for (const source of sources) {
        const key = `retention2:live:${state}:${source}`;
        await insertSession(key, source, state, NOW - 100 * DAY_MS, state === "working" ? NOW : null);
        await insertEvent(key, source, "UserPromptSubmit", NOW - 90 * DAY_MS);
        await insertEvent(key, source, "UserPromptSubmit", NOW - 90 * DAY_MS);
        await insertEvent(key, source, "PostToolUse", NOW - 90 * DAY_MS);
      }
    }

    await runDashboardMaintenance(maintenanceEnv(), NOW);

    for (const state of liveStates) {
      for (const source of sources) {
        const key = `retention2:live:${state}:${source}`;
        expect(
          await count(
            "SELECT COUNT(*) AS n FROM dashboard_events WHERE session_key = ? AND event = 'UserPromptSubmit'",
            key,
          ),
        ).toBe(2);
        expect(
          await count(
            "SELECT COUNT(*) AS n FROM dashboard_events WHERE session_key = ? AND event = 'PostToolUse'",
            key,
          ),
        ).toBe(0);
      }
    }
  });

  it("ended 세션의 발언은 세션 유예 기간(기본 7일) 안에서만 남고, 고아 발언은 지워진다", async () => {
    await insertSession("retention2:ended-grace", "codex", "ended", NOW - 1 * DAY_MS);
    await insertEvent("retention2:ended-grace", "codex", "UserPromptSubmit", NOW - 90 * DAY_MS);
    await insertSession("retention2:ended-edge", "codex", "ended", NOW - 7 * DAY_MS);
    await insertEvent("retention2:ended-edge", "codex", "UserPromptSubmit", NOW - 90 * DAY_MS);
    await insertSession("retention2:ended-past", "codex", "ended", NOW - 8 * DAY_MS);
    await insertEvent("retention2:ended-past", "codex", "UserPromptSubmit", NOW - 90 * DAY_MS);
    await insertEvent("retention2:orphan", "codex", "UserPromptSubmit", NOW - 90 * DAY_MS);

    await runDashboardMaintenance(maintenanceEnv(), NOW);

    expect(
      await count("SELECT COUNT(*) AS n FROM dashboard_events WHERE session_key = ?", "retention2:ended-grace"),
    ).toBe(1);
    expect(
      await count("SELECT COUNT(*) AS n FROM dashboard_events WHERE session_key = ?", "retention2:ended-edge"),
    ).toBe(1);
    expect(
      await count("SELECT COUNT(*) AS n FROM dashboard_events WHERE session_key = ?", "retention2:ended-past"),
    ).toBe(0);
    expect(
      await count("SELECT COUNT(*) AS n FROM dashboard_events WHERE session_key = ?", "retention2:orphan"),
    ).toBe(0);
  });

  it("env 보존 일수가 기본값을 덮는다: 이벤트 1일·세션 2일로 좁혀도 live 발언은 남는다", async () => {
    const narrowEnv = maintenanceEnv({
      DASHBOARD_RETAIN_EVENT_DAYS: "1",
      DASHBOARD_RETAIN_SESSION_DAYS: "2",
    });
    await insertSession("retention2:narrow-live", "codex", "idle", NOW);
    await insertEvent("retention2:narrow-live", "codex", "UserPromptSubmit", NOW - 90 * DAY_MS);
    await insertEvent("retention2:narrow-live", "codex", "PostToolUse", NOW - 2 * DAY_MS);
    await insertSession("retention2:narrow-grace", "codex", "ended", NOW - 1 * DAY_MS);
    await insertEvent("retention2:narrow-grace", "codex", "UserPromptSubmit", NOW - 90 * DAY_MS);
    await insertSession("retention2:narrow-past", "codex", "ended", NOW - 3 * DAY_MS);
    await insertEvent("retention2:narrow-past", "codex", "UserPromptSubmit", NOW - 90 * DAY_MS);

    await runDashboardMaintenance(narrowEnv, NOW);

    expect(
      await count("SELECT COUNT(*) AS n FROM dashboard_events WHERE session_key = ?", "retention2:narrow-live"),
    ).toBe(1);
    expect(
      await count("SELECT COUNT(*) AS n FROM dashboard_events WHERE session_key = ?", "retention2:narrow-grace"),
    ).toBe(1);
    expect(
      await count("SELECT COUNT(*) AS n FROM dashboard_events WHERE session_key = ?", "retention2:narrow-past"),
    ).toBe(0);
  });

  it("이상한 DASHBOARD_RETAIN_EVENT_DAYS는 기본 7일로 되돌아간다", async () => {
    const key = "retention2:badenv";
    await insertSession(key, "generic", "idle", NOW);
    await insertEvent(key, "generic", "PostToolUse", NOW - 3 * DAY_MS);
    await insertEvent(key, "generic", "PostToolUse", NOW - 10 * DAY_MS);

    await runDashboardMaintenance(maintenanceEnv({ DASHBOARD_RETAIN_EVENT_DAYS: "abc" }), NOW);

    const { results } = await testEnv.DB.prepare(
      "SELECT received_at FROM dashboard_events WHERE session_key = ?",
    )
      .bind(key)
      .all<{ received_at: number }>();
    const kept = (results ?? []).map((row) => row.received_at);
    expect(kept).toContain(NOW - 3 * DAY_MS);
    expect(kept).not.toContain(NOW - 10 * DAY_MS);
  });
});

describe("cron 유지관리: dashboard_push_log 보존(기본 30일)", () => {
  const DAY_MS = 24 * 60 * 60 * 1000;
  const NOW = 1_800_000_000_000;

  const maintenanceEnv = (extra: Record<string, string> = {}): MaintenanceEnv =>
    ({ ...baseEnv, ...extra }) as unknown as MaintenanceEnv;

  async function insertPushLog(target: string, createdAt: number): Promise<void> {
    await testEnv.DB.prepare(
      `INSERT INTO dashboard_push_log (transition_id, transport, target, result, detail, created_at)
       VALUES (NULL, 'web-push', ?, 'sent', NULL, ?)`,
    )
      .bind(target, createdAt)
      .run();
  }

  it("기본 보존 30일: 20일 전 행은 남고 40일 전 행은 지워진다", async () => {
    await insertPushLog("push-log:recent", NOW - 20 * DAY_MS);
    await insertPushLog("push-log:old", NOW - 40 * DAY_MS);

    await runDashboardMaintenance(maintenanceEnv(), NOW);

    expect(
      await count("SELECT COUNT(*) AS n FROM dashboard_push_log WHERE target = ?", "push-log:recent"),
    ).toBe(1);
    expect(
      await count("SELECT COUNT(*) AS n FROM dashboard_push_log WHERE target = ?", "push-log:old"),
    ).toBe(0);
  });

  it("env 보존 일수가 기본값을 덮는다: 2일로 좁히면 3일 전 행도 지워진다", async () => {
    await insertPushLog("push-log:narrow-recent", NOW - 1 * DAY_MS);
    await insertPushLog("push-log:narrow-old", NOW - 3 * DAY_MS);

    await runDashboardMaintenance(maintenanceEnv({ DASHBOARD_RETAIN_PUSH_LOG_DAYS: "2" }), NOW);

    expect(
      await count("SELECT COUNT(*) AS n FROM dashboard_push_log WHERE target = ?", "push-log:narrow-recent"),
    ).toBe(1);
    expect(
      await count("SELECT COUNT(*) AS n FROM dashboard_push_log WHERE target = ?", "push-log:narrow-old"),
    ).toBe(0);
  });
});
