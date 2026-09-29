import { antigravityAdapter } from "./antigravity";
import { claudeCodeAdapter } from "./claude-code";
import { codexAdapter } from "./codex";
import { devinAdapter } from "./devin";
import { genericAdapter } from "./generic";
import { grokAdapter } from "./grok";
import type { SessionState } from "../state";

/**
 * 소스 어댑터 레지스트리.
 *
 * 0001의 state.ts는 (event -> state) 표 하나를 모든 소스가 공유했다. 그런데 어휘는 소스마다
 * 다르다 - Codex의 PermissionRequest는 Claude Code에 없고, generic은 이벤트 이름 자체가 자유다.
 * 그래서 표를 소스별로 쪼개 각 파일이 자기 어휘만 알게 했다. 새 에이전트를 붙이는 일은
 * 이 디렉터리에 파일 하나를 더하고 SOURCE_ADAPTERS에 한 줄 등록하는 일로 끝난다.
 *
 * 어휘의 정본은 ../protocol.v1.json의 event_state_map.by_source / heartbeat_events이고,
 * 각 어댑터 파일은 그 표를 그대로 옮겨 적는다.
 */

/** 어댑터가 판정에 쓰는 입력. 요청 본문에서 어댑터가 볼 자격이 있는 값만 추린 것이다. */
export interface AdapterInput {
  /** hook 이벤트 이름. */
  event: string;
  /**
   * 요청 본문의 state 필드 원문(검증 전이라 unknown).
   * state_field_allowed가 false인 소스에는 undefined로 들어온다 - 즉 어댑터는 볼 수 없다.
   */
  reportedState?: unknown;
}

/** 이벤트 하나에 대한 어댑터의 판정. */
export interface AdapterVerdict {
  /** 이 이벤트가 가리키는 상태. null이면 상태를 바꾸지 않는다(기록만 한다). */
  state: SessionState | null;
  /**
   * 상태는 그대로 두되 "살아 있음"은 알리는 이벤트인가(protocol.v1.json heartbeat_events).
   * true면 last_occurred_at을 밀어 stalled 판정을 미룬다. 매핑에도 heartbeat에도 없는
   * 이벤트는 false - 기록만 되고 stalled 시계는 계속 흐른다.
   */
  heartbeat: boolean;
  /** 페이로드가 어휘를 어겨 400으로 거절해야 하는 사유. null이면 정상. */
  reject: string | null;
}

export interface SourceAdapter {
  /** protocol.v1.json sources.registered의 키. */
  readonly source: string;
  /**
   * 이 소스가 payload.state로 상태를 직접 신고할 수 있는가
   * (sources.registered[*].state_field_allowed). false면 event_state_map이 정본이고
   * 요청이 보낸 state는 아예 어댑터에 전달되지 않는다.
   */
  readonly stateFieldAllowed: boolean;
  resolve(input: AdapterInput): AdapterVerdict;
}

/**
 * 등록된 소스들. 여기 없는 source는 미등록이고, 이벤트 로그에만 남긴 뒤 202로 답한다
 * (sources.unregistered).
 */
export const SOURCE_ADAPTERS: Record<string, SourceAdapter> = {
  [antigravityAdapter.source]: antigravityAdapter,
  [claudeCodeAdapter.source]: claudeCodeAdapter,
  [codexAdapter.source]: codexAdapter,
  [devinAdapter.source]: devinAdapter,
  [genericAdapter.source]: genericAdapter,
  [grokAdapter.source]: grokAdapter,
};

/**
 * source 이름으로 어댑터를 찾는다. 없으면 null(= 미등록 소스).
 * 요청 본문에서 온 문자열로 조회하므로 Object.prototype의 상속 속성("constructor" 등)이
 * 어댑터인 척하지 못하게 자기 속성만 본다.
 */
export function adapterFor(source: string): SourceAdapter | null {
  return Object.prototype.hasOwnProperty.call(SOURCE_ADAPTERS, source)
    ? (SOURCE_ADAPTERS[source] ?? null)
    : null;
}

/** 등록된 소스 이름 목록. */
export function registeredSources(): string[] {
  return Object.keys(SOURCE_ADAPTERS);
}
