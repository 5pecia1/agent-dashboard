import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "./worker";
import { appendTransition } from "../src/dashboard/transitions";
import { authHeaders, eventPayload } from "./fixtures";

/**
 * 리뷰 지적 medium 수정: dashboard_sessions.last_transition_id UPDATE는 단조 증가만
 * 허용해야 한다(transitions.ts appendTransition). INSERT(전이 채번)와 이 UPDATE는 한 문장이
 * 아니라 별개의 두 왕복이라, 같은 세션에 겹쳐 들어온 두 요청의 UPDATE가 INSERT 순서와 다르게
 * 끝나면(스케줄러 사정) 단순 대입은 더 큰 값을 더 작은 값으로 역행시킬 수 있다 - seen 판정
 * (last_transition_id > seen_transition_id)에서 실제로 있었던 전이가 "아직 일어나지 않은
 * 것"처럼 사라진다.
 *
 * appendTransition을 직접 호출해(HTTP 경합을 재현하는 대신) "이 전이 자신의 id보다 이미 더
 * 큰 값이 dashboard_sessions.last_transition_id에 올라가 있는" 상황을 만들어(경합에서 늦게
 * 도착한 요청의 UPDATE를 흉내낸다) 역행하지 않는지 직접 검증한다.
 */
const app = worker as unknown as {
  fetch(request: Request, env: unknown, ctx: ExecutionContext): Response | Promise<Response>;
};

interface TestEnv {
  DB: D1Database;
}
const testEnv = env as unknown as TestEnv;

async function postEvent(body: Record<string, unknown>): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await app.fetch(
    new Request("http://dashboard.test/dashboard/events", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify(body),
    }),
    env,
    ctx,
  );
  await waitOnExecutionContext(ctx);
  return response;
}

async function lastTransitionId(key: string): Promise<number | null> {
  const row = await testEnv.DB.prepare("SELECT last_transition_id FROM dashboard_sessions WHERE key = ?")
    .bind(key)
    .first<{ last_transition_id: number | null }>();
  return row?.last_transition_id ?? null;
}

let seq = 0;
function nextEventId(prefix: string): string {
  seq += 1;
  return `${prefix}-${seq}`;
}

describe("appendTransition: dashboard_sessions.last_transition_id는 단조 증가만 허용한다", () => {
  it("이미 더 큰 값이 올라가 있으면(경합에서 늦게 실행되는 UPDATE를 흉내냄) 더 작은 새 전이 id로 역행시키지 않는다", async () => {
    const sessionId = "transitions-mono";
    const key = `claude-code:${sessionId}`;
    // dashboard_transitions.id는 이 파일의 모든 세션이 공유하는 전역 AUTOINCREMENT다(앞선
    // 테스트의 전이도 채번에 들어간다) - 절대값을 가정하지 않고 실제로 채번된 값을 그대로 쓴다.
    await postEvent(
      eventPayload({ session_id: sessionId, event: "SessionStart", event_id: nextEventId("tmono") }),
    ); // -> idle
    const realId = await lastTransitionId(key);
    expect(realId).not.toBeNull();

    // 경합에서 "나중에 실행된" 다른 요청의 UPDATE가 이미 더 큰 값을 올려놨다고 가정한다.
    await testEnv.DB.prepare("UPDATE dashboard_sessions SET last_transition_id = ? WHERE key = ?")
      .bind(999, key)
      .run();
    expect(await lastTransitionId(key)).toBe(999);

    // 이 전이 자신의 새 id(realId+1)는 999보다 작다 - 단순 대입이면 999에서 역행한다.
    await appendTransition(
      testEnv.DB,
      {
        session_key: key,
        from_state: "idle",
        to_state: "working",
        source: "claude-code",
        project: null,
        host: null,
        message: null,
        occurred_at: Date.now(),
      },
      Date.now(),
    );

    expect(await lastTransitionId(key)).toBe(999); // 역행하지 않았다.
  });

  it("정상적인 전진(더 큰 새 전이 id)은 그대로 반영된다", async () => {
    const sessionId = "transitions-forward";
    const key = `claude-code:${sessionId}`;
    await postEvent(
      eventPayload({ session_id: sessionId, event: "SessionStart", event_id: nextEventId("tfwd") }),
    ); // -> idle
    const firstId = await lastTransitionId(key);
    expect(firstId).not.toBeNull();

    await postEvent(
      eventPayload({ session_id: sessionId, event: "UserPromptSubmit", event_id: nextEventId("tfwd") }),
    ); // -> working

    expect(await lastTransitionId(key)).toBeGreaterThan(firstId!);
  });
});
