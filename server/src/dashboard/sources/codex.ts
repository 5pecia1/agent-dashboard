import type { SessionState } from "../state";
import type { AdapterInput, AdapterVerdict, SourceAdapter } from "./index";

/**
 * Codex CLI 어댑터.
 * 표의 정본은 ../protocol.v1.json의 event_state_map.by_source["codex"]다.
 * Claude Code와 겹치는 이름이 많지만 어휘가 같다는 보장이 없으므로 표를 공유하지 않고
 * 각자 적어 둔다(한쪽 어휘가 바뀌어도 다른 쪽이 조용히 따라가지 않게).
 */
const EVENT_STATE: Record<string, SessionState> = {
  SessionStart: "idle", // 세션 시작
  UserPromptSubmit: "working", // 사용자가 프롬프트를 넣어 실행이 시작됨
  PermissionRequest: "waiting_input", // 승인 대기 (Claude Code의 Notification 자리)
  Stop: "done", // 턴 실행 마침
  SessionEnd: "ended", // 세션 종료
  "agent-turn-complete": "done", // 구버전 notify fallback (argv JSON, kebab-case 키)
  UserInputRequest: "waiting_input", // F: request_user_input(동기·비동기)의 PreToolUse를 훅이 변환한 합성 이벤트
  UserInputResolved: "working", // F: request_user_input(동기만)의 PostToolUse를 훅이 변환한 전용 해소 이벤트. B의 하트비트 승격과 달리 waiting_input을 직접 해소한다(대기와 1:1 근거를 가진 전용 이벤트라서 가능 - heartbeat_events.$note).
};

/** heartbeat_events. Claude Code와 같은 이유로 PostToolUse 하나다. */
const HEARTBEAT_EVENTS: ReadonlySet<string> = new Set(["PostToolUse"]);

export const codexAdapter: SourceAdapter = {
  source: "codex",
  stateFieldAllowed: false,

  resolve({ event }: AdapterInput): AdapterVerdict {
    if (Object.prototype.hasOwnProperty.call(EVENT_STATE, event)) {
      return { state: EVENT_STATE[event]!, heartbeat: false, reject: null };
    }
    if (HEARTBEAT_EVENTS.has(event)) return { state: null, heartbeat: true, reject: null };
    return { state: null, heartbeat: false, reject: null };
  },
};
