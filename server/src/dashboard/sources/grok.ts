import type { SessionState } from "../state";
import type { AdapterInput, AdapterVerdict, SourceAdapter } from "./index";

/**
 * Grok 어댑터.
 * 표의 정본은 ../protocol.v1.json의 event_state_map.by_source["grok"]다.
 * claude-code와 같은 다섯 줄이다. 여기 값을 바꾸려면 정본을 먼저 바꿔야 하며,
 * test/contract.test.ts가 실제 adapter 판정과 대조한다.
 */
const EVENT_STATE: Record<string, SessionState> = {
  SessionStart: "idle", // 세션 시작
  UserPromptSubmit: "working", // 사용자가 프롬프트를 넣어 실행이 시작됨
  Notification: "waiting_input", // 권한 요청 또는 입력 대기 알림
  Stop: "done", // 턴 실행 마침
  SessionEnd: "ended", // 세션 종료
};

/**
 * heartbeat_events. 상태는 그대로 두고 "아직 살아 있다"만 알린다.
 * PostToolUse는 도구를 쓸 때마다 터지므로 hook이 60초에 한 번만 보낸다(throttle은 hook 쪽 몫).
 */
const HEARTBEAT_EVENTS: ReadonlySet<string> = new Set(["PostToolUse"]);

export const grokAdapter: SourceAdapter = {
  source: "grok",
  // event_state_map이 정본이다. 요청이 state를 보내도 무시한다.
  stateFieldAllowed: false,

  resolve({ event }: AdapterInput): AdapterVerdict {
    if (Object.prototype.hasOwnProperty.call(EVENT_STATE, event)) {
      return { state: EVENT_STATE[event]!, heartbeat: false, reject: null };
    }
    if (HEARTBEAT_EVENTS.has(event)) return { state: null, heartbeat: true, reject: null };
    // 표에도 heartbeat에도 없는 이벤트: 기록만 한다. IdleNotification 등이 여기 해당한다.
    return { state: null, heartbeat: false, reject: null };
  },
};
