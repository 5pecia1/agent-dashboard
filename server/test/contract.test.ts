import { describe, expect, it } from "vitest";
import contract from "../../contracts/dashboard-protocol.v1.json";
import {
  DEVIN_CORRELATION_MAX_CHARS,
  DEVIN_PENDING_LIMIT,
  readDevinCorrelation,
} from "../src/dashboard/devin-input";
import { SOURCE_ADAPTERS } from "../src/dashboard/sources";
import { DERIVED_STATES, PUSH_STATES, STATES, TERMINAL_STATES } from "../src/dashboard/state";

type ContractMapping = { event: string; state: string };
type ContractSource = { state_field_allowed: boolean };
type ContractField = { required?: boolean; max_length?: number };

interface DashboardContract {
  protocol_version: number;
  sources: { registered: Record<string, ContractSource> };
  states: { enum: string[]; detail: Record<string, { terminal?: boolean; derived?: boolean }> };
  event_state_map: {
    by_source: Record<string, ContractMapping[]>;
    devin_input_tracking?: {
      request_events: string[];
      completion_event: string;
      question_tool: string;
      correlation_fields: string[];
      pending_limit: number;
      reset_events: string[];
    };
  };
  event_payload: { fields: Record<string, ContractField> };
  push_states: { enum: string[] };
}

const dashboardContract = contract as DashboardContract;

function adapterMappingMismatches(candidate: DashboardContract, adapters = SOURCE_ADAPTERS): string[] {
  return Object.entries(candidate.event_state_map.by_source).flatMap(([source, mappings]) => {
    const adapter = adapters[source];
    if (!adapter) return [`${source}: registered adapter is missing`];
    return mappings.flatMap(({ event, state }) => {
      const actual = adapter.resolve({ event });
      return actual.state === state
        ? []
        : [`${source}:${event} expected ${state}, received ${actual.state ?? "null"}`];
    });
  });
}

describe("Agent Dashboard server provider-owned protocol.v1.json", () => {
  it("v1 계약은 서버 로컬 source에서 읽힌다", () => {
    expect(dashboardContract.protocol_version).toBe(1);
  });

  it("계약의 상태 어휘와 source 권한이 실제 서버 레지스트리와 일치한다", () => {
    expect(STATES).toEqual(dashboardContract.states.enum);
    expect([...PUSH_STATES]).toEqual(dashboardContract.push_states.enum);
    expect([...TERMINAL_STATES]).toEqual(
      dashboardContract.states.enum.filter((state) => dashboardContract.states.detail[state]?.terminal),
    );
    expect([...DERIVED_STATES]).toEqual(
      dashboardContract.states.enum.filter((state) => dashboardContract.states.detail[state]?.derived),
    );

    expect(Object.keys(SOURCE_ADAPTERS).sort()).toEqual(Object.keys(dashboardContract.sources.registered).sort());
    for (const [source, specification] of Object.entries(dashboardContract.sources.registered)) {
      expect(SOURCE_ADAPTERS[source]?.stateFieldAllowed).toBe(specification.state_field_allowed);
    }
  });

  it("계약의 event→state 표가 실제 adapter 판정과 일치한다", () => {
    expect(adapterMappingMismatches(dashboardContract)).toEqual([]);
  });

  it("검사 자체가 실제 adapter 상태 불일치를 결정적으로 보고한다", () => {
    const claude = SOURCE_ADAPTERS["claude-code"]!;
    const mismatches = adapterMappingMismatches(dashboardContract, {
      ...SOURCE_ADAPTERS,
      "claude-code": { ...claude, resolve: () => ({ state: "done", heartbeat: false, reject: null }) },
    });
    expect(mismatches).toContain("claude-code:SessionStart expected idle, received done");
  });

  it("devin_input_tracking 규약 값이 resolver 상수·필드 정의와 일치한다", () => {
    const tracking = dashboardContract.event_state_map.devin_input_tracking;
    expect(tracking).toBeDefined();
    expect(tracking!.request_events).toEqual(["PermissionRequest", "UserInputRequest"]);
    expect(tracking!.completion_event).toBe("PostToolUse");
    expect(tracking!.question_tool).toBe("ask_user_question");
    expect(tracking!.correlation_fields).toEqual(["prompt_id", "tool_use_id", "tool_name"]);
    expect(tracking!.reset_events).toEqual(["UserPromptSubmit", "SessionStart", "Stop", "SessionEnd", "UserAck"]);
    expect(tracking!.pending_limit).toBe(DEVIN_PENDING_LIMIT);

    for (const name of tracking!.correlation_fields) {
      const field = dashboardContract.event_payload.fields[name];
      expect(field?.required).toBe(false);
      expect(field?.max_length).toBe(DEVIN_CORRELATION_MAX_CHARS);
    }

    const correlation = readDevinCorrelation({ prompt_id: "p", tool_use_id: "u", tool_name: "t" });
    expect(Object.keys(correlation).sort()).toEqual([...tracking!.correlation_fields].sort());
    expect(correlation).toEqual({ prompt_id: "p", tool_use_id: "u", tool_name: "t" });
  });
});
