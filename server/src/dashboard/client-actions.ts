import type { SessionState } from "./state";

/**
 * UserAck: 사람이 대시보드(PWA·앱)에서 승인 완료를 직접 확인했다는 조작이 만드는 전이.
 *
 * 정본: protocol.v1.json client_actions.UserAck.
 *
 * 배경: claude-code에는 "approval 완료" 신호가 없다 - hook 관점에서 waiting_input은
 * Stop이 올 때까지 계속된다. 사람이 대시보드에서 승인을 실제로 마쳤다는 의도적 클릭은
 * 1:1(사람·세션)이 보장되는 해소 신호이므로, 이 클릭을 working 전이의 근거로 쓴다.
 *
 * 이것은 heartbeat_events가 지키는 "하트비트만으로는 상태를 확정하지 않는다"는 원칙의
 * 예외가 아니라 별개의 규칙이다 - 하트비트는 기계가 자동으로 반복 발신하는 생존 신호라
 * 무엇을 승인했는지 모르고, 이 클릭은 사람이 1회성으로 확정하는 의도 신호다.
 *
 * event_state_map에 넣지 않은 이유(위조 차단): 이 판정을 event_state_map과 같은
 * (source, event) 1:1 표에 넣으면 그 모양이 깨질 뿐 아니라, 누구나 흉내 낼 수 있는 event
 * 이름 하나로 승인 완료를 조작할 수 있는 길이 열린다.
 *
 * 위조 차단은 "표에 없다"만으로는 충분하지 않다(검증 리뷰 지적, high): event:"UserAck"가
 * POST /dashboard/events(수집 엔드포인트)로 들어오면 한 번은 event_state_map 미매핑이라
 * 기록만 되고 넘어가지만, 그 줄은 dashboard_events에 이미 남아 있다 - POST
 * /dashboard/admin/rebuild(rebuild.ts)가 재생할 때는 event 이름만 보고 이 파일의 판정을
 * 다시 적용하므로, 실시간에는 아무 전이도 안 만든 위조 줄이 재생에서는 진짜 UserAck 전이로
 * 둔갑한다(A!=B, 위조 차단 무력화). 그래서 차단은 "표 밖에 둔다"가 아니라 "애초에 로그에
 * 넣지 않는다"여야 한다 - RESERVED_CLIENT_ACTION_EVENTS가 그 목록이고, routes.ts는
 * POST /dashboard/events에서 이 목록에 있는 event 이름을 (source와 무관하게) 400으로
 * 거절하고 아예 적재하지 않는다. protocol.v1.json의 client_actions.reserved_event_names가
 * 정본이다.
 *
 * 판정 공유 원칙: "새 로직은 한 곳에 순수 함수로 두고 다른 계층은 호출만 한다." 이 판정은
 * routes.ts(POST /dashboard/sessions/:key/ack, 실시간 경로)와 rebuild.ts(재생 경로) 둘
 * 다에서 같은 결과를 내야 한다 - heartbeat.ts의 resolveHeartbeatPromotion과 똑같은 이유로
 * 이 파일 하나에만 판정을 두고 두 경로가 그대로 호출한다.
 *
 * state.ts에는 두지 않는다(어휘 파일 - "상태란 무엇인가"만 남긴다). sources/*.ts(어댑터)에도
 * 두지 않는다 - 어댑터는 AdapterInput(event, reportedState)만 보는 이벤트-어휘 판정이고,
 * UserAck는 애초에 어댑터가 보는 수집 경로(POST /dashboard/events)로 들어오지 않는
 * 별도 엔드포인트의 이벤트라 어댑터 인터페이스 자체가 맞지 않는다.
 */

/**
 * client_actions.reserved_event_names. POST /dashboard/events(수집 엔드포인트)가
 * source와 무관하게 거절해야 하는 event 이름 목록 - client_actions 전용 어휘라 hook이
 * 보내는 (source, event) 표에 들어갈 수 없다(위 헤더 코멘트의 위조 차단 설명 참고).
 */
export const RESERVED_CLIENT_ACTION_EVENTS: ReadonlySet<string> = new Set<string>(["UserAck"]);

/** client_actions.UserAck.from_states. 이 상태에서만 UserAck가 전이를 만든다. */
export const USER_ACK_FROM_STATES: ReadonlySet<SessionState> = new Set<SessionState>(["waiting_input"]);

/** client_actions.UserAck.to_state. */
export const USER_ACK_TO_STATE: SessionState = "working";

/**
 * 현재 상태가 USER_ACK_FROM_STATES 안에 있으면 목표 상태를, 아니면 null(전이 없음 - 기록만)을
 * 돌려준다. 세션이 아예 없으면(currentState === null) 당연히 null이다 - UserAck는 세션을
 * 새로 만들 수 없다(하트비트와 같은 원칙, heartbeat.ts 가드1 참고).
 *
 * 호출 전제: 실시간 경로(routes.ts)는 이 함수를 부르기 전에 이미 "세션이 존재하고
 * state===waiting_input"인 경우에만 이벤트를 적재하므로 사실상 언제나 USER_ACK_TO_STATE를
 * 받는다 - 그런데도 가드를 이 함수 안에 다시 두는 이유는 재생 경로(rebuild.ts)가 이벤트
 * 로그만 보고 "그 시점의 세션이 정말 waiting_input이었는지"를 매번 새로 판정해야 하기
 * 때문이다(A==B) - 실시간 경로의 사전 가드를 신뢰하고 생략하면 재생이 그 가드를 잃는다.
 */
export function resolveUserAckTransition(currentState: SessionState | null): SessionState | null {
  if (currentState === null) return null;
  if (!USER_ACK_FROM_STATES.has(currentState)) return null;
  return USER_ACK_TO_STATE;
}
