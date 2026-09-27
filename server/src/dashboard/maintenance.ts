import { dispatchPush, type DispatchEnv } from "./dispatch";
import { appendTransition } from "./transitions";
import { PUSH_STATES, type SessionState } from "./state";
import { DEFAULT_STALL_MS } from "./sync";

/**
 * cron 유지관리: (1) stalled 전이 스윕, (2) 보존 정리.
 * 정본: contracts/dashboard-protocol.v1.json의 states.detail.stalled.derivation 및 retention 절.
 *
 * 호스트 Worker의 scheduled 핸들러가 runDashboardMaintenance를 호출한다. 전이 적재
 * (appendTransition)·발송(dispatchPush)은 수집 경로와 같은 헬퍼를 사용한다
 * (routes.ts의 POST /events, dashboard-ops/routes.ts의 test-push와 같은 경로) - stalled 전이를
 * 여기서 다시 구현하지 않는다.
 */

/** Maintenance shares the public binding schema. */
export type MaintenanceEnv = DispatchEnv;

const DEFAULT_RETAIN_EVENT_DAYS = 7;
const DEFAULT_RETAIN_SESSION_DAYS = 7;
const DEFAULT_RETAIN_TRANSITION_DAYS = 7;
const DEFAULT_RETAIN_PUSH_LOG_DAYS = 30;
const DAY_MS = 24 * 60 * 60 * 1000;

/** dashboard_meta.hook_revs 원장 만료 정책(env로 빼지 않는다 - 다른 보존 기간과 달리 운영 조정 대상이 아니다). */
const HOOK_REVS_RETAIN_DAYS = 30;
const HOOK_REVS_MAX_ENTRIES = 32;

/** dashboard_meta.hook_revs 원장 한 host 몫. sync.ts의 HookRevEntry, routes.ts 4.5단계와 같은 모양이다. */
interface HookRevEntry {
  rev: string | null;
  at: number;
  project: string | null;
}

/** 양의 정수 env를 읽는다. 비었거나 이상하면 기본값(sync.ts의 envInt와 같은 규칙). */
function envInt(raw: string | undefined, fallback: number): number {
  const n = Number.parseInt(raw ?? "", 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function stallMs(env: MaintenanceEnv): number {
  return envInt(env.DASHBOARD_STALL_MS, DEFAULT_STALL_MS);
}

interface StalledCandidate {
  key: string;
  state: SessionState;
  source: string;
  project: string | null;
  host: string | null;
  last_message: string | null;
  last_progress_at: number | null;
}

/**
 * state='working'이고 last_progress_at이 stallMs를 넘겨 조용한 세션을 stalled로 전이한다.
 *
 * last_progress_at은 서버 수신 시각이다(states.detail.stalled.derivation) - 클라이언트
 * occurred_at은 여기서 쓰지 않는다. 느린 클라이언트 시계는 살아있는 세션을 즉시 stalled로,
 * 빠른 시계는 죽은 세션을 영영 stalled 아님으로 만들기 때문이다. 서버 시계끼리만 비교한다.
 *
 * 경합 방지: 후보를 SELECT로 고른 뒤, 전이 직전에 조건부 UPDATE
 * (`WHERE key=? AND state='working' AND last_progress_at=(그때 본 값)`)를 걸어 .meta.changes로
 * 확인한다. 그 사이 실제 진척 신호가 들어와 상태나 last_progress_at이 바뀌었으면 changes=0이라
 * 건너뛴다 - "stalled 세션에 실제 이벤트가 오면 즉시 벗어나고, 재차 stalled 적재가 중복되지
 * 않는다"는 완료 판정을 이 조건부 갱신 하나로 만족시킨다(전이는 이 갱신이 실제로 행을 바꿨을
 * 때만 쌓인다 - working이 아니게 됐거나 last_progress_at이 이미 갱신된 세션은 다시 stalled로
 * 적재되지 않는다). SELECT와 UPDATE가 같은 컬럼(last_progress_at)을 봐야 그 사이 도착한 진척
 * 신호가 누락 없이 걸러진다.
 */
async function stallWorkingSessions(env: MaintenanceEnv, now: number): Promise<number> {
  const cutoff = now - stallMs(env);

  const { results } = await env.DB.prepare(
    `SELECT key, state, source, project, host, last_message, last_progress_at
       FROM dashboard_sessions
      WHERE state = 'working' AND COALESCE(last_progress_at, 0) < ?`,
  )
    .bind(cutoff)
    .all<StalledCandidate>();

  let stalled = 0;
  for (const row of results ?? []) {
    const updated = await env.DB.prepare(
      `UPDATE dashboard_sessions SET state = 'stalled', updated_at = ?
         WHERE key = ? AND state = 'working' AND COALESCE(last_progress_at, 0) = ?`,
    )
      .bind(now, row.key, row.last_progress_at ?? 0)
      .run();
    if ((updated.meta?.changes ?? 0) === 0) continue; // 그 사이 실제 이벤트가 들어와 이미 벗어났다

    const transition = await appendTransition(
      env.DB,
      {
        session_key: row.key,
        from_state: row.state,
        to_state: "stalled",
        source: row.source,
        project: row.project,
        host: row.host,
        message: row.last_message,
        occurred_at: now,
      },
      now,
    );
    stalled += 1;

    // stalled는 protocol.v1.json push_states.enum에 늘 포함된다(state.ts.PUSH_STATES) -
    // routes.ts의 push 판정과 같은 모양으로 남겨 둔다(어휘가 바뀌어도 조용히 따라가게).
    if (PUSH_STATES.has("stalled")) {
      await dispatchPush(env, transition).catch((err) =>
        console.log(`stalled push 발송 실패(무시): ${String(err)}`),
      );
    }
  }
  return stalled;
}

export interface RetentionResult {
  eventsDeleted: number;
  sessionsDeleted: number;
  transitionsDeleted: number;
  prunedBelowId: number;
  /** 이번 cron에서 지운 dashboard_seen 행 수(세션과 함께 지운 것 + 고아 정리로 지운 것 합계). */
  seenDeleted: number;
  /** 이번 cron에서 지운 dashboard_push_log 행 수. */
  pushLogDeleted: number;
}

/**
 * dashboard_meta.hook_revs 원장 만료 - 새 로직은 여기 순수 함수 하나에만 두고(SoC),
 * 호출부(pruneRetention)는 읽기·쓰기만 한다.
 *
 * 두 규칙을 순서대로 적용한다:
 *  1) at이 HOOK_REVS_RETAIN_DAYS(30일)보다 오래된 항목은 지운다 - routes.ts UPSERT의 마지막
 *     절이 "값이 그대로여도 24시간마다 한 번씩 at을 최신화"하므로, 살아서 계속 보고하는
 *     기계라면 at이 30일 넘게 오래될 수 없다. 그만큼 오래 못 봤다면 더는 보고하지 않는
 *     기계로 본다.
 *  2) 그러고도 HOOK_REVS_MAX_ENTRIES(32)개를 넘으면 at이 오래된 것부터 지워 32개로 자른다 -
 *     무한정 늘어난 호스트 목록이 sync 응답 크기를 키우는 걸 막는 상한이다.
 *
 * 두 규칙 다 "지우기"만 하고 추가하지 않으므로, 반환값의 항목 수가 입력과 같다면 아무것도
 * 지워지지 않은 것이다(호출부가 이 사실로 "실제로 바뀌었는가"를 싸게 판단한다).
 */
function pruneHookRevs(
  hookRevs: Record<string, HookRevEntry>,
  now: number,
): Record<string, HookRevEntry> {
  const cutoff = now - HOOK_REVS_RETAIN_DAYS * DAY_MS;
  const entries = Object.entries(hookRevs).filter(([, entry]) => entry.at >= cutoff);
  entries.sort((a, b) => b[1].at - a[1].at); // 최신순 - 자를 때 오래된 쪽부터 버려야 하므로.
  return Object.fromEntries(entries.slice(0, HOOK_REVS_MAX_ENTRIES));
}

async function deleteAndCount(db: D1Database, sql: string, ...params: number[]): Promise<number> {
  const result = await db.prepare(sql).bind(...params).run();
  return result.meta?.changes ?? 0;
}

/** deleteAndCount와 같지만 바인딩할 파라미터가 없는(하드코딩된 조건만 있는) DELETE용. */
async function deleteAndCountNoParam(db: D1Database, sql: string): Promise<number> {
  const result = await db.prepare(sql).run();
  return result.meta?.changes ?? 0;
}

/**
 * 보존 정리 + dashboard_meta.pruned_below_id 갱신.
 *
 * dashboard_transitions.id는 sync 커서다(sync.ts). 정리로 전이를 지우면 그 경계를
 * pruned_below_id에 남겨야 GET /dashboard/sync가 이제는 없는 커서를 reset으로 되돌릴 수 있다
 * (정본: retention.cursor_hole). id와 created_at은 삽입 시점에 함께 단조 증가하므로
 * "created_at < cutoff로 지운다"는 늘 id 공간의 앞쪽 구간을 정확히 지우는 것과 같다 - 그래서
 * 지우기 "전에" `MAX(id) WHERE created_at < cutoff`를 구해 두면 그게 곧 새로 사라진 경계다.
 * pruned_below_id는 절대 뒤로 가지 않는다(sync.ts의 커서와 같은 단조 규칙) - 그래서 기존 값과
 * max(지운 id)+1 중 큰 쪽을 취한다.
 */
async function pruneRetention(env: MaintenanceEnv, now: number): Promise<RetentionResult> {
  const eventCutoff = now - envInt(env.DASHBOARD_RETAIN_EVENT_DAYS, DEFAULT_RETAIN_EVENT_DAYS) * DAY_MS;
  const sessionCutoff = now - envInt(env.DASHBOARD_RETAIN_SESSION_DAYS, DEFAULT_RETAIN_SESSION_DAYS) * DAY_MS;
  const transitionCutoff =
    now - envInt(env.DASHBOARD_RETAIN_TRANSITION_DAYS, DEFAULT_RETAIN_TRANSITION_DAYS) * DAY_MS;
  const pushLogCutoff =
    now - envInt(env.DASHBOARD_RETAIN_PUSH_LOG_DAYS, DEFAULT_RETAIN_PUSH_LOG_DAYS) * DAY_MS;

  // idx_dashboard_events_received (received_at) 축을 그대로 쓴다 - 보존은 "얼마나 오래 들고
  // 있었나"(수신 시각)의 문제이지, 클라이언트가 신고한 occurred_at(위조 가능)의 문제가 아니다.
  const eventsDeleted = await deleteAndCount(
    env.DB,
    `DELETE FROM dashboard_events
      WHERE received_at < ?
        AND NOT (
          event = 'UserPromptSubmit' AND EXISTS (
            SELECT 1 FROM dashboard_sessions AS session
             WHERE session.key = dashboard_events.session_key
               AND (session.state <> 'ended' OR session.updated_at >= ?)
          )
        )`,
    eventCutoff,
    sessionCutoff,
  );

  // scope: state in (ended) (retention.policies.dashboard_sessions.scope). 살아있는 세션은
  // 나이와 무관하게 남는다.
  //
  // dashboard_seen은 이 세션들이 지워지기 "전에" 먼저 지운다 - 서브쿼리가 대상 세션을 찾을 수
  // 있어야 하기 때문이다(순서가 뒤바뀌면 조건에 맞는 세션이 이미 없어 아무것도 못 지운다).
  // rebuild.ts는 이 테이블을 절대 건드리지 않지만(불가침), 사람이 세션 자체를 지우기로 한
  // 이상(보존 기간 만료) 그 세션에 대한 열람 기록만 따로 남겨 둘 이유가 없다 - 세션이 없으면
  // last_transition_id도 없으므로 미확인/읽음 판정 자체가 의미를 잃는다.
  let seenDeleted = await deleteAndCount(
    env.DB,
    "DELETE FROM dashboard_seen WHERE session_key IN (SELECT key FROM dashboard_sessions WHERE state = 'ended' AND updated_at < ?)",
    sessionCutoff,
  );

  const sessionsDeleted = await deleteAndCount(
    env.DB,
    "DELETE FROM dashboard_sessions WHERE state = 'ended' AND updated_at < ?",
    sessionCutoff,
  );

  // 고아 정리(안전망): 세션 삭제 경로가 이 함수(위)와 DELETE /dashboard/sessions/:key
  // (routes.ts) 두 곳이라 사람이 직접 지우는 경로도 이미 같이 치우지만, 그와 무관하게 매
  // cron 주기마다 한 번 더 "지금 시점에 세션이 없는" dashboard_seen 행을 훑어 지운다 -
  // 두 삭제 경로 중 하나가 이후에 바뀌거나 놓친 경우를 대비하는 일반적인 안전망이다.
  seenDeleted += await deleteAndCountNoParam(
    env.DB,
    "DELETE FROM dashboard_seen WHERE session_key NOT IN (SELECT key FROM dashboard_sessions)",
  );

  const maxPrunedRow = await env.DB.prepare(
    "SELECT MAX(id) AS max_id FROM dashboard_transitions WHERE created_at < ?",
  )
    .bind(transitionCutoff)
    .first<{ max_id: number | null }>();
  const maxPrunedId = maxPrunedRow?.max_id ?? null;

  const transitionsDeleted = await deleteAndCount(
    env.DB,
    "DELETE FROM dashboard_transitions WHERE created_at < ?",
    transitionCutoff,
  );

  // idx_dashboard_push_log_created (created_at) 축을 그대로 쓴다 - 커서·bookkeeping이 없는
  // 감사 로그라 events/transitions와 달리 pruned_below_id 같은 후속 처리가 필요 없다.
  const pushLogDeleted = await deleteAndCount(
    env.DB,
    "DELETE FROM dashboard_push_log WHERE created_at < ?",
    pushLogCutoff,
  );

  const currentRow = await env.DB.prepare(
    "SELECT value FROM dashboard_meta WHERE key = 'pruned_below_id'",
  ).first<{ value: string | null }>();
  const current = Number(currentRow?.value ?? 0) || 0;

  let prunedBelowId = current;
  if (maxPrunedId !== null) {
    prunedBelowId = Math.max(current, maxPrunedId + 1);
    await env.DB.prepare(
      `INSERT INTO dashboard_meta (key, value) VALUES ('pruned_below_id', ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
    )
      .bind(String(prunedBelowId))
      .run();
  }

  // dashboard_meta.hook_revs 만료(위 pruneHookRevs) - rebuild.ts는 이 키를 절대 건드리지
  // 않지만(dashboard_seen과 같은 불가침 tier, rebuild.ts 헤더 참고) 이 cron은 dashboard_meta의
  // 다른 키(pruned_below_id)도 이미 여기서 읽고 쓰므로 같은 자리에서 같이 처리한다.
  // "실제로 바뀌었을 때만 다시 쓴다" - pruneHookRevs가 항목을 하나도 안 지웠다면(entries 수가
  // 그대로라면) 쓰기 자체를 건너뛴다.
  const hookRevsRow = await env.DB.prepare(
    "SELECT value FROM dashboard_meta WHERE key = 'hook_revs'",
  ).first<{ value: string | null }>();
  if (hookRevsRow?.value) {
    let hookRevs: Record<string, HookRevEntry> = {};
    try {
      const parsed = JSON.parse(hookRevsRow.value) as unknown;
      if (parsed && typeof parsed === "object") hookRevs = parsed as Record<string, HookRevEntry>;
    } catch {
      hookRevs = {};
    }
    const originalCount = Object.keys(hookRevs).length;
    const pruned = pruneHookRevs(hookRevs, now);
    if (Object.keys(pruned).length !== originalCount) {
      await env.DB.prepare(
        `INSERT INTO dashboard_meta (key, value) VALUES ('hook_revs', ?)
           ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
      )
        .bind(JSON.stringify(pruned))
        .run();
    }
  }

  return { eventsDeleted, sessionsDeleted, transitionsDeleted, prunedBelowId, seenDeleted, pushLogDeleted };
}

export interface MaintenanceResult extends RetentionResult {
  stalled: number;
}

/**
 * 호스트 Worker가 예약 실행에서 호출하는 진입점.
 * 순서: stalled 판정을 먼저 하고 보존 정리를 나중에 한다 - 이번 cron에서 새로 stalled로 쌓인
 * 전이까지 포함해 pruned_below_id 계산이 항상 "이 시점의 전이 테이블 전체"를 기준으로 일관되게
 * 나오게 하기 위해서다(정리를 먼저 하면 결과가 달라지지는 않지만, 순서를 고정해 두는 편이
 * 추론하기 쉽다).
 */
export async function runDashboardMaintenance(env: MaintenanceEnv, now: number): Promise<MaintenanceResult> {
  const stalled = await stallWorkingSessions(env, now);
  const retention = await pruneRetention(env, now);
  return { stalled, ...retention };
}
