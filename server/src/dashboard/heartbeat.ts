import type { SessionState } from "./state";

/**
 * B: PostToolUse 하트비트의 조건부 승격 판정.
 *
 * 정본: protocol.v1.json heartbeat_events.events.PostToolUse
 * (promote_from/principle/promote_guards) 및 event_payload.fields.occurred_at.
 *
 * occurred_at은 서버가 고치지 않는다(클램프 없음) — 순서 판정(이 파일의 승격 가드 포함)은
 * 같은 세션 안에서만 하고, 같은 세션의 이벤트는 같은 기계·같은 시계에서 나오므로 시계가
 * 어긋나 있어도 자기들끼리의 순서는 보존된다(states.invariants). stalled 판정처럼 서버
 * 시계와 비교해야 하는 것은 occurred_at이 아니라 dashboard_sessions.last_progress_at(서버
 * 수신 시각)을 쓴다 — maintenance.ts 참고.
 *
 * 판정 공유 원칙: "새 로직은 한 곳에 순수 함수로 두고 다른 계층은 호출만 한다." 이 판정은
 * routes.ts(실시간 수집 경로)와 rebuild.ts(재생 경로) 둘 다에서 같은 결과를 내야 하는데, 그
 * 필요를 지키는 가장 단순한 방법은 판정 자체를 이 파일 하나에만 두고 두 경로가 그대로
 * 호출하는 것이다 - 각자 다시 적으면(무엇을 승격 후보로 볼지, strict greater를 어디 쓸지 등)
 * 미묘하게 갈라질 수 있고, 그 갈라짐은 완료 판정(d)의 A==B 재생 테스트가 아니면 못 잡는다.
 *
 * state.ts에는 이 로직을 두지 않는다 - state.ts의 파일 헤더가 "상태란 무엇인가(어휘)"만
 * 남긴다고 명시하고 있고(event -> state 판정 자체는 0001 이후 sources/ 로 옮겨졌다), 여기
 * 판정은 이벤트→상태 판정 중에서도 세션 프로젝션(현재 상태·last_occurred_at)을 함께 봐야
 * 하는 조건부 판정이라 어휘 파일에 어울리지 않는다. sources/*.ts(어댑터)에도 두지 않는다 -
 * 어댑터는 AdapterInput(event, reportedState)만 보는 순수 이벤트-어휘 판정이고, 이 판정은
 * 어댑터가 원래 볼 자격이 없는 세션 프로젝션 값(current.state, last_occurred_at)을 필요로
 * 하므로 어댑터 인터페이스를 넘어선다(AdapterVerdict를 넓히는 대안의 기각 사유 - 아래 참고).
 */

/** heartbeat_events.events.PostToolUse.promote_from. 이 상태에서만 working으로 승격될 수 있다. */
export const HEARTBEAT_PROMOTE_FROM: ReadonlySet<SessionState> = new Set<SessionState>([
  "done",
  "idle",
  "stalled",
]);

export interface HeartbeatPromotionInput {
  /** 프로젝션(dashboard_sessions)에 이미 있는 세션의 현재 상태. 행 자체가 없으면 null(가드1). */
  currentState: SessionState | null;
  /**
   * 요청 페이로드에 occurred_at이 "명시적으로" 있었는가(가드3). 없어서 서버 수신 시각으로
   * 대체된 경우는 여기 false로 들어와야 한다 - 대체된 값으로 strict 비교를 하면 비교 자체가
   * 무의미해진다(예: Stop 직전 발화의 하트비트가 늦게 도착하면 이미 끝난 턴이 되살아난다).
   */
  occurredAtProvided: boolean;
  /** 클라이언트가 보낸 원본 occurred_at(epoch ms). 서버는 이 값을 고치지 않는다. */
  occurredAt: number;
  /** 프로젝션의 last_occurred_at. 세션이 없으면 null(0으로 취급). */
  lastOccurredAt: number | null;
}

/**
 * heartbeat_events.events.PostToolUse.promote_guards 5개를 전부 통과하면 "working"을,
 * 하나라도 걸리면 null(승격 없음)을 돌려준다.
 *
 * 호출 전제: 이 이벤트가 이미 어댑터에 의해 heartbeat로 판정됐고(AdapterVerdict.heartbeat
 * === true) 상태는 바꾸지 않는다고 판정됐다(AdapterVerdict.state === null)는 것 - heartbeat
 * 여부 자체는 어댑터(사건 어휘)의 몫이고, 여기는 그 다음의 조건부 승격 여부만 판정한다.
 */
export function resolveHeartbeatPromotion(input: HeartbeatPromotionInput): SessionState | null {
  const { currentState, occurredAtProvided, occurredAt, lastOccurredAt } = input;
  if (currentState === null) return null; // 가드1: 세션 행 없음 - 세션 생성은 하트비트의 몫이 아니다.
  if (currentState === "ended") return null; // 가드2: ended는 어떤 경우에도 승격하지 않는다.
  if (!occurredAtProvided) return null; // 가드3: occurred_at 미명시.
  if (!(occurredAt > (lastOccurredAt ?? 0))) return null; // 가드4: strict greater(기존 >= last_occurred_at 갱신 규칙과는 다른 비교).
  if (currentState === "waiting_input") return null; // 가드5: waiting_input은 승격으로 해소되지 않는다(F와의 경계).
  if (!HEARTBEAT_PROMOTE_FROM.has(currentState)) return null; // promote_from 밖(=working, 이미 목표 상태)은 승격이 무의미하다.
  return "working";
}
