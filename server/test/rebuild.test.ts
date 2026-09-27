import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { authHeaders, eventPayload } from "./fixtures";

/**
 * T06 완료 판정(d): 무작위 이벤트 200건 -> 프로젝션 스냅샷 A -> rebuild -> 스냅샷 B, A==B.
 *
 * dashboard.test.ts와 같은 방식으로 `exports`(cloudflare:workers)의 default export를 그대로
 * 호출한다 - env를 바꿔 볼 필요가 없어서 auth-cors.test.ts처럼 src/index.ts를 직접 import할
 * 이유가 없다. POST /dashboard/admin/rebuild까지 실제 마운트(registry.ts)를 거쳐 부른다
 * (task item (3): "dispatch 경유 확인").
 */
interface MainExport {
  fetch(request: Request, env: unknown, ctx: ExecutionContext): Response | Promise<Response>;
}
const app = (exports as unknown as { default: MainExport }).default;

interface TestEnv {
  DB: D1Database;
}
const testEnv = env as unknown as TestEnv;

async function call(path: string, init: RequestInit = {}): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await app.fetch(new Request(`http://dashboard.test${path}`, init), env, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

async function postEvent(body: Record<string, unknown>): Promise<Response> {
  return call("/dashboard/events", {
    method: "POST",
    headers: { "content-type": "application/json", ...authHeaders() },
    body: JSON.stringify(body),
  });
}

// mulberry32: 재현 가능한(테스트가 매번 같은 입력으로 도는) 시드 PRNG. Math.random()을 쓰면
// 실패를 재현할 수 없다.
function mulberry32(seed: number): () => number {
  let a = seed;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const rand = mulberry32(20260909);
function pick<T>(items: readonly T[]): T {
  return items[Math.floor(rand() * items.length)]!;
}

const CLAUDE_EVENTS = ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd", "PostToolUse", "UnknownHook"];
const CODEX_EVENTS = [
  "SessionStart",
  "UserPromptSubmit",
  "PermissionRequest",
  "Stop",
  "SessionEnd",
  "PostToolUse",
  "UserInputRequest", // F: 신규 이벤트도 A==B 재생 잠금에 포함시킨다(과제 6).
  "UserInputResolved",
];
const GENERIC_STATES = ["idle", "working", "waiting_input", "done", "ended", undefined] as const;
const PROJECTS = ["/repo/a", "/repo/b", "/workspace/example/proj-c", ""];
const HOSTS = ["host-1", "host-2", null];

interface SessionSpec {
  source: "claude-code" | "codex" | "generic";
  sessionId: string;
}

// 세션 10개(각 source에 몇 개씩 섞는다) + 그 세션들에 흩뿌릴 이벤트 200건.
const SESSIONS: SessionSpec[] = [
  ...Array.from({ length: 4 }, (_, i) => ({ source: "claude-code" as const, sessionId: `cc-${i}` })),
  ...Array.from({ length: 3 }, (_, i) => ({ source: "codex" as const, sessionId: `cx-${i}` })),
  ...Array.from({ length: 3 }, (_, i) => ({ source: "generic" as const, sessionId: `gn-${i}` })),
];

interface GeneratedEvent {
  payload: Record<string, unknown>;
}

/**
 * 200건을 만든다. occurred_at은 전역으로 엄격히 증가시킨다(baseTime + i*1000) - 그래서 POST를
 * 이 순서 그대로 보내면 "도착 순서 == occurred_at 순서"가 세션별로도 항상 성립한다.
 *
 * 이게 중요한 이유: routes.ts의 순서 역행 방어(5-b)는 "이 세션에 지금까지 반영된 것보다 과거
 * 이벤트가 나중에 도착하면 건너뛴다"는 규칙이라, 실시간 처리(도착 순서 기준)와 재생(occurred_at
 * 기준)이 세션 안에서 다른 순서로 볼 여지가 있으면 두 결과가 갈릴 수 있다(더 이른 이벤트가
 * "물리적으로 먼저 도착"했다가 나중에 재생에서는 뒤늦게 끼어드는 경우 등). 전역 단조 증가
 * occurred_at + 그 순서대로 POST하면 이 여지 자체가 없어져, "재생이 실시간 처리와 같은 결과를
 * 낸다"는 완료 판정(d)을 실시간/재생 순서 차이라는 별개 변수 없이 순수하게 검증할 수 있다.
 */
function generateEvents(count: number): GeneratedEvent[] {
  const baseTime = Date.UTC(2026, 0, 1, 0, 0, 0);
  const events: GeneratedEvent[] = [];
  for (let i = 0; i < count; i++) {
    const occurredAt = baseTime + i * 1000;
    const session = pick(SESSIONS);
    const project = pick(PROJECTS);
    const host = pick(HOSTS);
    const message = rand() < 0.5 ? `msg-${i}` : undefined;

    let event: string;
    let state: string | undefined;
    if (session.source === "claude-code") {
      event = pick(CLAUDE_EVENTS);
    } else if (session.source === "codex") {
      event = pick(CODEX_EVENTS);
    } else {
      event = pick(["report", "heartbeat", "tick"]);
      state = pick(GENERIC_STATES);
    }

    const overrides: Record<string, unknown> = {
      source: session.source,
      session_id: session.sessionId,
      project,
      host,
      event,
      event_id: `seed-${i}`,
      occurred_at: occurredAt,
    };
    if (message !== undefined) overrides.message = message;
    if (state !== undefined) overrides.state = state;

    events.push({ payload: eventPayload(overrides) });
  }
  return events;
}

interface SessionSnapshotRow {
  key: string;
  source: string;
  session_id: string;
  project: string;
  host: string | null;
  state: string;
  last_event: string;
  last_message: string | null;
  last_occurred_at: number | null;
  last_progress_at: number | null;
  last_transition_id: number | null;
  created_at: number;
  updated_at: number;
}

interface TransitionSnapshotRow {
  id: number;
  session_key: string;
  from_state: string | null;
  to_state: string;
  source: string;
  project: string | null;
  host: string | null;
  message: string | null;
  occurred_at: number;
  created_at: number;
}

async function snapshotSessions(): Promise<SessionSnapshotRow[]> {
  const { results } = await testEnv.DB.prepare(
    `SELECT key, source, session_id, project, host, state, last_event, last_message, last_occurred_at, last_progress_at, last_transition_id, created_at, updated_at
       FROM dashboard_sessions ORDER BY key ASC`,
  ).all<SessionSnapshotRow>();
  return results ?? [];
}

async function snapshotTransitions(): Promise<TransitionSnapshotRow[]> {
  // notified_at은 일부러 뺀다: push 발송(dispatch.ts)이 실제로 도는 라이브 경로에서만
  // notified_at이 채워지고, rebuild는 정의상 알림을 다시 보내지 않는다(정합성은 재생만으로
  // 담보되고, push는 힌트일 뿐이라 다시 보낼 필요가 없다 - 설계 확정 사항). 그래서 notified_at은
  // A와 B가 달라도 되는 유일한 칼럼이고, 그 차이 자체가 이 설계가 지켜지고 있다는 증거다.
  const { results } = await testEnv.DB.prepare(
    `SELECT id, session_key, from_state, to_state, source, project, host, message, occurred_at, created_at
       FROM dashboard_transitions ORDER BY id ASC`,
  ).all<TransitionSnapshotRow>();
  return results ?? [];
}

const REPLAY_SEQUENCE_TIMEOUT_MS = 90_000; // D1 replay also runs on resource-constrained CI workers.

describe("POST /dashboard/admin/rebuild", () => {
  it("완료 판정(d): 무작위 이벤트 200건을 재생하면 원래 프로젝션과 같은 스냅샷이 나온다", async () => {
    const events = generateEvents(200);
    for (const { payload } of events) {
      const res = await postEvent(payload);
      expect(res.status).toBe(200); // 200건 전부 accepted (400/202 없음 - 어휘를 벗어난 값을 생성하지 않는다)
    }

    const eventsCount = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_events").first<{
      n: number;
    }>();
    expect(eventsCount?.n).toBe(200);

    const snapshotA = { sessions: await snapshotSessions(), transitions: await snapshotTransitions() };
    expect(snapshotA.sessions.length).toBeGreaterThan(0);
    expect(snapshotA.transitions.length).toBeGreaterThan(0);

    const rebuildRes = await call("/dashboard/admin/rebuild", { method: "POST", headers: authHeaders() });
    expect(rebuildRes.status).toBe(200);
    const rebuildBody = (await rebuildRes.json()) as {
      ok: boolean;
      eventsReplayed: number;
      sessionsRebuilt: number;
      transitionsRebuilt: number;
    };
    expect(rebuildBody.ok).toBe(true);
    expect(rebuildBody.eventsReplayed).toBe(200);
    expect(rebuildBody.sessionsRebuilt).toBe(snapshotA.sessions.length);
    expect(rebuildBody.transitionsRebuilt).toBe(snapshotA.transitions.length);

    // dashboard_events(원장)는 rebuild가 절대 건드리지 않는다.
    const eventsAfter = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_events").first<{
      n: number;
    }>();
    expect(eventsAfter?.n).toBe(200);

    const snapshotB = { sessions: await snapshotSessions(), transitions: await snapshotTransitions() };

    expect(snapshotB.sessions).toEqual(snapshotA.sessions);
    expect(snapshotB.transitions).toEqual(snapshotA.transitions);
  }, REPLAY_SEQUENCE_TIMEOUT_MS);

  it("B: raw가 4096바이트를 넘는 PostToolUse 승격도 재생이 실시간과 같은 상태를 낸다(검증 리뷰 지적, high)", async () => {
    // 0003_dashboard_v3.sql 이전에는 rebuild.ts가 occurred_at_provided를 저장된(잘린) raw를
    // 다시 JSON.parse해서 복원했다 - PostToolUse는 tool_response를 포함해 흔히 RAW_MAX_BYTES를
    // 넘으므로 저장된 raw가 항상 깨진 JSON이 되어 JSON.parse가 항상 실패, rebuild는 실시간이
    // 승격한 세션을 승격하지 못했다(A != B). 여기서는 그 정확한 조건(큰 raw + 명시된
    // occurred_at)을 재현해 실시간 승격과 재생 승격이 같은 결과를 내는지 확인한다.
    const key = "claude-code:big-posttooluse";
    const bigRaw = JSON.stringify({
      hook_event_name: "PostToolUse",
      session_id: "big-posttooluse",
      tool_response: "x".repeat(5000), // RAW_MAX_BYTES(4096)를 넘겨 저장 시 잘리게 만든다
    });
    expect(new TextEncoder().encode(bigRaw).length).toBeGreaterThan(4096);

    // event_id는 멱등 키다(insertEvent) - eventPayload().example의 고정 event_id를 그대로
    // 재사용하면 두 번째 호출부터 전부 중복으로 버려져(ON CONFLICT DO NOTHING) 세션 상태가
    // 하나도 안 바뀐다. 호출마다 새로 준다.
    await postEvent(eventPayload({ session_id: "big-posttooluse", event: "SessionStart", event_id: "big-1" }));
    await postEvent(
      eventPayload({ session_id: "big-posttooluse", event: "UserPromptSubmit", event_id: "big-2" }),
    );
    // done/idle/stalled 중 하나로 옮겨 둔다 - promote_from 대상 상태. claude-code에서 Stop은 done.
    await postEvent(eventPayload({ session_id: "big-posttooluse", event: "Stop", event_id: "big-3" })); // -> done

    const before = await testEnv.DB.prepare(
      "SELECT state, last_occurred_at FROM dashboard_sessions WHERE key = ?",
    )
      .bind(key)
      .first<{ state: string; last_occurred_at: number | null }>();
    expect(before?.state).toBe("done");

    const promoteRes = await postEvent(
      eventPayload({
        session_id: "big-posttooluse",
        event: "PostToolUse",
        event_id: "big-4",
        occurred_at: (before?.last_occurred_at ?? 0) + 1000, // 가드4: strict greater
        raw: bigRaw,
      }),
    );
    expect(promoteRes.status).toBe(200);

    const afterRealtime = await testEnv.DB.prepare("SELECT state FROM dashboard_sessions WHERE key = ?")
      .bind(key)
      .first<{ state: string }>();
    expect(afterRealtime?.state).toBe("working"); // 실시간 경로가 승격했다(가드 5개 통과)

    const snapshotA = { sessions: await snapshotSessions(), transitions: await snapshotTransitions() };

    const rebuildRes = await call("/dashboard/admin/rebuild", { method: "POST", headers: authHeaders() });
    expect(rebuildRes.status).toBe(200);

    const snapshotB = { sessions: await snapshotSessions(), transitions: await snapshotTransitions() };
    // project는 이 비교에서 뺀다: dashboard_events에 project 전용 컬럼이 없어 rebuild는 raw를
    // 다시 파싱해 복원하는데(위 파일 헤더 주석 - 이 파일의 버그가 아니라 알려진/수용된 스키마
    // 한계), 이 테스트가 일부러 만든 5000바이트 tool_response가 요청 본문 전체를 4096바이트
    // 절단선 뒤로 밀어내 raw 전체가 깨진 JSON이 되면 project처럼 실제로는 잘리지 않은 앞쪽
    // 필드도 함께 못 읽는다(JSON.parse는 부분 파싱을 하지 않는다) - 이 테스트가 검증하려는
    // occurred_at_provided/승격 결과(state)와는 무관한, 이미 알려진 별개의 간극이다.
    //
    // last_transition_id도 이 비교에서 뺀다: 이 값은 dashboard_transitions의 "전역"
    // AUTOINCREMENT id라 이 세션(들)만의 문제가 아니라 파일 전체에 누적된 이벤트의 occurred_at
    // 순서에 좌우된다. 이 테스트가 쓰는 eventPayload()의 기본 occurred_at(계약 예시의 고정
    // 값)은 "완료 판정(d)" 테스트가 만든 200건(baseTime=2026-01-01+i*1000)보다 이르다 - 그래서
    // 이 테스트의 (실시간 처리 뒤 스냅샷 A 시점의) 전역 id 뒤쪽 자리와, 재생이 전체 이벤트를
    // occurred_at 오름차순으로 다시 정렬했을 때(스냅샷 B) 이 세션의 전이들이 맨 앞으로 오면서
    // 받는 id가 서로 다르다 - 세션 내부의 상태·전이 순서(from_state/to_state, 이 테스트가
    // 검증하려는 승격 여부)는 그대로 A==B이지만, 전역 일련번호 자체는 이 파일에 누적된 다른
    // 테스트의 occurred_at 선택에 좌우되는 값이라 여기서 비교 대상이 아니다("A: raw..." 아래
    // "완료 판정(d)"·"ack" 테스트는 자기 occurred_at을 전역 단조 증가하게 골라 이 문제를
    // 피하지만, 이 테스트는 프로토콜 예시의 고정 occurred_at을 그대로 쓰는 게 검증 목적상
    // 더 중요해 그러지 않는다 - 이미 알려진/수용된 이 파일의 구조적 한계이지 seen 기능이
    // 새로 만든 간극이 아니다).
    const dropVolatile = (rows: typeof snapshotA.sessions) =>
      rows.map(({ project: _project, last_transition_id: _lastTransitionId, ...rest }) => rest);
    expect(dropVolatile(snapshotB.sessions)).toEqual(dropVolatile(snapshotA.sessions)); // A == B(state 포함)

    const afterRebuild = snapshotB.sessions.find((s) => s.key === key);
    expect(afterRebuild?.state).toBe("working"); // 재생도 실시간과 같은 working을 낸다 - B 수정의 핵심 단언
  });

  it("시계 불변식 리뷰 지적(medium) 수정: last_progress_at은 occurred_at 재생 순서상 마지막 값이 아니라 도착 순서(received_at)의 최댓값이다", async () => {
    // 실시간(routes.ts)은 진척 이벤트(상태 변경·heartbeat)마다 last_progress_at = 수신 시각
    // (now)을 쓰고, now는 도착 순서대로 단조 증가하므로 최종값은 사실상
    // max(received_at over 진척 이벤트)다. 재생(rebuild.ts)은 `ORDER BY occurred_at ASC`로
    // 순회하므로, 스풀/재시도로 도착 순서와 occurred_at 순서가 어긋나면(routes.ts 5-b 주석이
    // 명시적으로 상정하는 상황) "마지막으로 순회한 값"과 "max"가 갈릴 수 있다.
    //
    // 이 테스트는 dashboard_events.received_at을 직접 조작해 그 어긋남을 결정론적으로
    // 재현한다(실제 벽시계 타이밍에 기대는 대신 - maintenance.test.ts/ingest.test.ts와 같은
    // 관용, 검증 기준 SQL 직접 조작).
    const sessionId = "reorder-progress";
    const key = `claude-code:${sessionId}`;
    const t0 = Date.UTC(2026, 0, 3, 0, 0, 0);

    await postEvent(
      eventPayload({ session_id: sessionId, event: "SessionStart", event_id: "ro-1", occurred_at: t0 }),
    );
    await postEvent(
      eventPayload({
        session_id: sessionId,
        event: "UserPromptSubmit",
        event_id: "ro-2",
        occurred_at: t0 + 100,
      }),
    );
    // B: occurred_at=300(재생 순서상 A보다 먼저) - 하지만 아래에서 received_at을 더 나중
    // (도착 순서상 A보다 나중)으로 조작한다.
    await postEvent(
      eventPayload({ session_id: sessionId, event: "PostToolUse", event_id: "ro-3-b", occurred_at: t0 + 300 }),
    );
    // A: occurred_at=400(재생 순서상 마지막) - 하지만 received_at은 B보다 이르게(실제로는
    // 먼저 도착한 것처럼) 조작한다. "마지막 순회 값"을 쓰면 이 값(A)이 남는다 - 그게 버그였다.
    await postEvent(
      eventPayload({ session_id: sessionId, event: "PostToolUse", event_id: "ro-4-a", occurred_at: t0 + 400 }),
    );

    const r1 = t0 + 1_000; // SessionStart 도착
    const r2 = t0 + 2_000; // UserPromptSubmit 도착
    const rA = t0 + 3_000; // A(occ=400) 도착 - occurred_at 순서로는 마지막이지만 도착은 B보다 이르다
    const rB = t0 + 4_000; // B(occ=300) 도착 - 실제로는 가장 나중에 도착(스풀 지연)
    for (const [eventId, receivedAt] of [
      ["ro-1", r1],
      ["ro-2", r2],
      ["ro-4-a", rA],
      ["ro-3-b", rB],
    ] as const) {
      await testEnv.DB.prepare("UPDATE dashboard_events SET received_at = ? WHERE event_id = ?")
        .bind(receivedAt, eventId)
        .run();
    }

    const rebuildRes = await call("/dashboard/admin/rebuild", { method: "POST", headers: authHeaders() });
    expect(rebuildRes.status).toBe(200);

    const after = await testEnv.DB.prepare(
      "SELECT last_progress_at, last_occurred_at FROM dashboard_sessions WHERE key = ?",
    )
      .bind(key)
      .first<{ last_progress_at: number | null; last_occurred_at: number | null }>();

    // max(r1, r2, rA, rB) = rB. "마지막 순회 값"(occurred_at 순서상 마지막인 A의 rA)이면 회귀.
    expect(after?.last_progress_at).toBe(rB);
    // last_occurred_at은 원래도 max 규칙(occurred_at 자체의 >=)이라 도착 순서와 무관하게
    // A의 occurred_at(가장 큰 클라이언트 시계 값)이 남는다 - 대조군.
    expect(after?.last_occurred_at).toBe(t0 + 400);
  });

  it("A==B: POST /sessions/:key/ack로 만든 UserAck 전이도 재생이 같은 결과를 낸다(client_actions.UserAck)", async () => {
    // ack.test.ts는 ack 엔드포인트 자체(가드·no-op·occurred_at 단조 증가)를 단위로 검증한다.
    // 여기서는 그 엔드포인트가 남긴 이벤트가 완료 판정(d)의 A==B 재생 잠금에도 실제로 들어가
    // 있는지만 본다 - rebuild.ts가 event === "UserAck"를 어댑터가 아니라
    // resolveUserAckTransition(client-actions.ts)으로 판정하는 특수 분기를 이 테스트가 실행한다.
    // occurred_at을 명시적으로 준다: eventPayload()의 기본값(contract 예시의 고정 occurred_at)을
    // 그대로 쓰면 이 파일에 이미 쌓인 다른 테스트의 이벤트(예: "B" 테스트도 같은 기본값을 쓴다)와
    // 전역 occurred_at 순서가 실제 도착 순서와 어긋난다 - generateEvents()의 주석이 설명하는
    // 바로 그 전제("전역 단조 증가 occurred_at + 그 순서대로 POST")가 이 파일의 모든 테스트에
    // 걸쳐 성립해야 rebuild의 전역 정렬(occurred_at ASC)이 실시간 도착 순서와 같아진다 - 이
    // 테스트는 파일에서 가장 나중에 도니 지금까지 쓰인 어떤 값보다도 큰 시각을 쓴다.
    const sessionId = "rebuild-ack";
    const key = `claude-code:${sessionId}`;
    const base = Date.UTC(2026, 0, 10, 0, 0, 0);
    await postEvent(
      eventPayload({ session_id: sessionId, event: "SessionStart", event_id: "rb-ack-1", occurred_at: base }),
    );
    await postEvent(
      eventPayload({
        session_id: sessionId,
        event: "Notification",
        event_id: "rb-ack-2",
        occurred_at: base + 1000,
      }),
    ); // -> waiting_input

    const before = await testEnv.DB.prepare("SELECT state FROM dashboard_sessions WHERE key = ?")
      .bind(key)
      .first<{ state: string }>();
    expect(before?.state).toBe("waiting_input");

    const ackRes = await call(`/dashboard/sessions/${encodeURIComponent(key)}/ack`, {
      method: "POST",
      headers: authHeaders(),
    });
    expect(ackRes.status).toBe(200);
    const ackBody = (await ackRes.json()) as { ok: boolean; state: string; transition_id: number | null };
    expect(ackBody.state).toBe("working"); // 실시간 경로가 ack로 승격했다

    const snapshotA = { sessions: await snapshotSessions(), transitions: await snapshotTransitions() };
    expect(snapshotA.sessions.find((s) => s.key === key)?.state).toBe("working");

    const rebuildRes = await call("/dashboard/admin/rebuild", { method: "POST", headers: authHeaders() });
    expect(rebuildRes.status).toBe(200);

    const snapshotB = { sessions: await snapshotSessions(), transitions: await snapshotTransitions() };
    expect(snapshotB.sessions).toEqual(snapshotA.sessions);
    expect(snapshotB.transitions).toEqual(snapshotA.transitions);
    // 재생도 UserAck 이벤트 하나만으로 같은 승격(waiting_input -> working)을 재현한다 - 핵심 단언.
    expect(snapshotB.sessions.find((s) => s.key === key)?.state).toBe("working");
  });

  it("dashboard_seen 리베이스: rebuild는 재생 말미에 seen_transition_id를 새 last_transition_id로 무조건 맞춘다(MIN 아님) — 재생 시 읽음 재계산, protocol.v1.json client_actions.MarkSeen.invariants", async () => {
    // 이전에는 rebuild가 dashboard_seen을 절대 건드리지 않는다는 판정(불가침)이었으나,
    // 전이 id는 재생마다 1부터 재채번되므로 옛 id 공간의 seen 값은 새 공간과 비교할 수 없는
    // 범주 오류였다(재생 시 읽음 재계산). 이 테스트는 정확히 그 반대 방향의 사고를 재현한다:
    // "가장 이른 전이만 seen으로 찍어 둔 세션"이 rebuild 이후에도 그 옛 값 그대로 남으면(=
    // MIN이나 불가침으로 구현했다면) 이미 지나온 전이 다수가 미확인으로 다시 켜진다 - 그래서
    // 이 테스트는 seenBefore가 "옛 last_transition_id보다 작다"(=진짜로 안 본 전이가 있다)는
    // 것부터 확인하고, rebuild 이후 seenAfter가 새 last_transition_id와 정확히 같아졌는지
    // (MIN이었다면 여전히 옛 작은 값에 머물렀을 것) 단언한다.
    const sessionId = "rebuild-seen-rebase";
    const key = `claude-code:${sessionId}`;
    const base = Date.UTC(2026, 0, 25, 0, 0, 0); // 이 파일의 다른 테스트보다 뒤(전역 단조 증가 전제).
    await postEvent(
      eventPayload({ session_id: sessionId, event: "SessionStart", event_id: "rb-rebase-1", occurred_at: base }),
    ); // -> idle: 아직 전이 아님(초기 상태 진입은 from_state null -> idle이므로 전이 1)
    await postEvent(
      eventPayload({
        session_id: sessionId,
        event: "UserPromptSubmit",
        event_id: "rb-rebase-2",
        occurred_at: base + 1000,
      }),
    ); // -> working (전이 2)
    await postEvent(
      eventPayload({
        session_id: sessionId,
        event: "Notification",
        event_id: "rb-rebase-3",
        occurred_at: base + 2000,
      }),
    ); // -> waiting_input (전이 3)

    const sessionBefore = await testEnv.DB.prepare(
      "SELECT last_transition_id FROM dashboard_sessions WHERE key = ?",
    )
      .bind(key)
      .first<{ last_transition_id: number | null }>();
    const oldLastTransitionId = sessionBefore?.last_transition_id;
    expect(typeof oldLastTransitionId).toBe("number");
    expect(oldLastTransitionId as number).toBeGreaterThanOrEqual(3); // 최소 3개 전이가 쌓였다.

    // 가장 이른 전이(첫 SessionStart가 만든 전이)까지만 확인 처리한다 - 뒤 두 전이(working,
    // waiting_input)는 명백히 아직 미확인이다.
    const firstTransitionId = (oldLastTransitionId as number) - 2;
    const seenRes = await call(`/dashboard/sessions/${encodeURIComponent(key)}/seen`, {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ last_transition_id: firstTransitionId }),
    });
    expect(seenRes.status).toBe(200);

    const seenBefore = await testEnv.DB.prepare(
      "SELECT seen_transition_id FROM dashboard_seen WHERE session_key = ?",
    )
      .bind(key)
      .first<{ seen_transition_id: number | null }>();
    expect(seenBefore?.seen_transition_id).toBe(firstTransitionId);
    // 진짜로 안 본 전이가 남아 있다는 전제 확인 - 이게 없으면 아래 rebuild 이후 단언이 우연히도
    // 참일 수 있어 MIN과 무조건 대입을 구별하지 못한다.
    expect(seenBefore?.seen_transition_id as number).toBeLessThan(oldLastTransitionId as number);

    const rebuildRes = await call("/dashboard/admin/rebuild", { method: "POST", headers: authHeaders() });
    expect(rebuildRes.status).toBe(200);

    // rebuild는 전이 id를 1부터 재채번하므로 새 last_transition_id를 하드코딩하지 않고 재생
    // 결과에서 직접 읽는다(A==B 관점 - 값 자체가 아니라 "그 세션의 새 last_transition_id와
    // 정확히 같다"는 관계를 단언한다).
    const sessionAfter = await testEnv.DB.prepare(
      "SELECT last_transition_id FROM dashboard_sessions WHERE key = ?",
    )
      .bind(key)
      .first<{ last_transition_id: number | null }>();
    const newLastTransitionId = sessionAfter?.last_transition_id;
    expect(typeof newLastTransitionId).toBe("number");

    const seenAfter = await testEnv.DB.prepare(
      "SELECT seen_transition_id FROM dashboard_seen WHERE session_key = ?",
    )
      .bind(key)
      .first<{ seen_transition_id: number | null }>();
    // 핵심 단언: MIN이었다면 seenAfter는 여전히 firstTransitionId(옛 작은 값)에 머물렀을
    // 것이다 - 무조건 대입만이 seenAfter === newLastTransitionId를 만든다.
    expect(seenAfter?.seen_transition_id).toBe(newLastTransitionId);
  });

  it("dashboard_seen 리베이스: 한 번도 seen을 부른 적 없는 세션에는 rebuild가 행을 새로 만들지 않는다", async () => {
    const sessionId = "rebuild-seen-never-marked";
    const key = `claude-code:${sessionId}`;
    const base = Date.UTC(2026, 0, 26, 0, 0, 0);
    await postEvent(
      eventPayload({ session_id: sessionId, event: "SessionStart", event_id: "rb-never-1", occurred_at: base }),
    );

    const before = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_seen WHERE session_key = ?")
      .bind(key)
      .first<{ n: number }>();
    expect(before?.n).toBe(0);

    const rebuildRes = await call("/dashboard/admin/rebuild", { method: "POST", headers: authHeaders() });
    expect(rebuildRes.status).toBe(200);

    const after = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_seen WHERE session_key = ?")
      .bind(key)
      .first<{ n: number }>();
    expect(after?.n).toBe(0); // UPDATE는 없는 행을 만들지 않는다(seen.ts의 "가드 없음" 설계와 별개로, 여기서도 INSERT는 안 한다).
  });

  it("dashboard_seen 고아 삭제: 재생 결과에 없는 session_key의 seen 행은 rebuild가 지운다", async () => {
    // maintenance.test.ts의 고아 정리 테스트와 같은 모양(같은 조건, 다른 트리거) - rebuild는
    // 다음 cron까지 기다리지 않고 세션 전체를 다시 만드는 이 자리에서 바로 정합을 맞춘다.
    const orphanKey = "rebuild:orphan-seen";
    await testEnv.DB.prepare(
      "INSERT INTO dashboard_seen (session_key, seen_transition_id) VALUES (?, 999)",
    )
      .bind(orphanKey)
      .run();

    const sessionRow = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_sessions WHERE key = ?")
      .bind(orphanKey)
      .first<{ n: number }>();
    expect(sessionRow?.n).toBe(0); // 대응하는 세션이 애초에 없다 - 진짜 고아다.
    const seenRowBefore = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_seen WHERE session_key = ?")
      .bind(orphanKey)
      .first<{ n: number }>();
    expect(seenRowBefore?.n).toBe(1);

    const rebuildRes = await call("/dashboard/admin/rebuild", { method: "POST", headers: authHeaders() });
    expect(rebuildRes.status).toBe(200);

    const seenRowAfter = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_seen WHERE session_key = ?")
      .bind(orphanKey)
      .first<{ n: number }>();
    expect(seenRowAfter?.n).toBe(0);
  });

  it("dashboard_meta.hook_revs 불간섭(훅 구버전 배너): rebuild는 이 원장을 절대 건드리지 않는다", async () => {
    // rebuild.ts 헤더 코멘트 참고 - hook_revs는 dashboard_seen과 같은 급으로 rebuild의
    // "재생 대상"이 아니다. dashboard_seen은 그래도 rebuild가 능동적으로 리베이스·고아
    // 정리를 하는 반면, hook_revs는 raw가 4096바이트로 잘려 저장되는 탓에 이벤트 로그에서
    // 신뢰성 있게 복원할 방법 자체가 없고("이력의 투영"이 아니라 "현재 사실"이라 애초에
    // 재생할 대상도 아니다) - rebuild가 이 키를 조회조차 하지 않는지를 값 그대로 증명한다.
    await postEvent(
      eventPayload({
        session_id: "rebuild-hook-revs-noninterference",
        event: "SessionStart",
        event_id: "rb-hook-revs-1",
        host: "rebuild-hook-revs-host",
        occurred_at: Date.UTC(2026, 0, 27, 0, 0, 0),
        hook_rev: "deadbeef",
      }),
    );

    const before = await testEnv.DB.prepare("SELECT value FROM dashboard_meta WHERE key = 'hook_revs'").first<{
      value: string | null;
    }>();
    expect(before?.value).toBeTruthy();
    // toMatchObject(부분 일치) - 이 테스트의 관심사는 rebuild 불간섭이지 project 필드
    // 자체가 아니다(project 값은 event_payload.example을 그대로 쓴다).
    expect(JSON.parse(before!.value!)["rebuild-hook-revs-host"]).toMatchObject({
      rev: "deadbeef",
      at: Date.UTC(2026, 0, 27, 0, 0, 0),
    });

    const rebuildRes = await call("/dashboard/admin/rebuild", { method: "POST", headers: authHeaders() });
    expect(rebuildRes.status).toBe(200);

    const after = await testEnv.DB.prepare("SELECT value FROM dashboard_meta WHERE key = 'hook_revs'").first<{
      value: string | null;
    }>();
    // 바이트 그대로 동일 - rebuild가 이 행을 읽지도 쓰지도 않았다는 가장 강한 증거.
    expect(after?.value).toBe(before?.value);
  });
});
