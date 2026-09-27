import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "./worker";
import { runDashboardMaintenance, type MaintenanceEnv } from "../src/dashboard/maintenance";
import { authHeaders, pushStates, statesEnum } from "./fixtures";

// 수집 정합성(POST /dashboard/events) 테스트.
// mock 없이 실제 워커(src/index.ts)의 default export를 직접 호출한다. 인증 미들웨어·라우팅·
// D1 쓰기·waitUntil 발송까지 배포되는 코드 그대로 돈다.
//
// dashboard.test.ts처럼 cloudflare:workers의 `exports`로 부르지 않는 이유: 그 경로는 워커를
// 자기 자신에게 다시 태우기 때문에 넘긴 env와 ExecutionContext를 무시하고 바인딩 원본을 쓴다.
// 그러면 (a) env 하나만 바꿔 보는 테스트(DASHBOARD_STORE_MESSAGE=0)가 불가능하고
// (b) waitOnExecutionContext가 실제 waitUntil을 기다리지 못해 push 발송 흔적을 볼 수 없다.
// 직접 import는 둘 다 존중한다(@cloudflare/vitest-pool-workers의 unit test 방식).
const app = worker as unknown as {
  fetch(request: Request, env: unknown, ctx: ExecutionContext): Response | Promise<Response>;
};

interface TestEnv {
  DB: D1Database;
}
const testEnv = env as unknown as TestEnv;

interface IngestResponse {
  ok?: boolean;
  duplicate?: boolean;
  state?: string | null;
  transition_id?: number | null;
  push?: string;
  accepted?: string;
  reason?: string;
  error?: string;
}

/** 이벤트 발생 시각의 기준점. 테스트마다 여기에 오프셋을 더해 순서를 만든다. */
const T0 = Date.UTC(2026, 8, 8, 9, 0, 0);

let seq = 0;

/**
 * 요청 본문 한 벌. event_id·occurred_at은 매번 새로 만든다.
 * (멱등·순서 규칙을 시험하는 테스트만 이 둘을 명시적으로 고정한다.)
 */
function payload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  seq += 1;
  return {
    protocol_version: 1,
    source: "claude-code",
    session_id: "session",
    project: "/workspace/example",
    host: "example-host",
    event: "SessionStart",
    event_id: `evt-${seq}`,
    occurred_at: T0 + seq * 1000,
    ...overrides,
  };
}

async function postEvent(
  body: Record<string, unknown>,
  envOverrides: Record<string, unknown> = {},
): Promise<{ status: number; json: IngestResponse }> {
  const ctx = createExecutionContext();
  const request = new Request("http://dashboard.test/dashboard/events", {
    method: "POST",
    headers: { "content-type": "application/json", ...authHeaders() },
    body: JSON.stringify(body),
  });
  const response = await app.fetch(request, { ...env, ...envOverrides }, ctx);
  // waitUntil로 예약된 push 발송까지 끝나야 dashboard_push_log·notified_at을 볼 수 있다.
  await waitOnExecutionContext(ctx);
  return { status: response.status, json: (await response.json()) as IngestResponse };
}

async function count(sql: string, ...binds: unknown[]): Promise<number> {
  const row = await testEnv.DB.prepare(sql).bind(...binds).first<{ n: number }>();
  return Number(row?.n ?? 0);
}

async function sessionRow(key: string) {
  return testEnv.DB.prepare(
    "SELECT state, host, last_event, last_message, last_occurred_at, last_progress_at FROM dashboard_sessions WHERE key = ?",
  )
    .bind(key)
    .first<{
      state: string;
      host: string | null;
      last_event: string;
      last_message: string | null;
      last_occurred_at: number | null;
      last_progress_at: number | null;
    }>();
}

const transitionsOf = (key: string) =>
  count("SELECT COUNT(*) AS n FROM dashboard_transitions WHERE session_key = ?", key);
const eventsOf = (key: string) =>
  count("SELECT COUNT(*) AS n FROM dashboard_events WHERE session_key = ?", key);

describe("멱등: 같은 event_id는 한 번만 반영된다", () => {
  it("같은 event_id를 두 번 보내면 events 1행·transitions 1행이고 두 번째는 duplicate:true", async () => {
    const key = "claude-code:idem";
    const body = payload({ session_id: "idem", event: "Notification", event_id: "fixed-idem-1" });

    const first = await postEvent(body);
    expect(first.status).toBe(200);
    expect(first.json.state).toBe("waiting_input");
    // RETURNING id가 실제 커서 값을 돌려준다는 증거. 0이면 전이 id를 못 받은 것이다.
    expect(first.json.transition_id).toBeGreaterThan(0);
    expect(first.json.push).toBe("queued");

    const second = await postEvent(body);
    expect(second.status).toBe(200);
    expect(second.json).toEqual({ ok: true, duplicate: true });

    expect(await count("SELECT COUNT(*) AS n FROM dashboard_events WHERE event_id = ?", "fixed-idem-1")).toBe(1);
    expect(await transitionsOf(key)).toBe(1);
  });

  it("event_id가 없는 요청은 멱등 대상이 아니라 매번 새 이벤트로 쌓인다", async () => {
    const key = "claude-code:noid";
    const body = payload({ session_id: "noid", event: "SessionStart" });
    delete body.event_id;

    await postEvent(body);
    await postEvent(body);

    expect(await eventsOf(key)).toBe(2);
    // 상태는 같은 idle 재진입이라 전이는 한 줄뿐이다.
    expect(await transitionsOf(key)).toBe(1);
  });
});

describe("순서 역행 방어: 과거가 현재를 덮어쓰지 못한다", () => {
  it("occurred_at이 last_occurred_at보다 과거면 이벤트만 기록되고 상태는 그대로다", async () => {
    const key = "claude-code:order";
    await postEvent(payload({ session_id: "order", event: "SessionStart", occurred_at: T0 + 100_000 }));
    expect((await sessionRow(key))?.state).toBe("idle");

    // 스풀에 밀려 있다가 뒤늦게 도착한 과거 이벤트.
    const late = await postEvent(
      payload({ session_id: "order", event: "UserPromptSubmit", occurred_at: T0 + 50_000 }),
    );
    expect(late.status).toBe(200);
    expect(late.json.state).toBe("idle"); // working으로 바뀌지 않았다
    expect(late.json.transition_id).toBeNull();
    expect(late.json.push).toBe("none");

    const row = await sessionRow(key);
    expect(row?.state).toBe("idle");
    expect(row?.last_occurred_at).toBe(T0 + 100_000);
    expect(await eventsOf(key)).toBe(2); // 기록은 남는다
    expect(await transitionsOf(key)).toBe(1);
  });
});

describe("ended 불변식", () => {
  it("ended 세션에 늦게 도착한 Stop은 상태를 되돌리지 못한다", async () => {
    const key = "claude-code:ended";
    for (const event of ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"]) {
      await postEvent(payload({ session_id: "ended", event }));
    }
    expect((await sessionRow(key))?.state).toBe("ended");
    const before = await transitionsOf(key);

    // occurred_at은 더 미래다. 막는 이유가 순서가 아니라 ended 불변식이라는 뜻이다.
    const late = await postEvent(payload({ session_id: "ended", event: "Stop", occurred_at: T0 + 900_000 }));
    expect(late.json.state).toBe("ended");
    expect(late.json.transition_id).toBeNull();
    expect(late.json.push).toBe("none");
    expect(await transitionsOf(key)).toBe(before);
    expect((await sessionRow(key))?.state).toBe("ended");
  });

  it("ended 세션은 SessionStart로만 되살아난다", async () => {
    const key = "claude-code:revive";
    for (const event of ["SessionStart", "Stop", "SessionEnd"]) {
      await postEvent(payload({ session_id: "revive", event }));
    }
    expect((await sessionRow(key))?.state).toBe("ended");

    const revived = await postEvent(payload({ session_id: "revive", event: "SessionStart", occurred_at: T0 + 800_000 }));
    expect(revived.json.state).toBe("idle");
    expect(revived.json.transition_id).toBeGreaterThan(0);

    const last = await testEnv.DB.prepare(
      "SELECT from_state, to_state FROM dashboard_transitions WHERE session_key = ? ORDER BY id DESC LIMIT 1",
    )
      .bind(key)
      .first<{ from_state: string; to_state: string }>();
    expect(last).toEqual({ from_state: "ended", to_state: "idle" });
  });
});

describe("전이는 상태가 실제로 바뀔 때만 쌓인다", () => {
  it("Stop 연타(같은 상태 재진입)는 전이도 push도 만들지 않는다", async () => {
    const key = "claude-code:restop";
    await postEvent(payload({ session_id: "restop", event: "SessionStart" }));
    await postEvent(payload({ session_id: "restop", event: "UserPromptSubmit" }));

    const first = await postEvent(payload({ session_id: "restop", event: "Stop" }));
    expect(first.json.state).toBe("done");
    // done은 push_states.enum에 없다 - 전이 자체는 쌓이지만 발송은 없다.
    expect(first.json.push).toBe("none");
    const transitionId = first.json.transition_id!;
    expect(transitionId).toBeGreaterThan(0);

    const transitionsBefore = await transitionsOf(key);
    const pushLogBefore = await count("SELECT COUNT(*) AS n FROM dashboard_push_log");

    const second = await postEvent(payload({ session_id: "restop", event: "Stop" }));
    expect(second.json.state).toBe("done");
    expect(second.json.transition_id).toBeNull();
    expect(second.json.push).toBe("none");

    expect(await transitionsOf(key)).toBe(transitionsBefore);
    expect(await count("SELECT COUNT(*) AS n FROM dashboard_push_log")).toBe(pushLogBefore);
    expect(await eventsOf(key)).toBe(4); // 이벤트 로그에는 네 줄 다 남는다
  });

  // 회귀 방지: done은 계약상 "턴 실행을 마쳤다"일 뿐인데,
  // 백그라운드 서브에이전트가 계속 일하면 heartbeat.ts의 조건부 승격이 곧바로
  // working으로 되돌려 "끝났다" 알림 직후 "진행 중"이 이어지는 소음이 있었다.
  // push_states.enum에서 done을 뺀 결정이 되돌아가지 않는지 명시적으로 확인한다.
  it("done 전이는 쌓이지만 push는 만들지 않는다(push_states에서 제외됨)", async () => {
    expect(pushStates()).not.toContain("done");

    const key = "claude-code:done-no-push";
    await postEvent(payload({ session_id: "done-no-push", event: "SessionStart" }));
    await postEvent(payload({ session_id: "done-no-push", event: "UserPromptSubmit" }));

    const stop = await postEvent(payload({ session_id: "done-no-push", event: "Stop" }));
    expect(stop.json.state).toBe("done");
    expect(stop.json.push).toBe("none");
    const transitionId = stop.json.transition_id!;
    expect(transitionId).toBeGreaterThan(0); // 전이 자체는 여전히 쌓인다.

    // dispatchPush가 아예 불리지 않았다는 뜻이다 - 로그도 notified_at도 없다.
    expect(
      await count("SELECT COUNT(*) AS n FROM dashboard_push_log WHERE transition_id = ?", transitionId),
    ).toBe(0);
    const row = await testEnv.DB.prepare("SELECT notified_at FROM dashboard_transitions WHERE id = ?")
      .bind(transitionId)
      .first<{ notified_at: number | null }>();
    expect(row?.notified_at).toBeNull();
    expect(await transitionsOf(key)).toBe(3); // SessionStart/UserPromptSubmit/Stop 세 전이 모두 쌓인다.
  });

  it("push 대상 상태로 전이하면 dispatch가 실제로 불린다 (push 로그 + notified_at)", async () => {
    const key = "claude-code:dispatch";
    const { json } = await postEvent(payload({ session_id: "dispatch", event: "Notification" }));
    expect(pushStates()).toContain(json.state!);
    const transitionId = json.transition_id!;

    // 테스트 환경에는 FCM_SERVICE_ACCOUNT가 없으므로 결과는 skipped다. 중요한 건
    // "dispatchPush가 이 전이를 근거로 실제로 불렸다"는 사실이고, 그 흔적이 이 두 줄이다.
    const logged = await testEnv.DB.prepare(
      "SELECT transport, result FROM dashboard_push_log WHERE transition_id = ?",
    )
      .bind(transitionId)
      .first<{ transport: string; result: string }>();
    expect(logged).not.toBeNull();

    const notified = await testEnv.DB.prepare(
      "SELECT notified_at FROM dashboard_transitions WHERE id = ?",
    )
      .bind(transitionId)
      .first<{ notified_at: number | null }>();
    expect(notified?.notified_at).toBeGreaterThan(0);

    // push 대상이 아닌 전이(working)는 발송을 시도하지 않는다.
    const working = await postEvent(payload({ session_id: "dispatch", event: "UserPromptSubmit" }));
    expect(working.json.push).toBe("none");
    expect(
      await count("SELECT COUNT(*) AS n FROM dashboard_push_log WHERE transition_id = ?", working.json.transition_id),
    ).toBe(0);
    expect(await transitionsOf(key)).toBe(2);
  });
});

describe("소스 어댑터", () => {
  it("미등록 source는 202 + raw 보존, 세션·전이는 만들지 않는다", async () => {
    const key = "my-own-agent:unknown";
    const { status, json } = await postEvent(
      payload({ source: "my-own-agent", session_id: "unknown", event: "whatever", message: "안녕" }),
    );
    expect(status).toBe(202);
    expect(json).toEqual({ accepted: "logged", reason: "unknown_source" });

    const row = await testEnv.DB.prepare(
      "SELECT raw, host, occurred_at FROM dashboard_events WHERE session_key = ?",
    )
      .bind(key)
      .first<{ raw: string; host: string | null; occurred_at: number }>();
    expect(row?.host).toBe("example-host");
    expect(JSON.parse(row!.raw)).toMatchObject({ source: "my-own-agent", event: "whatever", message: "안녕" });

    expect(await sessionRow(key)).toBeNull();
    expect(await transitionsOf(key)).toBe(0);
  });

  it("generic이 state='waiting_input'을 보내면 서버 배포 없이 세션이 등장한다", async () => {
    const key = "generic:ci-42";
    const { status, json } = await postEvent(
      payload({
        source: "generic",
        session_id: "ci-42",
        event: "deploy-approval-needed", // generic은 이벤트 어휘가 자유다
        state: "waiting_input",
      }),
    );
    expect(status).toBe(200);
    expect(json.state).toBe("waiting_input");
    expect(json.push).toBe("queued");
    expect((await sessionRow(key))?.state).toBe("waiting_input");
    expect(await transitionsOf(key)).toBe(1);
  });

  it("generic이 state를 빼면 기록만 되고 상태는 안 생긴다", async () => {
    const key = "generic:no-state";
    const { status, json } = await postEvent(
      payload({ source: "generic", session_id: "no-state", event: "heartbeat-ish" }),
    );
    expect(status).toBe(200);
    expect(json.state).toBeNull();
    expect(await eventsOf(key)).toBe(1);
    expect(await sessionRow(key)).toBeNull();
  });

  it("generic이 파생 상태 stalled를 신고하면 400이고 아무것도 적재하지 않는다", async () => {
    const key = "generic:fake-stall";
    const { status } = await postEvent(
      payload({ source: "generic", session_id: "fake-stall", event: "x", state: "stalled" }),
    );
    expect(status).toBe(400);
    expect(await eventsOf(key)).toBe(0);

    const bogus = await postEvent(
      payload({ source: "generic", session_id: "fake-stall", event: "x", state: "not-a-state" }),
    );
    expect(bogus.status).toBe(400);
  });

  it("codex 어휘(PermissionRequest)는 codex에서만 상태를 바꾼다", async () => {
    const codex = await postEvent(payload({ source: "codex", session_id: "perm", event: "PermissionRequest" }));
    expect(codex.json.state).toBe("waiting_input");

    // 같은 이벤트 이름을 claude-code로 보내면 그쪽 표에 없으므로 상태가 생기지 않는다.
    const claude = await postEvent(payload({ source: "claude-code", session_id: "perm", event: "PermissionRequest" }));
    expect(claude.json.state).toBeNull();
    expect(await sessionRow("claude-code:perm")).toBeNull();
  });

  it("state_field_allowed=false인 소스가 보낸 state는 무시된다", async () => {
    const key = "claude-code:ignore-state";
    await postEvent(payload({ session_id: "ignore-state", event: "SessionStart" }));
    const { json } = await postEvent(
      payload({ session_id: "ignore-state", event: "PostToolUse", state: "done" }),
    );
    // done으로 지어내진 않았지만(B는 idle -> working만 되돌린다), idle에서 온 heartbeat라
    // 가드 5종을 다 통과해 working으로 승격된다(payload()가 매번 occurred_at을 명시하고
    // 순증시키므로 가드3·가드4가 자동으로 만족된다).
    expect(json.state).toBe("working");
    expect((await sessionRow(key))?.state).toBe("working");
  });

  it("heartbeat(PostToolUse)는 상태를 두고 last_occurred_at과 last_progress_at을 민다", async () => {
    const key = "claude-code:beat";
    await postEvent(payload({ session_id: "beat", event: "UserPromptSubmit", occurred_at: T0 + 10_000 }));
    const afterPrompt = await sessionRow(key);
    const progressAfterPrompt = afterPrompt?.last_progress_at ?? 0;

    const beat = await postEvent(payload({ session_id: "beat", event: "PostToolUse", occurred_at: T0 + 20_000 }));
    expect(beat.json.state).toBe("working");

    let row = await sessionRow(key);
    expect(row?.state).toBe("working");
    expect(row?.last_occurred_at).toBe(T0 + 20_000); // 순서 역행 방어 기준(클라이언트 시계)이 미뤄졌다
    // last_progress_at은 서버 수신 시각이다(진척 이벤트라 now로 갱신됐다) - stalled 판정이 이 값을 쓴다.
    expect(row?.last_progress_at).toBeGreaterThanOrEqual(progressAfterPrompt);

    const progressAfterBeat = row?.last_progress_at ?? 0;

    // heartbeat도 매핑도 아닌 이벤트(기록-전용)는 last_occurred_at도 last_progress_at도 밀지 않는다
    // (A안 원칙: 유휴/기록만 되는 이벤트가 stalled 판정을 미루면 안 된다).
    await postEvent(payload({ session_id: "beat", event: "PreToolUse", occurred_at: T0 + 30_000 }));
    row = await sessionRow(key);
    expect(row?.last_occurred_at).toBe(T0 + 20_000);
    expect(row?.last_progress_at).toBe(progressAfterBeat);
    expect(row?.last_event).toBe("PreToolUse");
  });
});

describe("B: PostToolUse 조건부 승격(heartbeat.ts의 resolveHeartbeatPromotion)", () => {
  it("done에서도 working으로 승격된다", async () => {
    const key = "claude-code:from-done";
    await postEvent(payload({ session_id: "from-done", event: "SessionStart" }));
    await postEvent(payload({ session_id: "from-done", event: "UserPromptSubmit" }));
    await postEvent(payload({ session_id: "from-done", event: "Stop" }));
    expect((await sessionRow(key))?.state).toBe("done");

    const beat = await postEvent(payload({ session_id: "from-done", event: "PostToolUse" }));
    expect(beat.json.state).toBe("working");
    expect(beat.json.push).toBe("none"); // working은 push 대상이 아니다 - 조용한 상태 보정
    expect(beat.json.transition_id).toBeGreaterThan(0);
    expect((await sessionRow(key))?.state).toBe("working");
  });

  it("stalled에서도 working으로 승격된다(cron이 만든 stalled를 실사용 하트비트가 되돌린다)", async () => {
    const key = "claude-code:from-stalled";
    await postEvent(payload({ session_id: "from-stalled", event: "SessionStart", occurred_at: T0 }));
    await postEvent(payload({ session_id: "from-stalled", event: "UserPromptSubmit", occurred_at: T0 + 1000 }));
    // cron이 만드는 stalled는 정상 ingest 경로로는 도달할 수 없다(DERIVED_STATES) - 직접 SQL로 흉내낸다.
    await testEnv.DB.prepare("UPDATE dashboard_sessions SET state = 'stalled', last_occurred_at = ? WHERE key = ?")
      .bind(T0 + 2000, key)
      .run();
    expect((await sessionRow(key))?.state).toBe("stalled");

    const beat = await postEvent(
      payload({ session_id: "from-stalled", event: "PostToolUse", occurred_at: T0 + 5000 }),
    );
    expect(beat.json.state).toBe("working");
    expect(beat.json.push).toBe("none");
    const row = await sessionRow(key);
    expect(row?.state).toBe("working");
    expect(row?.last_occurred_at).toBe(T0 + 5000);

    const transition = await testEnv.DB.prepare(
      "SELECT from_state, to_state FROM dashboard_transitions WHERE session_key = ? ORDER BY id DESC LIMIT 1",
    )
      .bind(key)
      .first<{ from_state: string; to_state: string }>();
    expect(transition).toEqual({ from_state: "stalled", to_state: "working" });
  });

  it("가드1: 세션 행이 없으면 PostToolUse가 세션을 만들지도, 승격하지도 않는다", async () => {
    const key = "claude-code:no-row";
    const { json } = await postEvent(payload({ session_id: "no-row", event: "PostToolUse" }));
    expect(json.state).toBeNull();
    expect(await sessionRow(key)).toBeNull();
  });

  it("가드2: ended 세션은 PostToolUse로도 승격되지 않는다", async () => {
    const key = "claude-code:ended-beat";
    for (const event of ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"]) {
      await postEvent(payload({ session_id: "ended-beat", event }));
    }
    expect((await sessionRow(key))?.state).toBe("ended");

    const beat = await postEvent(payload({ session_id: "ended-beat", event: "PostToolUse" }));
    expect(beat.json.state).toBe("ended");
    expect((await sessionRow(key))?.state).toBe("ended");
  });

  it("가드3: occurred_at 미명시 PostToolUse는 승격하지 않는다(수신 시각 대체는 strict 비교를 무의미하게 만든다)", async () => {
    const key = "claude-code:no-ts";
    await postEvent(payload({ session_id: "no-ts", event: "SessionStart" }));
    const withoutTs = payload({ session_id: "no-ts", event: "PostToolUse" });
    delete withoutTs.occurred_at;

    const { json } = await postEvent(withoutTs);
    expect(json.state).toBe("idle"); // working으로 승격되지 않았다
    expect((await sessionRow(key))?.state).toBe("idle");
  });

  it("가드4: occurred_at이 last_occurred_at과 같으면(동률) strict greater 실패로 승격하지 않는다", async () => {
    const key = "claude-code:tie";
    const start = await postEvent(
      payload({ session_id: "tie", event: "SessionStart", occurred_at: T0 + 500_000 }),
    );
    expect(start.json.state).toBe("idle");

    const tie = await postEvent(
      payload({ session_id: "tie", event: "PostToolUse", occurred_at: T0 + 500_000 }),
    );
    expect(tie.json.state).toBe("idle"); // 동률은 strict greater 실패 - 승격 없음
    const row = await sessionRow(key);
    expect(row?.state).toBe("idle");
    expect(row?.last_occurred_at).toBe(T0 + 500_000); // last_occurred_at 자체의 >= 갱신 규칙은 별개다
  });

  it("가드5: waiting_input 세션은 PostToolUse 하트비트로 승격되지 않는다(F의 UserInputResolved만 해소한다)", async () => {
    const key = "claude-code:approve-wait";
    await postEvent(payload({ session_id: "approve-wait", event: "SessionStart" }));
    await postEvent(payload({ session_id: "approve-wait", event: "Notification" })); // -> waiting_input
    expect((await sessionRow(key))?.state).toBe("waiting_input");

    const beat = await postEvent(payload({ session_id: "approve-wait", event: "PostToolUse" }));
    // 승격되지 않았다 - 백그라운드 서브에이전트의 하트비트가 부모 session_key로 도착해도
    // 승인 대기를 가리면 안 된다(놓친 승인 방지).
    expect(beat.json.state).toBe("waiting_input");
    expect((await sessionRow(key))?.state).toBe("waiting_input");
  });
});

describe("시계 불변식: occurred_at 서버 클램프 삭제 회귀", () => {
  // 원리: 순서 판정(역행 방어·승격 가드)은 같은 세션 = 같은 기계 시계라 원본 occurred_at이
  // 자기 일관적이다(states.invariants) - 클라이언트 시계가 서버보다 아무리 빠르거나 느려도,
  // 그 세션 안의 이벤트들끼리는 여전히 올바른 상대 순서를 가진다. 서버는 이제 occurred_at을
  // 전혀 고치지 않는다(clampOccurredAt 삭제) - 이 블록은 그 삭제 이후에도 (a) 순서 역행
  // 방어가 빠른/느린 시계 양쪽에서 그대로 동작하고, (b) stalled 판정(last_progress_at, 서버
  // 시계)은 클라이언트 시계와 완전히 무관하다는 것을 잠근다.

  it("빠른 클라이언트 시계: occurred_at이 서버 시각보다 훨씬 미래여도 고쳐지지 않고 그대로 저장된다", async () => {
    const key = "claude-code:fast-clock";
    const fastOffset = 50_000_000; // 실제 시계보다 한참 앞선 클라이언트(예: 시계 오조정)
    const farFuture = Date.now() + fastOffset;
    const { json } = await postEvent(
      payload({ session_id: "fast-clock", event: "SessionStart", occurred_at: farFuture }),
    );
    expect(json.state).toBe("idle");
    const row = await sessionRow(key);
    // 서버가 고치지 않는다 - 클램프 삭제 전이라면 Date.now() 근방으로 깎였을 값이 원본 그대로다.
    expect(row?.last_occurred_at).toBe(farFuture);
  });

  it("빠른 클라이언트 시계에서도 순서 역행 방어는 원본 occurred_at끼리 그대로 동작한다", async () => {
    const key = "claude-code:fast-order";
    const fastOffset = 50_000_000;
    const first = T0 + fastOffset + 100_000;
    await postEvent(payload({ session_id: "fast-order", event: "SessionStart", occurred_at: first }));
    expect((await sessionRow(key))?.last_occurred_at).toBe(first);

    // 같은 세션의 더 이른 시각(여전히 빠른 시계 오프셋 안) - 자기들끼리는 순서가 보존된다.
    const earlier = T0 + fastOffset + 50_000;
    const { json } = await postEvent(
      payload({ session_id: "fast-order", event: "UserPromptSubmit", occurred_at: earlier }),
    );
    expect(json.state).toBe("idle"); // working으로 바뀌지 않았다 - 과거 취급됐다
    expect(json.transition_id).toBeNull();
    expect((await sessionRow(key))?.last_occurred_at).toBe(first); // 원본이 그대로 남아 있다
  });

  it("느린 클라이언트 시계: occurred_at이 서버 시각보다 한참 과거여도 고쳐지지 않고 그대로 저장된다", async () => {
    const key = "claude-code:slow-clock";
    const slowOffset = -50_000_000; // 실제 시계보다 한참 뒤처진 클라이언트
    const farPast = T0 + slowOffset;
    const { json } = await postEvent(
      payload({ session_id: "slow-clock", event: "SessionStart", occurred_at: farPast }),
    );
    expect(json.state).toBe("idle");
    expect((await sessionRow(key))?.last_occurred_at).toBe(farPast);
  });

  it("느린 클라이언트 시계에서도 순서 역행 방어는 원본 occurred_at끼리 그대로 동작한다", async () => {
    const key = "claude-code:slow-order";
    const slowOffset = -50_000_000;
    const first = T0 + slowOffset + 100_000;
    await postEvent(payload({ session_id: "slow-order", event: "SessionStart", occurred_at: first }));
    expect((await sessionRow(key))?.last_occurred_at).toBe(first);

    const earlier = T0 + slowOffset + 50_000;
    const { json } = await postEvent(
      payload({ session_id: "slow-order", event: "UserPromptSubmit", occurred_at: earlier }),
    );
    expect(json.state).toBe("idle");
    expect(json.transition_id).toBeNull();
    expect((await sessionRow(key))?.last_occurred_at).toBe(first);
  });

  it("stalled 판정은 클라이언트 시계 스큐(빠름/느림)와 무관하다 - last_progress_at(서버 시계)만 본다", async () => {
    const fastKey = "claude-code:skew-stall-fast";
    const slowKey = "claude-code:skew-stall-slow";
    const fastOffset = 365 * 24 * 60 * 60 * 1000; // 1년 앞선 시계
    const slowOffset = -365 * 24 * 60 * 60 * 1000; // 1년 뒤처진 시계

    await postEvent(payload({ session_id: "skew-stall-fast", event: "SessionStart", occurred_at: Date.now() + fastOffset }));
    await postEvent(
      payload({ session_id: "skew-stall-fast", event: "UserPromptSubmit", occurred_at: Date.now() + fastOffset + 1000 }),
    );
    await postEvent(payload({ session_id: "skew-stall-slow", event: "SessionStart", occurred_at: Date.now() + slowOffset }));
    await postEvent(
      payload({ session_id: "skew-stall-slow", event: "UserPromptSubmit", occurred_at: Date.now() + slowOffset + 1000 }),
    );
    expect((await sessionRow(fastKey))?.state).toBe("working");
    expect((await sessionRow(slowKey))?.state).toBe("working");

    // "6초 조용했다"를 서버 시계(last_progress_at)로만 흉내 낸다 - occurred_at은 건드리지 않는다.
    await testEnv.DB.prepare("UPDATE dashboard_sessions SET last_progress_at = ? WHERE key IN (?, ?)")
      .bind(Date.now() - 6000, fastKey, slowKey)
      .run();

    const maintenanceEnv = { ...(env as unknown as MaintenanceEnv), DASHBOARD_STALL_MS: "5000" };
    await runDashboardMaintenance(maintenanceEnv, Date.now());

    // 두 세션 다 stalled로 전이한다 - 극단적인 시계 스큐가 있어도 서버 시계 기준 판정은 그대로다.
    expect((await sessionRow(fastKey))?.state).toBe("stalled");
    expect((await sessionRow(slowKey))?.state).toBe("stalled");
  });
});

describe("프라이버시: DASHBOARD_STORE_MESSAGE=0은 raw 안에 중첩된 message도 지운다", () => {
  it("훅이 raw에 실어 보낸 원본 stdin(JSON 문자열)을 파싱해 그 안의 message도 지운다", async () => {
    const key = "claude-code:nested-secret";
    const secret = "실제 비밀 메시지 hunter2";
    // agent-event-hook.sh가 실제로 만드는 모양을 흉내낸다: CORE_PAYLOAD(message는 이미 다듬어진
    // 값) + raw(원본 stdin 전체를 담은 JSON 문자열 - 그 안에도 message가 그대로 있다).
    const nestedStdin = JSON.stringify({
      hook_event_name: "Notification",
      session_id: "nested-secret",
      message: secret,
    });
    const body = payload({
      session_id: "nested-secret",
      event: "Notification",
      message: secret,
      raw: nestedStdin,
    });
    const { status } = await postEvent(body, { DASHBOARD_STORE_MESSAGE: "0" });
    expect(status).toBe(200);

    const row = await testEnv.DB.prepare("SELECT raw, message FROM dashboard_events WHERE session_key = ?")
      .bind(key)
      .first<{ raw: string; message: string | null }>();
    expect(row?.message).toBeNull();
    expect(row?.raw).not.toContain("hunter2"); // 최상위뿐 아니라 raw 안에 중첩된 값도 지워졌다

    const parsedRaw = JSON.parse(row!.raw) as { raw: string };
    expect(parsedRaw.raw).toBeUndefined(); // Original payload is omitted entirely.
  });

  it("raw 안 문자열이 조각난 JSON이라 못 읽으면 안전하게 그 필드째 지운다", async () => {
    const key = "claude-code:nested-broken";
    const secret = "hunter2-깨진-원본";
    const body = payload({
      session_id: "nested-broken",
      event: "Notification",
      message: "정상 메시지",
      raw: `{"message":"${secret}", "trunca`, // 일부러 깨뜨린 JSON(4096바이트 절단을 흉내)
    });
    const { status } = await postEvent(body, { DASHBOARD_STORE_MESSAGE: "0" });
    expect(status).toBe(200);

    const row = await testEnv.DB.prepare("SELECT raw FROM dashboard_events WHERE session_key = ?")
      .bind(key)
      .first<{ raw: string }>();
    expect(row?.raw).not.toContain("hunter2");
    const parsedRaw = JSON.parse(row!.raw) as { raw: unknown };
    expect(parsedRaw.raw).toBeUndefined(); // Original payload is omitted entirely.
  });

  it("F(codex request_user_input)의 질문 문구(header/question)도 raw 안에서 지운다", async () => {
    // agent-event-hook.sh의 first_question_text가 뽑는 원본 위치를 흉내낸다:
    // .tool_input.questions[0].header // .tool_input.questions[0].question (검증 리뷰 지적, medium).
    const key = "codex:nested-question";
    const secretHeader = "hunter2-plan-header";
    const secretQuestion = "hunter2-plan-question-detail";
    const nestedStdin = JSON.stringify({
      hook_event_name: "PreToolUse",
      session_id: "nested-question",
      tool_name: "request_user_input",
      tool_input: {
        questions: [{ header: secretHeader, question: secretQuestion }],
      },
    });
    const body = payload({
      source: "codex",
      session_id: "nested-question",
      event: "UserInputRequest",
      message: secretHeader,
      raw: nestedStdin,
    });
    const { status } = await postEvent(body, { DASHBOARD_STORE_MESSAGE: "0" });
    expect(status).toBe(200);

    const row = await testEnv.DB.prepare("SELECT raw, message FROM dashboard_events WHERE session_key = ?")
      .bind(key)
      .first<{ raw: string; message: string | null }>();
    expect(row?.message).toBeNull();
    expect(row?.raw).not.toContain("hunter2");

    const parsedRaw = JSON.parse(row!.raw) as { raw: string };
    expect(parsedRaw.raw).toBeUndefined();
  });
});

describe("F: codex request_user_input 합성 이벤트(UserInputRequest/UserInputResolved)", () => {
  it("UserInputRequest -> waiting_input, UserInputResolved -> working로 이어진다", async () => {
    const key = "codex:req-input";
    await postEvent(payload({ source: "codex", session_id: "req-input", event: "SessionStart" }));
    await postEvent(payload({ source: "codex", session_id: "req-input", event: "UserPromptSubmit" }));

    const req = await postEvent(payload({ source: "codex", session_id: "req-input", event: "UserInputRequest" }));
    expect(req.json.state).toBe("waiting_input");
    expect(req.json.push).toBe("queued");

    const resolved = await postEvent(
      payload({ source: "codex", session_id: "req-input", event: "UserInputResolved" }),
    );
    expect(resolved.json.state).toBe("working");
    expect((await sessionRow(key))?.state).toBe("working");
  });

  it("claude-code에는 이 두 이벤트가 매핑돼 있지 않아 상태를 바꾸지 않는다", async () => {
    const key = "claude-code:req-input-cc";
    await postEvent(payload({ session_id: "req-input-cc", event: "SessionStart" }));
    const req = await postEvent(payload({ session_id: "req-input-cc", event: "UserInputRequest" }));
    expect(req.json.state).toBe("idle"); // 매핑에 없으니 그대로다(기록만 된다)
    expect((await sessionRow(key))?.state).toBe("idle");
  });

  it("B(비특정 하트비트)와 달리 F(UserInputResolved)는 waiting_input을 직접 해소한다", async () => {
    const key = "codex:f-vs-b";
    await postEvent(payload({ source: "codex", session_id: "f-vs-b", event: "SessionStart" }));
    await postEvent(payload({ source: "codex", session_id: "f-vs-b", event: "UserInputRequest" }));
    expect((await sessionRow(key))?.state).toBe("waiting_input");

    // 가드5: 비특정 하트비트(PostToolUse)는 waiting_input을 승격하지 못한다.
    const beat = await postEvent(payload({ source: "codex", session_id: "f-vs-b", event: "PostToolUse" }));
    expect(beat.json.state).toBe("waiting_input");

    // 반면 전용 해소 이벤트(UserInputResolved)는 대기와 1:1 근거를 가지므로 곧장 해소한다.
    const resolved = await postEvent(payload({ source: "codex", session_id: "f-vs-b", event: "UserInputResolved" }));
    expect(resolved.json.state).toBe("working");
    expect((await sessionRow(key))?.state).toBe("working");
  });
});

describe("페이로드 검증", () => {
  it("protocol_version 99는 400 {error:'unsupported protocol_version'}", async () => {
    const { status, json } = await postEvent(payload({ session_id: "v99", protocol_version: 99 }));
    expect(status).toBe(400);
    expect(json.error).toBe("unsupported protocol_version");
    expect(await eventsOf("claude-code:v99")).toBe(0);
  });

  it("protocol_version이 없거나 정수가 아니면 400", async () => {
    const missing = payload({ session_id: "vnone" });
    delete missing.protocol_version;
    expect((await postEvent(missing)).status).toBe(400);
    expect((await postEvent(payload({ session_id: "vstr", protocol_version: "1" }))).status).toBe(400);
    expect((await postEvent(payload({ session_id: "vfloat", protocol_version: 1.5 }))).status).toBe(400);
  });

  it("occurred_at이 정수가 아니면 400 (잘못된 시각은 순서 방어를 망가뜨린다)", async () => {
    const { status } = await postEvent(payload({ session_id: "badts", occurred_at: "1757300000000" }));
    expect(status).toBe(400);
    expect(await eventsOf("claude-code:badts")).toBe(0);
  });

  it("raw는 4096바이트로 잘려 저장되고 message는 300자로 잘린다", async () => {
    const key = "claude-code:big";
    await postEvent(
      payload({ session_id: "big", event: "Notification", message: "가".repeat(1000), note: "x".repeat(9000) }),
    );
    const row = await testEnv.DB.prepare("SELECT raw, message FROM dashboard_events WHERE session_key = ?")
      .bind(key)
      .first<{ raw: string; message: string }>();
    expect(new TextEncoder().encode(row!.raw).length).toBeLessThanOrEqual(4096);
    expect(row!.message.length).toBe(300);
    expect((await sessionRow(key))?.last_message?.length).toBe(300);
  });

  it("DASHBOARD_STORE_MESSAGE=0이면 message가 프로젝션에도 raw에도 남지 않는다", async () => {
    const key = "claude-code:nomsg";
    const secret = "비밀번호는 hunter2 입니다";
    const { status } = await postEvent(
      payload({ session_id: "nomsg", event: "Notification", message: secret }),
      { DASHBOARD_STORE_MESSAGE: "0" },
    );
    expect(status).toBe(200);

    const row = await testEnv.DB.prepare("SELECT raw, message FROM dashboard_events WHERE session_key = ?")
      .bind(key)
      .first<{ raw: string; message: string | null }>();
    expect(row?.message).toBeNull();
    expect(row?.raw).not.toContain("hunter2");

    const transition = await testEnv.DB.prepare(
      "SELECT message FROM dashboard_transitions WHERE session_key = ?",
    )
      .bind(key)
      .first<{ message: string | null }>();
    expect(transition?.message).toBeNull();
  });

  it("저장되는 상태는 언제나 states.enum 안의 값이다", async () => {
    const { results } = await testEnv.DB.prepare("SELECT DISTINCT state FROM dashboard_sessions").all<{
      state: string;
    }>();
    expect((results ?? []).length).toBeGreaterThan(0);
    for (const row of results ?? []) expect(statesEnum()).toContain(row.state);
  });
});
