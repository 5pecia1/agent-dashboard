/**
 * dashboard 상태 어휘(vocabulary).
 *
 * 정본은 같은 디렉터리의 protocol.v1.json이고, 이 파일은 그 어휘를 타입으로 옮겨 적은 것이다.
 *
 * 0001에는 여기 (event -> state) 평면 표가 하나 있었다. 소스마다 이벤트 어휘가 다르고
 * generic은 표 자체가 없으므로 그 표는 sources/ 아래 소스별 어댑터로 옮겼다.
 * 이 파일에는 "상태란 무엇인가"만 남는다.
 */

/** protocol.v1.json states.enum. 이 6개가 상태 어휘의 전부다. */
export type SessionState = "idle" | "working" | "waiting_input" | "done" | "ended" | "stalled";

export const STATES: readonly SessionState[] = [
  "idle",
  "working",
  "waiting_input",
  "done",
  "ended",
  "stalled",
];

/** 요청 본문에서 온 unknown 값이 states.enum 안의 값인지. */
export function isSessionState(value: unknown): value is SessionState {
  return typeof value === "string" && (STATES as readonly string[]).includes(value);
}

/**
 * states.detail[*].terminal. 끝난 세션은 늦게 도착한 이벤트로 되살아나지 않는다.
 * 되살리는 유일한 통로가 REVIVAL_EVENT다.
 */
export const TERMINAL_STATES: ReadonlySet<SessionState> = new Set<SessionState>(["ended"]);

/** ended 세션을 다시 열 수 있는 유일한 이벤트 이름 (states.invariants). */
export const REVIVAL_EVENT = "SessionStart";

/**
 * states.detail[*].derived == true. 서버(cron)가 관측해서 만드는 상태다.
 * 클라이언트가 신고하면 400으로 거절한다 - 안 그러면 "조용히 죽었다"는 관측을 위조할 수 있다.
 */
export const DERIVED_STATES: ReadonlySet<SessionState> = new Set<SessionState>(["stalled"]);

/**
 * protocol.v1.json push_states.enum.
 * 이 상태로 "전이"했을 때만 push를 보낸다. 전이 적재는 상태와 무관하게 항상 한다.
 *
 * done은 없다(계약상) - done은 계약상 "턴 실행을 마쳤다"일 뿐인데
 * heartbeat.ts의 조건부 승격(promote_from에 done 포함)이 백그라운드 서브에이전트가
 * 계속 일하는 done 세션을 곧바로 working으로 되돌려 "끝났다" 직후 "진행 중"이
 * 이어지는 알림 소음을 만들었다. 자세한 사유는 protocol.v1.json의
 * push_states.$note_done_excluded 참고.
 */
export const PUSH_STATES: ReadonlySet<SessionState> = new Set<SessionState>([
  "waiting_input",
  "stalled",
]);

/** protocol.v1.json versioning.current. major 정수 하나뿐이다. */
export const PROTOCOL_VERSION = 1;

/** versioning.accepted_by_server. 여기 없는 major는 조용히 추측하지 않고 400으로 거절한다. */
export const ACCEPTED_PROTOCOL_VERSIONS: ReadonlySet<number> = new Set<number>([PROTOCOL_VERSION]);

/**
 * 0001 시절 GET /dashboard/sessions가 붙이던 stale:true 플래그의 기준값.
 * stalled 상태(cron이 DASHBOARD_STALL_MS로 판정)가 이 플래그를 대체하는 중이라,
 * 조회 경로가 stalled로 옮겨갈 때까지만 남겨 둔다.
 */
export const STALE_MS = 60 * 60 * 1000;

/** protocol.v1.json i18n.ko의 state.* 문구. push 제목·본문이 같은 라벨을 쓴다. */
export const STATE_LABEL: Record<SessionState, string> = {
  idle: "대기",
  working: "진행 중",
  waiting_input: "질문·승인 대기",
  done: "실행 마침",
  ended: "세션 종료",
  stalled: "멈춘 듯",
};

/** 어휘 밖 값이 들어와도 표시가 깨지지 않게 값 자체로 되돌린다. */
export function stateLabel(state: string): string {
  return STATE_LABEL[state as SessionState] ?? state;
}
