import type { SessionState } from "../state";
import type { AdapterInput, AdapterVerdict, SourceAdapter } from "./index";

/**
 * Antigravity CLI(agy) 어댑터.
 * 표의 정본은 contracts/dashboard-protocol.v1.json의 event_state_map.by_source["antigravity"]다.
 * agy는 hook stdin에 이벤트 이름을 싣지 않는다. hook이 hooks.json 명령이 넘긴 이름과 payload를 보고
 * 정본 어휘(UserPromptSubmit·UserInputRequest·UserInputResolved·Stop·PostToolUse)로 번역해서 보내므로
 * (같은 파일의 event_state_map.antigravity_hook_translation) 서버는 번역된 이름만 안다.
 * 다른 소스와 겹치는 이름이 많지만 어휘가 같다는 보장이 없으므로 표를 공유하지 않고
 * 각자 적어 둔다(한쪽 어휘가 바뀌어도 다른 쪽이 조용히 따라가지 않게).
 *
 * SessionStart·SessionEnd 줄은 없다 — hook이 서버로 넘길 세션 시작·종료 신호가 agy에는 없기 때문이다.
 * 그래서 세션은 첫 UserPromptSubmit으로 생기고, ended로 가지 않고 done에 머문다
 * (정리는 stale 표시와 수동 삭제 몫 - antigravity_hook_translation.limitations).
 *
 * Stop은 hook이 fullyIdle 값과 상관없이 전부 보내고 서버는 전부 done으로 본다. fullyIdle이 false인
 * Stop은 서브에이전트 같은 백그라운드 작업이 남았다는 뜻이지만 턴 실행은 끝났으므로 done이 맞다.
 * 실물 E2E(agy 1.2.12)에서 서브에이전트를 쓰는 턴은 부모의 마지막 Stop까지 fullyIdle false로
 * 끝났고, 그 Stop을 버리면 세션이 working에 멈춰 stalled 푸시가 잘못 나갔다. agy가 실행을 재개하면
 * invocationNum 0인 PreInvocation, 또는 Stop 뒤 처음 오는 PreInvocation(한 실행 안에서 모델 호출이
 * 이어지는 경우)이 UserPromptSubmit으로 번역되어 working으로 되돌린다.
 * 여기 값을 바꾸려면 정본을 먼저 바꿔야 하며, test/contract.test.ts가 실제 adapter 판정과 대조한다.
 */
const EVENT_STATE: Record<string, SessionState> = {
  UserPromptSubmit: "working", // hook이 PreInvocation을 번역한 턴 (재)시작(invocationNum 0이거나 Stop 뒤 처음 오는 것). agy가 스스로 시작한 턴도 포함
  UserInputRequest: "waiting_input", // hook이 ask_question·ask_permission의 PreToolUse를 번역한 합성 질문 대기 이벤트
  UserInputResolved: "working", // hook이 같은 도구의 PostToolUse를 번역한 전용 해소 이벤트. 대기와 1:1이라 waiting_input을 직접 해소한다
  Stop: "done", // 턴 실행 마침. fullyIdle 값과 상관없이 모든 Stop이 온다(백그라운드 작업이 남은 채 끝난 턴도 done이고 agy가 재개하면 UserPromptSubmit이 working으로 되돌린다)
};

/**
 * heartbeat_events. 상태는 그대로 두고 "아직 살아 있다"만 알린다.
 * PostToolUse는 도구를 쓸 때마다 터지므로 hook이 60초에 한 번만 보낸다(throttle은 hook 쪽 몫).
 * 질문 도구의 PostToolUse는 hook이 UserInputResolved로 번역하므로 여기로 오지 않는다.
 */
const HEARTBEAT_EVENTS: ReadonlySet<string> = new Set(["PostToolUse"]);

export const antigravityAdapter: SourceAdapter = {
  source: "antigravity",
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
