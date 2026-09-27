import {
  deleteTarget,
  markTargetFailure,
  markTargetSuccess,
  type ChannelStatus,
  type PushEnv,
  type PushMessage,
  type PushTarget,
  type PushTransport,
  type SendOutcome,
  type TransportDeps,
} from "./transport";

/**
 * FCM HTTP v1 트랜스포트.
 *
 * 원래 src/features/dashboard/fcm.ts에 있던 서명(RS256 JWT) · OAuth 토큰 교환 ·
 * messages:send 호출 로직을 그대로 옮겨 왔다. 옮기면서 더한 것만 적으면:
 *   - fetch·엔드포인트 주입(env FCM_TOKEN_URI/FCM_BASE_URL 오버라이드 + deps 파라미터).
 *     자격증명 없이도 서명과 요청 본문을 테스트로 닫기 위해서다.
 *   - PushTransport 구현(대상 하나씩 보내고 결과를 어휘로 돌려준다).
 *   - dashboard_devices 확장 컬럼(transport/label/enabled/failure_count/last_error) 반영.
 *   - 웹 토큰용 webpush 블록(headers.TTL, fcm_options.link)과 android 블록.
 *   - 액세스 토큰 isolate 캐시(원래도 있었다. 캐시 키만 서비스 계정별로 나눴다).
 *
 * 바뀐 것 하나: 메시지에 notification 블록을 넣지 않는다(data 전용).
 * 표시는 클라이언트(서비스 워커/앱)가 한다 - 그래야 '알림 본문 숨기기' 같은 클라이언트 설정이
 * 실제로 먹고, 백그라운드에서도 항상 우리 핸들러가 돌아 링크·묶음 처리를 우리가 정할 수 있다.
 * 웹 payload는 data 전용이다.
 *
 * Apple 알림 예외: transport가 "fcm-apns"인 대상(macOS 상주 앱 등
 * APNs로 받는 Apple 대상)에는 apns.payload.aps.alert를 동봉한다. data는 그대로 유지한다.
 * 이유는 OS 종료 상태에서 배너를 띄우려면 iOS/macOS는 alert가 있어야 하고, 그 표시는
 * 클라이언트 코드가 아니라 OS가 한다(앱이 떠 있지 않을 수 있어서다) - 그래서 이 채널만
 * data-only 원칙의 예외다. 앱 쪽 소유권 규칙(APNs 등록 성공 시 로컬 알림 끄기·포그라운드
 * 배너 억제)은 contracts/dashboard-protocol.v1.json의 push.channels.fcm-apns에 적었다.
 * 웹 'fcm' 대상은 지금처럼 data 전용이다(무회귀).
 */

/** 서비스 계정 JSON에서 우리가 쓰는 필드. */
export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri: string;
}

const DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token";
const DEFAULT_BASE_URL = "https://fcm.googleapis.com";
const SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

/**
 * 알림의 유효기간(초). 세션 상태 알림은 늦게 도착하면 소음이라 하루씩 살려 두지 않는다.
 * webpush.headers.TTL과 android.ttl 양쪽에 같은 값을 쓴다.
 */
export const PUSH_TTL_SECONDS = 3600;

/**
 * Workers isolate가 살아 있는 동안 OAuth 액세스 토큰을 재사용한다.
 * 키는 (client_email, token_uri) - 서비스 계정이나 엔드포인트가 바뀌면 다른 토큰이다.
 */
const tokenCache = new Map<string, { accessToken: string; expiresAt: number }>();

/** 테스트 seam. isolate가 살아 있는 채로 "처음 발송"을 다시 만들고 싶을 때 쓴다. */
export function resetAccessTokenCache(): void {
  tokenCache.clear();
}

function base64url(data: ArrayBuffer | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToPkcs8(pem: string): ArrayBuffer {
  const body = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

/** 서비스 계정으로 firebase.messaging 스코프의 OAuth 액세스 토큰을 얻는다 (FCM HTTP v1용). */
async function getAccessToken(sa: ServiceAccount, deps: TransportDeps = {}): Promise<string> {
  const doFetch = deps.fetch ?? fetch;
  const nowMs = deps.now ? deps.now() : Date.now();
  const now = Math.floor(nowMs / 1000);

  const cacheKey = `${sa.client_email}|${sa.token_uri}`;
  const cached = tokenCache.get(cacheKey);
  if (cached && cached.expiresAt > now + 60) return cached.accessToken;

  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(
    JSON.stringify({
      iss: sa.client_email,
      scope: SCOPE,
      aud: sa.token_uri,
      iat: now,
      exp: now + 3600,
    }),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  const jwt = `${header}.${claims}.${base64url(signature)}`;

  const res = await doFetch(sa.token_uri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!res.ok) {
    throw new Error(`OAuth 토큰 교환 실패: ${res.status} ${await res.text()}`);
  }
  const json = (await res.json()) as { access_token: string; expires_in: number };
  tokenCache.set(cacheKey, { accessToken: json.access_token, expiresAt: now + json.expires_in });
  return json.access_token;
}

/**
 * env의 서비스 계정 JSON을 읽는다. token_uri는 (1) env.FCM_TOKEN_URI (2) JSON의 token_uri
 * (3) 구글 기본값 순으로 정한다. 필수 필드가 없으면 던진다 - 자격증명이 반쯤 설정된 상태로
 * "보내는 척"하는 것보다 채널을 skipped로 내리는 편이 정직하다.
 */
export function parseServiceAccount(env: PushEnv): ServiceAccount {
  const parsed = JSON.parse(env.FCM_SERVICE_ACCOUNT ?? "") as Partial<ServiceAccount>;
  const projectId = parsed.project_id;
  const clientEmail = parsed.client_email;
  const privateKey = parsed.private_key;
  if (!projectId || !clientEmail || !privateKey) {
    throw new Error("project_id·client_email·private_key가 모두 있어야 한다");
  }
  return {
    project_id: projectId,
    client_email: clientEmail,
    private_key: privateKey,
    token_uri: env.FCM_TOKEN_URI || parsed.token_uri || DEFAULT_TOKEN_URI,
  };
}

function messagesSendUrl(env: PushEnv, sa: ServiceAccount): string {
  const base = (env.FCM_BASE_URL || DEFAULT_BASE_URL).replace(/\/+$/, "");
  return `${base}/v1/projects/${sa.project_id}/messages:send`;
}

/** 알림 링크. PWA origin을 알면 절대 URL로 만든다(구글은 상대 경로를 거절할 수 있다). */
function absoluteLink(env: PushEnv, link: string): string {
  const origin = env.DASHBOARD_APP_ORIGIN;
  if (!origin) return link;
  try {
    return new URL(link, origin).toString();
  } catch {
    return link;
  }
}

/**
 * apns-priority 10(즉시 전달). 세션 상태 알림은 지연 전달(5)로 묶어 낼 만큼 배치성이지
 * 않다 - 사용자가 지금 확인해야 의미가 있다.
 */
const APNS_PRIORITY_IMMEDIATE = "10";

/**
 * FCM HTTP v1 messages:send의 message 객체를 만든다.
 *
 * - data는 항상 동봉한다(표시는 원칙적으로 클라이언트가 한다).
 * - transport가 "fcm-apns"면 apns 블록(alert+sound+thread-id)을 추가로 얹는다 - 종료 상태
 *   OS 배너용 예외(모듈 주석 참고). android/webpush 블록과는 배타적이다(Apple 대상은
 *   platform이 ios/macos라 어차피 android가 아니고, apns 대상에 webpush 블록을 얹을 이유가 없다).
 * - fcm-apns가 아니면 기존 그대로: android 대상이면 android 블록, 그 밖(web 포함)이면 webpush
 *   블록. platform을 모르는 행은 web으로 본다 - 이 대시보드의 1차 클라이언트가 PWA라서다.
 */
export function buildFcmMessage(
  env: PushEnv,
  target: PushTarget,
  msg: PushMessage,
): Record<string, unknown> {
  const isApns = target.transport === "fcm-apns";
  const isAndroid = !isApns && (target.platform ?? "web").toLowerCase() === "android";
  const message: Record<string, unknown> = {
    token: target.id,
    data: msg.data,
  };

  if (isApns) {
    message.apns = {
      headers: { "apns-priority": APNS_PRIORITY_IMMEDIATE },
      payload: {
        aps: {
          alert: { title: msg.title, body: msg.body },
          sound: "default",
          "thread-id": msg.data.session_key,
        },
      },
    };
  } else if (isAndroid) {
    // android 블록 슬롯: 네이티브 앱을 붙일 때 notification 채널·클릭 액션이 여기 들어간다.
    message.android = {
      priority: "high",
      ttl: `${PUSH_TTL_SECONDS}s`,
    };
  } else {
    message.webpush = {
      headers: { TTL: String(PUSH_TTL_SECONDS) },
      fcm_options: { link: absoluteLink(env, msg.link) },
    };
  }

  return message;
}

/**
 * 발송 가능한 fcm 트랜스포트를 만든다.
 *
 * 액세스 토큰은 이 인스턴스 안에서 한 번만 요청한다(대상이 여러 개라도). isolate 캐시가
 * 살아 있으면 그 한 번마저 네트워크를 타지 않는다.
 */
export function createFcmTransport(
  env: PushEnv,
  sa: ServiceAccount,
  deps: TransportDeps = {},
): PushTransport {
  const doFetch = deps.fetch ?? fetch;
  const url = messagesSendUrl(env, sa);
  let tokenPromise: Promise<string> | null = null;

  return {
    id: "fcm",
    supports(target: PushTarget): boolean {
      // fcm-apns도 이 트랜스포트가 맡는다(같은 FCM HTTP v1 엔드포인트·자격증명, 페이로드
      // 포장만 다르다 - buildFcmMessage 참고). 별도 채널로 쪼개지 않는다.
      return target.transport === "fcm" || target.transport === "fcm-apns";
    },
    async send(target: PushTarget, msg: PushMessage): Promise<SendOutcome> {
      const nowMs = deps.now ? deps.now() : Date.now();

      // OAuth 실패는 채널 전체의 사고지 이 기기의 잘못이 아니다 - failure_count를 올리지 않는다.
      let accessToken: string;
      try {
        tokenPromise ??= getAccessToken(sa, deps);
        accessToken = await tokenPromise;
      } catch (err) {
        tokenPromise = null;
        return { ok: false, detail: `OAuth 실패: ${String(err).slice(0, 200)}` };
      }

      let res: Response;
      try {
        res = await doFetch(url, {
          method: "POST",
          headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
          body: JSON.stringify({ message: buildFcmMessage(env, target, msg) }),
        });
      } catch (err) {
        const detail = `네트워크 실패: ${String(err).slice(0, 200)}`;
        await markTargetFailure(env, target, detail, nowMs);
        return { ok: false, detail };
      }

      if (res.ok) {
        await markTargetSuccess(env, target);
        return { ok: true };
      }

      const text = await res.text();
      // 등록이 해제된 토큰은 그 자리에서 지운다(0001 시절 동작 보존).
      if (res.status === 404 || text.includes("UNREGISTERED")) {
        await deleteTarget(env, target);
        return { ok: false, remove: true, detail: `UNREGISTERED (${res.status})` };
      }

      const detail = `${res.status} ${text.slice(0, 200)}`;
      await markTargetFailure(env, target, detail, nowMs);
      console.log(`FCM 발송 실패 (${res.status}): ${text.slice(0, 300)}`);
      return { ok: false, detail };
    },
  };
}

/**
 * 레지스트리 항목. 자격증명이 없거나 깨져 있으면 transport 없이 사유만 돌려준다.
 * "FCM_SERVICE_ACCOUNT 미설정" 문구는 기존 계약이다(dashboard-ops의 test-push 응답과
 * 그 완료 판정 테스트가 이 문구를 본다).
 */
export function resolveFcmChannel(env: PushEnv, deps: TransportDeps = {}): ChannelStatus {
  if (!env.FCM_SERVICE_ACCOUNT) {
    return { id: "fcm", transport: null, skipped: "FCM_SERVICE_ACCOUNT 미설정" };
  }
  let sa: ServiceAccount;
  try {
    sa = parseServiceAccount(env);
  } catch (err) {
    return { id: "fcm", transport: null, skipped: `FCM_SERVICE_ACCOUNT 파싱 실패: ${String(err).slice(0, 200)}` };
  }
  return { id: "fcm", transport: createFcmTransport(env, sa, deps) };
}
