import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "./worker";
import contract from "../../contracts/dashboard-protocol.v1.json";
import { opencodeAdapter } from "../src/dashboard/sources/opencode";
import { authHeaders, eventStateMap } from "./fixtures";

/**
 * OpenCode CLI v2 어댑터(src/dashboard/sources/opencode.ts) 수집 테스트.
 *
 * OpenCode는 lifecycle hook이 없어 전역 플러그인(hooks/opencode-plugin.mjs)이 이벤트를 계약 어휘로
 * 번역해 보낸다 — 서버는 번역된 이름만 본다. 여기서는 그 번역 결과가 서버에 들어왔을 때
 * event_state_map.by_source.opencode·heartbeat_events 대로 세션이 움직이는지를 ingest.test.ts와 같은
 * 방식(실제 워커 직접 호출, mock 없음)으로 확인한다. 어댑터 표 자체가 정본과 같은지는
 * contract.test.ts와 scripts/contract_check.py(source adapters)가 집행한다.
 */
const app = worker as unknown as {
  fetch(request: Request, env: unknown, ctx: ExecutionContext): Response | Promise<Response>;
};

interface TestEnv {
  DB: D1Database;
}
const testEnv = env as unknown as TestEnv;

interface IngestResponse {
  ok?: boolean;
  state?: string | null;
  transition_id?: number | null;
  push?: string;
  accepted?: string;
  error?: string;
}

const SOURCE = "opencode";
const T0 = Date.UTC(2026, 9, 18, 9, 0, 0);
let seq = 0;

/** 플러그인→hook이 만드는 본문과 같은 모양의 요청. event_id·occurred_at은 매번 새로 순증한다. */
function payload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  seq += 1;
  return {
    protocol_version: 1,
    source: SOURCE,
    session_id: "ses_default",
    project: "/workspace/opencode",
    host: "example-host",
    event: "UserPromptSubmit",
    event_id: `oc-evt-${seq}`,
    occurred_at: T0 + seq * 1000,
    ...overrides,
  };
}

async function postEvent(body: Record<string, unknown>): Promise<{ status: number; json: IngestResponse }> {
  const ctx = createExecutionContext();
  const request = new Request("http://dashboard.test/dashboard/events", {
    method: "POST",
    headers: { "content-type": "application/json", ...authHeaders() },
    body: JSON.stringify(body),
  });
  const response = await app.fetch(request, env, ctx);
  await waitOnExecutionContext(ctx);
  return { status: response.status, json: (await response.json()) as IngestResponse };
}

async function sessionRow(key: string) {
  return testEnv.DB.prepare(
    "SELECT state, last_event, last_message, last_occurred_at, last_progress_at FROM dashboard_sessions WHERE key = ?",
  )
    .bind(key)
    .first<{
      state: string;
      last_event: string;
      last_message: string | null;
      last_occurred_at: number | null;
      last_progress_at: number | null;
    }>();
}

async function transitionsOf(key: string): Promise<number> {
  const row = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_transitions WHERE session_key = ?")
    .bind(key)
    .first<{ n: number }>();
  return Number(row?.n ?? 0);
}

const key = (sessionId: string) => `${SOURCE}:${sessionId}`;

describe("opencode 어댑터: 정본 표와 어댑터 판정", () => {
  it("정본 event_state_map.by_source.opencode의 다섯 줄을 그대로 판정하고 state 필드는 허용하지 않는다", () => {
    expect(opencodeAdapter.source).toBe(SOURCE);
    expect(opencodeAdapter.stateFieldAllowed).toBe(false);

    const expected = eventStateMap(SOURCE).map(({ event, state }) => [event, state]);
    expect(expected).toEqual([
      ["UserPromptSubmit", "working"],
      ["UserInputRequest", "waiting_input"],
      ["UserInputResolved", "working"],
      ["Stop", "done"],
      ["SessionEnd", "ended"],
    ]);
    for (const [event, state] of expected) {
      expect(opencodeAdapter.resolve({ event: event! })).toEqual({ state, heartbeat: false, reject: null });
    }
  });

  it("PostToolUse만 하트비트이고(heartbeat_events.events.PostToolUse.sources에 opencode가 있다) 그 밖의 이름은 기록 전용이다", () => {
    const heartbeat = (contract.heartbeat_events as { events: Record<string, { sources: string[] }> }).events;
    expect(heartbeat.PostToolUse.sources).toContain(SOURCE);
    expect(opencodeAdapter.resolve({ event: "PostToolUse" })).toEqual({ state: null, heartbeat: true, reject: null });

    // 플러그인이 보내지 않는 이름(SessionStart·Notification·PermissionRequest)과 원본 OpenCode 이벤트 타입은
    // 표에도 하트비트에도 없다 — 어휘를 다른 소스와 공유하지 않는다는 뜻이다.
    for (const event of ["SessionStart", "Notification", "PermissionRequest", "session.execution.started", "toString"]) {
      expect(opencodeAdapter.resolve({ event })).toEqual({ state: null, heartbeat: false, reject: null });
    }
  });
});

describe("opencode 어댑터: 세션 수명주기", () => {
  it("SessionStart 없이 첫 UserPromptSubmit이 세션을 working으로 만들고 Stop이 done, SessionEnd가 ended로 끝낸다", async () => {
    const id = "ses_lifecycle";
    const prompt = await postEvent(payload({ session_id: id, message: "테스트 하나 추가해 줘" }));
    expect(prompt.status).toBe(200);
    expect(prompt.json.ok).toBe(true);
    expect(prompt.json.state).toBe("working");
    expect(prompt.json.push).toBe("none");
    expect(prompt.json.transition_id).toBeGreaterThan(0);
    const created = await sessionRow(key(id));
    expect(created?.state).toBe("working");
    expect(created?.last_message).toBe("테스트 하나 추가해 줘");

    const stop = await postEvent(payload({ session_id: id, event: "Stop" }));
    expect(stop.json.state).toBe("done");
    expect(stop.json.push).toBe("none"); // done은 push_states가 아니다
    expect((await sessionRow(key(id)))?.state).toBe("done");

    const end = await postEvent(payload({ session_id: id, event: "SessionEnd" }));
    expect(end.json.state).toBe("ended");
    expect(end.json.push).toBe("none");
    expect((await sessionRow(key(id)))?.state).toBe("ended");
    expect(await transitionsOf(key(id))).toBe(3);
  });

  it("standalone을 SIGINT로 끊은 경우(한계 목록): Stop 없이 바로 온 SessionEnd도 working을 ended로 닫는다", async () => {
    const id = "ses_sigint";
    await postEvent(payload({ session_id: id }));
    const end = await postEvent(payload({ session_id: id, event: "SessionEnd" }));
    expect(end.json.state).toBe("ended");
    expect((await sessionRow(key(id)))?.state).toBe("ended");
  });

  it("ended 뒤에 늦게 도착한 Stop·UserPromptSubmit·UserInputRequest는 상태를 되돌리지 못한다(SessionStart가 없는 소스라 되살릴 길이 없다)", async () => {
    const id = "ses_after_end";
    await postEvent(payload({ session_id: id }));
    await postEvent(payload({ session_id: id, event: "SessionEnd" }));
    expect((await sessionRow(key(id)))?.state).toBe("ended");

    for (const event of ["Stop", "UserPromptSubmit", "UserInputRequest"]) {
      const late = await postEvent(payload({ session_id: id, event }));
      expect(late.status).toBe(200);
      expect(late.json.state).toBe("ended");
      expect(late.json.push).toBe("none");
    }
    expect((await sessionRow(key(id)))?.state).toBe("ended");
    expect(await transitionsOf(key(id))).toBe(2);
  });

  it("execution.failed·interrupted도 플러그인이 Stop으로 번역하므로 같은 done이고, 같은 상태 재진입은 전이를 만들지 않는다", async () => {
    const id = "ses_failed";
    await postEvent(payload({ session_id: id }));
    // 플러그인은 어느 종료였는지를 stdin의 opencode 객체에만 남긴다 — 서버는 raw로 보존할 뿐 판정에 쓰지 않는다.
    const failed = await postEvent(
      payload({ session_id: id, event: "Stop", raw: { opencode: { type: "session.execution.failed", error_type: "APIError" } } }),
    );
    expect(failed.json.state).toBe("done");
    const interrupted = await postEvent(
      payload({ session_id: id, event: "Stop", raw: { opencode: { type: "session.execution.interrupted", reason: "abort" } } }),
    );
    expect(interrupted.json.state).toBe("done");
    expect(interrupted.json.transition_id).toBeNull();
    expect(await transitionsOf(key(id))).toBe(2); // working, done 두 번뿐
  });

  it("done 뒤 다음 턴의 UserPromptSubmit이 working으로 되돌린다", async () => {
    const id = "ses_next_turn";
    await postEvent(payload({ session_id: id }));
    await postEvent(payload({ session_id: id, event: "Stop" }));
    expect((await sessionRow(key(id)))?.state).toBe("done");

    const next = await postEvent(payload({ session_id: id, message: "이번엔 문서도" }));
    expect(next.json.state).toBe("working");
    expect((await sessionRow(key(id)))?.last_message).toBe("이번엔 문서도");
  });
});

describe("opencode 어댑터: UserInputRequest → UserInputResolved 해소", () => {
  it("permission.asked/form.created 번역(UserInputRequest)은 waiting_input + push, 응답(UserInputResolved)은 working으로 해소한다", async () => {
    const id = "ses_ask";
    await postEvent(payload({ session_id: id }));

    const ask = await postEvent(
      payload({ session_id: id, event: "UserInputRequest", message: "bash: rm -rf node_modules" }),
    );
    expect(ask.json.state).toBe("waiting_input");
    expect(ask.json.push).toBe("queued");
    expect((await sessionRow(key(id)))?.last_message).toBe("bash: rm -rf node_modules");

    const resolved = await postEvent(payload({ session_id: id, event: "UserInputResolved" }));
    expect(resolved.json.state).toBe("working");
    expect(resolved.json.push).toBe("none");
    expect((await sessionRow(key(id)))?.state).toBe("working");
  });

  it("비대화형 opencode run처럼 대기가 수 ms 만에 자동 해소돼도 두 전이가 모두 남는다", async () => {
    const id = "ses_run";
    await postEvent(payload({ session_id: id, occurred_at: T0 + 100_000 }));
    await postEvent(payload({ session_id: id, event: "UserInputRequest", occurred_at: T0 + 100_001 }));
    await postEvent(payload({ session_id: id, event: "UserInputResolved", occurred_at: T0 + 100_003 }));
    expect((await sessionRow(key(id)))?.state).toBe("working");
    expect(await transitionsOf(key(id))).toBe(3);
  });

  it("대기 중에 Stop이 오면(승인 거부로 턴이 끝남) 해소 없이도 done으로 간다", async () => {
    const id = "ses_reject_stop";
    await postEvent(payload({ session_id: id }));
    await postEvent(payload({ session_id: id, event: "UserInputRequest" }));
    const stop = await postEvent(payload({ session_id: id, event: "Stop" }));
    expect(stop.json.state).toBe("done");
  });

  it("대기 중에 SessionEnd가 오면 ended로 닫히고, 뒤늦은 UserInputResolved는 무시된다", async () => {
    const id = "ses_end_while_waiting";
    await postEvent(payload({ session_id: id }));
    await postEvent(payload({ session_id: id, event: "UserInputRequest" }));
    await postEvent(payload({ session_id: id, event: "SessionEnd" }));
    const late = await postEvent(payload({ session_id: id, event: "UserInputResolved" }));
    expect(late.json.state).toBe("ended");
    expect((await sessionRow(key(id)))?.state).toBe("ended");
  });

  it("세션이 아직 없을 때 온 UserInputRequest(자식 세션에서 루트로 올라온 첫 이벤트)는 그 자체로 세션을 만들며 waiting_input이다", async () => {
    // 플러그인은 자식 세션의 대기 이벤트를 루트 세션 ID로 바꿔 보낸다. 루트의 UserPromptSubmit이 먼저 왔어야 정상이지만
    // (hot-reload로 레지스트리가 비면) 대기가 첫 이벤트일 수 있다 — 상태 이벤트이므로 세션이 생기고 놓치지 않는다.
    const id = "ses_orphan_ask";
    const ask = await postEvent(payload({ session_id: id, event: "UserInputRequest" }));
    expect(ask.json.state).toBe("waiting_input");
    expect(ask.json.push).toBe("queued");
  });
});

describe("opencode 어댑터: PostToolUse 하트비트와 승격 가드", () => {
  it("working 세션의 PostToolUse는 상태를 두고 last_occurred_at·last_progress_at만 민다", async () => {
    const id = "ses_beat";
    await postEvent(payload({ session_id: id, occurred_at: T0 + 10_000 }));
    const before = await sessionRow(key(id));

    const beat = await postEvent(payload({ session_id: id, event: "PostToolUse", occurred_at: T0 + 20_000 }));
    expect(beat.json.state).toBe("working");
    expect(beat.json.transition_id).toBeNull();
    const after = await sessionRow(key(id));
    expect(after?.state).toBe("working");
    expect(after?.last_occurred_at).toBe(T0 + 20_000);
    expect(after?.last_progress_at).toBeGreaterThanOrEqual(before?.last_progress_at ?? 0);
    expect(after?.last_event).toBe("PostToolUse");
    expect(await transitionsOf(key(id))).toBe(1);
  });

  it("done 세션의 PostToolUse(Stop 뒤 백그라운드 도구 활동)는 working으로 조건부 승격되고 push는 없다", async () => {
    const id = "ses_promote";
    await postEvent(payload({ session_id: id }));
    await postEvent(payload({ session_id: id, event: "Stop" }));
    expect((await sessionRow(key(id)))?.state).toBe("done");

    const beat = await postEvent(payload({ session_id: id, event: "PostToolUse" }));
    expect(beat.json.state).toBe("working");
    expect(beat.json.push).toBe("none");
    expect(beat.json.transition_id).toBeGreaterThan(0);
  });

  it("가드1: 세션 행이 없으면 PostToolUse가 세션을 만들지 않는다(세션 생성은 UserPromptSubmit의 몫)", async () => {
    const id = "ses_no_row";
    const beat = await postEvent(payload({ session_id: id, event: "PostToolUse" }));
    expect(beat.status).toBe(200);
    expect(beat.json.state).toBeNull();
    expect(await sessionRow(key(id))).toBeNull();
  });

  it("가드2: ended 세션은 PostToolUse로도 되살아나지 않는다", async () => {
    const id = "ses_ended_beat";
    await postEvent(payload({ session_id: id }));
    await postEvent(payload({ session_id: id, event: "SessionEnd" }));
    const beat = await postEvent(payload({ session_id: id, event: "PostToolUse" }));
    expect(beat.json.state).toBe("ended");
    expect((await sessionRow(key(id)))?.state).toBe("ended");
  });

  it("가드3: occurred_at이 없는 PostToolUse는 승격하지 않는다", async () => {
    const id = "ses_no_ts";
    await postEvent(payload({ session_id: id }));
    await postEvent(payload({ session_id: id, event: "Stop" }));
    const withoutTs = payload({ session_id: id, event: "PostToolUse" });
    delete withoutTs.occurred_at;
    const beat = await postEvent(withoutTs);
    expect(beat.json.state).toBe("done");
    expect((await sessionRow(key(id)))?.state).toBe("done");
  });

  it("가드4: occurred_at이 last_occurred_at과 같으면(동률) 승격하지 않는다", async () => {
    const id = "ses_tie";
    await postEvent(payload({ session_id: id, occurred_at: T0 + 500_000 }));
    await postEvent(payload({ session_id: id, event: "Stop", occurred_at: T0 + 500_001 }));
    const beat = await postEvent(payload({ session_id: id, event: "PostToolUse", occurred_at: T0 + 500_001 }));
    expect(beat.json.state).toBe("done");
    expect((await sessionRow(key(id)))?.last_occurred_at).toBe(T0 + 500_001);
  });

  it("가드5: waiting_input 세션은 PostToolUse로 승격되지 않고 UserInputResolved만 해소한다(자식 세션 도구 활동이 승인 대기를 가리면 안 된다)", async () => {
    const id = "ses_wait_beat";
    await postEvent(payload({ session_id: id }));
    await postEvent(payload({ session_id: id, event: "UserInputRequest" }));
    expect((await sessionRow(key(id)))?.state).toBe("waiting_input");

    const beat = await postEvent(payload({ session_id: id, event: "PostToolUse" }));
    expect(beat.json.state).toBe("waiting_input");
    expect((await sessionRow(key(id)))?.state).toBe("waiting_input");

    const resolved = await postEvent(payload({ session_id: id, event: "UserInputResolved" }));
    expect(resolved.json.state).toBe("working");
  });

  it("state_field_allowed=false: 요청이 state를 실어도 무시되고 표대로만 판정한다", async () => {
    const id = "ses_state_field";
    const prompt = await postEvent(payload({ session_id: id, state: "ended" }));
    expect(prompt.json.state).toBe("working");
    const stop = await postEvent(payload({ session_id: id, event: "Stop", state: "waiting_input" }));
    expect(stop.json.state).toBe("done");
  });
});
