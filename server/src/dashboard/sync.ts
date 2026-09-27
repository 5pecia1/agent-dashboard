import { Hono } from "hono";
import type { Env } from "../env";
import { HOOK_REV } from "../hooks/routes";
import { STALE_MS } from "./state";

/**
 * 커서 동기화 읽기 계층 — GET /dashboard/sync.
 *
 * 클라이언트가 쓰는 유일한 조회 엔드포인트다. 커서 하나로 스냅샷(reset)과 델타가 수렴한다.
 * push는 "깨워주는 힌트"일 뿐이고 정합성은 언제나 이 엔드포인트의 커서 재조회가 담보한다.
 *
 * 어휘와 응답 필드의 정본은 같은 디렉터리의 protocol.v1.json `sync` 절이다. 이 파일은 그 절을
 * 그대로 구현한다.
 *
 * 배선(라우터 마운트)은 이 파일 밖의 일이다. src/index.ts가 `dashboard`를 붙이는 것과 같은 방식으로
 *   app.route("/dashboard", syncRoutes)
 * 하면 GET /dashboard/sync가 된다. 테스트는 이 모듈을 직접 인스턴스화해서 부른다.
 */

/**
 * sync가 읽는 env. 아직 env.ts에 없는 값은 선택 필드로 둔다
 * DashboardEnv의 공통 설정을 사용한다.
 */
export type SyncEnv = Env;

/** protocol.v1.json sync.query.limit */
export const DEFAULT_LIMIT = 200;
export const MAX_LIMIT = 1000;

/** protocol.v1.json states.detail.stalled.derivation.env.default_ms */
export const DEFAULT_STALL_MS = 5 * 60 * 1000;

/** protocol.v1.json sync.session_object + legacy stale 플래그. */
export interface SyncSession {
  key: string;
  source: string;
  session_id: string;
  project: string;
  host: string | null;
  state: string;
  last_event: string;
  last_message: string | null;
  last_occurred_at: number | null;
  /**
   * 마지막 진척 신호를 서버가 받은 시각(epoch ms, 서버 시계). 상태를 바꾼 이벤트와
   * heartbeat_events만 민다 - 기록만 되는 이벤트는 밀지 않는다(A안 원칙). stalled 판정과
   * 클라이언트의 곧-멈춘-듯 표시가 둘 다 이 값을 쓰고 server_time과 비교한다(sync.session_object).
   */
  last_progress_at: number | null;
  /**
   * 이 세션에 대해 dashboard_transitions에 마지막으로 적재된 행의 id. seen(읽음/안읽음)의
   * 기준값 - 미확인 = last_transition_id > seen_transition_id(0004_dashboard_seen.sql,
   * seen.ts). 전이가 한 번도 없던 세션은 null이다.
   *
   * seen_transition_id는 더 이상 이 객체에 없다(읽음 단일 표현 - 같은 사실의 복수 표현
   * 금지) - SyncResponse.seen(top-level, SyncSeen[])에서 mute_until과 같은 "절대값 서버
   * 상태"로 매 응답에 절대값 동봉된다. 아래 readSeen() 참고.
   */
  last_transition_id: number | null;
  created_at: number;
  updated_at: number;
  /**
   * 0001 시절의 stale 불린 플래그. 새 어휘에서는 파생 상태 stalled가 이 역할을 넘겨받지만
   * (그건 cron이 만든다), 스냅샷을 그대로 쓰는 기존 화면을 위해 계속 계산해 준다.
   * 기준 시각은 legacy GET /dashboard/sessions와 똑같이 서버 시각인 updated_at이다
   * (last_occurred_at은 클라이언트 시계라 서버 now와 비교하면 시계 차가 섞인다).
   */
  stale: boolean;
}

/** protocol.v1.json sync.transition_object. */
export interface SyncTransition {
  id: number;
  session_key: string;
  from_state: string | null;
  to_state: string;
  source: string;
  project: string | null;
  host: string | null;
  message: string | null;
  occurred_at: number;
  created_at: number;
}

/**
 * protocol.v1.json sync.seen_object. 응답 최상위 seen 배열의 원소 하나 - 세션 하나의 확인
 * 처리 마커. mute_until과 같은 "절대값 서버 상태" 선례를 따라 reset 값과 무관하게 매
 * 응답(스냅샷·델타 공통)에 항상 배열 전체가 실린다(읽음 단일 표현). 아래 readSeen() 참고.
 */
export interface SyncSeen {
  key: string;
  seen_transition_id: number | null;
}

/**
 * protocol.v1.json sync.hook_skew_object. "훅 구버전 배너" 기능의 응답 원소 하나 - 서버의
 * 현재 HOOK_REV(hooks/routes.ts)와 다른 rev를 마지막으로 보고한 기계 하나.
 *
 * seen과 달리 MAX-merge 대상이 아니다 - mute_until과 같은 "절대값 서버 상태"로, 매 응답에
 * dashboard_meta.hook_revs 원장 전체를 훑어 다시 계산한 배열을 그대로 덮어쓴다(클라이언트는
 * 로컬 값과 병합하지 않고 그대로 교체한다). rev가 null이면 그 훅이 아직 hook_rev 필드를
 * 보고한 적이 없다는 뜻이고(구버전 훅이거나, 서버로부터 아직 rev를 치환받지 못한 원본
 * 실행), 이 역시 "서버의 현재 rev와 다르다"로 취급해 배열에 포함한다 - 판정은
 * `rev !== HOOK_REV` 한 줄뿐이다(rev 부재와 rev 낡음 사이에 우선순위 없음).
 *
 * project - devcontainer처럼 host(hostname)만으로는 사람이 식별할 수 없는 환경(식별 예:
 * "235f7d6e85ff" 류 컨테이너 ID)을 배너에서 구분하기 위한 additive 힌트다. routes.ts
 * 4.5단계가 이 host로부터 마지막 신고를 받은 세션의 project(cwd)를 그대로 원장에 얹어
 * 둔 값이라 "지금 이 host의 project"가 아니라 "이 host가 마지막으로 hook_rev를 신고한
 * 순간의 project"다 - session_object.project와 같은 원문 그대로(경로 전체)이고, basename
 * 추림은 표시 계층(앱) 몫이다. 원장에 그 host가 아직 없거나 project를 신고한 적 없으면 null.
 */
export interface SyncHookSkew {
  host: string;
  rev: string | null;
  project: string | null;
}

/** protocol.v1.json sync.response.fields. sessions와 transitions는 항상 둘 다 존재한다. */
export interface SyncResponse {
  protocol_version: number;
  reset: boolean;
  cursor: number;
  has_more: boolean;
  server_time: number;
  pruned_below_id: number;
  stall_ms: number;
  mute_until: number | null;
  /**
   * settings.ui_lang의 확정값(protocol.v1.json sync.response.fields.ui_lang) — mute_until과
   * 같은 "절대값 서버 상태"로 reset 여부와 무관하게 매 응답에 항상 무조건 대입된다(seen의
   * MAX 병합이 아니다). null이면 서버 규범이 없다 - 각 기기가 플랫폼 로케일을 쓴다.
   */
  ui_lang: "ko" | "en" | null;
  /**
   * 세션별 확인 처리 마커(protocol.v1.json sync.response.fields.seen) - mute_until과 같은
   * "절대값 서버 상태"로 reset 값과 무관하게 매 응답에 항상 전체가 동봉된다. 범위는 스냅샷의
   * sessions와 동일(비-ended 세션, include_ended 쿼리와 무관). 클라이언트는 수신 값을 로컬
   * 값과 MAX로 멱등 병합한다 - 낙관 갱신 직후 비행 중이던 옛 응답이 뒤늦게 도착해 방금 올린
   * 로컬 값을 되돌리는 깜빡임을 막는다.
   */
  seen: SyncSeen[];
  /**
   * "훅 구버전 배너"(protocol.v1.json sync.response.fields.hook_skew) - 서버의 현재 rev와
   * 다른(또는 아직 한 번도 보고한 적 없는) 훅을 쓰는 기계 목록. mute_until·seen과 같은
   * "절대값 서버 상태"로 reset 값과 무관하게 매 응답에 항상 전체가 동봉된다. seen과 달리
   * MAX-merge가 아니라 그때그때 dashboard_meta.hook_revs 원장 전체를 다시 훑어 계산한
   * 배열을 그대로 덮어쓴다(무조건 대입) - 위 SyncHookSkew 참고.
   */
  hook_skew: SyncHookSkew[];
  sessions: SyncSession[];
  transitions: SyncTransition[];
  /**
   * 이번 델타가 건드린 session_key 목록(등장 순서, 중복 제거).
   * reset:true면 빈 배열이다. 클라이언트가 "어느 카드를 다시 그릴지"를 transitions를 훑지 않고
   * 바로 알 수 있게 얹은 편의 필드다. 세션의 내용은 transitions가 이미 다 담고 있다.
   */
  sessions_touched: string[];
}

/** 파싱이 끝난 질의 인자. since가 null이면 스냅샷(reset)을 뜻한다. */
export interface SyncQuery {
  since: number | null;
  limit: number;
  includeEnded: boolean;
}

interface MetaRow {
  key: string;
  value: string | null;
}

/** 양의 정수 env를 읽는다. 비었거나 이상하면 기본값. */
function envInt(raw: string | undefined, fallback: number): number {
  const n = Number.parseInt(raw ?? "", 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function staleMs(env: SyncEnv): number {
  return envInt(env.DASHBOARD_STALE_MS, STALE_MS);
}

function stallMs(env: SyncEnv): number {
  return envInt(env.DASHBOARD_STALL_MS, DEFAULT_STALL_MS);
}

/**
 * 질의 인자를 파싱한다.
 *
 * since: 정수로 읽히지 않으면(없음·빈 문자열·"abc") null 로 본다 = 스냅샷.
 *        모르는 커서에 델타를 주느니 스냅샷을 주는 쪽이 언제나 수렴한다.
 * limit: 1..MAX_LIMIT로 조인다. 이상한 값은 기본값.
 */
export function parseSyncQuery(params: URLSearchParams): SyncQuery {
  const rawSince = params.get("since");
  const parsedSince = rawSince === null || rawSince.trim() === "" ? Number.NaN : Number(rawSince);
  const since = Number.isInteger(parsedSince) ? parsedSince : null;

  const parsedLimit = Number(params.get("limit"));
  const limit = Number.isInteger(parsedLimit) && parsedLimit > 0
    ? Math.min(parsedLimit, MAX_LIMIT)
    : DEFAULT_LIMIT;

  return { since, limit, includeEnded: params.get("include_ended") === "1" };
}

/** dashboard_meta.hook_revs 원장 한 host 몫. write 쪽(routes.ts 4.5단계)이 쓰는 것과 같은 모양이다. */
interface HookRevEntry {
  rev: string | null;
  at: number;
  project: string | null;
}

/** dashboard_meta / dashboard_settings / 전이 최대 id를 한 트랜잭션(batch)으로 읽는다. */
async function readHeader(env: SyncEnv): Promise<{
  protocolVersion: number;
  prunedBelowId: number;
  muteUntilRaw: number;
  uiLang: "ko" | "en" | null;
  maxTransitionId: number | null;
  hookRevs: Record<string, HookRevEntry>;
}> {
  // hook_revs를 readSeen()처럼 별도 쿼리로 새로 만들지 않는다 - 이미 존재하는 이 batch의
  // IN 목록에 키 하나만 더한다(추가 왕복 없음). buildSync의 hook_skew 계산은 순수 CPU
  // 연산이다(아래 참고). dashboard_settings도 같은 요령이다 - mute_until 하나만 읽던 두 번째
  // 문장의 WHERE를 IN 목록으로 넓혀 ui_lang을 얹는다(batch 문장 수는 여전히 3, 왕복 증가 0).
  const [meta, settings, maxId] = await env.DB.batch<Record<string, unknown>>([
    env.DB.prepare(
      "SELECT key, value FROM dashboard_meta WHERE key IN ('pruned_below_id', 'protocol_version', 'hook_revs')",
    ),
    env.DB.prepare("SELECT key, value FROM dashboard_settings WHERE key IN ('mute_until', 'ui_lang')"),
    env.DB.prepare("SELECT MAX(id) AS max_id FROM dashboard_transitions"),
  ]);

  const metaMap = new Map<string, string | null>(
    ((meta.results ?? []) as unknown as MetaRow[]).map((row) => [row.key, row.value]),
  );
  const settingsMap = new Map<string, string | null>(
    ((settings.results ?? []) as unknown as MetaRow[]).map((row) => [row.key, row.value]),
  );
  const rawMax = ((maxId.results ?? []) as unknown as Array<{ max_id: number | null }>)[0]?.max_id;
  const rawMute = settingsMap.get("mute_until");
  const rawUiLang = settingsMap.get("ui_lang");

  let hookRevs: Record<string, HookRevEntry> = {};
  const rawHookRevs = metaMap.get("hook_revs");
  if (rawHookRevs) {
    try {
      const parsed = JSON.parse(rawHookRevs) as unknown;
      if (parsed && typeof parsed === "object") hookRevs = parsed as Record<string, HookRevEntry>;
    } catch {
      // 손상된 JSON이면 조용히 빈 원장으로 - hook_skew는 additive 배너 기능이라 이 한 줄
      // 파싱 실패가 sync 응답 전체를 깨서는 안 된다.
    }
  }

  return {
    protocolVersion: Number(metaMap.get("protocol_version") ?? 1) || 1,
    prunedBelowId: Number(metaMap.get("pruned_below_id") ?? 0) || 0,
    muteUntilRaw: Number(rawMute ?? 0) || 0,
    // settings.ui_lang: non-null이면 그 값이 규범, 그 밖은(행 부재·NULL·손상된 값 전부) null.
    uiLang: rawUiLang === "ko" || rawUiLang === "en" ? rawUiLang : null,
    maxTransitionId: typeof rawMax === "number" ? rawMax : null,
    hookRevs,
  };
}

/**
 * 전체 스냅샷(프로젝션 dashboard_sessions)을 읽는다.
 * legacy GET /dashboard/sessions와 같은 정렬·필터·stale 계산을 쓴다.
 *
 * seen_transition_id는 더 이상 이 조회에 없다(읽음 단일 표현) - dashboard_seen을 JOIN할
 * 필요가 사라졌다. 그 값은 readSeen()이 응답 최상위 seen 배열로 따로 실어 나른다.
 */
async function readSessions(env: SyncEnv, includeEnded: boolean, now: number): Promise<SyncSession[]> {
  const columns =
    "key, source, session_id, project, host, state, last_event, last_message, " +
    "last_occurred_at, last_progress_at, last_transition_id, created_at, updated_at";
  const stmt = includeEnded
    ? env.DB.prepare(`SELECT ${columns} FROM dashboard_sessions ORDER BY updated_at DESC`)
    : env.DB.prepare(
        `SELECT ${columns} FROM dashboard_sessions WHERE state != 'ended' ORDER BY updated_at DESC`,
      );
  const { results } = await stmt.all<Omit<SyncSession, "stale">>();
  const threshold = staleMs(env);
  return (results ?? []).map((s) => ({
    ...s,
    stale: s.state !== "ended" && now - s.updated_at > threshold,
  }));
}

/**
 * 세션별 확인 처리 마커(protocol.v1.json sync.seen_object)를 읽는다.
 *
 * 범위는 항상 비-ended 세션이다(스냅샷 sessions의 기본 범위와 동일) - include_ended 쿼리
 * 파라미터는 여기 영향을 주지 않는다("범위는 스냅샷과 동일(비-ended 세션)" 판정). mute_until과
 * 같은 "절대값 서버 상태"이므로 reset 여부와 무관하게 buildSync가 매 응답에 이 전체를 싣는다.
 *
 * dashboard_seen을 LEFT JOIN해서 얹는다 - 한 번도 seen을 호출한 적 없는 세션은 dashboard_seen에
 * 행 자체가 없으므로(seen.ts의 markSeenAtLeast가 처음 호출될 때 비로소 행이 생긴다) LEFT JOIN이
 * 자연스럽게 null을 채운다(INNER JOIN이면 그런 세션이 배열에서 통째로 빠지는 사고가 난다) -
 * "범위는 스냅샷과 동일"이 요구하는 세션 키 집합(모든 비-ended 세션)을 그대로 지킨다.
 */
async function readSeen(env: SyncEnv): Promise<SyncSeen[]> {
  const { results } = await env.DB.prepare(
    `SELECT dashboard_sessions.key AS key, dashboard_seen.seen_transition_id AS seen_transition_id
       FROM dashboard_sessions
       LEFT JOIN dashboard_seen ON dashboard_seen.session_key = dashboard_sessions.key
      WHERE dashboard_sessions.state != 'ended'
      ORDER BY dashboard_sessions.key ASC`,
  ).all<SyncSeen>();
  return results ?? [];
}

/** since 이후 전이를 id 오름차순으로 limit개까지. has_more 판정을 위해 한 줄 더 읽는다. */
async function readTransitions(
  env: SyncEnv,
  since: number,
  limit: number,
): Promise<{ transitions: SyncTransition[]; hasMore: boolean }> {
  const { results } = await env.DB.prepare(
    `SELECT id, session_key, from_state, to_state, source, project, host, message, occurred_at, created_at
       FROM dashboard_transitions
      WHERE id > ?
      ORDER BY id ASC
      LIMIT ?`,
  )
    .bind(since, limit + 1)
    .all<SyncTransition>();

  const rows = results ?? [];
  const hasMore = rows.length > limit;
  return { transitions: hasMore ? rows.slice(0, limit) : rows, hasMore };
}

/**
 * 응답 본문을 만든다. 라우터 없이도 부를 수 있게 순수 함수로 떼어 둔다(테스트·cron 재사용).
 *
 * reset 판정(protocol.v1.json sync.reset_rules):
 *  - since가 없으면 reset
 *  - since + 1 < pruned_below_id면 다음에 받을 전이가 이미 정리되어 사라졌으므로 reset
 *  - since가 전이 로그의 끝을 넘으면 reset (아래 cursorCeiling 참고)
 *  - 그 밖에는 델타
 */
export async function buildSync(env: SyncEnv, query: SyncQuery, now: number): Promise<SyncResponse> {
  const header = await readHeader(env);

  const base = {
    protocol_version: header.protocolVersion,
    server_time: now,
    pruned_below_id: header.prunedBelowId,
    stall_ms: stallMs(env),
    // 지난 시각은 음소거가 아니다. 정본: "null이면 음소거 아님".
    mute_until: header.muteUntilRaw > now ? header.muteUntilRaw : null,
    // settings.ui_lang 확정값. mute_until과 같은 무조건 대입(절대값) - MAX 병합 대상이 아니다.
    ui_lang: header.uiLang,
    // mute_until과 같은 "절대값 서버 상태" - reset 여부와 무관하게 매 응답에 항상 동봉한다
    // (읽음 단일 표현). 아래 두 return 모두 이 base를 스프레드하므로 스냅샷·델타 공통이다.
    seen: await readSeen(env),
    // 추가 DB 읽기 없이 header.hookRevs(위 readHeader가 이미 같은 batch로 읽어 둔 것)를
    // 훑기만 하는 순수 계산이다 - 서버의 현재 rev와 다르거나(구버전) 아직 한 번도 rev를
    // 보고한 적 없는(rev===null) host만 골라낸다. 판정은 이 한 줄이 전부다(SyncHookSkew 참고).
    hook_skew: Object.entries(header.hookRevs)
      .filter(([, entry]) => entry.rev !== HOOK_REV)
      // entry.project ?? null - project 필드 추가 이전에 쓰인 원장 항목에는 이 키가 아예
      // 없다(undefined). JSON.stringify가 undefined 값을 가진 키를 통째로 생략해 계약이
      // 보장하는 "항상 존재하는 null 가능 필드"를 어겨 버리므로, additive 필드답게 없으면
      // null로 대신한다.
      .map(([host, entry]) => ({ host, rev: entry.rev, project: entry.project ?? null })),
  };

  /**
   * 전이 로그가 지금 발급할 수 있는 커서의 상한.
   *
   * 전이 테이블이 비어 있으면 reset 경로가 주는 값과 같은 기준(pruned_below_id 바로 아래)을 쓴다.
   * 정상 운영에서 클라이언트가 아는 커서는 전부 서버가 준 것이라 이 상한을 넘을 수 없다 - 넘었다면
   * 커서 파일이 손상됐거나(예: 전부 숫자인 쓰레기 값) DB가 옛 백업으로 되돌아간 경우다.
   * 둘 다 델타로는 절대 수렴하지 않는다(id > since인 전이가 영원히 안 생기므로 조용히 아무것도
   * 전달되지 않는다). 그래서 상한을 넘는 커서는 스냅샷으로 되돌려 스스로 낫게 한다.
   */
  const cursorCeiling = header.maxTransitionId ?? Math.max(header.prunedBelowId - 1, 0);

  /**
   * reset 판정.
   *
   * 아래쪽 경계는 "클라이언트가 다음에 받을 id가 정리되어 사라졌는가"로 본다(since + 1).
   * since는 "여기까지 봤다"는 뜻이므로 since 자체가 지워진 건 손실이 아니다 - 정말로 놓친 건
   * since + 1부터가 사라졌을 때다. 이 +1이 없으면 전이 로그가 통째로 비는 순간
   * (보존 정리가 전부 지운 뒤) pruned_below_id가 max(id)보다 커져서 어떤 커서도 조건을
   * 만족하지 못하고 - reset이 주는 커서(pruned_below_id - 1)조차 다시 reset을 부른다 -
   * 영원히 reset만 반복한다. 그러면 클라이언트는 매 폴링마다 스냅샷 전체를 "방금 일어난 일"로
   * 재생해 알림이 폭주한다(T21 실패 주입에서 25초에 176건 관측).
   */
  const needsReset =
    query.since === null ||
    // 음수 커서는 서버가 준 적 없는 값이다(id는 1부터). 추측하지 않고 스냅샷으로 되돌린다.
    query.since < 0 ||
    query.since + 1 < header.prunedBelowId ||
    query.since > cursorCeiling;

  if (query.since !== null && query.since > cursorCeiling) {
    console.log(
      `sync: 전이 로그의 끝(${cursorCeiling})을 넘는 커서 since=${query.since} — 스냅샷으로 되돌린다`,
    );
  }

  if (needsReset) {
    // 커서는 sessions를 읽기 "전"에 확정한 max(id)다. 두 읽기 사이에 새 전이가 끼어들면
    // 스냅샷에는 그 결과가 이미 보이고 커서는 그보다 옛것이 되는데, 그 방향은 안전하다
    // (클라이언트가 그 전이를 델타로 한 번 더 받아 같은 상태를 다시 적용할 뿐 — 멱등하다).
    // 반대 방향(커서가 앞서고 스냅샷이 뒤진 것)이라야 전이를 통째로 건너뛰는 구멍이 난다.
    //
    // 전이 테이블이 비어 있으면 max(id)가 없다. 보존 정리로 다 지워진 경우까지 감안해
    // pruned_below_id 바로 아래를 커서로 준다(AUTOINCREMENT는 id를 재사용하지 않으므로
    // 다음 전이는 반드시 이 값보다 크다 = 건너뛰지 않는다). 그 값이 곧 cursorCeiling이다.
    const cursor = cursorCeiling;
    return {
      ...base,
      reset: true,
      cursor,
      has_more: false,
      sessions: await readSessions(env, query.includeEnded, now),
      transitions: [],
      sessions_touched: [],
    };
  }

  const since = query.since as number;
  const { transitions, hasMore } = await readTransitions(env, since, query.limit);
  // 새 전이가 없으면 커서는 그대로다 — 커서는 절대 뒤로 가지 않는다.
  const cursor = transitions.length > 0 ? transitions[transitions.length - 1]!.id : since;

  const touched: string[] = [];
  const touchedKeys = new Set<string>();
  for (const t of transitions) {
    if (touchedKeys.has(t.session_key)) continue;
    touchedKeys.add(t.session_key);
    touched.push(t.session_key);
  }

  return {
    ...base,
    reset: false,
    cursor,
    has_more: hasMore,
    sessions: [],
    transitions,
    sessions_touched: touched,
  };
}

/**
 * Hono 서브앱. src/index.ts에 `app.route("/dashboard", syncRoutes)`로 붙으면
 * GET /dashboard/sync가 된다 (배선은 이 파일 밖의 일이다).
 */
export const syncRoutes = new Hono<{ Bindings: SyncEnv }>();

syncRoutes.get("/sync", async (c) => {
  const query = parseSyncQuery(new URL(c.req.url).searchParams);
  const body = await buildSync(c.env, query, Date.now());
  // 커서 응답은 절대 캐시되면 안 된다 (정본 sync.cache).
  c.header("Cache-Control", "no-store");
  return c.json(body);
});

export default syncRoutes;
