import { Hono } from "hono";
import type { Env } from "../env";
import { resolveUserAckTransition } from "./client-actions";
import { resolveDevinInput } from "./devin-input";
import { resolveHeartbeatPromotion } from "./heartbeat";
import { adapterFor } from "./sources";
import { REVIVAL_EVENT, type SessionState } from "./state";

/**
 * POST /dashboard/admin/rebuild — dashboard_events(append-only 원장)를 처음부터 재생해
 * dashboard_sessions(프로젝션)와 dashboard_transitions(전이 로그/커서)를 통째로 다시 만든다.
 *
 * dashboard_events는 절대 바뀌지 않는다 - 이 파일은 그 로그를 "다시 읽을" 뿐이다. 그래서
 * 실시간 수집과 같은 순서 역행 방어, ended 불변식, 상태 변경 시 전이 적재,
 * project/host/message의 COALESCE 규칙을 적용한다. 재생과 실시간 수집의 결과는
 * 회귀 테스트에서 대조한다. heartbeat, 사용자 확인, Devin 상관 판정은 공통 함수를 사용한다.
 *
 * occurred_at은 서버가 고치지 않는다(클램프 없음, 시계 불변식) - 순서 판정(순서
 * 역행 방어 · 위 승격 strict greater)은 같은 세션 안에서만 하므로 클라이언트 시계가 서버와
 * 어긋나 있어도 자기들끼리의 순서는 보존된다(states.invariants). last_progress_at(서버
 * 수신 시각, 진척 이벤트만 갱신)이 stalled 판정을 담당한다 - maintenance.ts 참고.
 *
 * 한 가지 근본적인 제약: dashboard_events에는 project 컬럼이 없다(session_key = "source:session_id"
 * 로만 존재하고, project는 raw JSON 원문 안에만 남아 있다 - routes.ts의 raw 보존 주석이 말하는
 * "프로젝션이 놓친 정보를 나중에 다시 읽기 위한 원본"이 정확히 이 상황이다). 그래서 project는
 * raw를 파싱해 복원한다. raw가 4096바이트로 잘려 project 필드 자체가 잘려나간 경우에만
 * (아주 긴 message를 가진 이벤트) 빈 문자열로 대체한다 - 원본 dashboard_events 스키마의
 * 한계이지 이 파일의 버그가 아니다.
 *
 * occurred_at이 "명시적으로 있었는가"(B의 가드3)는 raw를 다시 파싱하지 않는다 - 검증에서
 * 드러난 실측 버그(0003_dashboard_v3.sql 참고): routes.ts가 훅의 원본 stdin을 그대로 실어
 * 보내는 body.raw 필드까지 포함한 요청 본문은 PostToolUse(tool_response 포함)에서 흔히
 * RAW_MAX_BYTES(4096바이트)를 넘고, 그러면 저장된 raw는 문자열 중간에서 잘린 깨진 JSON이라
 * JSON.parse가 항상 실패해 재생이 실시간 수집과 다른 승격 판정을 냈다(A != B, project처럼
 * "정보가 잘려서 없다"가 아니라 "판정 자체가 반대로 나온다"는 점에서 project 절단과는 성격이
 * 다르다 - 그래서 project와 달리 이건 버그로 취급해 고쳤다). 이제는 routes.ts가 삽입 시점에
 * occurred_at_provided 컬럼에 원본 진실을 직접 남기고 이 파일은 그 컬럼을 그대로 읽는다 -
 * raw 크기와 무관하게 항상 정확하다. 이 컬럼이 없던 시절(마이그레이션 이전) 행은 NULL이고,
 * false(보수적 기본값 - 기존 "복원 실패 시 승격 막음" 원칙과 동일)로 취급한다.
 *
 * dashboard_seen 리베이스 + last_transition_id 재계산 판정(seen 기능, 0004_dashboard_seen.sql,
 * 재생 시 읽음 재계산 - 2026-09-11 갱신, 이전 판정("rebuild는 dashboard_seen 불가침")을 대체한다):
 *
 * 1) dashboard_seen은 이 파일이 유일하게, 의도적으로 건드리는 "원장에서 직접 유도되지 않는"
 *    테이블이다. rebuild는 전이 id 공간을 새로 만든다(2번 문단의 AUTOINCREMENT 재채번) - 그래서
 *    재생 말미에 "재생 결과에 남아 있는" 각 세션의 seen_transition_id를 그 세션의 새
 *    last_transition_id로 무조건 대입한다(MIN이 아니다 - 옛 값이 새 값보다 우연히 작으면
 *    이미 본 전이가 대량으로 다시 미확인으로 점등된다). 재생된 전이는 전부 사용자가 이미
 *    지나온 사건이고, 옛 id 공간의 seen 값은 새 id 공간과 비교할 근거가 없는 범주 오류다(id
 *    공간 자체가 다른 두 값을 비교하는 것과 같다) - 그래서 "재생 시점까지는 전부 봤다"가 새
 *    id 공간에서 유일하게 말이 되는 시작점이다. 이후의 진짜 변화(재생 이후 실제로 일어나는 새
 *    이벤트)는 그 새 id로 다시 미확인을 켠다 - 이 리베이스는 "재생 시점까지"만 유효하고 영구히
 *    미확인을 막지 않는다.
 *
 *    아직 seen 행이 없던 세션(한 번도 MarkSeen/ack를 부른 적 없다)에는 이 UPDATE가 아무
 *    영향도 주지 않는다 - 행을 새로 만들지 않는다(seen.ts의 "가드 없음" 설계와, 행이 없다는
 *    사실 자체가 갖는 "첫 도입 미확인 벽" 의미를 그대로 지킨다).
 *
 *    고아 삭제: 재생 결과(=방금 다시 채운 dashboard_sessions)에 없는 session_key의
 *    dashboard_seen 행은 리베이스할 대상 자체가 없으므로 같은 자리에서 지운다 -
 *    maintenance.ts의 주기적 고아 정리(DELETE ... WHERE session_key NOT IN (SELECT key FROM
 *    dashboard_sessions))와 같은 조건이지만, rebuild는 이미 세션 전체를 통째로 다시 만들었으니
 *    다음 cron까지 기다리지 않고 이 자리에서 바로 정합을 맞춘다.
 *
 *    계약(protocol.v1.json client_actions.MarkSeen.invariants) 판정 문안: "rebuild는 전이 id
 *    공간을 새로 만든다. 그래서 재생 말미에 모든 세션의 seen_transition_id를 그 세션의 새
 *    last_transition_id로 맞춘다 — 재생된 전이는 전부 사용자가 이미 지나온 사건이고, 옛 id
 *    공간의 seen 값은 새 공간에서 비교할 수 없다. 이후의 진짜 변화는 새 id로 다시 미확인을
 *    켠다."
 *
 * 2) last_transition_id는 재생 시 재계산한다(과거 값을 이월하지 않는다). 이 컬럼은
 *    last_progress_at·last_occurred_at과 같은 성격의 "완전히 파생된" 값이다 - 오직
 *    dashboard_transitions에서만 나온다(정의: 이 세션에 대해 마지막으로 적재된 전이의 id).
 *    그런데 dashboard_transitions 자체를 이 함수가 통째로 지우고 새 AUTOINCREMENT id로 다시
 *    채우므로(위 DELETE + sqlite_sequence 리셋), 재생이 끝난 뒤의 "마지막 전이"는 재생이 새로
 *    부여한 id를 가리켜야만 그 전이 로그와 앞뒤가 맞는다 - last_occurred_at·last_progress_at을
 *    이미 원본 값을 무시하고 매 이벤트마다 다시 계산하는 것과 완전히 같은 이유(이 파일의
 *    "처음부터 다시 만든다"는 핵심 원칙)다. 반대로 재생 이전의 last_transition_id를 그대로
 *    들고 있으면, 재생 직후 dashboard_transitions에는 존재하지 않는(또는 전혀 다른 전이를
 *    가리키는) id가 dashboard_sessions에 박제되어 "미확인 = last_transition_id >
 *    seen_transition_id" 판정 자체가 근거를 잃는다.
 *
 *    계산 방법: sessions 맵에 올려 둔 프로젝션 객체 참조를 들고 있다가, 6)에서 실제로
 *    transitions.push()가 일어난 바로 다음에 transitions.length를 그 전이의 새 id로 대입한다.
 *    이 값이 실제 DB id와 일치하는 이유는 아래 db.batch(writes) 구성 순서 때문이다 -
 *    sqlite_sequence를 리셋한 다음 writes 배열은 "세션 INSERT 전부 → 전이 INSERT 전부(이
 *    transitions 배열의 push 순서 그대로)"로 쌓이므로, transitions[i]는 항상 DB id i+1을
 *    받는다(AUTOINCREMENT가 문장 실행 순서대로 1부터 채번한다). 즉 push 직후의
 *    transitions.length가 곧 그 전이의 최종 id다.
 *
 *    해소된 한계(과거 기록, 재생 시 읽음 재계산로 해소됨 - 아래는 문제였던 것과 고쳐진 이유를
 *    남겨 둔다): dashboard_events·dashboard_sessions·dashboard_transitions는 서로 다른 보존
 *    기간을 독립적으로 운영한다(maintenance.ts의 DASHBOARD_RETAIN_*_DAYS). 과거에 retention
 *    prune으로 일부 dashboard_events가 이미 영구히 사라진 상태에서 rebuild를 돌리면, 재생은
 *    "남아 있는" 이벤트만으로 전이 로그를 처음부터 다시 채번하므로 전이 개수·순서·id 배정이
 *    prune 이전과 달라진다(이 파일의 다른 파생값도 원장이 이미 잘려 나갔다면 근본적으로 같은
 *    특성을 공유한다 - rebuild는 "지금 남아 있는 원장"만의 진실이다). 예전에는 이 상황에서
 *    dashboard_seen.seen_transition_id가 옛 id 공간을 가리키던 값을 그대로 들고 있어 재생
 *    직후 실제 의미와 어긋났다(오래전에 확인한 세션이 새 id 공간에서 우연히 다시 "미확인"으로
 *    보이거나, 그 반대) - 위 1)의 무조건 리베이스가 정확히 이 어긋남을 없앤다: 재생이 끝나는
 *    시점의 "새 last_transition_id"를 그 세션의 seen으로 못박으므로, retention이 전이 개수를
 *    얼마나 바꿔 놓았든 재생 직후에는 항상 "지금까지는 전부 봤다"는 정합 상태에서 다시 시작한다.
 *
 * dashboard_meta.hook_revs("훅 구버전 배너" 원장, routes.ts POST /dashboard/events의 4.5단계,
 * sync.ts의 hook_skew)는 이 파일이 절대 건드리지 않는다 - dashboard_seen이 과거(위 1번 문단 이전)
 * 에 있던 "rebuild 불가침" 지위를 지금도 그대로 유지하는 유일한 테이블이다. 이유가 dashboard_seen과
 * 다르다: dashboard_seen은 "재생 결과에 맞춰 다시 정의할 수 있는" 파생값이라 위 1)에서 리베이스
 * 규칙을 새로 만들었지만, hook_revs는 애초에 dashboard_events로부터 복원할 수 없다 - 원본
 * payload는 raw로 저장되어도 RAW_MAX_BYTES(4096바이트)에서 잘리므로 hook_rev 필드가 잘려
 * 나갔는지 여부를 재생 시점에 신뢰할 수 없고(project 복원과 같은 종류의 한계), 설령 안 잘렸어도
 * hook_revs는 애초에 "이 시각까지 각 호스트가 마지막으로 보고한 값"이라는 현재 시점의 사실이지,
 * 과거 원장을 다시 훑어 재구성해야 하는 히스토리 프로젝션이 아니다(dashboard_sessions·
 * dashboard_transitions와 근본적으로 다른 성격). 그래서 이 파일은 hook_revs를 읽지도 쓰지도
 * 지우지도 않는다 - maintenance.ts의 pruneRetention만이 이 원장의 유일한 정리 주체다.
 */

interface RawEventRow {
  session_key: string;
  source: string;
  event: string;
  message: string | null;
  occurred_at: number | null;
  /** occurred_at_provided 컬럼(0003_dashboard_v3.sql). NULL은 마이그레이션 이전 행(=알 수 없음). */
  occurred_at_provided: number | null;
  received_at: number;
  host: string | null;
  raw: string | null;
  prompt_id: string | null;
  tool_use_id: string | null;
  tool_name: string | null;
  display_title: string | null;
}

interface SessionProjection {
  key: string;
  source: string;
  session_id: string;
  project: string;
  host: string | null;
  state: SessionState;
  last_event: string;
  last_message: string | null;
  display_title: string | null;
  last_occurred_at: number | null;
  last_progress_at: number | null;
  /** 재생 시 재계산한다(원본 값을 이월하지 않는다) - 위 파일 헤더의 판정 근거 참고. */
  last_transition_id: number | null;
  input_state: string | null;
  created_at: number;
  updated_at: number;
}

interface RebuiltTransition {
  session_key: string;
  from_state: SessionState | null;
  to_state: SessionState;
  source: string;
  project: string;
  host: string | null;
  message: string | null;
  display_title: string | null;
  occurred_at: number;
  created_at: number;
}

/** key = "source:session_id" (routes.ts). source 길이 + 구분자 하나만 잘라내면 session_id다. */
function sessionIdFromKey(key: string, source: string): string {
  return key.slice(source.length + 1);
}

/** raw JSON 원문에서 하나의 문자열 필드를 읽는다. 못 읽으면 undefined(호출부가 fallback을 정한다). */
function readRawStringField(raw: string | null, field: string): string | undefined {
  if (!raw) return undefined;
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    const value = parsed[field];
    return typeof value === "string" ? value : undefined;
  } catch {
    return undefined;
  }
}

/** raw JSON 원문의 state 필드(unknown) - generic 소스의 stateFieldAllowed 판정에 그대로 넘긴다. */
function readRawState(raw: string | null): unknown {
  if (!raw) return undefined;
  try {
    return (JSON.parse(raw) as Record<string, unknown>).state;
  } catch {
    return undefined;
  }
}

export interface RebuildResult {
  eventsReplayed: number;
  sessionsRebuilt: number;
  transitionsRebuilt: number;
}

/**
 * dashboard_events를 occurred_at(없으면 received_at) 순으로 재생해 sessions/transitions를
 * 메모리에서 통째로 계산한 뒤, 기존 두 테이블을 지우고 한 번에 다시 채운다.
 *
 * `now`로 쓰는 시각: routes.ts의 insertEvent는 요청 처리 시각(now)을 dashboard_events.received_at
 * 컬럼에 그대로 적어 둔다 - 즉 각 이벤트 행의 received_at은 그 이벤트가 원래 처리되던 순간의
 * `now`와 같은 값이다. 그래서 재생 중에도 매 이벤트의 received_at을 그 단계의 now로 그대로
 * 쓰면 created_at/updated_at까지 원래 실시간 처리와 같은 값으로 재구성된다.
 *
 * dashboard_transitions.id(AUTOINCREMENT)를 재현 가능하게 만들기 위해 지우기 전에
 * sqlite_sequence 카운터도 함께 리셋한다 - 그래야 같은 이벤트 로그를 다시 재생했을 때
 * 매번 같은 id로 다시 쌓인다(재현성). dashboard_meta.pruned_below_id도 0으로 되돌린다 -
 * 재구성된 전이 로그는 아직 아무것도 정리(retention)되지 않았기 때문이다.
 */
export async function rebuildProjection(db: D1Database): Promise<RebuildResult> {
  const { results } = await db
    .prepare(
      `SELECT session_key, source, event, message, display_title, occurred_at, occurred_at_provided, received_at, host, raw, prompt_id, tool_use_id, tool_name
         FROM dashboard_events
        ORDER BY COALESCE(occurred_at, received_at) ASC, id ASC`,
    )
    .all<RawEventRow>();
  const events = results ?? [];

  const sessions = new Map<string, SessionProjection>();
  const transitions: RebuiltTransition[] = [];

  for (const row of events) {
    const adapter = adapterFor(row.source);
    if (!adapter) continue; // 미등록 source: 원래도 프로젝션·전이를 만들지 않고 로그만 됐다

    // UserAck(client_actions.UserAck)는 hook이 보내는 (source, event) 어휘가 아니라 사람이
    // 대시보드에서 누른 조작이다 - 애초에 어댑터의 EVENT_STATE 표 밖에 있으므로 어댑터를
    // 부르지 않는다(불러도 항상 미매핑=기록만으로 나와 실시간과 어긋난다). client-actions.ts의
    // 순수 판정만 그대로 부른다(SoC) - routes.ts(POST /dashboard/sessions/:key/ack)와 같은 함수다.
    //
    // 위조 전제(검증 리뷰 지적 high로 수정): event이름만 보고 이 분기를 타므로, dashboard_events에
    // event:"UserAck" 행이 하나라도 위조로 들어와 있으면 재생이 그 행도 똑같이 진짜 승격으로
    // 처리해 실시간과 어긋난다(A!=B). 이 행 자체가 진짜인지는 여기서 다시 검증하지 않는다 -
    // 대신 POST /dashboard/events(수집 엔드포인트, routes.ts)가 event 이름이
    // RESERVED_CLIENT_ACTION_EVENTS(client-actions.ts)에 있으면 source를 무엇으로 자칭하든
    // 애초에 적재를 거절한다. dashboard_events에 event:"UserAck" 행이 존재한다는 사실 자체가
    // POST /dashboard/sessions/:key/ack(client_actions 전용 엔드포인트)를 거쳤다는 증거이므로,
    // 여기서는 그 전제를 믿고 판정만 한다.
    const isUserAck = row.event === "UserAck";
    const reportedState = adapter.stateFieldAllowed ? readRawState(row.raw) : undefined;
    const verdict = isUserAck
      ? { state: null as SessionState | null, heartbeat: false, reject: undefined as string | undefined }
      : adapter.resolve({ event: row.event, reportedState });
    // 원래 400으로 거절됐다면 애초에 dashboard_events에 적재되지 않았다 - 방어적 스킵일 뿐이다.
    if (verdict.reject) continue;

    const now = row.received_at;
    // 서버는 occurred_at을 고치지 않는다(클램프 없음) - 저장된 값을 그대로 순서 판정에 쓴다.
    const occurredAt = row.occurred_at ?? now;
    const current = sessions.get(row.session_key);

    // B: heartbeat면서 상태 불변 판정이라도 조건부 승격 가드 5종을 통과하면 working으로
    // 승격한다. routes.ts와 같은 함수(resolveHeartbeatPromotion)를 그대로 호출한다(SoC).
    // UserAck는 하트비트가 아니라 client_actions 판정이므로 resolveUserAckTransition을 쓴다.
    const promotedState = isUserAck
      ? resolveUserAckTransition(current?.state ?? null)
      : !verdict.state && verdict.heartbeat
        ? resolveHeartbeatPromotion({
            currentState: current?.state ?? null,
            occurredAtProvided: row.occurred_at_provided === 1,
            occurredAt,
            lastOccurredAt: current?.last_occurred_at ?? null,
          })
        : null;
    const effectiveState = verdict.state ?? promotedState;

    const resolved =
      row.source === "devin"
        ? resolveDevinInput({
            event: row.event,
            prompt_id: row.prompt_id,
            tool_use_id: row.tool_use_id,
            tool_name: row.tool_name,
            currentState: current?.state ?? null,
            lastOccurredAt: current?.last_occurred_at ?? null,
            occurredAt,
            occurredAtProvided: row.occurred_at_provided === 1,
            storedInputState: current?.input_state ?? null,
            proposedState: effectiveState,
          })
        : { state: effectiveState, inputState: current?.input_state ?? null };

    // 5-a) 상태를 바꾸지 않는 이벤트(승격도 안 된 heartbeat 포함). heartbeat만 last_occurred_at과
    //      last_progress_at을 민다(A안 원칙: 기록만 되는 이벤트는 last_progress_at을 밀지 않는다).
    //      last_occurred_at은 순서 비교(>=)를 거쳐 갱신하고, last_progress_at은 서버 수신
    //      시각(now)이라 그 비교와 무관하게 항상 민다 - 둘은 서로 다른 시계를 잰다.
    if (!resolved.state) {
      if (current) {
        current.last_event = row.event;
        current.updated_at = now;
        if (verdict.heartbeat && occurredAt >= (current.last_occurred_at ?? 0)) {
          current.last_occurred_at = occurredAt;
        }
        if (verdict.heartbeat) {
          // 리뷰 지적(medium) 수정: 재생은 occurred_at 순서로 순회하므로 이 루프의
          // now(=row.received_at)는 실시간 처리 순서(=도착 순서)와 다를 수 있다 -
          // 마지막 순회 값이 아니라 max를 유지해야 도착 순서와 무관하게 실시간과
          // 같은 결과(A==B)가 나온다. last_occurred_at은 이미 같은 이유로 max
          // 형태(>= 비교 후 대입)라 이 규칙이 없어도 안전했다.
          current.last_progress_at = Math.max(current.last_progress_at ?? 0, now);
        }
      }
      continue;
    }

    // 5-b) 순서 역행 방어. (승격된 경우 가드4가 이미 strict greater를 보장해 여기 걸릴 일이 없다.)
    if (current && current.last_occurred_at !== null && occurredAt < current.last_occurred_at) continue;
    // 5-c) ended 불변식. (승격된 경우 가드2가 이미 ended를 걸러낸다.)
    if (current?.state === "ended" && row.event !== REVIVAL_EVENT) continue;

    const newState = resolved.state;
    const project = readRawStringField(row.raw, "project") ?? "";
    // host/last_message는 세션 프로젝션에서만 COALESCE한다(0002 스키마의 ON CONFLICT 규칙).
    // 전이 로그에는 이 이벤트 자신의 값(raw, coalesce 이전)을 그대로 남긴다 - routes.ts가
    // appendTransition에 넘기는 값도 세션에 저장된 값이 아니라 요청 본문의 원래 값이다.
    const projectedHost = row.host ?? current?.host ?? null;
    const projectedMessage = row.message ?? current?.last_message ?? null;

    const projection: SessionProjection = {
      key: row.session_key,
      source: row.source,
      session_id: sessionIdFromKey(row.session_key, row.source),
      project,
      host: projectedHost,
      state: newState,
      last_event: row.event,
      last_message: projectedMessage,
      display_title: row.display_title,
      last_occurred_at: occurredAt,
      // 상태가 실제로 바뀌는(혹은 승격되는) 경로는 언제나 진척이다 - routes.ts의 상태 변경
      // UPSERT와 같은 규칙(last_progress_at = now, 기록만 경로는 위 5-a에서 이미 갈라진다).
      // max를 쓰는 이유는 위 5-a 분기의 주석과 같다 - occurred_at 순서 재생이 실제 도착
      // 순서와 다를 수 있어, 마지막 순회 값이 아니라 max여야 실시간과 같은 결과가 된다
      // (리뷰 지적 medium 수정).
      last_progress_at: Math.max(current?.last_progress_at ?? 0, now),
      // 일단 이전 값을 이월해 두고, 바로 아래에서 이번 이벤트가 실제로 새 전이를 만들면
      // 그 전이의 새 id로 덮어쓴다(파일 헤더의 "last_transition_id 재계산 판정" 참고).
      // 전이를 안 만드는 경우(같은 상태 재진입)는 이월한 값이 그대로 최종값이다.
      last_transition_id: current?.last_transition_id ?? null,
      input_state: resolved.inputState,
      created_at: current?.created_at ?? now,
      updated_at: now,
    };
    sessions.set(row.session_key, projection);

    // 6) 같은 상태 재진입은 전이가 아니다.
    if (newState !== (current?.state ?? null)) {
      transitions.push({
        session_key: row.session_key,
        from_state: current?.state ?? null,
        to_state: newState,
        source: row.source,
        project,
        host: row.host,
        message: row.message,
        display_title: row.display_title,
        occurred_at: occurredAt,
        created_at: now,
      });
      // dashboard_transitions.id는 재생이 sqlite_sequence를 리셋한 뒤 이 transitions 배열을
      // push 순서 그대로 다시 삽입해서 만든다(아래 db.batch(writes) 구성 순서) - 그래서
      // transitions[i]는 항상 DB id i+1을 받는다. 방금 push한 이 전이의 최종 id는 곧
      // transitions.length(1-indexed)와 같다.
      projection.last_transition_id = transitions.length;
    }
  }

  await db.prepare("DELETE FROM dashboard_sessions").run();
  await db.prepare("DELETE FROM dashboard_transitions").run();
  // AUTOINCREMENT 카운터를 되돌려 같은 로그를 다시 재생하면 같은 id로 다시 쌓이게 한다.
  await db.prepare("DELETE FROM sqlite_sequence WHERE name = 'dashboard_transitions'").run();

  const sessionRows = [...sessions.values()];
  const writes = sessionRows.map((s) =>
    db
      .prepare(
        `INSERT INTO dashboard_sessions
           (key, source, session_id, project, host, state, last_event, last_message, display_title, last_occurred_at, last_progress_at, last_transition_id, created_at, updated_at, input_state)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(
        s.key,
        s.source,
        s.session_id,
        s.project,
        s.host,
        s.state,
        s.last_event,
        s.last_message,
        s.display_title,
        s.last_occurred_at,
        s.last_progress_at,
        s.last_transition_id,
        s.created_at,
        s.updated_at,
        s.input_state,
      ),
  );
  for (const t of transitions) {
    writes.push(
      db
        .prepare(
          `INSERT INTO dashboard_transitions
             (session_key, from_state, to_state, source, project, host, message, display_title, occurred_at, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .bind(t.session_key, t.from_state, t.to_state, t.source, t.project, t.host, t.message, t.display_title, t.occurred_at, t.created_at),
    );
  }
  if (writes.length > 0) await db.batch(writes);

  // dashboard_seen 리베이스(파일 헤더의 "dashboard_seen 리베이스" 판정 1) 참고): 방금 다시 채운
  // 각 세션의 seen_transition_id를 그 세션의 새 last_transition_id로 무조건 대입한다(MIN 금지 -
  // 위 for 루프에서 확인했듯 sessions 맵에 오른 모든 세션은 최초 진입 시 반드시 전이를 하나
  // 만들므로 s.last_transition_id는 여기서 항상 실제 숫자다). 대상 session_key에 애초에
  // dashboard_seen 행이 없으면 UPDATE는 아무 행도 건드리지 않는다 - 새로 만들지 않는다.
  if (sessionRows.length > 0) {
    await db.batch(
      sessionRows.map((s) =>
        db
          .prepare("UPDATE dashboard_seen SET seen_transition_id = ? WHERE session_key = ?")
          .bind(s.last_transition_id, s.key),
      ),
    );
  }
  // 고아 삭제: 재생 결과(=방금 다시 채운 dashboard_sessions)에 없는 session_key의 dashboard_seen
  // 행은 리베이스할 대상이 없으므로 같은 자리에서 지운다(maintenance.ts의 주기적 고아 정리와
  // 같은 조건).
  await db.prepare("DELETE FROM dashboard_seen WHERE session_key NOT IN (SELECT key FROM dashboard_sessions)").run();

  await db
    .prepare(
      `INSERT INTO dashboard_meta (key, value) VALUES ('pruned_below_id', '0')
         ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
    )
    .run();

  return {
    eventsReplayed: events.length,
    sessionsRebuilt: sessionRows.length,
    transitionsRebuilt: transitions.length,
  };
}

/**
 * Hono 서브앱. registry.ts가 다른 dashboard feature들과 같은 "/dashboard" prefix에 붙인다.
 * 인증은 src/index.ts의 공통 미들웨어가 담당한다 - POST /dashboard/events만 INGEST_TOKEN
 * 전용이고 그 외 경로는 전부 CLIENT_TOKEN(or AUTH_TOKEN)이라, 이 경로는 별도 처리 없이도
 * 이미 클라이언트 인증으로 막혀 있다.
 */
export const dashboardAdmin = new Hono<{ Bindings: Env }>();

dashboardAdmin.post("/admin/rebuild", async (c) => {
  const result = await rebuildProjection(c.env.DB);
  return c.json({ ok: true, ...result });
});

export default dashboardAdmin;
