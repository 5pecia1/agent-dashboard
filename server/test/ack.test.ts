import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "./worker";
import { authHeaders } from "./fixtures";

// POST /dashboard/sessions/:key/ack 정합성 테스트(protocol.v1.json client_actions.UserAck).
//
// ingest.test.ts와 같은 이유로 cloudflare:workers의 `exports`가 아니라 워커를 직접 import해
// 부른다 - createExecutionContext/waitOnExecutionContext로 waitUntil까지 관찰할 수 있어야
// (push 발송이 없다는 것 자체도) 검증할 수 있다.
const app = worker as unknown as {
  fetch(request: Request, env: unknown, ctx: ExecutionContext): Response | Promise<Response>;
};

interface TestEnv {
  DB: D1Database;
}
const testEnv = env as unknown as TestEnv;

interface DashboardResponse {
  ok?: boolean;
  duplicate?: boolean;
  state?: string | null;
  transition_id?: number | null;
  push?: string;
}

/** 이벤트 발생 시각의 기준점. ingest.test.ts의 T0와 같은 관례다. */
const T0 = Date.UTC(2026, 8, 8, 9, 0, 0);
const TEST_PROJECT = "/workspace/example";

let seq = 0;

/** POST /dashboard/events 본문 한 벌. */
function eventBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  seq += 1;
  return {
    protocol_version: 1,
    source: "claude-code",
    session_id: "session",
    project: TEST_PROJECT,
    host: "example-host",
    event: "SessionStart",
    event_id: `ack-evt-${seq}`,
    occurred_at: T0 + seq * 1000,
    ...overrides,
  };
}

async function postEvent(body: Record<string, unknown>): Promise<{ status: number; json: DashboardResponse }> {
  const ctx = createExecutionContext();
  const request = new Request("http://dashboard.test/dashboard/events", {
    method: "POST",
    headers: { "content-type": "application/json", ...authHeaders() },
    body: JSON.stringify(body),
  });
  const response = await app.fetch(request, env, ctx);
  await waitOnExecutionContext(ctx);
  return { status: response.status, json: (await response.json()) as DashboardResponse };
}

/** ack는 본문이 없다(DELETE /sessions/:key와 같은 모양) - CLIENT_TOKEN 인증 헤더만 싣는다. */
async function postAck(key: string): Promise<{ status: number; json: DashboardResponse }> {
  const ctx = createExecutionContext();
  const request = new Request(`http://dashboard.test/dashboard/sessions/${encodeURIComponent(key)}/ack`, {
    method: "POST",
    headers: { ...authHeaders() },
  });
  const response = await app.fetch(request, env, ctx);
  await waitOnExecutionContext(ctx);
  return { status: response.status, json: (await response.json()) as DashboardResponse };
}

async function sessionRow(key: string) {
  return testEnv.DB.prepare("SELECT state, last_occurred_at, last_progress_at FROM dashboard_sessions WHERE key = ?")
    .bind(key)
    .first<{ state: string; last_occurred_at: number | null; last_progress_at: number | null }>();
}

async function count(sql: string, ...binds: unknown[]): Promise<number> {
  const row = await testEnv.DB.prepare(sql).bind(...binds).first<{ n: number }>();
  return Number(row?.n ?? 0);
}

const transitionsOf = (key: string) =>
  count("SELECT COUNT(*) AS n FROM dashboard_transitions WHERE session_key = ?", key);
const userAckEventsOf = (key: string) =>
  count("SELECT COUNT(*) AS n FROM dashboard_events WHERE session_key = ? AND event = 'UserAck'", key);

/** claude-code 세션을 waiting_input까지 끌어올린다(Notification 이벤트가 그 상태로 매핑된다). */
async function bringToWaitingInput(sessionId: string): Promise<string> {
  const key = `claude-code:${sessionId}`;
  await postEvent(eventBody({ session_id: sessionId, event: "SessionStart" }));
  await postEvent(eventBody({ session_id: sessionId, event: "Notification" }));
  expect((await sessionRow(key))?.state).toBe("waiting_input");
  return key;
}

describe("POST /dashboard/sessions/:key/ack: 정상 전이", () => {
  it("waiting_input 세션은 ack로 working이 되고, 이벤트 로그·전이 로그를 모두 남긴다(지름길 UPDATE가 아니다)", async () => {
    const key = await bringToWaitingInput("ack-normal");
    const beforeTransitions = await transitionsOf(key);

    const res = await postAck(key);
    expect(res.status).toBe(200);
    // ingest_responses.200_ok와 같은 모양이다: {ok, state, transition_id, push}.
    expect(res.json.ok).toBe(true);
    expect(res.json.state).toBe("working");
    expect(res.json.transition_id).toBeGreaterThan(0);
    // working은 push_states에 없으므로 push는 발송되지 않는다.
    expect(res.json.push).toBe("none");

    expect((await sessionRow(key))?.state).toBe("working");
    expect(await transitionsOf(key)).toBe(beforeTransitions + 1);

    // 세션 행을 직접 UPDATE하지 않고 dashboard_events에 정식 이벤트로 적재했는지 확인한다.
    const ackEvent = await testEnv.DB.prepare(
      "SELECT source, occurred_at, occurred_at_provided, raw FROM dashboard_events WHERE session_key = ? AND event = 'UserAck'",
    )
      .bind(key)
      .first<{ source: string; occurred_at: number; occurred_at_provided: number; raw: string }>();
    expect(ackEvent).toBeTruthy();
    expect(ackEvent?.source).toBe("claude-code");
    expect(ackEvent?.occurred_at_provided).toBe(1);
    // rebuild.ts(readRawStringField)가 raw를 파싱해 project를 복원하므로 raw는 project를 담아야 한다.
    const parsedRaw = JSON.parse(ackEvent!.raw) as { project?: string };
    expect(parsedRaw.project).toBe(TEST_PROJECT);

    const lastTransition = await testEnv.DB.prepare(
      "SELECT from_state, to_state FROM dashboard_transitions WHERE session_key = ? ORDER BY id DESC LIMIT 1",
    )
      .bind(key)
      .first<{ from_state: string; to_state: string }>();
    expect(lastTransition).toEqual({ from_state: "waiting_input", to_state: "working" });
  });
});

describe("POST /dashboard/sessions/:key/ack: no-op(멱등) 가드", () => {
  it("두 번째 ack는 이미 working이라 아무 것도 바꾸지 않는다(같은 기기 연타·두 기기 동시 클릭을 흉내)", async () => {
    const key = await bringToWaitingInput("ack-double");
    const first = await postAck(key);
    expect(first.json.state).toBe("working");
    const afterFirst = await transitionsOf(key);

    const second = await postAck(key);
    expect(second.status).toBe(200);
    expect(second.json).toEqual({ ok: true, state: "working", transition_id: null, push: "none" });
    expect(await transitionsOf(key)).toBe(afterFirst); // 전이가 늘지 않았다

    // 가드가 이벤트 삽입 이전에 걸러내므로 두 번째 호출은 이벤트 로그도 남기지 않는다.
    expect(await userAckEventsOf(key)).toBe(1);
  });

  it("ended 세션에 대한 ack는 no-op이다", async () => {
    const sessionId = "ack-ended";
    const key = `claude-code:${sessionId}`;
    for (const eventName of ["SessionStart", "Notification", "Stop", "SessionEnd"]) {
      await postEvent(eventBody({ session_id: sessionId, event: eventName }));
    }
    expect((await sessionRow(key))?.state).toBe("ended");
    const before = await transitionsOf(key);

    const res = await postAck(key);
    expect(res.status).toBe(200);
    expect(res.json).toEqual({ ok: true, state: "ended", transition_id: null, push: "none" });
    expect((await sessionRow(key))?.state).toBe("ended");
    expect(await transitionsOf(key)).toBe(before);
    expect(await userAckEventsOf(key)).toBe(0);
  });

  it("이미 working인 세션에 대한 ack는 no-op이다", async () => {
    const sessionId = "ack-working";
    const key = `claude-code:${sessionId}`;
    await postEvent(eventBody({ session_id: sessionId, event: "SessionStart" }));
    await postEvent(eventBody({ session_id: sessionId, event: "UserPromptSubmit" })); // -> working
    expect((await sessionRow(key))?.state).toBe("working");

    const res = await postAck(key);
    expect(res.json).toEqual({ ok: true, state: "working", transition_id: null, push: "none" });
    expect(await userAckEventsOf(key)).toBe(0);
  });

  it("존재하지 않는 세션에 대한 ack는 state:null인 no-op이다", async () => {
    const res = await postAck("claude-code:no-such-session");
    expect(res.status).toBe(200);
    expect(res.json).toEqual({ ok: true, state: null, transition_id: null, push: "none" });
  });
});

describe("POST /dashboard/sessions/:key/ack: occurred_at 단조 증가", () => {
  it("세션 시계가 서버 now보다 앞서 있어도(기록 기계 시계가 빠른 경우) ack가 순서 역행 방어에 걸리지 않는다", async () => {
    const sessionId = "ack-clock-skew";
    const key = `claude-code:${sessionId}`;
    // last_occurred_at을 실제 서버 시각(Date.now())보다 한참 미래로 만든다.
    const farFuture = Date.now() + 10_000_000;
    await postEvent(eventBody({ session_id: sessionId, event: "SessionStart", occurred_at: farFuture }));
    await postEvent(eventBody({ session_id: sessionId, event: "Notification", occurred_at: farFuture + 1000 }));
    const before = await sessionRow(key);
    expect(before?.state).toBe("waiting_input");
    expect(before?.last_occurred_at).toBe(farFuture + 1000);

    const res = await postAck(key);
    expect(res.status).toBe(200);
    // 서버의 now가 last_occurred_at보다 "과거"로 보여도 ack 자체가 순서 역행으로 걷어차이지 않는다.
    expect(res.json.state).toBe("working");
    expect(res.json.transition_id).toBeGreaterThan(0);

    const ackEvent = await testEnv.DB.prepare(
      "SELECT occurred_at FROM dashboard_events WHERE session_key = ? AND event = 'UserAck'",
    )
      .bind(key)
      .first<{ occurred_at: number }>();
    // (last_occurred_at ?? now) + 1 계산이 실제로 적용됐다는 증거 - 세션이 마지막으로 본
    // 시각보다 최소 1ms 뒤여야 한다.
    expect(ackEvent!.occurred_at).toBeGreaterThan(farFuture + 1000);
  });
});

describe('위조 차단: POST /dashboard/events로 들어온 event:"UserAck"는 적재조차 되지 않는다', () => {
  // 검증 리뷰 지적(high): "event_state_map에 없으니 기록만 되고 상태는 안 바뀐다"만으로는
  // 부족하다 - 그 기록된 줄이 POST /dashboard/admin/rebuild(rebuild.ts) 재생 때는 event
  // 이름만 보고 client_actions 판정을 다시 적용해 진짜 전이로 둔갑한다(A!=B). 그래서 지금은
  // 로그에도 안 남긴다 - client-actions.ts의 RESERVED_CLIENT_ACTION_EVENTS.
  it("400으로 거절하고 dashboard_events에도 남기지 않는다(재생 시 위조 전이로 둔갑할 여지 자체를 없앤다)", async () => {
    const sessionId = "ack-forge";
    const key = `claude-code:${sessionId}`;
    await postEvent(eventBody({ session_id: sessionId, event: "SessionStart" }));
    await postEvent(eventBody({ session_id: sessionId, event: "Notification" }));
    expect((await sessionRow(key))?.state).toBe("waiting_input");
    const before = await transitionsOf(key);

    // 수집 엔드포인트로 event:"UserAck"를 직접 흉내 내 보낸다(위조 시도).
    const forged = await postEvent(eventBody({ session_id: sessionId, event: "UserAck" }));
    expect(forged.status).toBe(400);
    expect(await transitionsOf(key)).toBe(before);
    expect((await sessionRow(key))?.state).toBe("waiting_input");

    // 로그에도 남지 않는다 - rebuild.ts가 재생할 거리 자체가 없다.
    expect(await userAckEventsOf(key)).toBe(0);
  });

  it("모르는 source를 자칭해도 거절한다(자칭 source와 무관하게 event 이름만 본다)", async () => {
    const res = await postEvent(eventBody({ source: "totally-unknown-source", event: "UserAck" }));
    expect(res.status).toBe(400);
  });
});
