import { DERIVED_STATES, STATES, isSessionState } from "../state";
import type { AdapterInput, AdapterVerdict, SourceAdapter } from "./index";

/**
 * generic 어댑터: 임의의 스크립트·CI가 상태를 직접 신고하는 통로.
 *
 * 이 소스에는 고정된 이벤트 어휘가 없다(event_state_map.by_source["generic"]은 빈 배열).
 * 그래서 event 이름을 보지 않고 payload.state를 그대로 믿는다. 이것이 "서버 배포 없이
 * 새 에이전트를 붙일 수 있다"는 성질의 근거다 - 새 소스가 생겨도 서버 표를 고칠 필요가 없다.
 *
 * 다만 두 가지는 서버가 지킨다(generic_rule):
 *  - state는 states.enum 안의 값이어야 한다.
 *  - stalled는 서버 cron만 만드는 파생 상태다. 클라이언트가 신고하면 400으로 거절한다.
 *    (허용하면 "조용히 죽었다"는 관측이 신고로 위조될 수 있다.)
 */
export const genericAdapter: SourceAdapter = {
  source: "generic",
  stateFieldAllowed: true,

  resolve({ reportedState }: AdapterInput): AdapterVerdict {
    // state가 없으면 기록만 된다. generic에게 event 이름은 사람이 읽는 라벨일 뿐이다.
    if (reportedState === undefined || reportedState === null) return { state: null, heartbeat: false, reject: null };

    if (!isSessionState(reportedState)) {
      return {
        state: null,
        heartbeat: false,
        reject: `state는 ${STATES.join("|")} 중 하나여야 한다`,
      };
    }
    if (DERIVED_STATES.has(reportedState)) {
      return {
        state: null,
        heartbeat: false,
        reject: `state '${reportedState}'는 서버가 스스로 만드는 파생 상태라 신고할 수 없다`,
      };
    }
    return { state: reportedState, heartbeat: false, reject: null };
  },
};
