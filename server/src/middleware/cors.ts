import type { MiddlewareHandler } from "hono";
import type { Env } from "../env";

/**
 * CORS 화이트리스트 미들웨어. PWA(Cloudflare Pages)와 API(Worker)가 다른 origin이라 필요하다.
 * 정본: contracts/dashboard-protocol.v1.json auth.cors.
 *
 * index.ts에서 인증 미들웨어보다 먼저 등록한다 — 그래야
 *   1) OPTIONS 프리플라이트가 인증 없이 204로 끝나고 (auth.unauthenticated_endpoints: "OPTIONS *")
 *   2) 이 미들웨어가 감싸는 모든 응답(healthz, 401/403, 실제 라우트)에 빠짐없이
 *      Vary: Origin + Cache-Control: no-store가 붙는다.
 *
 * 허용되지 않은 origin을 서버가 능동적으로 막지는 않는다(Authorization 검사는 이 미들웨어
 * 다음 순서인 인증 미들웨어의 몫이다) — 그냥 Access-Control-Allow-Origin을 안 붙일 뿐이고,
 * 그러면 브라우저가 스스로 응답 읽기를 막는다. Origin 헤더 자체가 없는 서버-서버 호출(hook 등)은
 * 원래 CORS 대상이 아니므로 아무 영향도 없다.
 */

function parseAllowedOrigins(raw: string | undefined): string[] {
  return (raw ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

/** 모든 응답에 공통으로 붙는 헤더. no-store는 CORS와 무관하게 "모든 응답"에 요구되는 규칙이라
 *  이 미들웨어가 요청 파이프라인의 맨 앞이라는 위치를 빌려 여기서 함께 보장한다. */
function applyCommonHeaders(headers: Headers, allowOrigin: string | null): void {
  const vary = headers.get("Vary")?.split(",").map((value) => value.trim()) ?? [];
  if (!vary.some((value) => value.toLowerCase() === "origin")) headers.append("Vary", "Origin");
  headers.set("Cache-Control", "no-store");
  if (allowOrigin) {
    headers.set("Access-Control-Allow-Origin", allowOrigin);
  }
}

export const corsMiddleware: MiddlewareHandler<{ Bindings: Env }> = async (c, next) => {
  const origin = c.req.header("Origin");
  const allowedOrigins = parseAllowedOrigins(c.env.ALLOWED_ORIGINS);
  const allowOrigin = origin && allowedOrigins.includes(origin) ? origin : null;

  if (c.req.method === "OPTIONS") {
    // 프리플라이트: 인증 없이 항상 204. CORS용 Allow-* 헤더는 origin이 허용됐을 때만 붙인다.
    const headers = new Headers();
    applyCommonHeaders(headers, allowOrigin);
    if (allowOrigin) {
      headers.set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS");
      const requested = c.req.header("Access-Control-Request-Headers");
      const requestedList = requested
        ? requested.split(",").map((h) => h.trim()).filter(Boolean)
        : [];
      // Authorization은 요청이 뭘 물어봤든 항상 넣는다 — 모든 엔드포인트가 그걸 요구하니까.
      const allowHeaders = Array.from(new Set(["Authorization", "Content-Type", ...requestedList]));
      headers.set("Access-Control-Allow-Headers", allowHeaders.join(", "));
      headers.append("Vary", "Access-Control-Request-Headers");
      headers.set("Access-Control-Max-Age", "86400");
    }
    return new Response(null, { status: 204, headers });
  }

  await next();
  applyCommonHeaders(c.res.headers, allowOrigin);
};
