import { Hono } from "hono";
import type { Env } from "../env";
import { dispatchPush, type TransportOutcome } from "./dispatch";
import { appendTransition } from "./transitions";
import { TRANSPORT_IDS, activeChannelIds } from "./push";

/**
 * dashboard "운영" 엔드포인트: 진단·음소거·수동 테스트 발송.
 *
 * createDashboardApp이 수집·동기화 라우트와 같은 prefix에 이 서브앱을 마운트한다.
 *
 * 정본: contracts/dashboard-protocol.v1.json의 push.mute / push.test_push / settings.ui_lang 절.
 * diagnostics는 정본 문서에 없는 순수 운영자용 엔드포인트라 응답 모양은 이 파일이 정한다.
 */

export const dashboardOps = new Hono<{ Bindings: Env }>();

const DIAGNOSTIC_TABLES = [
  "dashboard_events",
  "dashboard_sessions",
  "dashboard_transitions",
  "dashboard_devices",
  "dashboard_push_subscriptions",
  "dashboard_push_log",
] as const;

interface CountRow {
  n: number;
}

async function tableCounts(db: D1Database): Promise<Record<string, number>> {
  const rows = await Promise.all(
    DIAGNOSTIC_TABLES.map((table) => db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<CountRow>()),
  );
  const out: Record<string, number> = {};
  DIAGNOSTIC_TABLES.forEach((table, i) => {
    out[table] = rows[i]?.n ?? 0;
  });
  return out;
}

/**
 * GET /dashboard/diagnostics — "왜 알림이 안 왔나"에 답하기 위한 운영 스냅샷.
 * 마지막 이벤트 시각, 마지막 push 결과, 기기/구독 실패 카운트, 커서 최댓값, pruned_below_id,
 * 채널별 자격증명 유무, 테이블 행수를 한 번에 돌려준다.
 */
dashboardOps.get("/diagnostics", async (c) => {
  const db = c.env.DB;

  const [lastEvent, maxTransition, prunedRow, lastPush, deviceFailures, subscriptionFailures, counts] =
    await Promise.all([
      db.prepare("SELECT MAX(received_at) AS received_at FROM dashboard_events").first<{
        received_at: number | null;
      }>(),
      db.prepare("SELECT MAX(id) AS m FROM dashboard_transitions").first<{ m: number | null }>(),
      db.prepare("SELECT value FROM dashboard_meta WHERE key = 'pruned_below_id'").first<{
        value: string | null;
      }>(),
      db
        .prepare(
          "SELECT transport, target, result, detail, created_at FROM dashboard_push_log ORDER BY id DESC LIMIT 1",
        )
        .first<{ transport: string; target: string; result: string; detail: string | null; created_at: number }>(),
      db.prepare("SELECT COUNT(*) AS n FROM dashboard_devices WHERE failure_count > 0").first<CountRow>(),
      db.prepare("SELECT COUNT(*) AS n FROM dashboard_push_subscriptions WHERE failure_count > 0").first<CountRow>(),
      tableCounts(db),
    ]);

  return c.json({
    last_event_at: lastEvent?.received_at ?? null,
    max_transition_id: maxTransition?.m ?? 0,
    pruned_below_id: Number(prunedRow?.value ?? 0) || 0,
    last_push: lastPush ?? null,
    device_failure_count: deviceFailures?.n ?? 0,
    subscription_failure_count: subscriptionFailures?.n ?? 0,
    // 채널 레지스트리는 push/transport.ts의 TRANSPORT_IDS가 정본이다(하드코딩 금지).
    // activeChannelIds(env)가 지금 실제로 발송 가능한(자격증명 있는) 채널만 걸러준다.
    channels: Object.fromEntries(
      TRANSPORT_IDS.map((id) => [id, activeChannelIds(c.env).includes(id)]),
    ),
    table_counts: counts,
  });
});

async function readMuteUntil(db: D1Database): Promise<number> {
  const row = await db.prepare("SELECT value FROM dashboard_settings WHERE key = 'mute_until'").first<{
    value: string | null;
  }>();
  return Number(row?.value ?? 0) || 0;
}

async function writeMuteUntil(db: D1Database, value: number): Promise<void> {
  await db
    .prepare(
      `INSERT INTO dashboard_settings (key, value) VALUES ('mute_until', ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
    )
    .bind(String(value))
    .run();
}

/** GET /dashboard/mute — 현재 음소거 상태 조회. */
dashboardOps.get("/mute", async (c) => {
  const now = Date.now();
  const muteUntil = await readMuteUntil(c.env.DB);
  return c.json({ mute_until: muteUntil > now ? muteUntil : null });
});

/**
 * POST /dashboard/mute {minutes} — 지금부터 minutes분 음소거. minutes<=0이면 즉시 해제.
 * dashboard_settings.mute_until만 바꾼다 — 전이 적재(수집 경로)는 이 값과 무관하게 계속된다.
 * push를 보낼 때가 되어서야(dispatch.ts.dispatchPush) 이 값을 확인해 건너뛴다.
 */
dashboardOps.post("/mute", async (c) => {
  const body = (await c.req.json().catch(() => null)) as Record<string, unknown> | null;
  const minutes = Number(body?.minutes);
  if (!Number.isFinite(minutes)) {
    return c.json({ error: "minutes는 숫자여야 한다" }, 400);
  }

  const now = Date.now();
  const muteUntil = minutes > 0 ? now + Math.floor(minutes) * 60_000 : 0;
  await writeMuteUntil(c.env.DB, muteUntil);
  return c.json({ ok: true, mute_until: muteUntil > now ? muteUntil : null });
});

/** protocol.v1.json settings.ui_lang.state_location — 서버가 아는 값은 "ko"/"en"/null(미설정) 셋뿐이다. */
type UiLang = "ko" | "en" | null;

async function readUiLang(db: D1Database): Promise<UiLang> {
  const row = await db.prepare("SELECT value FROM dashboard_settings WHERE key = 'ui_lang'").first<{
    value: string | null;
  }>();
  const value = row?.value;
  return value === "ko" || value === "en" ? value : null;
}

async function writeUiLang(db: D1Database, value: UiLang): Promise<void> {
  await db
    .prepare(
      `INSERT INTO dashboard_settings (key, value) VALUES ('ui_lang', ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
    )
    .bind(value)
    .run();
}

/** GET /dashboard/ui-lang — 현재 서버 확정값 조회(정본: settings.ui_lang). */
dashboardOps.get("/ui-lang", async (c) => {
  const uiLang = await readUiLang(c.env.DB);
  return c.json({ ui_lang: uiLang });
});

/**
 * POST /dashboard/ui-lang {lang: "ko"|"en"|null} — 확정값을 그대로 교체한다.
 * mute(writeMuteUntil)와 같은 순수 LWW다 — 단조 가드·타임스탬프·병합 규칙이 없다.
 * 명시적 null은 "선택 해제"라는 유효값이라 키 부재(400)와 구분한다(정본 settings.ui_lang.endpoint.post.request.lang).
 */
dashboardOps.post("/ui-lang", async (c) => {
  const body = (await c.req.json().catch(() => null)) as Record<string, unknown> | null;
  if (!body || !("lang" in body)) {
    return c.json({ error: "lang은 'ko'|'en'|null이어야 하고, 요청 본문에 반드시 있어야 한다" }, 400);
  }
  const lang = body.lang;
  if (lang !== "ko" && lang !== "en" && lang !== null) {
    return c.json({ error: "lang은 'ko'|'en'|null이어야 한다" }, 400);
  }

  await writeUiLang(c.env.DB, lang);
  return c.json({ ok: true, ui_lang: lang });
});

/** dispatch.ts의 TransportOutcome 한 줄을 fcm.ts SendResult 모양({sent, removed, skipped})으로 편다. */
function toChannelResult(outcome: TransportOutcome): { sent: number; removed: number; skipped?: string } {
  if (outcome.result === "sent" || outcome.result === "no_target") {
    try {
      const parsed = JSON.parse(outcome.detail ?? "{}") as { sent?: number; removed?: number; skipped?: string };
      return {
        sent: parsed.sent ?? 0,
        removed: parsed.removed ?? 0,
        ...(parsed.skipped ? { skipped: parsed.skipped } : {}),
      };
    } catch {
      return { sent: 0, removed: 0 };
    }
  }
  // skipped(자격증명 미설정 등) | failed | muted | no_target 실패 경로 전부 "안 보냈다"로 접는다.
  // detail이 곧 skip 사유다.
  return { sent: 0, removed: 0, skipped: outcome.detail ?? outcome.result };
}

/**
 * POST /dashboard/test-push {label?} — 기기 등록이 살아 있는지 확인하는 수동 발송.
 * 음소거를 무시한다(dispatchPush ignoreMute:true). 실제 세션과 무관한 합성 전이를
 * dashboard_transitions에 한 줄 남기고(자격증명 여부와 무관하게 이 적재는 항상 성공한다),
 * dispatch.ts를 그대로 거쳐 채널별 결과를 얻는다.
 */
dashboardOps.post("/test-push", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as Record<string, unknown>;
  const label = typeof body.label === "string" && body.label.trim() ? body.label.slice(0, 300) : null;

  const now = Date.now();
  const sessionKey = "ops:test-push";

  // transitions.ts의 appendTransition을 그대로 쓴다 — 커서 부여(RETURNING id) 방식을
  // 실제 수집 경로(routes.ts)와 다르게 두 번 구현하지 않기 위해서다.
  const transition = await appendTransition(
    c.env.DB,
    {
      session_key: sessionKey,
      from_state: null,
      to_state: "done",
      source: "generic",
      project: null,
      host: null,
      message: label,
      occurred_at: now,
    },
    now,
  );
  const transitionId = transition.id;

  const result = await dispatchPush(c.env, transition, {
    ignoreMute: true,
    now,
    bodyOverride: label ?? "테스트 알림입니다. 이 문구가 보이면 기기 등록이 살아 있습니다.",
  });

  const channels: Record<string, { sent: number; removed: number; skipped?: string }> = {};
  for (const outcome of result.outcomes) {
    channels[outcome.transport] = toChannelResult(outcome);
  }

  return c.json({ ok: true, transition_id: transitionId, channels });
});

export default dashboardOps;
