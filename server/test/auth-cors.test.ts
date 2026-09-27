import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "./worker";
import { authHeaders, eventPayload } from "./fixtures";

/**
 * 토큰 분리(INGEST_TOKEN/CLIENT_TOKEN/AUTH_TOKEN) + CORS 화이트리스트 완료 판정.
 *
 * ingest.test.ts와 같은 방식으로 src/index.ts의 default export를 직접 호출한다
 * (cloudflare:workers의 `exports`는 넘긴 env를 무시하고 원본 바인딩을 쓰므로,
 * 이 파일처럼 env를 바꿔 보는 테스트에는 쓸 수 없다).
 *
 * vitest.config.ts(공유 설정, 이 TASK 소유 밖)는 AUTH_TOKEN만 전역 바인딩으로 준다.
 * INGEST_TOKEN/CLIENT_TOKEN/ALLOWED_ORIGINS는 vitest.config.ts를 건드리지 않고, 전역 env를
 * 펼쳐 이 필드들만 얹은 로컬 env 객체를 만들어 app.fetch(request, scopedEnv, ctx)에 직접
 * 넘긴다 - Hono의 fetch(request, env, ctx)는 넘겨받은 env 객체를 그대로 c.env로 쓴다.
 */

interface WorkerEnv {
  DB: D1Database;
  AUTH_TOKEN?: string;
  INGEST_TOKEN?: string;
  CLIENT_TOKEN?: string;
  ALLOWED_ORIGINS?: string;
}

const app = worker as unknown as {
  fetch(request: Request, env: unknown, ctx: ExecutionContext): Response | Promise<Response>;
};

const baseEnv = env as unknown as WorkerEnv;

const INGEST_TOKEN = "test-ingest-token";
const CLIENT_TOKEN = "test-client-token";
const ALLOWED_ORIGIN = "https://allowed.example";

const scopedEnv: WorkerEnv = {
  ...baseEnv,
  INGEST_TOKEN,
  CLIENT_TOKEN,
  ALLOWED_ORIGINS: ALLOWED_ORIGIN,
};

async function call(path: string, init: RequestInit = {}, useEnv: WorkerEnv = scopedEnv): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await app.fetch(new Request(`http://dashboard.test${path}`, init), useEnv, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

describe("토큰 분리: INGEST_TOKEN / CLIENT_TOKEN / 레거시 AUTH_TOKEN", () => {
  it("완료 판정: INGEST_TOKEN으로 조회(client-only) 엔드포인트를 두드리면 403", async () => {
    const res = await call("/dashboard/sessions", {
      headers: { authorization: `Bearer ${INGEST_TOKEN}` },
    });
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: "forbidden" });
  });

  it("완료 판정: CLIENT_TOKEN으로 POST /dashboard/events(수집 전용)를 두드리면 403", async () => {
    const res = await call("/dashboard/events", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${CLIENT_TOKEN}` },
      body: JSON.stringify(
        eventPayload({ source: "generic", session_id: "tok-403", event_id: "tok-403-evt", state: "idle" }),
      ),
    });
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: "forbidden" });
  });

  it("완료 판정: INGEST_TOKEN은 POST /dashboard/events에서 그대로 통한다(200)", async () => {
    const res = await call("/dashboard/events", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${INGEST_TOKEN}` },
      body: JSON.stringify(
        eventPayload({ source: "generic", session_id: "tok-ingest-ok", event_id: "tok-ingest-ok-evt", state: "idle" }),
      ),
    });
    expect(res.status).toBe(200);
  });

  it("완료 판정: CLIENT_TOKEN은 조회 엔드포인트에서 그대로 통한다(200)", async () => {
    const res = await call("/dashboard/sessions", { headers: { authorization: `Bearer ${CLIENT_TOKEN}` } });
    expect(res.status).toBe(200);
  });

  it("완료 판정: 레거시 AUTH_TOKEN은 두 종류 엔드포인트 모두에서 200", async () => {
    const postRes = await call("/dashboard/events", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify(
        eventPayload({ source: "generic", session_id: "tok-legacy", event_id: "tok-legacy-evt", state: "idle" }),
      ),
    });
    expect(postRes.status).toBe(200);

    const getRes = await call("/dashboard/sessions", { headers: authHeaders() });
    expect(getRes.status).toBe(200);
  });

  it("회귀 보존: 토큰이 없거나 모르는 값이면 401 {error:'unauthorized'} (기존 test/dashboard.test.ts와 같은 계약)", async () => {
    const missing = await call("/dashboard/sessions", {});
    expect(missing.status).toBe(401);
    expect(await missing.json()).toEqual({ error: "unauthorized" });

    const garbage = await call("/dashboard/sessions", { headers: { authorization: "Bearer garbage" } });
    expect(garbage.status).toBe(401);
    expect(await garbage.json()).toEqual({ error: "unauthorized" });
  });

  it("/healthz는 인증 없이 200 (기존 계약 보존)", async () => {
    const res = await call("/healthz", {});
    expect(res.status).toBe(200);
  });
});

describe("CORS: 화이트리스트 + 프리플라이트 + 모든 응답 no-store", () => {
  it("완료 판정: 허용된 origin의 OPTIONS 프리플라이트는 인증 없이 204 + CORS 헤더", async () => {
    const res = await call("/dashboard/sessions", {
      method: "OPTIONS",
      headers: { Origin: ALLOWED_ORIGIN, "Access-Control-Request-Method": "GET" },
    });
    expect(res.status).toBe(204);
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe(ALLOWED_ORIGIN);
    expect(res.headers.get("Access-Control-Allow-Headers")).toContain("Authorization");
    expect(res.headers.get("Cache-Control")).toBe("no-store");
    expect(res.headers.get("Vary")).toContain("Origin");
  });

  it("완료 판정: 허용되지 않은 origin은 프리플라이트에서도 Access-Control-Allow-Origin이 없다", async () => {
    const res = await call("/dashboard/sessions", {
      method: "OPTIONS",
      headers: { Origin: "https://evil.example", "Access-Control-Request-Method": "GET" },
    });
    expect(res.status).toBe(204);
    expect(res.headers.get("Access-Control-Allow-Origin")).toBeNull();
    expect(res.headers.get("Access-Control-Allow-Methods")).toBeNull();
  });

  it("완료 판정: 실제 요청도 허용되지 않은 origin이면 Access-Control-Allow-Origin이 붙지 않는다", async () => {
    const res = await call("/healthz", { headers: { Origin: "https://evil.example" } });
    expect(res.status).toBe(200);
    expect(res.headers.get("Access-Control-Allow-Origin")).toBeNull();
    expect(res.headers.get("Cache-Control")).toBe("no-store");
  });

  it("완료 판정: 모든 응답이 Cache-Control: no-store를 갖는다 (200/401/403 전부)", async () => {
    const ok = await call("/healthz", {});
    expect(ok.headers.get("Cache-Control")).toBe("no-store");

    const unauthorized = await call("/dashboard/sessions", {});
    expect(unauthorized.status).toBe(401);
    expect(unauthorized.headers.get("Cache-Control")).toBe("no-store");

    const forbidden = await call("/dashboard/sessions", {
      headers: { authorization: `Bearer ${INGEST_TOKEN}` },
    });
    expect(forbidden.status).toBe(403);
    expect(forbidden.headers.get("Cache-Control")).toBe("no-store");
  });
});
