import { Hono } from "hono";
import {
  DEFAULT_TRANSPORT,
  activeChannelIds,
  isKnownTransport,
  type PushEnv,
} from "./transport";

/**
 * 기기 등록·해제와 클라이언트 push 설정 조회.
 *
 * dashboard/routes.ts의 옛 /devices 블록을 대신한다(그 파일은 이 서브앱을 같은 prefix에
 * 얹기만 한다). 인증은 index.ts의 CLIENT_TOKEN 계층을 그대로 탄다 - POST /dashboard/events만
 * INGEST_TOKEN 전용이고 나머지는 전부 클라이언트 토큰이라, 이 파일은 인증을 다시 하지 않는다.
 *
 * 정본: contracts/dashboard-protocol.v1.json의 push 절.
 */

export const pushRoutes = new Hono<{ Bindings: PushEnv }>();

/** FCM 등록 토큰은 보통 150~200자, Web Push endpoint는 더 길다. 넉넉히 잡고 그 이상은 거절한다. */
const TOKEN_MAX_CHARS = 4096;
const LABEL_MAX_CHARS = 100;
const PLATFORM_MAX_CHARS = 32;

/** platform을 안 알려준 클라이언트의 기본값. 이 대시보드의 1차 클라이언트가 PWA(web)다. */
const DEFAULT_PLATFORM = "web";

/**
 * POST /dashboard/devices {token, transport?, platform?, label?}
 *
 * 같은 토큰이 다시 오면 갱신만 한다(ON CONFLICT upsert + last_seen_at). 재등록은
 * "이 기기가 살아 있다"는 신고이므로 연속 실패로 내려가 있던 행(enabled=0)도 되살린다.
 */
pushRoutes.post("/devices", async (c) => {
  const body = (await c.req.json().catch(() => null)) as Record<string, unknown> | null;

  const token = body?.token;
  if (typeof token !== "string" || !token || token.length > TOKEN_MAX_CHARS) {
    return c.json({ error: `token은 ${TOKEN_MAX_CHARS}자 이하의 필수 문자열` }, 400);
  }

  const transportRaw = body?.transport;
  if (transportRaw !== undefined && transportRaw !== null && typeof transportRaw !== "string") {
    return c.json({ error: "transport는 문자열이어야 한다" }, 400);
  }
  const transport = transportRaw ? String(transportRaw) : DEFAULT_TRANSPORT;
  // 자격증명이 아직 없어도 등록은 받는다(등록이 먼저고 발송이 나중이다). 다만 서버가 모르는
  // 채널 이름은 받지 않는다 - 영영 발송되지 않을 행이 조용히 쌓이기 때문이다.
  if (!isKnownTransport(transport)) {
    return c.json({ error: `알 수 없는 transport: ${transport}` }, 400);
  }

  const platformRaw = body?.platform;
  if (platformRaw !== undefined && platformRaw !== null && typeof platformRaw !== "string") {
    return c.json({ error: "platform은 문자열이어야 한다" }, 400);
  }
  const platform = (platformRaw ? String(platformRaw) : DEFAULT_PLATFORM).slice(0, PLATFORM_MAX_CHARS);

  const labelRaw = body?.label;
  if (labelRaw !== undefined && labelRaw !== null && typeof labelRaw !== "string") {
    return c.json({ error: "label은 문자열이어야 한다" }, 400);
  }
  const label = typeof labelRaw === "string" && labelRaw.trim() ? labelRaw.slice(0, LABEL_MAX_CHARS) : null;

  const now = Date.now();
  await c.env.DB.prepare(
    `INSERT INTO dashboard_devices (token, platform, transport, label, enabled, created_at, last_seen_at)
     VALUES (?, ?, ?, ?, 1, ?, ?)
     ON CONFLICT(token) DO UPDATE SET
       platform = excluded.platform,
       transport = excluded.transport,
       label = COALESCE(excluded.label, dashboard_devices.label),
       enabled = 1,
       failure_count = 0,
       last_error = NULL,
       last_error_at = NULL,
       last_seen_at = excluded.last_seen_at`,
  )
    .bind(token, platform, transport, label, now, now)
    .run();

  return c.json({ ok: true, transport, platform, label });
});

/**
 * DELETE /dashboard/devices {token} (또는 ?token=)
 * 로그아웃·알림 끄기에서 부른다. 없는 토큰이어도 200이다(멱등).
 */
pushRoutes.delete("/devices", async (c) => {
  const body = (await c.req.json().catch(() => null)) as Record<string, unknown> | null;
  const fromBody = typeof body?.token === "string" ? body.token : null;
  const token = fromBody || c.req.query("token") || null;
  if (!token) return c.json({ error: "token은 필수 문자열" }, 400);

  const result = await c.env.DB.prepare("DELETE FROM dashboard_devices WHERE token = ?").bind(token).run();
  return c.json({ ok: true, removed: Number(result.meta?.changes ?? 0) });
});

/** GET /dashboard/devices — 등록된 기기 목록. 실패 흔적까지 같이 준다(왜 조용한지 보이게). */
pushRoutes.get("/devices", async (c) => {
  const { results } = await c.env.DB.prepare(
    `SELECT token, platform, transport, label, enabled, failure_count, last_error, last_error_at,
            created_at, last_seen_at
       FROM dashboard_devices
      ORDER BY last_seen_at DESC`,
  ).all();
  return c.json({ devices: results ?? [] });
});

/** JSON 문자열 env 값을 파싱한다. 파싱되면 객체로, 안 되면 원문 문자열 그대로 돌려준다
 * (여기서 고쳐 주지 않는다 - 잘못 설정된 값을 조용히 성형하면 진단이 어려워진다). 미설정이면 null. */
function parseJsonEnvValue(raw: string | undefined): unknown {
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return raw;
  }
}

/**
 * GET /dashboard/push-config — 클라이언트가 push 등록에 필요한 값을 받아 가는 곳.
 *
 * Firebase 웹/Apple 설정과 VAPID 공개키를 앱 번들에 굽지 않고 서버가 그대로 전달한다. 그래야
 * 프로젝트를 바꾸거나 키를 회전해도 앱을 다시 빌드하지 않는다.
 *
 * channels는 "지금 이 서버가 실제로 발송할 수 있는 채널"이다. 자격증명이 없으면 빈 배열이고,
 * 클라이언트는 등록 UI를 감추면 된다 - 보낼 수 없는데 등록만 받아 두는 것은 거짓말이다.
 *
 * client_ready는 채널(웹/Apple)마다 따로 판정한다(A안 설계 ③) - 웹은 web_config+vapid_key,
 * macOS/iOS 상주 앱은 apple_config 기준이다. 서로 다른 자격증명이라 한쪽만 설정돼도 나머지
 * 클라이언트가 등록을 시도하면 안 되기 때문이다.
 */
pushRoutes.get("/push-config", (c) => {
  const env = c.env;
  const channels = activeChannelIds(env);

  let fcm: {
    web_config: unknown;
    vapid_key: string | null;
    client_ready: boolean;
    apple_config: unknown;
    apple_client_ready: boolean;
  } | null = null;

  if (channels.includes("fcm")) {
    const webConfig = parseJsonEnvValue(env.FIREBASE_WEB_CONFIG);
    const vapidKey = env.FCM_WEB_VAPID_KEY || null;
    const appleConfig = parseJsonEnvValue(env.FIREBASE_APPLE_CONFIG);
    fcm = {
      web_config: webConfig,
      vapid_key: vapidKey,
      // 웹 클라이언트가 getToken()을 부르려면 둘 다 있어야 한다.
      client_ready: Boolean(webConfig) && Boolean(vapidKey),
      apple_config: appleConfig,
      // 상주 앱은 Firebase 초기화 옵션(apple_config) 하나면 APNs 등록을 시도할 수 있다.
      apple_client_ready: Boolean(appleConfig),
    };
  }

  return c.json({ channels, fcm });
});

export default pushRoutes;
