import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import {
  authHeaders,
  eventPayload,
  extraMappings,
  isTerminalState,
  lifecycleChain,
  pushStates,
  sourcesWithEventMap,
  statesEnum,
} from "./fixtures";

// `main` 워커(src/index.ts)의 default export를 로컬 서비스 바인딩으로 그대로 호출한다.
// 실제 배포되는 라우팅·인증 미들웨어·D1 쓰기 전부가 이 안에서 그대로 돈다 - mock이 아니다.
interface MainExport {
  fetch(request: Request, env: unknown, ctx: ExecutionContext): Response | Promise<Response>;
}
const app = (exports as unknown as { default: MainExport }).default;

interface TestEnv {
  DB: D1Database;
}
const testEnv = env as unknown as TestEnv;

interface EventResponse {
  ok?: boolean;
  state: string | null;
  push?: string;
  error?: string;
}

async function postEvent(body: Record<string, unknown>): Promise<{ status: number; json: EventResponse }> {
  const ctx = createExecutionContext();
  const request = new Request("http://dashboard.test/dashboard/events", {
    method: "POST",
    headers: { "content-type": "application/json", ...authHeaders() },
    body: JSON.stringify(body),
  });
  const response = await app.fetch(request, env, ctx);
  await waitOnExecutionContext(ctx);
  return { status: response.status, json: (await response.json()) as EventResponse };
}

async function getSessions(query = ""): Promise<Response> {
  const ctx = createExecutionContext();
  const request = new Request(`http://dashboard.test/dashboard/sessions${query}`, { headers: authHeaders() });
  const response = await app.fetch(request, env, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

describe("POST /dashboard/events 세션 수명주기 (실제 v1 서버, 로컬 protocol.v1.json 기반 픽스처)", () => {
  it("완료 판정(b): 이 파일은 마이그레이션만 적용된 빈 D1에서 시작한다", async () => {
    // vitest-pool-workers는 테스트 파일마다 새 storage 스냅샷을 준다(test/setup.ts가 매번
    // applyD1Migrations만 재실행). 다른 테스트 파일에서 만든 세션이 여기 보이면 격리가 깨진 것이다.
    const sessions = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_sessions").first<{ n: number }>();
    expect(sessions?.n).toBe(0);
    const events = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_events").first<{ n: number }>();
    expect(events?.n).toBe(0);

    // 0002_dashboard_v2.sql까지 실제로 적용됐다는 증거: 0002가 만드는 dashboard_meta에
    // protocol_version 행이 seed돼 있다. 0001만 적용됐다면 이 테이블 자체가 없어 쿼리가 실패한다.
    const meta = await testEnv.DB.prepare(
      "SELECT value FROM dashboard_meta WHERE key = 'protocol_version'",
    ).first<{ value: string }>();
    expect(meta?.value).toBeDefined();
  });

  it("인증 토큰이 없거나 틀리면 401 {error:'unauthorized'}", async () => {
    const ctx = createExecutionContext();
    const request = new Request("http://dashboard.test/dashboard/events", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(eventPayload()),
    });
    const response = await app.fetch(request, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
  });

  for (const source of sourcesWithEventMap()) {
    it(`${source}: contract.event_state_map.by_source를 따라 세션 상태가 이어진다`, async () => {
      const chain = lifecycleChain(source);
      expect(chain.length).toBeGreaterThan(0);

      const sessionId = `lifecycle-${source}`;
      let previousState: string | null = null;
      for (const step of chain) {
        // event_id는 전역 멱등 키다(protocol.v1.json event_payload.fields.event_id).
        // eventPayload()의 기본값은 contract.event_payload.example이 준 고정 예시 id라
        // override 없이 그대로 여러 번 보내면 두 번째 호출부터 전부 "같은 이벤트"로 뭉쳐
        // duplicate:true가 되어 상태가 안 바뀐다 - 세션·이벤트별로 매번 새 id를 준다.
        const { status, json } = await postEvent(
          eventPayload({ source, session_id: sessionId, event: step.event, event_id: `${sessionId}-${step.event}` }),
        );
        expect(status).toBe(200);
        expect(json.ok).toBe(true);
        expect(json.state).toBe(step.state);

        // 실제 push 판정(routes.ts): 상태가 "바뀌었고" 그 새 상태가 push 대상일 때만 queued.
        const expectedPush = step.state !== previousState && pushStates().includes(step.state) ? "queued" : "none";
        expect(json.push).toBe(expectedPush);
        previousState = step.state;
      }

      // contract.states.invariants: "ended 세션은 SessionStart 이벤트로만 다른 상태로 나간다."
      if (isTerminalState(previousState ?? "")) {
        const nonRestartEvent = chain.find((step) => step.event !== "SessionStart")!.event;
        const { json } = await postEvent(
          eventPayload({
            source,
            session_id: sessionId,
            event: nonRestartEvent,
            event_id: `${sessionId}-${nonRestartEvent}-after-ended`,
          }),
        );
        expect(json.state).toBe(previousState);
        expect(json.push).toBe("none");
      }
    });

    for (const extra of extraMappings(source)) {
      it(`${source}: 추가 매핑 ${extra.event} -> ${extra.state} (독립 세션에서 확인)`, async () => {
        // lifecycleChain을 다 태운 세션은 ended라 이후 이벤트가 막힌다. 매핑 자체를 보려면 새 세션이 필요하다.
        const sessionId = `extra-${source}-${extra.event}`;
        const { status, json } = await postEvent(
          eventPayload({ source, session_id: sessionId, event: extra.event, event_id: `${sessionId}-evt` }),
        );
        expect(status).toBe(200);
        expect(json.state).toBe(extra.state);
        expect(json.push).toBe(pushStates().includes(extra.state) ? "queued" : "none");
      });
    }
  }

  it("매핑에 없는 이벤트는 상태를 바꾸지 않고 기록만 한다", async () => {
    const source = sourcesWithEventMap()[0]!;
    const sessionId = `unmapped-${source}`;
    const { json: started } = await postEvent(
      eventPayload({ source, session_id: sessionId, event: "SessionStart", event_id: `${sessionId}-start` }),
    );
    expect(started.state).toBe("idle");

    const { status, json } = await postEvent(
      eventPayload({ source, session_id: sessionId, event: "PostToolUse", event_id: `${sessionId}-posttool` }),
    );
    expect(status).toBe(200);
    expect(json.state).toBe("idle"); // 안 바뀜
    expect(json.push).toBe("none");
  });

  it("완료 판정(b): GET /dashboard/sessions가 방금 만든 세션들을 states.enum 값의 state와 함께 돌려준다", async () => {
    const response = await getSessions("?include_ended=1");
    expect(response.status).toBe(200);
    const { sessions } = (await response.json()) as { sessions: Array<{ key: string; state: string }> };
    expect(sessions.length).toBeGreaterThan(0);
    for (const session of sessions) {
      expect(statesEnum()).toContain(session.state);
    }
  });
});
