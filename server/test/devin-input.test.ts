import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "./worker";
import {
  DEVIN_CORRELATION_MAX_CHARS,
  DEVIN_PENDING_LIMIT,
  parseDevinInputState,
  readDevinCorrelation,
  resolveDevinInput,
  type DevinInputState,
} from "../src/dashboard/devin-input";
import contract from "../../contracts/dashboard-protocol.v1.json";
import { authHeaders } from "./fixtures";

const app = worker as unknown as {
  fetch(request: Request, env: unknown, ctx: ExecutionContext): Response | Promise<Response>;
};

interface TestEnv {
  DB: D1Database;
}

const testEnv = env as unknown as TestEnv;

interface IngestResponse {
  ok?: boolean;
  duplicate?: boolean;
  state?: string | null;
  transition_id?: number | null;
  push?: string;
  error?: string;
}

const T0 = Date.UTC(2026, 8, 24, 9, 0, 0);
let seq = 0;

function devinEvent(
  sessionId: string,
  event: string,
  occurredAt: number,
  extra: Record<string, unknown> = {},
): Record<string, unknown> {
  seq += 1;
  return {
    protocol_version: 1,
    source: "devin",
    session_id: sessionId,
    project: "/repo",
    host: "h",
    event,
    event_id: `dvt-${seq}`,
    occurred_at: occurredAt,
    ...extra,
  };
}

function corr(promptId: unknown, toolUseId: unknown, toolName: unknown): Record<string, unknown> {
  return { prompt_id: promptId, tool_use_id: toolUseId, tool_name: toolName };
}

async function postEvent(
  body: Record<string, unknown>,
  envOverrides: Record<string, unknown> = {},
): Promise<{ status: number; json: IngestResponse }> {
  const ctx = createExecutionContext();
  const request = new Request("http://dashboard.test/dashboard/events", {
    method: "POST",
    headers: { "content-type": "application/json", ...authHeaders() },
    body: JSON.stringify(body),
  });
  const response = await app.fetch(request, { ...env, ...envOverrides }, ctx);
  await waitOnExecutionContext(ctx);
  return { status: response.status, json: (await response.json()) as IngestResponse };
}

async function ackSession(
  key: string,
  envOverrides: Record<string, unknown> = {},
): Promise<{ status: number; json: IngestResponse }> {
  const ctx = createExecutionContext();
  const request = new Request(
    `http://dashboard.test/dashboard/sessions/${encodeURIComponent(key)}/ack`,
    { method: "POST", headers: authHeaders() },
  );
  const response = await app.fetch(request, { ...env, ...envOverrides }, ctx);
  await waitOnExecutionContext(ctx);
  return { status: response.status, json: (await response.json()) as IngestResponse };
}

async function callRebuild() {
  const ctx = createExecutionContext();
  const request = new Request("http://dashboard.test/dashboard/admin/rebuild", {
    method: "POST",
    headers: authHeaders(),
  });
  const response = await app.fetch(request, env, ctx);
  await waitOnExecutionContext(ctx);
  return { status: response.status, json: (await response.json()) as Record<string, unknown> };
}

async function sessionRow(key: string) {
  return testEnv.DB.prepare(
    "SELECT state, last_event, last_occurred_at, last_transition_id, input_state FROM dashboard_sessions WHERE key = ?",
  )
    .bind(key)
    .first<{
      state: string;
      last_event: string;
      last_occurred_at: number | null;
      last_transition_id: number | null;
      input_state: string | null;
    }>();
}

async function inputStateOf(key: string): Promise<DevinInputState | null> {
  const row = await sessionRow(key);
  if (!row || row.input_state === null) return null;
  return JSON.parse(row.input_state) as DevinInputState;
}

async function transitionsOf(key: string): Promise<string[]> {
  const { results } = await testEnv.DB.prepare(
    "SELECT to_state FROM dashboard_transitions WHERE session_key = ? ORDER BY id",
  )
    .bind(key)
    .all<{ to_state: string }>();
  return (results ?? []).map((r) => r.to_state);
}

async function eventRowOf(key: string, event: string) {
  return testEnv.DB.prepare(
    "SELECT event, message, raw, prompt_id, tool_use_id, tool_name FROM dashboard_events WHERE session_key = ? AND event = ? ORDER BY id DESC LIMIT 1",
  )
    .bind(key, event)
    .first<{
      event: string;
      message: string | null;
      raw: string | null;
      prompt_id: string | null;
      tool_use_id: string | null;
      tool_name: string | null;
    }>();
}

const devinKey = (sid: string) => `devin:${sid}`;

const FORCED_CAS_MISSES = 33;
function conflictingDatabase() {
  let attempts = 0;
  const db = {
    prepare: testEnv.DB.prepare.bind(testEnv.DB),
    batch: async (statements: D1PreparedStatement[]) => {
      attempts += 1;
      if (attempts <= FORCED_CAS_MISSES) return statements.map(() => ({ success: true, results: [], meta: {} }));
      return testEnv.DB.batch(statements);
    },
  };
  return { db, attempts: () => attempts };
}

describe("Devin 입력 해소 추적: 기본 흐름", () => {
  it("질문 수락은 정확히 일치하는 PostToolUse로만 해소된다", async () => {
    const sid = "di-q-accept";
    const key = devinKey(sid);
    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 1, { prompt_id: "p1" }));
    await postEvent(
      devinEvent(sid, "UserInputRequest", T0 + 2, corr("p1", "u-a", "ask_user_question")),
    );
    expect((await sessionRow(key))?.state).toBe("waiting_input");
    expect(await inputStateOf(key)).toEqual({
      prompt_id: "p1",
      pending: [{ tool_use_id: "u-a", tool_name: "ask_user_question" }],
      untracked: false,
    });

    const res = await postEvent(
      devinEvent(sid, "PostToolUse", T0 + 3, corr("p1", "u-a", "ask_user_question")),
    );
    expect(res.json.state).toBe("working");
    expect((await sessionRow(key))?.state).toBe("working");
    expect(await inputStateOf(key)).toEqual({ prompt_id: "p1", pending: [], untracked: false });
    expect(await transitionsOf(key)).toEqual(["working", "waiting_input", "working"]);
  });

  it("권한 승인 후 완료된 도구의 PostToolUse가 대기를 해소한다(raw tool_input과 무관)", async () => {
    const sid = "di-perm-ok";
    const key = devinKey(sid);
    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 10, { prompt_id: "p1" }));
    await postEvent(
      devinEvent(sid, "PermissionRequest", T0 + 11, {
        ...corr("p1", "u-exec", "exec"),
        tool_input: { command: "printf ok" },
      }),
    );
    expect((await sessionRow(key))?.state).toBe("waiting_input");

    const res = await postEvent(
      devinEvent(sid, "PostToolUse", T0 + 12, {
        ...corr("p1", "u-exec", "exec"),
        tool_input: { command: "printf ok", extra_answer_key: "답변이 붙어도 상관 키는 같다" },
      }),
    );
    expect(res.json.state).toBe("working");
    expect(await transitionsOf(key)).toEqual(["working", "waiting_input", "working"]);
  });

  it("두 개의 대기는 각각 독립적으로 해소되고 중복 요청·완료는 무해하다", async () => {
    const sid = "di-two-pending";
    const key = devinKey(sid);
    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 20, { prompt_id: "p1" }));
    const requestA = devinEvent(sid, "PermissionRequest", T0 + 21, corr("p1", "u-a", "exec"));
    await postEvent(requestA);
    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 22, corr("p1", "u-b", "exec")));
    expect((await inputStateOf(key))?.pending).toEqual([
      { tool_use_id: "u-a", tool_name: "exec" },
      { tool_use_id: "u-b", tool_name: "exec" },
    ]);

    await postEvent(devinEvent(sid, "PostToolUse", T0 + 23, corr("p1", "u-a", "exec")));
    expect((await sessionRow(key))?.state).toBe("waiting_input");
    expect((await inputStateOf(key))?.pending).toEqual([{ tool_use_id: "u-b", tool_name: "exec" }]);

    const dupRequest = await postEvent(requestA);
    expect(dupRequest.json.duplicate).toBe(true);
    expect((await inputStateOf(key))?.pending).toEqual([{ tool_use_id: "u-b", tool_name: "exec" }]);

    await postEvent(devinEvent(sid, "PostToolUse", T0 + 24, corr("p1", "u-a", "exec")));
    expect((await sessionRow(key))?.state).toBe("waiting_input");
    expect((await inputStateOf(key))?.pending).toEqual([{ tool_use_id: "u-b", tool_name: "exec" }]);

    await postEvent(devinEvent(sid, "PostToolUse", T0 + 25, corr("p1", "u-b", "exec")));
    expect((await sessionRow(key))?.state).toBe("working");
    expect(await transitionsOf(key)).toEqual(["working", "waiting_input", "working"]);
  });
});

describe("Devin 입력 해소 추적: 해소 불가 조건", () => {
  it("식별자가 어긋난 완료와 식별자 없는 하트비트는 대기를 해소하지 못한다", async () => {
    const sid = "di-mismatch";
    const key = devinKey(sid);
    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 30, { prompt_id: "p1" }));
    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 31, corr("p1", "u-a", "exec")));
    expect((await sessionRow(key))?.state).toBe("waiting_input");

    const variants: Record<string, unknown>[] = [
      corr("p1", "u-zz", "exec"),
      corr("p1", "u-a", "other_tool"),
      corr("p9", "u-a", "exec"),
      { prompt_id: "p1", tool_name: "exec" },
      corr("p1", 12345, "exec"),
      { prompt_id: "x".repeat(DEVIN_CORRELATION_MAX_CHARS + 1), tool_use_id: "u-a", tool_name: "exec" },
      {},
    ];
    for (let i = 0; i < variants.length; i++) {
      await postEvent(devinEvent(sid, "PostToolUse", T0 + 40 + i, variants[i]));
      expect((await sessionRow(key))?.state).toBe("waiting_input");
    }
    expect((await inputStateOf(key))?.pending).toEqual([{ tool_use_id: "u-a", tool_name: "exec" }]);
  });

  it("식별 불가 대기(untracked)가 남아 있으면 상관 완료만으로 해소되지 않는다", async () => {
    const sid = "di-untracked";
    const key = devinKey(sid);
    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 60, { prompt_id: "p1" }));
    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 61));
    expect((await sessionRow(key))?.state).toBe("waiting_input");
    expect(await inputStateOf(key)).toEqual({ prompt_id: "p1", pending: [], untracked: true });

    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 62, corr("p1", "u-b", "exec")));
    await postEvent(devinEvent(sid, "PostToolUse", T0 + 63, corr("p1", "u-b", "exec")));
    expect((await sessionRow(key))?.state).toBe("waiting_input");
    expect(await inputStateOf(key)).toEqual({ prompt_id: "p1", pending: [], untracked: true });
  });

  it("새 UserPromptSubmit은 이전 대기를 지우고 다른 턴의 늦은 완료·Stop은 현재 대기를 건드리지 않는다", async () => {
    const sid = "di-prompt-reset";
    const key = devinKey(sid);
    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 70, { prompt_id: "p1" }));
    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 71, corr("p1", "u-a", "exec")));
    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 72, { prompt_id: "p2" }));
    expect(await inputStateOf(key)).toEqual({ prompt_id: "p2", pending: [], untracked: false });
    expect(await transitionsOf(key)).toEqual(["working", "waiting_input", "working"]);

    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 73, corr("p2", "u-b", "exec")));
    expect((await sessionRow(key))?.state).toBe("waiting_input");

    await postEvent(devinEvent(sid, "PostToolUse", T0 + 74, corr("p1", "u-a", "exec")));
    expect((await sessionRow(key))?.state).toBe("waiting_input");
    expect((await inputStateOf(key))?.pending).toEqual([{ tool_use_id: "u-b", tool_name: "exec" }]);

    await postEvent(devinEvent(sid, "Stop", T0 + 75, { prompt_id: "p1" }));
    expect((await sessionRow(key))?.state).toBe("waiting_input");
    expect((await inputStateOf(key))?.pending).toEqual([{ tool_use_id: "u-b", tool_name: "exec" }]);

    await postEvent(devinEvent(sid, "PostToolUse", T0 + 76, corr("p2", "u-b", "exec")));
    expect((await sessionRow(key))?.state).toBe("working");
  });

  it("역행 완료·ended 세션의 완료·모르는 세션의 완료는 전이를 만들지 않는다", async () => {
    const sid = "di-stale-ended";
    const key = devinKey(sid);
    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 80, { prompt_id: "p1" }));
    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 81, corr("p1", "u-a", "exec")));

    await postEvent(devinEvent(sid, "PostToolUse", T0 + 70, corr("p1", "u-a", "exec")));
    expect((await sessionRow(key))?.state).toBe("waiting_input");
    expect((await inputStateOf(key))?.pending).toEqual([{ tool_use_id: "u-a", tool_name: "exec" }]);

    await postEvent(devinEvent(sid, "SessionEnd", T0 + 90, { prompt_id: "p1" }));
    expect((await sessionRow(key))?.state).toBe("ended");
    await postEvent(devinEvent(sid, "PostToolUse", T0 + 91, corr("p1", "u-a", "exec")));
    expect((await sessionRow(key))?.state).toBe("ended");
    expect(await transitionsOf(key)).toEqual(["working", "waiting_input", "ended"]);

    const ghostSid = "di-ghost";
    await postEvent(devinEvent(ghostSid, "PostToolUse", T0 + 92, corr("p1", "u-a", "exec")));
    expect(await sessionRow(devinKey(ghostSid))).toBeNull();
  });
});

describe("Devin 입력 해소 추적: 경계 이벤트와 보수적 폴백", () => {
  it("Stop·SessionEnd·UserAck는 대기를 지우고, ack 뒤 새 대기는 옛 완료가 지우지 못한다", async () => {
    const sid = "di-boundaries";
    const key = devinKey(sid);
    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 100, { prompt_id: "p1" }));
    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 101, corr("p1", "u-a", "exec")));
    await postEvent(devinEvent(sid, "Stop", T0 + 102, { prompt_id: "p1" }));
    expect((await sessionRow(key))?.state).toBe("done");
    expect(await inputStateOf(key)).toEqual({ prompt_id: "p1", pending: [], untracked: false });

    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 103, { prompt_id: "p2" }));
    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 104, corr("p2", "u-b", "exec")));
    const ackRes = await ackSession(key);
    expect(ackRes.json.state).toBe("working");
    expect(await inputStateOf(key)).toEqual({ prompt_id: "p2", pending: [], untracked: false });

    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 105, corr("p2", "u-c", "exec")));
    expect((await sessionRow(key))?.state).toBe("waiting_input");
    await postEvent(devinEvent(sid, "PostToolUse", T0 + 106, corr("p2", "u-b", "exec")));
    expect((await sessionRow(key))?.state).toBe("waiting_input");
    expect((await inputStateOf(key))?.pending).toEqual([{ tool_use_id: "u-c", tool_name: "exec" }]);
  });

  it("손상된 저장 상태는 '대기 없음'으로 재해석하지 않고, pending 상한 초과는 untracked가 된다", async () => {
    const sid = "di-corrupt";
    const key = devinKey(sid);
    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 110, { prompt_id: "p1" }));
    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 111, corr("p1", "u-a", "exec")));

    await testEnv.DB.prepare("UPDATE dashboard_sessions SET input_state = ? WHERE key = ?")
      .bind("not-json", key)
      .run();
    await postEvent(devinEvent(sid, "PostToolUse", T0 + 112, corr("p1", "u-a", "exec")));
    expect((await sessionRow(key))?.state).toBe("waiting_input");

    const fullPending = Array.from({ length: DEVIN_PENDING_LIMIT }, (_, i) => ({
      tool_use_id: `u-${String(i).padStart(3, "0")}`,
      tool_name: "exec",
    }));
    await testEnv.DB.prepare("UPDATE dashboard_sessions SET input_state = ? WHERE key = ?")
      .bind(JSON.stringify({ prompt_id: "p1", pending: fullPending, untracked: false }), key)
      .run();
    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 113, corr("p1", "u-new", "exec")));
    const state = await inputStateOf(key);
    expect(state?.pending.length).toBe(DEVIN_PENDING_LIMIT);
    expect(state?.untracked).toBe(true);
  });
});

describe("Devin 입력 해소 추적: 저장·프라이버시·재생", () => {
  it("메시지 저장이 꺼져도 상관 컬럼은 보존되어 해소된다", async () => {
    const sid = "di-raw-trunc";
    const key = devinKey(sid);
    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 120, { prompt_id: "p1" }), {
      DASHBOARD_STORE_MESSAGE: "0",
    });
    const res = await postEvent(
      devinEvent(sid, "UserInputRequest", T0 + 121, {
        ...corr("p1", "u-a", "ask_user_question"),
        message: "m".repeat(5000),
      }),
      { DASHBOARD_STORE_MESSAGE: "0" },
    );
    expect(res.json.state).toBe("waiting_input");

    const eventRow = await eventRowOf(key, "UserInputRequest");
    expect(eventRow?.prompt_id).toBe("p1");
    expect(eventRow?.tool_use_id).toBe("u-a");
    expect(eventRow?.tool_name).toBe("ask_user_question");
    expect(eventRow?.message).toBeNull();
    expect(new TextEncoder().encode(eventRow?.raw ?? "").length).toBeLessThanOrEqual(4096);

    const done = await postEvent(
      devinEvent(sid, "PostToolUse", T0 + 122, corr("p1", "u-a", "ask_user_question")),
      { DASHBOARD_STORE_MESSAGE: "0" },
    );
    expect(done.json.state).toBe("working");
  });

  it("상세 수집에서 raw가 잘려도 상관 컬럼으로 해소되고 rebuild도 같은 결과를 재생한다", async () => {
    const sid = "di-raw-clip";
    const key = devinKey(sid);
    const bigRaw = JSON.stringify({ tool_response: { output: "x".repeat(6000) } });
    const contentEnabled = { DASHBOARD_STORE_MESSAGE: "1" };

    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 190, { prompt_id: "p1" }), contentEnabled);
    await postEvent(
      devinEvent(sid, "PermissionRequest", T0 + 191, { ...corr("p1", "u-a", "exec"), raw: bigRaw }),
      contentEnabled,
    );
    await postEvent(
      devinEvent(sid, "PermissionRequest", T0 + 192, { ...corr("p1", "u-b", "exec"), raw: bigRaw }),
      contentEnabled,
    );
    const resA = await postEvent(
      devinEvent(sid, "PostToolUse", T0 + 193, { ...corr("p1", "u-a", "exec"), raw: bigRaw }),
      contentEnabled,
    );
    expect(resA.json.state).toBe("waiting_input");

    const clipped = await eventRowOf(key, "PostToolUse");
    expect(new TextEncoder().encode(clipped?.raw ?? "").length).toBe(4096);
    expect(() => JSON.parse(clipped?.raw ?? "")).toThrow();
    expect(clipped?.prompt_id).toBe("p1");
    expect(clipped?.tool_use_id).toBe("u-a");
    expect(clipped?.tool_name).toBe("exec");

    const requestB = await eventRowOf(key, "PermissionRequest");
    expect(new TextEncoder().encode(requestB?.raw ?? "").length).toBe(4096);
    expect(() => JSON.parse(requestB?.raw ?? "")).toThrow();
    expect(requestB?.tool_use_id).toBe("u-b");

    const beforeRebuild = await sessionRow(key);
    expect(beforeRebuild?.state).toBe("waiting_input");
    expect((await inputStateOf(key))?.pending).toEqual([{ tool_use_id: "u-b", tool_name: "exec" }]);

    const rebuildRes = await callRebuild();
    expect(rebuildRes.status).toBe(200);
    const afterRebuild = await sessionRow(key);
    expect(afterRebuild?.state).toBe("waiting_input");
    expect(afterRebuild?.input_state).toBe(beforeRebuild?.input_state);
    expect(await transitionsOf(key)).toEqual(["working", "waiting_input"]);

    const resB = await postEvent(
      devinEvent(sid, "PostToolUse", T0 + 194, { ...corr("p1", "u-b", "exec"), raw: bigRaw }),
      contentEnabled,
    );
    expect(resB.json.state).toBe("working");
    const liveRow = await sessionRow(key);
    const liveTransitions = await transitionsOf(key);
    expect(liveTransitions).toEqual(["working", "waiting_input", "working"]);

    const rebuildRes2 = await callRebuild();
    expect(rebuildRes2.status).toBe(200);
    const rebuiltRow = await sessionRow(key);
    expect(rebuiltRow?.state).toBe(liveRow?.state);
    expect(rebuiltRow?.input_state).toBe(liveRow?.input_state);
    expect(await transitionsOf(key)).toEqual(liveTransitions);
  });

  it("rebuild는 저장 컬럼만으로 같은 input_state·전이를 재생한다(중간 미해소 상태 포함)", async () => {
    const sid = "di-rebuild";
    const key = devinKey(sid);
    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 130, { prompt_id: "p1" }));
    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 131, corr("p1", "u-a", "exec")));
    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 132, corr("p1", "u-b", "exec")));
    await postEvent(devinEvent(sid, "PostToolUse", T0 + 133, corr("p1", "u-a", "exec")));
    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 134));
    await postEvent(devinEvent(sid, "PostToolUse", T0 + 135, corr("p1", "u-b", "exec")));

    const liveRow = await sessionRow(key);
    const liveInput = await inputStateOf(key);
    const liveTransitions = await transitionsOf(key);
    expect(liveRow?.state).toBe("waiting_input");
    expect(liveInput).toEqual({ prompt_id: "p1", pending: [], untracked: true });

    const rebuildRes = await callRebuild();
    expect(rebuildRes.status).toBe(200);

    const rebuiltRow = await sessionRow(key);
    expect(rebuiltRow?.state).toBe(liveRow?.state);
    expect(rebuiltRow?.input_state).toBe(liveRow?.input_state);
    expect(await transitionsOf(key)).toEqual(liveTransitions);
  });

  it("devin이 아닌 소스는 상관 필드를 저장하지 않는다", async () => {
    seq += 1;
    const res = await postEvent({
      protocol_version: 1,
      source: "claude-code",
      session_id: "di-nondevin",
      project: "/repo",
      host: "h",
      event: "Notification",
      event_id: `dvt-${seq}`,
      occurred_at: T0 + 140,
      ...corr("p1", "u-a", "exec"),
    });
    expect(res.json.state).toBe("waiting_input");
    const row = await testEnv.DB.prepare(
      "SELECT prompt_id, tool_use_id, tool_name FROM dashboard_events WHERE session_key = ? ORDER BY id DESC LIMIT 1",
    )
      .bind("claude-code:di-nondevin")
      .first<{ prompt_id: string | null; tool_use_id: string | null; tool_name: string | null }>();
    expect(row).toEqual({ prompt_id: null, tool_use_id: null, tool_name: null });
  });
});

describe("Devin 입력 해소 추적: 동시성", () => {
  it("같은 occurred_at의 동시 요청 10건은 둘 다 추적되고 대기 전이는 한 번이다", async () => {
    const sid = "di-conc-req";
    const key = devinKey(sid);
    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 150, { prompt_id: "p1" }));

    const batch = [
      ...Array.from({ length: 5 }, () => devinEvent(sid, "PermissionRequest", T0 + 151, corr("p1", "u-a", "exec"))),
      ...Array.from({ length: 5 }, () => devinEvent(sid, "PermissionRequest", T0 + 151, corr("p1", "u-b", "exec"))),
    ];
    await Promise.all(batch.map((b) => postEvent(b)));

    const state = await inputStateOf(key);
    expect(state?.pending).toEqual([
      { tool_use_id: "u-a", tool_name: "exec" },
      { tool_use_id: "u-b", tool_name: "exec" },
    ]);
    expect(state?.untracked).toBe(false);
    expect((await sessionRow(key))?.state).toBe("waiting_input");
    expect(await transitionsOf(key)).toEqual(["working", "waiting_input"]);
  });

  it("같은 occurred_at의 동시 완료는 정확히 한 번만 working으로 전이한다", async () => {
    const sid = "di-conc-done";
    const key = devinKey(sid);
    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 160, { prompt_id: "p1" }));
    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 161, corr("p1", "u-a", "exec")));
    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 162, corr("p1", "u-b", "exec")));

    const batch = [
      ...Array.from({ length: 5 }, () => devinEvent(sid, "PostToolUse", T0 + 163, corr("p1", "u-a", "exec"))),
      ...Array.from({ length: 5 }, () => devinEvent(sid, "PostToolUse", T0 + 163, corr("p1", "u-b", "exec"))),
    ];
    await Promise.all(batch.map((b) => postEvent(b)));

    expect((await sessionRow(key))?.state).toBe("working");
    expect(await inputStateOf(key)).toEqual({ prompt_id: "p1", pending: [], untracked: false });
    expect(await transitionsOf(key)).toEqual(["working", "waiting_input", "working"]);
  });
});

describe("Devin 입력 해소 추적: CAS 충돌 재시도", () => {
  it("일치하는 PostToolUse 커밋이 계속 충돌해도 성공할 때까지 재시도한다", async () => {
    const sid = "di-cas-post";
    const key = devinKey(sid);
    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 200, { prompt_id: "p1" }));
    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 201, corr("p1", "u-a", "exec")));

    const conflicting = conflictingDatabase();
    const res = await postEvent(
      devinEvent(sid, "PostToolUse", T0 + 202, corr("p1", "u-a", "exec")),
      { DB: conflicting.db },
    );
    expect(conflicting.attempts()).toBe(FORCED_CAS_MISSES + 1);
    expect(res.json.state).toBe("working");
    expect((await sessionRow(key))?.state).toBe("working");
    expect(await inputStateOf(key)).toEqual({ prompt_id: "p1", pending: [], untracked: false });
    expect(await transitionsOf(key)).toEqual(["working", "waiting_input", "working"]);
    const count = await testEnv.DB.prepare(
      "SELECT COUNT(*) AS n FROM dashboard_events WHERE session_key = ? AND event = 'PostToolUse'",
    )
      .bind(key)
      .first<{ n: number }>();
    expect(count?.n).toBe(1);
  });

  it("UserAck 커밋이 계속 충돌해도 성공할 때까지 재시도한다", async () => {
    const sid = "di-cas-ack";
    const key = devinKey(sid);
    await postEvent(devinEvent(sid, "UserPromptSubmit", T0 + 210, { prompt_id: "p1" }));
    await postEvent(devinEvent(sid, "PermissionRequest", T0 + 211, corr("p1", "u-a", "exec")));

    const conflicting = conflictingDatabase();
    const res = await ackSession(key, { DB: conflicting.db });
    expect(conflicting.attempts()).toBe(FORCED_CAS_MISSES + 1);
    expect(res.json.state).toBe("working");
    expect((await sessionRow(key))?.state).toBe("working");
    expect(await inputStateOf(key)).toEqual({ prompt_id: "p1", pending: [], untracked: false });
    expect(await transitionsOf(key)).toEqual(["working", "waiting_input", "working"]);
    const count = await testEnv.DB.prepare(
      "SELECT COUNT(*) AS n FROM dashboard_events WHERE session_key = ? AND event = 'UserAck'",
    )
      .bind(key)
      .first<{ n: number }>();
    expect(count?.n).toBe(1);
  });
});

describe("resolveDevinInput 순수 판정", () => {
  const base = {
    event: "PostToolUse",
    prompt_id: "p1",
    tool_use_id: "u-a",
    tool_name: "exec",
    currentState: "waiting_input" as const,
    lastOccurredAt: 100,
    occurredAt: 101,
    occurredAtProvided: true,
    storedInputState: JSON.stringify({
      prompt_id: "p1",
      pending: [{ tool_use_id: "u-a", tool_name: "exec" }],
      untracked: false,
    }),
    proposedState: null,
  };

  it("상관 식별자는 비어있거나 200자를 넘거나 문자열이 아니면 무효다", () => {
    expect(readDevinCorrelation({})).toEqual({ prompt_id: null, tool_use_id: null, tool_name: null });
    expect(readDevinCorrelation(corr("  ", "u", "t"))).toEqual({
      prompt_id: null,
      tool_use_id: "u",
      tool_name: "t",
    });
    expect(readDevinCorrelation(corr("p", 7, "t")).tool_use_id).toBeNull();
    expect(readDevinCorrelation(corr("x".repeat(DEVIN_CORRELATION_MAX_CHARS), "u", "t")).prompt_id).toBe(
      "x".repeat(DEVIN_CORRELATION_MAX_CHARS),
    );
    expect(
      readDevinCorrelation(corr("x".repeat(DEVIN_CORRELATION_MAX_CHARS + 1), "u", "t")).prompt_id,
    ).toBeNull();
  });

  it("저장된 input_state가 없거나 깨져 있으면 보수적 폴백으로 돌아간다", () => {
    expect(parseDevinInputState(null, "waiting_input")).toEqual({
      prompt_id: null,
      pending: [],
      untracked: true,
    });
    expect(parseDevinInputState(null, "working")).toEqual({
      prompt_id: null,
      pending: [],
      untracked: false,
    });
    expect(parseDevinInputState("not-json", "waiting_input").untracked).toBe(true);
    expect(parseDevinInputState('{"prompt_id":"p1"}', "waiting_input").untracked).toBe(true);
    expect(
      parseDevinInputState(
        JSON.stringify({ prompt_id: "p1", pending: [{ tool_use_id: "u" }], untracked: false }),
        "waiting_input",
      ),
    ).toEqual({ prompt_id: null, pending: [], untracked: true });
    const overflow = {
      prompt_id: "p1",
      pending: Array.from({ length: DEVIN_PENDING_LIMIT + 1 }, (_, i) => ({
        tool_use_id: `u-${i}`,
        tool_name: "exec",
      })),
      untracked: false,
    };
    expect(parseDevinInputState(JSON.stringify(overflow), "waiting_input")).toEqual({
      prompt_id: null,
      pending: [],
      untracked: true,
    });
  });

  it("waiting_input이 아닌 상태의 PostToolUse는 input_state를 건드리지 않는다", () => {
    const result = resolveDevinInput({ ...base, currentState: "working" });
    expect(result.state).toBeNull();
    expect(result.inputState).toBe(base.storedInputState);
  });

  it("다른 prompt_id의 식별 이벤트는 상태 무효로 돌아간다", () => {
    const result = resolveDevinInput({ ...base, event: "Stop", prompt_id: "p2" });
    expect(result.state).toBeNull();
    expect(result.inputState).toBe(base.storedInputState);
  });
});

describe("계약 정본과 구현 상수의 일치", () => {
  it("devin_input_tracking·상관 필드 정의가 소스 상수·해석기와 일치한다", () => {
    const tracking = (
      contract.event_state_map as unknown as Record<
        string,
        {
          request_events: string[];
          completion_event: string;
          question_tool: string;
          correlation_fields: string[];
          pending_limit: number;
          reset_events: string[];
        }
      >
    ).devin_input_tracking;
    expect(tracking.request_events).toEqual(["PermissionRequest", "UserInputRequest"]);
    expect(tracking.completion_event).toBe("PostToolUse");
    expect(tracking.question_tool).toBe("ask_user_question");
    expect(tracking.correlation_fields).toEqual(["prompt_id", "tool_use_id", "tool_name"]);
    expect(tracking.pending_limit).toBe(DEVIN_PENDING_LIMIT);
    expect([...tracking.reset_events].sort()).toEqual(
      ["UserPromptSubmit", "SessionStart", "Stop", "SessionEnd", "UserAck"].sort(),
    );

    const fields = contract.event_payload.fields as Record<string, { max_length?: number }>;
    const optional = contract.event_payload.optional as string[];
    for (const f of ["prompt_id", "tool_use_id", "tool_name"]) {
      expect(fields[f]?.max_length).toBe(DEVIN_CORRELATION_MAX_CHARS);
      expect(optional).toContain(f);
    }

    const devinMap = contract.event_state_map.by_source.devin as { event: string; state: string }[];
    expect(devinMap.find((e) => e.event === "UserInputRequest")?.state).toBe("waiting_input");

    const postToolUse = (
      contract.heartbeat_events.events as Record<string, Record<string, unknown>>
    ).PostToolUse;
    expect(postToolUse.throttle_ms).toBe(60000);
    expect(typeof postToolUse.throttle_exception_devin_correlated).toBe("string");
  });
});
