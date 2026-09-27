import type { SessionState } from "../state";
import type { AdapterInput, AdapterVerdict, SourceAdapter } from "./index";

/**
 * Devin CLI 어댑터.
 * 표의 정본은 ../protocol.v1.json의 event_state_map.by_source["devin"]다.
 * 다른 소스와 겹치는 이름이 많지만 어휘가 같다는 보장이 없으므로 표를 공유하지 않고
 * 각자 적어 둔다(한쪽 어휘가 바뀌어도 다른 쪽이 조용히 따라가지 않게).
 *
 * SessionStart(source:"startup")는 hook이 보내기 전에 걸러 서버까지 오지 않는다
 * (sources.registered.devin.sessionstart_handling). 그래도 매핑에는 남겨 둔다 —
 * startup이 아닌 SessionStart(resume 등)는 idle로 처리할 수 있어야 하고,
 * 매핑표는 계약과 1:1로 맞춰야 하기 때문이다.
 */
const EVENT_STATE: Record<string, SessionState> = {
  SessionStart: "idle", // 세션 시작 (startup 초기화 이벤트는 hook에서 무시)
  UserPromptSubmit: "working", // 사용자가 프롬프트를 넣어 실행이 시작됨
  PermissionRequest: "waiting_input", // 승인 대기 (Claude Code의 Notification 자리)
  Stop: "done", // 턴 실행 마침
  SessionEnd: "ended", // 세션 종료
  UserInputRequest: "waiting_input",
};

/** heartbeat_events. 다른 소스와 같은 이유로 PostToolUse 하나다. */
const HEARTBEAT_EVENTS: ReadonlySet<string> = new Set(["PostToolUse"]);

export const devinAdapter: SourceAdapter = {
  source: "devin",
  stateFieldAllowed: false,

  resolve({ event }: AdapterInput): AdapterVerdict {
    if (Object.prototype.hasOwnProperty.call(EVENT_STATE, event)) {
      return { state: EVENT_STATE[event]!, heartbeat: false, reject: null };
    }
    if (HEARTBEAT_EVENTS.has(event)) return { state: null, heartbeat: true, reject: null };
    return { state: null, heartbeat: false, reject: null };
  },
};
