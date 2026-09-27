import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "./worker";
import { authHeaders, eventPayload } from "./fixtures";

/**
 * dashboard-ops(diagnostics/mute/test-push) 완료 판정.
 *
 * 레거시 AUTH_TOKEN 하나로 충분하므로(전환기 호환 - 조회·수집 어디에나 통한다) 여기서는
 * auth-cors.test.ts처럼 env를 커스터마이즈하지 않고 전역 env(vitest.config.ts의
 * AUTH_TOKEN="test-auth-token")를 그대로 쓴다.
 *
 * "음소거해도 전이 적재는 계속된다"는 완료 판정은 test-push(항상 ignoreMute:true)로는
 * 보일 수 없으므로, 실제 수집 경로(POST /dashboard/events, 다른 task 소유이지만 HTTP로
 * 호출하는 것은 이 TASK의 파일 소유 경계를 넘지 않는다)로 push 대상 상태 전이를 만들어
 * dashboard_push_log에 남는 실제 결과(result='muted')로 확인한다.
 */

const app = worker as unknown as {
  fetch(request: Request, env: unknown, ctx: ExecutionContext): Response | Promise<Response>;
};

interface TestEnv {
  DB: D1Database;
}
const testEnv = env as unknown as TestEnv;

interface JsonResponse<T = Record<string, unknown>> {
  status: number;
  headers: Headers;
  json: T;
}

async function call<T = Record<string, unknown>>(path: string, init: RequestInit = {}): Promise<JsonResponse<T>> {
  const ctx = createExecutionContext();
  const response = await app.fetch(new Request(`http://dashboard.test${path}`, init), env, ctx);
  await waitOnExecutionContext(ctx);
  const json = (await response.json().catch(() => ({}))) as T;
  return { status: response.status, headers: response.headers, json };
}

async function countRows(table: string): Promise<number> {
  const row = await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>();
  return row?.n ?? 0;
}

describe("POST/GET /dashboard/mute", () => {
  it("완료 판정: 30분 음소거해도 전이 적재는 계속되고, 실제 push는 muted로 건너뛴다", async () => {
    const muteRes = await call<{ ok: boolean; mute_until: number | null }>("/dashboard/mute", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ minutes: 30 }),
    });
    expect(muteRes.status).toBe(200);
    expect(muteRes.json.ok).toBe(true);
    expect(muteRes.json.mute_until).toBeGreaterThan(Date.now());

    const getMute = await call<{ mute_until: number | null }>("/dashboard/mute", { headers: authHeaders() });
    expect(getMute.status).toBe(200);
    expect(getMute.json.mute_until).toBeGreaterThan(Date.now());

    const before = await countRows("dashboard_transitions");

    // 실제 수집 경로를 통해 push 대상 상태(waiting_input)로 전이를 만든다.
    const postRes = await call<{ ok: boolean; state: string; push: string }>("/dashboard/events", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify(
        eventPayload({
          source: "generic",
          session_id: "mute-test",
          event: "manual-report",
          event_id: "mute-test-evt-1",
          state: "waiting_input",
        }),
      ),
    });
    expect(postRes.status).toBe(200);
    expect(postRes.json.state).toBe("waiting_input");
    // 판정 자체는 여전히 "queued"다 - 이 값은 "push 대상 상태로 전이했다"는 뜻이고,
    // 실제 발송 시도는 waitUntil로 예약된 dispatchPush 내부에서 음소거로 막힌다.
    expect(postRes.json.push).toBe("queued");

    const after = await countRows("dashboard_transitions");
    expect(after).toBe(before + 1);

    const pushLog = await testEnv.DB.prepare(
      "SELECT result, transport FROM dashboard_push_log ORDER BY id DESC LIMIT 1",
    ).first<{ result: string; transport: string }>();
    expect(pushLog?.result).toBe("muted");
  });

  it("음소거 해제(minutes<=0)는 mute_until을 null로 되돌린다", async () => {
    await call("/dashboard/mute", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ minutes: 30 }),
    });
    const cleared = await call<{ ok: boolean; mute_until: number | null }>("/dashboard/mute", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ minutes: 0 }),
    });
    expect(cleared.status).toBe(200);
    expect(cleared.json.mute_until).toBeNull();

    const getMute = await call<{ mute_until: number | null }>("/dashboard/mute", { headers: authHeaders() });
    expect(getMute.json.mute_until).toBeNull();
  });
});

/**
 * dashboard-ops/routes.ts의 mute 패턴을 복제한 settings.ui_lang(정본: protocol.v1.json
 * settings.ui_lang 절) 완료 판정. mute와 마찬가지로 순수 LWW다 - 단조 가드·병합 없이 POST 응답의
 * 확정값이 곧 저장값이다.
 */
describe("GET/POST /dashboard/ui-lang", () => {
  it("아직 한 번도 설정한 적 없으면 GET은 null이다(서버 규범 없음 = 각 기기가 플랫폼 로케일을 쓴다)", async () => {
    const res = await call<{ ui_lang: string | null }>("/dashboard/ui-lang", { headers: authHeaders() });
    expect(res.status).toBe(200);
    expect(res.json.ui_lang).toBeNull();
  });

  it("완료 판정: POST {lang:'ko'}는 확정값을 그대로 응답하고 GET에도 그대로 반영된다", async () => {
    const postRes = await call<{ ok: boolean; ui_lang: string | null }>("/dashboard/ui-lang", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ lang: "ko" }),
    });
    expect(postRes.status).toBe(200);
    expect(postRes.json.ok).toBe(true);
    expect(postRes.json.ui_lang).toBe("ko");

    const getRes = await call<{ ui_lang: string | null }>("/dashboard/ui-lang", { headers: authHeaders() });
    expect(getRes.status).toBe(200);
    expect(getRes.json.ui_lang).toBe("ko");
  });

  it("완료 판정: POST {lang:'en'}도 마찬가지로 'ko'를 덮어써 확정값이 된다", async () => {
    await call("/dashboard/ui-lang", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ lang: "ko" }),
    });
    const postRes = await call<{ ok: boolean; ui_lang: string | null }>("/dashboard/ui-lang", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ lang: "en" }),
    });
    expect(postRes.json.ui_lang).toBe("en");

    const getRes = await call<{ ui_lang: string | null }>("/dashboard/ui-lang", { headers: authHeaders() });
    expect(getRes.json.ui_lang).toBe("en");
  });

  it("명시적 null은 유효값('선택 해제')이다 - 키 부재(400)와 구분되고, 이전 확정값을 지운다", async () => {
    await call("/dashboard/ui-lang", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ lang: "en" }),
    });
    const postRes = await call<{ ok: boolean; ui_lang: string | null }>("/dashboard/ui-lang", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ lang: null }),
    });
    expect(postRes.status).toBe(200);
    expect(postRes.json.ok).toBe(true);
    expect(postRes.json.ui_lang).toBeNull();

    const getRes = await call<{ ui_lang: string | null }>("/dashboard/ui-lang", { headers: authHeaders() });
    expect(getRes.json.ui_lang).toBeNull();
  });

  it("LWW 덮어쓰기: 여러 번 갈아타도 마지막 POST 값만 남는다(단조 가드·병합 없음)", async () => {
    const sequence: Array<"ko" | "en" | null> = ["ko", "en", null, "en", "ko", null, "ko"];
    for (const lang of sequence) {
      const res = await call<{ ui_lang: string | null }>("/dashboard/ui-lang", {
        method: "POST",
        headers: { "content-type": "application/json", ...authHeaders() },
        body: JSON.stringify({ lang }),
      });
      expect(res.json.ui_lang).toBe(lang);
      const getRes = await call<{ ui_lang: string | null }>("/dashboard/ui-lang", { headers: authHeaders() });
      expect(getRes.json.ui_lang).toBe(lang);
    }
  });

  it("lang이 'ko'|'en'|null이 아니면 400이고 값은 바뀌지 않는다", async () => {
    await call("/dashboard/ui-lang", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ lang: "ko" }),
    });

    for (const bad of ["fr", "KO", "", 1, true, {}, []]) {
      const res = await call<{ error: string }>("/dashboard/ui-lang", {
        method: "POST",
        headers: { "content-type": "application/json", ...authHeaders() },
        body: JSON.stringify({ lang: bad }),
      });
      expect(res.status).toBe(400);
      expect(typeof res.json.error).toBe("string");
    }

    const getRes = await call<{ ui_lang: string | null }>("/dashboard/ui-lang", { headers: authHeaders() });
    expect(getRes.json.ui_lang).toBe("ko"); // 거절된 시도들이 값을 건드리지 않았다
  });

  it("요청 본문에 lang 키 자체가 없으면(누락) 400이다 - 명시적 null과 구분된다", async () => {
    await call("/dashboard/ui-lang", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ lang: "en" }),
    });

    for (const body of [{}, { other: "field" }]) {
      const res = await call<{ error: string }>("/dashboard/ui-lang", {
        method: "POST",
        headers: { "content-type": "application/json", ...authHeaders() },
        body: JSON.stringify(body),
      });
      expect(res.status).toBe(400);
      expect(typeof res.json.error).toBe("string");
    }

    const getRes = await call<{ ui_lang: string | null }>("/dashboard/ui-lang", { headers: authHeaders() });
    expect(getRes.json.ui_lang).toBe("en"); // 누락 요청이 값을 건드리지 않았다
  });

  it("본문 자체가 없거나 JSON이 아니면 400이다", async () => {
    const noBody = await call<{ error: string }>("/dashboard/ui-lang", {
      method: "POST",
      headers: authHeaders(),
    });
    expect(noBody.status).toBe(400);

    const notJson = await call<{ error: string }>("/dashboard/ui-lang", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: "not json",
    });
    expect(notJson.status).toBe(400);
  });
});

describe("POST /dashboard/test-push", () => {
  it("완료 판정: 자격증명이 전혀 없어도 성공하고, 전이 정확히 1건을 남기고, 채널별 skip 사유를 반환한다", async () => {
    const before = await countRows("dashboard_transitions");

    const res = await call<{
      ok: boolean;
      transition_id: number;
      channels: Record<string, { sent: number; removed: number; skipped?: string }>;
    }>("/dashboard/test-push", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ label: "완료 판정용 테스트 발송" }),
    });

    expect(res.status).toBe(200);
    expect(res.json.ok).toBe(true);
    expect(typeof res.json.transition_id).toBe("number");
    expect(res.json.transition_id).toBeGreaterThan(0);

    const after = await countRows("dashboard_transitions");
    expect(after).toBe(before + 1);

    expect(res.json.channels.fcm).toBeDefined();
    expect(res.json.channels.fcm!.sent).toBe(0);
    expect(res.json.channels.fcm!.removed).toBe(0);
    expect(typeof res.json.channels.fcm!.skipped).toBe("string");
    expect(res.json.channels.fcm!.skipped).toContain("FCM_SERVICE_ACCOUNT");
  });

  it("test-push는 음소거 중에도 발송을 시도한다(ignoreMute)", async () => {
    await call("/dashboard/mute", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ minutes: 30 }),
    });

    const res = await call<{ channels: Record<string, { skipped?: string }> }>("/dashboard/test-push", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({}),
    });
    expect(res.status).toBe(200);
    // 음소거 때문에 건너뛴 게 아니라 자격증명 미설정 때문에 건너뛴 것이어야 한다.
    expect(res.json.channels.fcm!.skipped).toContain("FCM_SERVICE_ACCOUNT");

    await call("/dashboard/mute", {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ minutes: 0 }),
    });
  });
});

describe("GET /dashboard/diagnostics", () => {
  it("완료 판정: 마지막 이벤트 시각·push 결과·실패 카운트·커서·pruned_below_id·채널 자격증명·테이블 행수를 함께 돌려준다", async () => {
    const res = await call<{
      last_event_at: number | null;
      last_push: unknown;
      device_failure_count: number;
      subscription_failure_count: number;
      max_transition_id: number;
      pruned_below_id: number;
      channels: Record<string, boolean>;
      table_counts: Record<string, number>;
    }>("/dashboard/diagnostics", { headers: authHeaders() });

    expect(res.status).toBe(200);
    expect(res.headers.get("Cache-Control")).toBe("no-store");
    expect(res.json).toHaveProperty("last_event_at");
    expect(res.json).toHaveProperty("last_push");
    expect(res.json.device_failure_count).toBe(0);
    expect(res.json.subscription_failure_count).toBe(0);
    expect(res.json.max_transition_id).toBeGreaterThan(0);
    expect(res.json.pruned_below_id).toBe(0);
    // fcm-apns는 별도 채널이 아니라 fcm 트랜스포트가 다루는 대상 모양이라 activeChannelIds()에는
    // 절대 나오지 않는다(TRANSPORT_IDS.md — push/transport.ts 주석 참고) - 자격증명이 있어도 false.
    expect(res.json.channels).toEqual({ fcm: false, "fcm-apns": false });
    expect(res.json.table_counts.dashboard_transitions).toBeGreaterThan(0);
    expect(res.json.table_counts.dashboard_events).toBeGreaterThan(0);
  });
});
