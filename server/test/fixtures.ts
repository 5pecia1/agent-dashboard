// 공용 테스트 픽스처. 값은 여기서 하드코딩하지 않고 Agent Dashboard server가 소유하는 protocol.v1.json 정본을
// 읽어서 만든다. 정본이 바뀌면(상태 어휘, 이벤트 매핑, 예시 payload) 이 픽스처도 같이 바뀐다.
//
// JSON은 일반 import로 읽는다(워커 런타임 안에서 돌아가는 테스트 파일은 node:fs로 임의 경로를
// 읽을 수 없으므로, Vite가 번들 시점에 인라인해주는 정적 import에 의존한다).
import contract from "../../contracts/dashboard-protocol.v1.json";

export interface StateTransition {
  event: string;
  state: string;
  description?: string;
}

type ByocaSource = Record<string, StateTransition[]>;

const bySource = (contract.event_state_map as { by_source: ByocaSource }).by_source;
const statesDetail = contract.states.detail as Record<string, { terminal?: boolean }>;

/** 인증 미들웨어(src/index.ts)가 요구하는 토큰. vitest.config.ts의 miniflare.bindings.AUTH_TOKEN과 같은 값이어야 한다. */
export const AUTH_TOKEN = "test-auth-token";

export function authHeaders(extra: Record<string, string> = {}): Record<string, string> {
  return { authorization: `Bearer ${AUTH_TOKEN}`, ...extra };
}

/** contract.event_payload.example을 복제해 오버라이드를 얹는다. 필드 이름·예시 값은 정본에서만 온다. */
export function eventPayload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { ...contract.event_payload.example, ...overrides };
}

/** source별 (event -> state) 매핑 표. 정본의 event_state_map.by_source를 그대로 읽는다. */
export function eventStateMap(source: string): StateTransition[] {
  return bySource[source] ?? [];
}

/** event_state_map.by_source 중 매핑이 비어 있지 않은 source만 돌려준다 (예: generic은 제외된다). */
export function sourcesWithEventMap(): string[] {
  return Object.keys(bySource).filter((source) => bySource[source].length > 0);
}

/** states.enum의 값 하나가 terminal(states.detail[state].terminal)인지. */
export function isTerminalState(state: string): boolean {
  return Boolean(statesDetail[state]?.terminal);
}

/**
 * source의 이벤트 매핑 표에서 "한 세션의 정상 수명"에 해당하는 앞부분만 자른다.
 * 처음으로 terminal 상태에 닿는 항목까지 포함하고 멈춘다. (예: codex의 event_state_map은
 * SessionEnd 뒤에 구버전 notify fallback인 agent-turn-complete를 별도 항목으로 덧붙여 두는데,
 * 이건 같은 세션이 SessionEnd 다음에 다시 겪는 이벤트가 아니라 Stop의 대체 표기이므로 체인에
 * 넣지 않는다.)
 */
export function lifecycleChain(source: string): StateTransition[] {
  const all = eventStateMap(source);
  const chain: StateTransition[] = [];
  for (const entry of all) {
    chain.push(entry);
    if (isTerminalState(entry.state)) break;
  }
  return chain;
}

/** lifecycleChain 밖에 남은 나머지 매핑(예: codex의 agent-turn-complete). 독립적으로 검증한다. */
export function extraMappings(source: string): StateTransition[] {
  const chain = lifecycleChain(source);
  return eventStateMap(source).slice(chain.length);
}

/** push는 이 상태들로 "전이"했을 때만 보낸다(정본 push_states.enum). */
export function pushStates(): string[] {
  return contract.push_states.enum;
}

export function statesEnum(): string[] {
  return contract.states.enum;
}
