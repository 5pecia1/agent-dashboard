import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import worker from "./worker";
import { dispatchPush, type DispatchEnv, type PushTransition } from "../src/dashboard/dispatch";
import { resetAccessTokenCache } from "../src/dashboard/push";
import { appendTransition } from "../src/dashboard/transitions";
import { TEST_PRIVATE_KEY_PEM, TEST_PUBLIC_KEY_PEM, base64urlToBytes, pemToBuffer } from "./fcm-test-key";
import { authHeaders } from "./fixtures";

/**
 * FCM 우선 push 트랜스포트(T08f) 완료 판정.
 *
 * Firebase 자격증명은 아직 없다. 그래서 "실제로 구글에 붙는다"는 확인은 이 스위트가 하지
 * 않는다(그건 자격증명이 생긴 뒤 실배달로만 닫힌다). 대신 자격증명 없이 닫을 수 있는 것을
 * 전부 닫는다:
 *
 *   - openssl로 만든 버리는 RSA 키로 가짜 서비스 계정을 조립하고, OAuth 스텁이 받은 JWT를
 *     그 공개키로 실제로 검증한다(alg/iss/scope/aud/iat/exp).
 *   - messages:send 스텁이 받은 요청 본문을 통째로 대조한다(data 전용 + webpush/android 블록).
 *   - 액세스 토큰 isolate 캐시, UNREGISTERED 토큰 즉시 삭제, 실패 카운트 누적.
 *   - 자격증명 미설정 시 채널이 사유를 담아 skipped로 닫히는 것(기존 65개 테스트의 전제).
 *   - 기기 등록/해제 라우트와 GET /dashboard/push-config.
 *
 * 워커를 직접 import해 부르는 이유는 ingest.test.ts와 같다(넘긴 env와 ExecutionContext를
 * 존중해야 env 하나만 바꿔 보는 테스트가 가능하다).
 */

const app = worker as unknown as {
  fetch(request: Request, env: unknown, ctx: ExecutionContext): Response | Promise<Response>;
};

const testEnv = env as unknown as { DB: D1Database };

const TOKEN_URI = "https://oauth2.test/token";
const FCM_BASE_URL = "https://fcm.test";
const PROJECT_ID = "my-dashboard-test";
const CLIENT_EMAIL = "push@my-dashboard-test.iam.gserviceaccount.com";
const ACCESS_TOKEN = "stub-access-token";
const SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const SEND_URL = `${FCM_BASE_URL}/v1/projects/${PROJECT_ID}/messages:send`;

/**
 * 가짜 서비스 계정. token_uri는 일부러 구글 기본값으로 두고, env.FCM_TOKEN_URI가 그걸
 * 덮어쓰는지까지 aud 클레임으로 확인한다.
 */
const SERVICE_ACCOUNT = JSON.stringify({
  type: "service_account",
  project_id: PROJECT_ID,
  private_key_id: "test-key-id",
  private_key: TEST_PRIVATE_KEY_PEM,
  client_email: CLIENT_EMAIL,
  token_uri: "https://oauth2.googleapis.com/token",
});

const FIREBASE_WEB_CONFIG = JSON.stringify({
  apiKey: "test-api-key",
  projectId: PROJECT_ID,
  appId: "1:1234567890:web:abcdef",
  messagingSenderId: "1234567890",
});
const WEB_VAPID_KEY = "BTestVapidPublicKeyForWebPushCertificates";

const FIREBASE_APPLE_CONFIG = JSON.stringify({
  apiKey: "test-api-key",
  projectId: PROJECT_ID,
  appId: "1:1234567890:ios:abcdef",
  gcmSenderId: "1234567890",
  bundleId: "com.example.agentdashboard",
});

interface StubCall {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: string;
}

interface FetchStub {
  calls: StubCall[];
  fetch: typeof fetch;
  tokenCalls(): StubCall[];
  sendCalls(): StubCall[];
}

/** messages:send 응답을 시나리오별로 갈아끼울 수 있는 fetch 스텁. */
function makeStub(send?: (call: StubCall, index: number) => Response): FetchStub {
  const calls: StubCall[] = [];
  let sendIndex = 0;

  const stub = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url =
      typeof input === "string" ? input : input instanceof URL ? input.href : (input as Request).url;
    const headers = new Headers((init?.headers as HeadersInit | undefined) ?? {});
    const rawBody = init?.body;
    const body =
      typeof rawBody === "string"
        ? rawBody
        : rawBody instanceof URLSearchParams
          ? rawBody.toString()
          : "";
    const call: StubCall = {
      url,
      method: init?.method ?? "GET",
      headers: Object.fromEntries(headers.entries()),
      body,
    };
    calls.push(call);

    if (url === TOKEN_URI) {
      return new Response(JSON.stringify({ access_token: ACCESS_TOKEN, expires_in: 3600 }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }
    if (url === SEND_URL) {
      const response = send ? send(call, sendIndex) : new Response(JSON.stringify({ name: "projects/p/messages/1" }), { status: 200 });
      sendIndex++;
      return response;
    }
    return new Response(`스텁이 모르는 요청: ${url}`, { status: 500 });
  };

  return {
    calls,
    fetch: stub as unknown as typeof fetch,
    tokenCalls: () => calls.filter((call) => call.url === TOKEN_URI),
    sendCalls: () => calls.filter((call) => call.url === SEND_URL),
  };
}

function pushEnv(overrides: Record<string, unknown> = {}): DispatchEnv {
  return {
    ...(env as unknown as Record<string, unknown>),
    FCM_SERVICE_ACCOUNT: SERVICE_ACCOUNT,
    FCM_TOKEN_URI: TOKEN_URI,
    FCM_BASE_URL,
    // wrangler.jsonc의 vars.DASHBOARD_APP_ORIGIN 실값(배포 설정)이 실제 cloudflare:workers
    // env 스프레드를 통해 새어 들어오면 absoluteLink()가 링크를 절대 URL로 바꿔버려서,
    // 상대 경로를 기대하는 테스트들이 배포 설정값에 우연히 좌우된다. 기본값을 명시적으로
    // undefined로 덮어써 테스트를 배포 설정과 무관하게 만든다. 절대 URL 동작 자체는 아래
    // "DASHBOARD_APP_ORIGIN이 있으면..." 테스트가 명시적 값으로 별도 검증한다.
    DASHBOARD_APP_ORIGIN: undefined,
    ...overrides,
  } as unknown as DispatchEnv;
}

async function addDevice(
  token: string,
  platform = "web",
  transport = "fcm",
  label: string | null = null,
): Promise<void> {
  const now = Date.now();
  await testEnv.DB.prepare(
    `INSERT INTO dashboard_devices (token, platform, transport, label, enabled, created_at, last_seen_at)
     VALUES (?, ?, ?, ?, 1, ?, ?)
     ON CONFLICT(token) DO UPDATE SET last_seen_at = excluded.last_seen_at`,
  )
    .bind(token, platform, transport, label, now, now)
    .run();
}

/** 실제 수집 경로와 같은 헬퍼로 전이 한 줄을 만든다(커서 부여 방식을 두 번 구현하지 않는다). */
async function makeTransition(sessionId: string, message: string | null = "승인 필요"): Promise<PushTransition> {
  const now = Date.now();
  return appendTransition(
    testEnv.DB,
    {
      session_key: `claude-code:${sessionId}`,
      from_state: "working",
      to_state: "waiting_input",
      source: "claude-code",
      project: "/workspace/example",
      host: "example-host",
      message,
      occurred_at: now,
    },
    now,
  );
}

/** 전이 하나가 만드는 push data 페이로드(정본 push.data_keys). 스냅샷 대조의 기대값이다. */
function expectedData(transition: PushTransition, body: string): Record<string, string> {
  const title = "example · example-host · 질문·승인 대기";
  return {
    transition_id: String(transition.id),
    session_key: transition.session_key,
    state: "waiting_input",
    source: "claude-code",
    project: "/workspace/example",
    host: "example-host",
    title,
    body,
    link: `/?session=${encodeURIComponent(transition.session_key)}`,
  };
}

async function pushLogFor(transitionId: number): Promise<
  { transport: string; target: string; result: string; detail: string | null }[]
> {
  const { results } = await testEnv.DB.prepare(
    "SELECT transport, target, result, detail FROM dashboard_push_log WHERE transition_id = ? ORDER BY id",
  )
    .bind(transitionId)
    .all<{ transport: string; target: string; result: string; detail: string | null }>();
  return results ?? [];
}

beforeEach(async () => {
  // isolate 캐시가 테스트 사이로 새면 "첫 발송"을 다시 만들 수 없다.
  resetAccessTokenCache();
  await testEnv.DB.prepare("DELETE FROM dashboard_devices").run();
  await testEnv.DB.prepare("DELETE FROM dashboard_push_log").run();
});

describe("FCM OAuth 서명", () => {
  it("완료 판정(a): OAuth 스텁이 받은 JWT를 공개키로 실제 검증한다 (RS256/iss/scope/aud/iat/exp)", async () => {
    await addDevice("web-token-a");
    const transition = await makeTransition("sign");
    const stub = makeStub();
    const before = Math.floor(Date.now() / 1000);

    const result = await dispatchPush(pushEnv(), transition, { deps: { fetch: stub.fetch } });
    const after = Math.floor(Date.now() / 1000);

    expect(result.outcomes).toHaveLength(1);
    expect(result.outcomes[0]).toMatchObject({ transport: "fcm", result: "sent" });

    const tokenCalls = stub.tokenCalls();
    expect(tokenCalls).toHaveLength(1);
    // env.FCM_TOKEN_URI가 서비스 계정의 token_uri를 덮어썼다.
    expect(tokenCalls[0].url).toBe(TOKEN_URI);
    expect(tokenCalls[0].method).toBe("POST");
    expect(tokenCalls[0].headers["content-type"]).toBe("application/x-www-form-urlencoded");

    const form = new URLSearchParams(tokenCalls[0].body);
    expect(form.get("grant_type")).toBe("urn:ietf:params:oauth:grant-type:jwt-bearer");

    const jwt = form.get("assertion") ?? "";
    const [headerB64, claimsB64, signatureB64] = jwt.split(".");
    expect(signatureB64).toBeTruthy();

    const header = JSON.parse(new TextDecoder().decode(base64urlToBytes(headerB64))) as Record<string, string>;
    expect(header).toEqual({ alg: "RS256", typ: "JWT" });

    const claims = JSON.parse(new TextDecoder().decode(base64urlToBytes(claimsB64))) as Record<string, unknown>;
    expect(claims.iss).toBe(CLIENT_EMAIL);
    expect(claims.scope).toBe(SCOPE);
    expect(claims.aud).toBe(TOKEN_URI);
    expect(Number(claims.iat)).toBeGreaterThanOrEqual(before);
    expect(Number(claims.iat)).toBeLessThanOrEqual(after);
    expect(Number(claims.exp)).toBe(Number(claims.iat) + 3600);

    // 서명 검증: 버리는 키의 공개키로 `header.claims`를 실제로 확인한다.
    const verifyKey = await crypto.subtle.importKey(
      "spki",
      pemToBuffer(TEST_PUBLIC_KEY_PEM),
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    const signed = new TextEncoder().encode(`${headerB64}.${claimsB64}`);
    const signature = base64urlToBytes(signatureB64);
    expect(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", verifyKey, signature, signed)).toBe(true);

    // 검증이 진짜인지 자체 확인: 클레임을 한 글자 건드리면 실패해야 한다.
    const tampered = new TextEncoder().encode(`${headerB64}.${claimsB64}x`);
    expect(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", verifyKey, signature, tampered)).toBe(false);
  });

  it("서비스 계정의 private_key가 이 테스트 키와 같은 쌍이어야 한다(픽스처 자체 검증)", async () => {
    expect(SERVICE_ACCOUNT).toContain("BEGIN PRIVATE KEY");
    expect(TEST_PRIVATE_KEY_PEM).not.toBe(TEST_PUBLIC_KEY_PEM);
  });
});

describe("messages:send 페이로드", () => {
  it("완료 판정(b): 웹 토큰이면 data 전용 + webpush.headers.TTL + fcm_options.link", async () => {
    await addDevice("web-token-b", "web");
    const transition = await makeTransition("payload");
    const stub = makeStub();

    await dispatchPush(pushEnv(), transition, { deps: { fetch: stub.fetch } });

    const sendCalls = stub.sendCalls();
    expect(sendCalls).toHaveLength(1);
    expect(sendCalls[0].method).toBe("POST");
    expect(sendCalls[0].headers.authorization).toBe(`Bearer ${ACCESS_TOKEN}`);
    expect(sendCalls[0].headers["content-type"]).toBe("application/json");

    const sent = JSON.parse(sendCalls[0].body) as Record<string, unknown>;
    expect(sent).toEqual({
      message: {
        token: "web-token-b",
        data: expectedData(transition, "승인 필요"),
        webpush: {
          headers: { TTL: "3600" },
          fcm_options: { link: `/?session=${encodeURIComponent(transition.session_key)}` },
        },
      },
    });
    // 표시는 클라이언트가 한다 - 서버는 notification 블록을 보내지 않는다.
    expect(JSON.stringify(sent)).not.toContain("notification");
  });

  it("android 토큰이면 webpush 대신 android 블록이 붙는다", async () => {
    await addDevice("android-token", "android");
    const transition = await makeTransition("android");
    const stub = makeStub();

    await dispatchPush(pushEnv(), transition, { deps: { fetch: stub.fetch } });

    const sent = JSON.parse(stub.sendCalls()[0].body) as { message: Record<string, unknown> };
    expect(sent.message.android).toEqual({ priority: "high", ttl: "3600s" });
    expect(sent.message.webpush).toBeUndefined();
  });

  it("완료 판정(a): fcm-apns 대상은 apns.payload.aps.alert + data가 공존하고 thread-id가 session_key다", async () => {
    await addDevice("apns-token-a", "macos", "fcm-apns");
    const transition = await makeTransition("apns-alert");
    const stub = makeStub();

    await dispatchPush(pushEnv(), transition, { deps: { fetch: stub.fetch } });

    const sendCalls = stub.sendCalls();
    expect(sendCalls).toHaveLength(1);
    const sent = JSON.parse(sendCalls[0].body) as Record<string, unknown>;
    expect(sent).toEqual({
      message: {
        token: "apns-token-a",
        data: expectedData(transition, "승인 필요"),
        apns: {
          headers: { "apns-priority": "10" },
          payload: {
            aps: {
              alert: {
                title: "example · example-host · 질문·승인 대기",
                body: "승인 필요",
              },
              sound: "default",
              "thread-id": transition.session_key,
            },
          },
        },
      },
    });
    expect(sent.message).not.toHaveProperty("webpush");
    expect(sent.message).not.toHaveProperty("android");
  });

  it("완료 판정(c): 혼합 팬아웃(웹1+apns1)에서 각자 올바른 형태로 나가고 토큰 교환은 1회다", async () => {
    await addDevice("web-token-mixed", "web", "fcm");
    await addDevice("apns-token-mixed", "macos", "fcm-apns");
    const transition = await makeTransition("mixed-fanout");
    const stub = makeStub();

    const result = await dispatchPush(pushEnv(), transition, { deps: { fetch: stub.fetch } });

    expect(stub.tokenCalls()).toHaveLength(1); // 대상 채널이 같은 fcm 트랜스포트라 토큰 교환은 한 번뿐이다.
    const sendCalls = stub.sendCalls();
    expect(sendCalls).toHaveLength(2);

    const byToken = new Map(
      sendCalls.map((call) => {
        const parsed = JSON.parse(call.body) as { message: Record<string, unknown> & { token: string } };
        return [parsed.message.token, parsed.message];
      }),
    );

    const webMsg = byToken.get("web-token-mixed");
    expect(webMsg).toBeDefined();
    expect(webMsg).not.toHaveProperty("apns");
    expect(webMsg?.webpush).toEqual({
      headers: { TTL: "3600" },
      fcm_options: { link: `/?session=${encodeURIComponent(transition.session_key)}` },
    });

    const apnsMsg = byToken.get("apns-token-mixed");
    expect(apnsMsg).toBeDefined();
    expect(apnsMsg).not.toHaveProperty("webpush");
    expect((apnsMsg?.apns as { payload: { aps: { alert: { body: string }; "thread-id": string } } }).payload.aps.alert.body).toBe(
      "승인 필요",
    );
    expect((apnsMsg?.apns as { payload: { aps: { "thread-id": string } } }).payload.aps["thread-id"]).toBe(
      transition.session_key,
    );

    // 채널이 하나(fcm)뿐이라 outcome도 하나, 대상 둘 다 성공.
    expect(result.outcomes).toHaveLength(1);
    expect(JSON.parse(result.outcomes[0].detail ?? "{}")).toEqual({ sent: 2, removed: 0, failed: 0 });
  });

  it("완료 판정(d): 본문 숨기기(DASHBOARD_STORE_MESSAGE=0)면 fcm-apns의 alert.body에도 message가 없다", async () => {
    await addDevice("apns-token-private", "macos", "fcm-apns");
    const transition = await makeTransition("apns-private", "비밀 프롬프트 내용");
    const stub = makeStub();

    await dispatchPush(pushEnv({ DASHBOARD_STORE_MESSAGE: "0" }), transition, {
      deps: { fetch: stub.fetch },
    });

    const sent = JSON.parse(stub.sendCalls()[0].body) as {
      message: { apns: { payload: { aps: { alert: { body: string } } } }; data: { body: string } };
    };
    expect(sent.message.apns.payload.aps.alert.body).toBe(
      "claude-code 세션이 '질문·승인 대기' 상태가 되었습니다.",
    );
    expect(sent.message.data.body).toBe(sent.message.apns.payload.aps.alert.body);
    expect(JSON.stringify(sent)).not.toContain("비밀 프롬프트 내용");
  });

  it("DASHBOARD_APP_ORIGIN이 있으면 webpush 링크가 절대 URL이 된다", async () => {
    await addDevice("web-token-origin", "web");
    const transition = await makeTransition("origin");
    const stub = makeStub();

    await dispatchPush(pushEnv({ DASHBOARD_APP_ORIGIN: "https://dashboard.example" }), transition, {
      deps: { fetch: stub.fetch },
    });

    const sent = JSON.parse(stub.sendCalls()[0].body) as {
      message: { webpush: { fcm_options: { link: string } } };
    };
    expect(sent.message.webpush.fcm_options.link).toBe(
      `https://dashboard.example/?session=${encodeURIComponent(transition.session_key)}`,
    );
  });

  it("알림 본문 숨기기(DASHBOARD_STORE_MESSAGE=0)면 body에서 message가 빠진다", async () => {
    await addDevice("web-token-private", "web");
    const transition = await makeTransition("private", "비밀 프롬프트 내용");
    const stub = makeStub();

    await dispatchPush(pushEnv({ DASHBOARD_STORE_MESSAGE: "0" }), transition, {
      deps: { fetch: stub.fetch },
    });

    const sent = JSON.parse(stub.sendCalls()[0].body) as { message: { data: Record<string, string> } };
    expect(sent.message.data.body).toBe("claude-code 세션이 '질문·승인 대기' 상태가 되었습니다.");
    expect(JSON.stringify(sent)).not.toContain("비밀 프롬프트 내용");
  });
});

describe("액세스 토큰 캐시", () => {
  it("완료 판정(c): 두 번째 발송은 토큰 요청을 다시 하지 않는다", async () => {
    await addDevice("web-token-cache");
    const first = await makeTransition("cache-1");
    const second = await makeTransition("cache-2");
    const stub = makeStub();

    await dispatchPush(pushEnv(), first, { deps: { fetch: stub.fetch } });
    await dispatchPush(pushEnv(), second, { deps: { fetch: stub.fetch } });

    expect(stub.tokenCalls()).toHaveLength(1);
    expect(stub.sendCalls()).toHaveLength(2);
  });
});

describe("UNREGISTERED 토큰", () => {
  it("완료 판정(d): 기기 행을 그 자리에서 지우고 push_log에 남긴다", async () => {
    // 실제 FCM 등록 토큰만큼 긴 값을 쓴다 - 감사 로그가 토큰을 요약해 남기는지까지 보기 위해서.
    const DEAD_TOKEN = `dead-${"d".repeat(120)}-9f3c1a`;
    const LIVE_TOKEN = `live-${"l".repeat(120)}-2b7e40`;
    await addDevice(DEAD_TOKEN);
    await addDevice(LIVE_TOKEN);
    const transition = await makeTransition("unregistered");

    const stub = makeStub((call) => {
      const parsed = JSON.parse(call.body) as { message: { token: string } };
      if (parsed.message.token === DEAD_TOKEN) {
        return new Response(
          JSON.stringify({ error: { status: "NOT_FOUND", message: "Requested entity was not found.", details: [{ errorCode: "UNREGISTERED" }] } }),
          { status: 404 },
        );
      }
      return new Response(JSON.stringify({ name: "projects/p/messages/1" }), { status: 200 });
    });

    const result = await dispatchPush(pushEnv(), transition, { deps: { fetch: stub.fetch } });

    const remaining = await testEnv.DB.prepare("SELECT token FROM dashboard_devices").all<{ token: string }>();
    expect((remaining.results ?? []).map((row) => row.token)).toEqual([LIVE_TOKEN]);

    // 채널 요약 한 줄 + 삭제된 대상 한 줄.
    const log = await pushLogFor(transition.id);
    const summary = log.filter((row) => row.target === "all");
    const perTarget = log.filter((row) => row.target !== "all");
    expect(summary).toHaveLength(1);
    expect(JSON.parse(summary[0].detail ?? "{}")).toEqual({ sent: 1, removed: 1, failed: 0 });
    expect(perTarget).toHaveLength(1);
    expect(perTarget[0].transport).toBe("fcm");
    expect(perTarget[0].detail).toContain("대상 삭제");
    // 토큰 원문은 감사 로그에 통째로 남기지 않는다(앞뒤만 남긴 요약).
    expect(perTarget[0].target).not.toBe(DEAD_TOKEN);
    expect(perTarget[0].target).toContain("…");
    expect(perTarget[0].target.startsWith("dead-")).toBe(true);
    expect(perTarget[0].target.endsWith("9f3c1a")).toBe(true);

    expect(result.outcomes[0]).toMatchObject({ transport: "fcm", result: "sent" });
  });

  it("일반 실패(500)는 기기를 지우지 않고 failure_count·last_error만 올린다", async () => {
    await addDevice("flaky-token");
    const transition = await makeTransition("flaky");
    const stub = makeStub(() => new Response("upstream boom", { status: 500 }));

    const result = await dispatchPush(pushEnv(), transition, { deps: { fetch: stub.fetch } });

    const row = await testEnv.DB.prepare(
      "SELECT failure_count, last_error, enabled FROM dashboard_devices WHERE token = ?",
    )
      .bind("flaky-token")
      .first<{ failure_count: number; last_error: string | null; enabled: number }>();
    expect(row?.failure_count).toBe(1);
    expect(row?.last_error).toContain("500");
    expect(row?.enabled).toBe(1);

    expect(result.outcomes[0].result).toBe("failed");
    expect(JSON.parse(result.outcomes[0].detail ?? "{}")).toEqual({ sent: 0, removed: 0, failed: 1 });
  });
});

describe("채널 레지스트리", () => {
  it("완료 판정(e): FCM_SERVICE_ACCOUNT가 없으면 발송하지 않고 사유를 담아 skipped", async () => {
    await addDevice("web-token-skip");
    const transition = await makeTransition("skip");
    const stub = makeStub();

    const result = await dispatchPush(pushEnv({ FCM_SERVICE_ACCOUNT: undefined }), transition, {
      deps: { fetch: stub.fetch },
    });

    expect(stub.calls).toHaveLength(0);
    expect(result.outcomes).toEqual([
      { transport: "fcm", result: "skipped", target: "all", detail: "FCM_SERVICE_ACCOUNT 미설정" },
    ]);
    const log = await pushLogFor(transition.id);
    expect(log).toEqual([
      { transport: "fcm", target: "all", result: "skipped", detail: "FCM_SERVICE_ACCOUNT 미설정" },
    ]);
  });

  it("서비스 계정 JSON이 깨져 있으면 발송하지 않고 파싱 실패 사유를 남긴다", async () => {
    await addDevice("web-token-broken");
    const transition = await makeTransition("broken");
    const stub = makeStub();

    const result = await dispatchPush(pushEnv({ FCM_SERVICE_ACCOUNT: "{not json" }), transition, {
      deps: { fetch: stub.fetch },
    });

    expect(stub.calls).toHaveLength(0);
    expect(result.outcomes[0].result).toBe("skipped");
    expect(result.outcomes[0].detail).toContain("파싱 실패");
  });

  it("완료 판정(f): 전이 하나가 활성 채널당 한 번씩만 나간다(기기 2대 = 대상당 1회, 채널 요약 1줄)", async () => {
    await addDevice("token-1");
    await addDevice("token-2");
    const transition = await makeTransition("fanout");
    const stub = makeStub();

    const result = await dispatchPush(pushEnv(), transition, { deps: { fetch: stub.fetch } });

    const sentTokens = stub
      .sendCalls()
      .map((call) => (JSON.parse(call.body) as { message: { token: string } }).message.token);
    expect(sentTokens.sort()).toEqual(["token-1", "token-2"]);
    expect(stub.tokenCalls()).toHaveLength(1); // 대상이 여럿이어도 토큰 교환은 한 번

    expect(result.outcomes).toHaveLength(1);
    expect(result.outcomes[0].transport).toBe("fcm");
    expect(JSON.parse(result.outcomes[0].detail ?? "{}")).toEqual({ sent: 2, removed: 0, failed: 0 });

    const summary = (await pushLogFor(transition.id)).filter((row) => row.target === "all");
    expect(summary).toHaveLength(1);
  });

  it("등록된 기기가 없으면 no_target으로 닫고 발송하지 않는다", async () => {
    const transition = await makeTransition("empty");
    const stub = makeStub();

    const result = await dispatchPush(pushEnv(), transition, { deps: { fetch: stub.fetch } });

    expect(stub.sendCalls()).toHaveLength(0);
    expect(result.outcomes[0].result).toBe("no_target");
  });

  it("enabled=0인 기기는 발송 대상에서 빠진다", async () => {
    await addDevice("disabled-token");
    await testEnv.DB.prepare("UPDATE dashboard_devices SET enabled = 0 WHERE token = ?")
      .bind("disabled-token")
      .run();
    const transition = await makeTransition("disabled");
    const stub = makeStub();

    const result = await dispatchPush(pushEnv(), transition, { deps: { fetch: stub.fetch } });

    expect(stub.sendCalls()).toHaveLength(0);
    expect(result.outcomes[0].result).toBe("no_target");
  });
});

// ── 라우트 ────────────────────────────────────────────────────────────────────

interface JsonResponse<T> {
  status: number;
  json: T;
}

async function call<T = Record<string, unknown>>(
  path: string,
  init: RequestInit = {},
  useEnv: unknown = env,
): Promise<JsonResponse<T>> {
  const ctx = createExecutionContext();
  const response = await app.fetch(new Request(`http://dashboard.test${path}`, init), useEnv, ctx);
  await waitOnExecutionContext(ctx);
  return { status: response.status, json: (await response.json().catch(() => ({}))) as T };
}

function jsonBody(body: unknown): RequestInit {
  return {
    method: "POST",
    headers: { "content-type": "application/json", ...authHeaders() },
    body: JSON.stringify(body),
  };
}

describe("POST/DELETE /dashboard/devices", () => {
  it("token·transport·label을 upsert하고 last_seen_at을 갱신한다", async () => {
    const first = await call<{ ok: boolean; transport: string; platform: string; label: string | null }>(
      "/dashboard/devices",
      jsonBody({ token: "route-token", transport: "fcm", platform: "web", label: "맥북 크롬" }),
    );
    expect(first.status).toBe(200);
    expect(first.json).toMatchObject({ ok: true, transport: "fcm", platform: "web", label: "맥북 크롬" });

    const row = await testEnv.DB.prepare(
      "SELECT token, transport, label, platform, enabled, last_seen_at FROM dashboard_devices WHERE token = ?",
    )
      .bind("route-token")
      .first<{ transport: string; label: string; platform: string; enabled: number; last_seen_at: number }>();
    expect(row).toMatchObject({ transport: "fcm", label: "맥북 크롬", platform: "web", enabled: 1 });

    // 같은 토큰 재등록: 행이 늘지 않고 last_seen_at만 앞으로 간다. 실패로 내려간 행도 되살아난다.
    await testEnv.DB.prepare(
      "UPDATE dashboard_devices SET enabled = 0, failure_count = 9, last_seen_at = 1 WHERE token = ?",
    )
      .bind("route-token")
      .run();
    await call("/dashboard/devices", jsonBody({ token: "route-token", label: "맥북 크롬" }));

    const after = await testEnv.DB.prepare(
      "SELECT COUNT(*) AS n FROM dashboard_devices WHERE token = ?",
    )
      .bind("route-token")
      .first<{ n: number }>();
    expect(after?.n).toBe(1);

    const revived = await testEnv.DB.prepare(
      "SELECT enabled, failure_count, last_seen_at FROM dashboard_devices WHERE token = ?",
    )
      .bind("route-token")
      .first<{ enabled: number; failure_count: number; last_seen_at: number }>();
    expect(revived?.enabled).toBe(1);
    expect(revived?.failure_count).toBe(0);
    expect(revived?.last_seen_at).toBeGreaterThan(1);
  });

  it("완료 판정(f): transport=fcm-apns 등록이 성공한다", async () => {
    const res = await call<{ ok: boolean; transport: string; platform: string }>(
      "/dashboard/devices",
      jsonBody({ token: "apns-route-token", transport: "fcm-apns", platform: "macos" }),
    );
    expect(res.status).toBe(200);
    expect(res.json).toMatchObject({ ok: true, transport: "fcm-apns", platform: "macos" });

    const row = await testEnv.DB.prepare(
      "SELECT transport, platform, enabled FROM dashboard_devices WHERE token = ?",
    )
      .bind("apns-route-token")
      .first<{ transport: string; platform: string; enabled: number }>();
    expect(row).toMatchObject({ transport: "fcm-apns", platform: "macos", enabled: 1 });
  });

  it("transport를 안 주면 fcm으로 본다 (0001 시절 행과 같은 뜻)", async () => {
    await call("/dashboard/devices", jsonBody({ token: "legacy-shape", platform: "android" }));
    const row = await testEnv.DB.prepare("SELECT transport, platform FROM dashboard_devices WHERE token = ?")
      .bind("legacy-shape")
      .first<{ transport: string; platform: string }>();
    expect(row).toEqual({ transport: "fcm", platform: "android" });
  });

  it("token이 없거나 모르는 transport면 400", async () => {
    const noToken = await call<{ error: string }>("/dashboard/devices", jsonBody({ platform: "web" }));
    expect(noToken.status).toBe(400);
    expect(noToken.json.error).toContain("token");

    const badTransport = await call<{ error: string }>(
      "/dashboard/devices",
      jsonBody({ token: "x", transport: "carrier-pigeon" }),
    );
    expect(badTransport.status).toBe(400);
    expect(badTransport.json.error).toContain("carrier-pigeon");
  });

  it("DELETE는 토큰을 지우고, 없는 토큰이어도 200이다(멱등)", async () => {
    await call("/dashboard/devices", jsonBody({ token: "to-delete" }));

    const removed = await call<{ ok: boolean; removed: number }>("/dashboard/devices", {
      method: "DELETE",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ token: "to-delete" }),
    });
    expect(removed.status).toBe(200);
    expect(removed.json.removed).toBe(1);

    const again = await call<{ removed: number }>("/dashboard/devices", {
      method: "DELETE",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ token: "to-delete" }),
    });
    expect(again.status).toBe(200);
    expect(again.json.removed).toBe(0);
  });

  it("GET은 실패 흔적까지 함께 돌려준다", async () => {
    await call("/dashboard/devices", jsonBody({ token: "listed-token", label: "폰" }));
    const res = await call<{ devices: Record<string, unknown>[] }>("/dashboard/devices", {
      headers: authHeaders(),
    });
    expect(res.status).toBe(200);
    expect(res.json.devices).toHaveLength(1);
    expect(res.json.devices[0]).toMatchObject({
      token: "listed-token",
      transport: "fcm",
      label: "폰",
      enabled: 1,
      failure_count: 0,
      last_error: null,
    });
  });

  it("INGEST_TOKEN으로는 기기 등록을 할 수 없다 (CLIENT_TOKEN 계층)", async () => {
    const scoped = {
      ...(env as unknown as Record<string, unknown>),
      AUTH_TOKEN: undefined,
      INGEST_TOKEN: "ingest-only",
      CLIENT_TOKEN: "client-only",
    };

    const forbidden = await call<{ error: string }>(
      "/dashboard/devices",
      {
        method: "POST",
        headers: { "content-type": "application/json", authorization: "Bearer ingest-only" },
        body: JSON.stringify({ token: "nope" }),
      },
      scoped,
    );
    expect(forbidden.status).toBe(403);

    const allowed = await call<{ ok: boolean }>(
      "/dashboard/devices",
      {
        method: "POST",
        headers: { "content-type": "application/json", authorization: "Bearer client-only" },
        body: JSON.stringify({ token: "client-registered" }),
      },
      scoped,
    );
    expect(allowed.status).toBe(200);
    expect(allowed.json.ok).toBe(true);
  });
});

describe("GET /dashboard/push-config", () => {
  it("완료 판정(g): 자격증명이 없으면 channels:[]로 정직하게 답한다", async () => {
    const res = await call<{ channels: string[]; fcm: unknown }>("/dashboard/push-config", {
      headers: authHeaders(),
    });
    expect(res.status).toBe(200);
    expect(res.json.channels).toEqual([]);
    expect(res.json.fcm).toBeNull();
  });

  it("완료 판정(g): 설정돼 있으면 활성 채널과 웹 설정·VAPID 키를 그대로 전달한다", async () => {
    const configured = {
      ...(env as unknown as Record<string, unknown>),
      FCM_SERVICE_ACCOUNT: SERVICE_ACCOUNT,
      FIREBASE_WEB_CONFIG,
      FCM_WEB_VAPID_KEY: WEB_VAPID_KEY,
    };

    const res = await call<{
      channels: string[];
      fcm: { web_config: Record<string, string>; vapid_key: string; client_ready: boolean };
    }>("/dashboard/push-config", { headers: authHeaders() }, configured);

    expect(res.status).toBe(200);
    expect(res.json.channels).toEqual(["fcm"]);
    expect(res.json.fcm.web_config).toEqual(JSON.parse(FIREBASE_WEB_CONFIG));
    expect(res.json.fcm.vapid_key).toBe(WEB_VAPID_KEY);
    expect(res.json.fcm.client_ready).toBe(true);
  });

  it("서비스 계정만 있고 웹 설정이 없으면 client_ready=false로 알린다", async () => {
    const halfConfigured = {
      ...(env as unknown as Record<string, unknown>),
      FCM_SERVICE_ACCOUNT: SERVICE_ACCOUNT,
    };
    const res = await call<{ channels: string[]; fcm: { client_ready: boolean; vapid_key: null } }>(
      "/dashboard/push-config",
      { headers: authHeaders() },
      halfConfigured,
    );
    expect(res.json.channels).toEqual(["fcm"]);
    expect(res.json.fcm.client_ready).toBe(false);
    expect(res.json.fcm.vapid_key).toBeNull();
  });

  it("완료 판정(e): FIREBASE_APPLE_CONFIG 미설정이면 apple_config=null, apple_client_ready=false", async () => {
    const configured = {
      ...(env as unknown as Record<string, unknown>),
      FCM_SERVICE_ACCOUNT: SERVICE_ACCOUNT,
      FIREBASE_WEB_CONFIG,
      FCM_WEB_VAPID_KEY: WEB_VAPID_KEY,
    };

    const res = await call<{ fcm: { apple_config: unknown; apple_client_ready: boolean } }>(
      "/dashboard/push-config",
      { headers: authHeaders() },
      configured,
    );
    expect(res.json.fcm.apple_config).toBeNull();
    expect(res.json.fcm.apple_client_ready).toBe(false);
    // 웹 쪽 필드는 그대로다(무회귀) — apple_config 추가가 web_config/client_ready를 건드리지 않는다.
  });

  it("완료 판정(e): FIREBASE_APPLE_CONFIG가 있으면 그대로 전달하고 apple_client_ready=true", async () => {
    const configured = {
      ...(env as unknown as Record<string, unknown>),
      FCM_SERVICE_ACCOUNT: SERVICE_ACCOUNT,
      FIREBASE_APPLE_CONFIG,
    };

    const res = await call<{
      channels: string[];
      fcm: { apple_config: Record<string, string>; apple_client_ready: boolean; client_ready: boolean };
    }>("/dashboard/push-config", { headers: authHeaders() }, configured);

    expect(res.json.channels).toEqual(["fcm"]);
    expect(res.json.fcm.apple_config).toEqual(JSON.parse(FIREBASE_APPLE_CONFIG));
    expect(res.json.fcm.apple_client_ready).toBe(true);
    // 웹 설정이 없으니 웹 쪽은 여전히 false — 채널별로 독립 판정된다.
    expect(res.json.fcm.client_ready).toBe(false);
  });
});
