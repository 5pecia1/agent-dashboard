import type { SessionState } from "../state";
import type { AdapterInput, AdapterVerdict, SourceAdapter } from "./index";

/**
 * OpenCode CLI v2 어댑터.
 * 표의 정본은 contracts/dashboard-protocol.v1.json의 event_state_map.by_source["opencode"]다.
 * OpenCode는 lifecycle hook이 없고 전역 플러그인(hooks/opencode-plugin.mjs)이 api.event.subscribe 이벤트를
 * 정본 어휘(UserPromptSubmit·UserInputRequest·UserInputResolved·Stop·SessionEnd·PostToolUse)로 번역해
 * agent-event-hook.sh opencode에 넘기므로(같은 파일의 event_state_map.opencode_plugin_translation) 서버는
 * 번역된 이름만 안다. 다른 소스와 겹치는 이름이 많지만 어휘가 같다는 보장이 없으므로 표를 공유하지 않고
 * 각자 적어 둔다(한쪽 어휘가 바뀌어도 다른 쪽이 조용히 따라가지 않게).
 *
 * SessionStart 줄은 없다 — OpenCode에 세션 시작에 해당하는 신호가 없기 때문이다(session.created는 standalone에서
 * 플러그인이 보지 못한다 - opencode_plugin_translation.limitations). 세션은 첫 UserPromptSubmit으로 생긴다.
 * SessionEnd는 있다 — session.deleted와 자기 location의 location.shutdown을 플러그인이 번역하므로 antigravity와
 * 달리 ended까지 간다. 단 standalone을 SIGINT로 끊으면 Stop 없이 SessionEnd만 올 수 있다(한계 목록 참고).
 *
 * Stop은 session.execution.succeeded·failed·interrupted 세 가지를 모두 포함한다. 어느 것이었는지는 raw의
 * opencode 객체(error_type·reason)에만 남고 상태는 전부 done이다 — 턴 실행이 끝났다는 점은 같기 때문이다.
 * 여기 값을 바꾸려면 정본을 먼저 바꿔야 하며, test/contract.test.ts가 실제 adapter 판정과 대조한다.
 */
const EVENT_STATE: Record<string, SessionState> = {
  UserPromptSubmit: "working", // 플러그인이 session.execution.started를 번역한 턴 시작. message는 가장 최근 session.inbox.enqueued의 본문 앞 300자
  UserInputRequest: "waiting_input", // 플러그인이 permission.asked와 form.created를 번역한 합성 대기 이벤트(자식 세션 것도 루트 세션 ID로 올라온다)
  UserInputResolved: "working", // 플러그인이 permission.replied·form.replied·form.cancelled를 번역한 전용 해소 이벤트. 대기와 1:1이라 waiting_input을 직접 해소한다
  Stop: "done", // 플러그인이 session.execution.succeeded·failed·interrupted를 번역한 턴 끝
  SessionEnd: "ended", // 플러그인이 session.deleted와 자기 location의 location.shutdown을 번역한 세션 종료
};

/**
 * heartbeat_events. 상태는 그대로 두고 "아직 살아 있다"만 알린다.
 * 플러그인이 session.step.started·session.tool.called·session.tool.success·session.tool.failed를 이 이름으로 번역해
 * 보내고, 60초 스로틀은 hook 스크립트가 다른 소스와 같은 규칙으로 적용한다(throttle은 hook 쪽 몫).
 */
const HEARTBEAT_EVENTS: ReadonlySet<string> = new Set(["PostToolUse"]);

export const opencodeAdapter: SourceAdapter = {
  source: "opencode",
  // event_state_map이 정본이다. 요청이 state를 보내도 무시한다.
  stateFieldAllowed: false,

  resolve({ event }: AdapterInput): AdapterVerdict {
    if (Object.prototype.hasOwnProperty.call(EVENT_STATE, event)) {
      return { state: EVENT_STATE[event]!, heartbeat: false, reject: null };
    }
    if (HEARTBEAT_EVENTS.has(event)) return { state: null, heartbeat: true, reject: null };
    // 표에도 heartbeat에도 없는 이벤트: 기록만 한다.
    return { state: null, heartbeat: false, reject: null };
  },
};
