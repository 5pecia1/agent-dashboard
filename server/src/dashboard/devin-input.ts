import type { SessionState } from "./state";

export const DEVIN_CORRELATION_MAX_CHARS = 200;
export const DEVIN_PENDING_LIMIT = 256;

export interface DevinCorrelation {
  prompt_id: string | null;
  tool_use_id: string | null;
  tool_name: string | null;
}

export interface DevinInputState {
  prompt_id: string | null;
  pending: { tool_use_id: string; tool_name: string }[];
  untracked: boolean;
}

export function correlationValue(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 && value.length <= DEVIN_CORRELATION_MAX_CHARS
    ? value
    : null;
}

export function readDevinCorrelation(body: Record<string, unknown>): DevinCorrelation {
  return {
    prompt_id: correlationValue(body.prompt_id),
    tool_use_id: correlationValue(body.tool_use_id),
    tool_name: correlationValue(body.tool_name),
  };
}

export function parseDevinInputState(
  value: string | null,
  currentState: SessionState | null,
): DevinInputState {
  const fallback: DevinInputState = {
    prompt_id: null,
    pending: [],
    untracked: currentState === "waiting_input",
  };
  if (value === null) return fallback;
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    return fallback;
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return fallback;
  const obj = parsed as Record<string, unknown>;
  if (!("prompt_id" in obj)) return fallback;
  const promptId = obj.prompt_id === null ? null : correlationValue(obj.prompt_id);
  if (obj.prompt_id !== null && promptId === null) return fallback;
  if (typeof obj.untracked !== "boolean") return fallback;
  if (!Array.isArray(obj.pending) || obj.pending.length > DEVIN_PENDING_LIMIT) return fallback;
  const pending: { tool_use_id: string; tool_name: string }[] = [];
  for (const entry of obj.pending) {
    if (entry === null || typeof entry !== "object" || Array.isArray(entry)) return fallback;
    const e = entry as Record<string, unknown>;
    const toolUseId = correlationValue(e.tool_use_id);
    const toolName = correlationValue(e.tool_name);
    if (toolUseId === null || toolName === null) return fallback;
    pending.push({ tool_use_id: toolUseId, tool_name: toolName });
  }
  return { prompt_id: promptId, pending, untracked: obj.untracked };
}

export interface DevinInputResolution extends DevinCorrelation {
  event: string;
  currentState: SessionState | null;
  lastOccurredAt: number | null;
  occurredAt: number;
  occurredAtProvided: boolean;
  storedInputState: string | null;
  proposedState: SessionState | null;
}

export function resolveDevinInput(
  input: DevinInputResolution,
): { state: SessionState | null; inputState: string | null } {
  const unchanged = { state: input.proposedState, inputState: input.storedInputState };
  if (
    (input.lastOccurredAt !== null && input.occurredAt < input.lastOccurredAt) ||
    (input.currentState === "ended" && input.event !== "SessionStart")
  ) {
    return unchanged;
  }
  const tracker = parseDevinInputState(input.storedInputState, input.currentState);
  const save = (state: SessionState | null) => ({ state, inputState: JSON.stringify(tracker) });
  if (input.event === "UserPromptSubmit" || input.event === "SessionStart") {
    tracker.prompt_id = input.prompt_id;
    tracker.pending = [];
    tracker.untracked = false;
    return save(input.proposedState);
  }
  if (input.event === "SessionEnd" || input.event === "UserAck") {
    tracker.pending = [];
    tracker.untracked = false;
    if (input.event === "SessionEnd") tracker.prompt_id = null;
    return save(input.proposedState);
  }
  if (tracker.prompt_id !== null && input.prompt_id !== null && tracker.prompt_id !== input.prompt_id) {
    return { state: null, inputState: input.storedInputState };
  }
  if (input.event === "Stop") {
    tracker.pending = [];
    tracker.untracked = false;
    return save(input.proposedState);
  }
  if (input.event === "PermissionRequest" || input.event === "UserInputRequest") {
    const identified =
      input.prompt_id !== null &&
      input.tool_use_id !== null &&
      input.tool_name !== null &&
      input.occurredAtProvided &&
      (input.event !== "UserInputRequest" || input.tool_name === "ask_user_question");
    if (!identified) {
      tracker.untracked = true;
    } else {
      tracker.prompt_id ??= input.prompt_id;
      const exists = tracker.pending.some(
        (p) => p.tool_use_id === input.tool_use_id && p.tool_name === input.tool_name,
      );
      if (!exists) {
        if (tracker.pending.length >= DEVIN_PENDING_LIMIT) tracker.untracked = true;
        else tracker.pending.push({ tool_use_id: input.tool_use_id!, tool_name: input.tool_name! });
      }
      tracker.pending.sort(
        (a, b) => a.tool_use_id.localeCompare(b.tool_use_id) || a.tool_name.localeCompare(b.tool_name),
      );
    }
    return save(input.proposedState);
  }
  if (
    input.event === "PostToolUse" &&
    input.currentState === "waiting_input" &&
    input.occurredAtProvided &&
    input.prompt_id !== null &&
    input.prompt_id === tracker.prompt_id &&
    input.tool_use_id !== null &&
    input.tool_name !== null
  ) {
    const index = tracker.pending.findIndex(
      (p) => p.tool_use_id === input.tool_use_id && p.tool_name === input.tool_name,
    );
    if (index >= 0) {
      tracker.pending.splice(index, 1);
      return save(tracker.pending.length || tracker.untracked ? "waiting_input" : "working");
    }
  }
  return unchanged;
}
