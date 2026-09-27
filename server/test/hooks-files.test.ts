import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "./worker";
import { HOOK_REV } from "../src/hooks/routes";
const AUTH_TOKEN = "deployment-secret-canary-7dcf0b6f";

// GET /setup.sh, GET /hooks/files/:name (src/features/hooks/routes.ts) 완료 판정.
// auth-cors.test.ts와 같은 이유로 src/index.ts의 default export를 직접 호출한다 - 이
// 라우트들은 인증 미들웨어보다 앞에 마운트되므로 애초에 env의 토큰 값과 무관하게 동작해야
// 하고, 그걸 실제 라우팅으로 증명하려면 mock이 아니라 실제 워커를 태워야 한다.
//
// Expected assets come directly from the root hook sources, independently of the generated bundle.
import expectedSetup from "../../hooks/setup.sh?raw";
import expectedAgentEventHook from "../../hooks/agent-event-hook.sh?raw";
import expectedCodexNotify from "../../hooks/codex-notify.sh?raw";
import expectedCodexHooksToml from "../../hooks/codex-hooks.toml?raw";
import expectedInstall from "../../hooks/install.sh?raw";
import expectedSendGeneric from "../../hooks/send-generic.sh?raw";
import expectedTestHooks from "../../hooks/test-hooks.sh?raw";

const app = worker as unknown as {
  fetch(request: Request, env: unknown, ctx: ExecutionContext): Response | Promise<Response>;
};

async function call(path: string): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await app.fetch(new Request(`http://dashboard.test${path}`), { ...env, AUTH_TOKEN }, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

describe("GET /setup.sh", () => {
  it("완료 판정: 200 + origin 치환됨 + 플레이스홀더 잔존 없음", async () => {
    const res = await call("/setup.sh");
    expect(res.status).toBe(200);

    const body = await res.text();
    expect(body).not.toContain("__MY_DASHBOARD_ORIGIN__");
    expect(body).toContain('ORIGIN="http://dashboard.test"');
    // 치환 그 자체 말고는 원본과 완전히 같다.
    expect(body).toBe(expectedSetup.split("__MY_DASHBOARD_ORIGIN__").join("http://dashboard.test"));
  });

  it("완료 판정: rev 플레이스홀더도 치환 대상이다(setup.sh 원본 자체엔 없어도 무해하게 no-op)", async () => {
    const res = await call("/setup.sh");
    expect(res.status).toBe(200);

    const body = await res.text();
    // setup.sh 원본에는 HOOK_REV 플레이스홀더가 없다(agent-event-hook.sh 등 3개 훅
    // 스크립트에만 있다) - 그래도 라우트는 origin과 마찬가지로 이 치환을 항상 적용하므로,
    // 원본 그대로 놔둬도(치환 대상 문자열이 없어 no-op이어도) 결과가 달라지지 않는다.
    expect(body).not.toContain("__MY_DASHBOARD_HOOK_REV__");
    expect(body).toBe(
      expectedSetup
        .split("__MY_DASHBOARD_ORIGIN__")
        .join("http://dashboard.test")
        .split("__MY_DASHBOARD_HOOK_REV__")
        .join(HOOK_REV),
    );
  });

  it("완료 판정: text/plain + no-store, 인증 없이도 200(healthz와 같은 자리)", async () => {
    const res = await call("/setup.sh");
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toContain("text/plain");
    expect(res.headers.get("Cache-Control")).toBe("no-store");
  });
});

describe("GET /hooks/files/:name", () => {
  const cases: Array<[string, string]> = [
    ["agent-event-hook.sh", expectedAgentEventHook],
    ["codex-notify.sh", expectedCodexNotify],
    ["codex-hooks.toml", expectedCodexHooksToml],
    ["install.sh", expectedInstall],
    ["send-generic.sh", expectedSendGeneric],
    ["test-hooks.sh", expectedTestHooks],
  ];

  for (const [name, expected] of cases) {
    it(`완료 판정: ${name} — 200 + 원본과 바이트 동일(rev 치환 반영), 인증 불필요`, async () => {
      const res = await call(`/hooks/files/${name}`);
      expect(res.status).toBe(200);
      expect(res.headers.get("Content-Type")).toContain("text/plain");
      // codex-hooks.toml·install.sh·test-hooks.sh에는 애초에 플레이스홀더가 없어
      // no-op이고, agent-event-hook.sh·codex-notify.sh·send-generic.sh 3개는 실제로
      // 치환이 일어난다 - 어느 쪽이든 이 한 줄로 같이 검증된다.
      const rawText = await res.text();
      expect(rawText).not.toContain("__MY_DASHBOARD_HOOK_REV__");
      expect(rawText).toBe(expected.split("__MY_DASHBOARD_HOOK_REV__").join(HOOK_REV));
    });
  }

  it("완료 판정: 알 수 없는 파일명은 404", async () => {
    const res = await call("/hooks/files/does-not-exist.sh");
    expect(res.status).toBe(404);
  });

  it("setup.sh는 이 경로에 없다(전용 라우트 GET /setup.sh가 따로 있음)", async () => {
    const res = await call("/hooks/files/setup.sh");
    expect(res.status).toBe(404);
  });

  // FILES가 평범한 객체 리터럴이라 Object.prototype에서 상속되는 이름들은 `FILES[name]`이
  // undefined가 아닌 상속된 값을 돌려준다 - hasOwnProperty 가드가 없으면 이 이름들이
  // 200 + 내부 JS 값(함수 원문 등)으로 서빙된다(실측으로 확인된 회귀).
  for (const name of ["toString", "constructor", "__proto__", "hasOwnProperty", "valueOf"]) {
    it(`완료 판정: Object 상속 프로퍼티 이름 '${name}'도 404 (내부 값 노출 금지)`, async () => {
      const res = await call(`/hooks/files/${name}`);
      expect(res.status).toBe(404);
    });
  }
});

describe("응답 본문에 토큰류 문자열이 없다", () => {
  it("완료 판정: 어떤 파일 응답에도 'Bearer '+실토큰 패턴이나 테스트 AUTH_TOKEN 값이 없다", async () => {
    const paths = [
      "/setup.sh",
      "/hooks/files/agent-event-hook.sh",
      "/hooks/files/codex-notify.sh",
      "/hooks/files/send-generic.sh",
      "/hooks/files/install.sh",
      "/hooks/files/test-hooks.sh",
      "/hooks/files/codex-hooks.toml",
    ];
    for (const path of paths) {
      const res = await call(path);
      const body = await res.text();
      // 스크립트 안에는 `Bearer $MY_DASHBOARD_TOKEN`(변수 참조)만 있고 실제 값은 없다 -
      // 변수가 아니라 실제 토큰처럼 보이는 값(영숫자 8자 이상)이 뒤따르면 실패시킨다.
      expect(body).not.toMatch(/Bearer\s+[A-Za-z0-9._-]{8,}/);
      expect(body).not.toContain(AUTH_TOKEN);
    }
  });
});
