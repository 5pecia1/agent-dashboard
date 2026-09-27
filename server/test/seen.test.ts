import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "./worker";
import { authHeaders, eventPayload } from "./fixtures";
// 0004 마이그레이션 원문을 그대로 재사용한다(재구현하지 않는다) - 백필 UPDATE 문이 실제로
// 배포되는 SQL과 항상 같은 문장인지를 검증해야 하므로, 이 테스트가 별도로 베낀 SQL을 돌리면
// 마이그레이션 파일이 나중에 바뀌어도 테스트가 따라가지 못하고 계속 통과해 버릴 수 있다
// (test/contract.test.ts·hooks-files.test.ts와 같은 `?raw` 관용).
import migration0004 from "../migrations/0004_dashboard_seen.sql?raw";

/**
 * seen(읽음/안읽음) 정합성 테스트 - protocol.v1.json client_actions.MarkSeen 및 두 불변식
 * (rebuild 불가침, push 무영향)의 서버 쪽 구현(seen.ts·routes.ts·maintenance.ts·0004 마이그레이션).
 *
 * ack.test.ts와 같은 이유로 `exports`가 아니라 워커(src/index.ts)를 직접 import해 부른다.
 */
const app = worker as unknown as {
  fetch(request: Request, env: unknown, ctx: ExecutionContext): Response | Promise<Response>;
};

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

async function postAck(key: string): Promise<{ status: number; json: { ok: boolean; state: string | null; transition_id: number | null; push: string } }> {
  const res = await call(`/dashboard/sessions/${encodeURIComponent(key)}/ack`, {
    method: "POST",
    headers: { ...authHeaders() },
  });
  return { status: res.status, json: (await res.json()) as { ok: boolean; state: string | null; transition_id: number | null; push: string } };
}

/** last_transition_id를 생략하면(body 없음) 본문 자체를 안 싣는다 - ack.test.ts의 postAck와 같은 관례. */
async function postSeen(
  key: string,
  lastTransitionId?: number,
): Promise<{ status: number; json: { ok: boolean; seen_transition_id: number | null } }> {
  const init: RequestInit = { method: "POST", headers: { ...authHeaders() } };
  if (lastTransitionId !== undefined) {
    init.headers = { "content-type": "application/json", ...authHeaders() };
    init.body = JSON.stringify({ last_transition_id: lastTransitionId });
  }
  const res = await call(`/dashboard/sessions/${encodeURIComponent(key)}/seen`, init);
  return { status: res.status, json: (await res.json()) as { ok: boolean; seen_transition_id: number | null } };
}

async function deleteSession(key: string): Promise<Response> {
  return call(`/dashboard/sessions/${encodeURIComponent(key)}`, { method: "DELETE", headers: { ...authHeaders() } });
}

async function sessionRow(key: string): Promise<{ state: string; last_transition_id: number | null } | null> {
  return testEnv.DB.prepare("SELECT state, last_transition_id FROM dashboard_sessions WHERE key = ?")
    .bind(key)
    .first<{ state: string; last_transition_id: number | null }>();
}

/** dashboard_seen 행 자체(있는지 없는지)와 값을 함께 본다 - null 리턴은 "행 없음"과 "값이 NULL"을 구분 못 하므로 별도 카운트도 잰다. */
async function seenRow(key: string): Promise<{ seen_transition_id: number | null } | null> {
  return testEnv.DB.prepare("SELECT seen_transition_id FROM dashboard_seen WHERE session_key = ?")
    .bind(key)
    .first<{ seen_transition_id: number | null }>();
}

async function seenRowCount(key: string): Promise<number> {
  const row = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_seen WHERE session_key = ?")
    .bind(key)
    .first<{ n: number }>();
  return Number(row?.n ?? 0);
}

let seq = 0;
/** eventPayload()의 고정 occurred_at 예시를 그대로 쓰면 이 파일의 여러 세션이 서로 다른
 * event_id로도 겹치는 event_id 충돌은 없지만(세션별 키 분리), occurred_at 단조 증가만
 * 필요한 이 파일에서는 굳이 전역 정렬을 지킬 필요가 없다(rebuild A==B 잠금은 rebuild.test.ts
 * 소관) - 세션 내부에서만 순서가 지켜지면 된다.
 */
function nextEventId(prefix: string): string {
  seq += 1;
  return `${prefix}-${seq}`;
}

describe("POST /dashboard/sessions/:key/seen: 단조 갱신(멀티 기기 역행 차단)", () => {
  it("뒤처진 기기가 더 오래된 last_transition_id를 보내도 이미 올라간 seen_transition_id를 역행시키지 않는다", async () => {
    const sessionId = "seen-mono";
    const key = `claude-code:${sessionId}`;
    await postEvent(eventPayload({ session_id: sessionId, event: "SessionStart", event_id: nextEventId("mono") })); // -> idle (전이 1)
    await postEvent(eventPayload({ session_id: sessionId, event: "UserPromptSubmit", event_id: nextEventId("mono") })); // -> working (전이 2)
    await postEvent(eventPayload({ session_id: sessionId, event: "Notification", event_id: nextEventId("mono") })); // -> waiting_input (전이 3)

    const session = await sessionRow(key);
    expect(session?.last_transition_id).toBe(3);

    // 앞선 기기: 최신 값(3)으로 seen을 올린다.
    const first = await postSeen(key, 3);
    expect(first.json).toEqual({ ok: true, seen_transition_id: 3 });

    // 뒤처진 기기: 과거 값(1, 2)을 나중에 보내도 역행하지 않는다.
    const laggingA = await postSeen(key, 1);
    expect(laggingA.json.seen_transition_id).toBe(3);
    const laggingB = await postSeen(key, 2);
    expect(laggingB.json.seen_transition_id).toBe(3);
    expect((await seenRow(key))?.seen_transition_id).toBe(3); // DB에도 역행 없이 3 그대로.

    // 리뷰 지적 medium 수정: 실제 전이 개수(3)보다 큰 값(5, "아직 일어나지 않은 미래")을 보내도
    // 세션의 현재 last_transition_id(3)를 넘어서까지 전진하지는 않는다(resolveSeenTarget의
    // 상한 클램프) - 단조 MAX는 한 번 기록되면 되돌릴 수 없어서, 클램프가 없으면 이 앞선 값이
    // 영원히 박혀 그 뒤의 진짜 새 전이(4, 5, ...)까지 "이미 본 것"으로 영구히 가려버린다.
    const ahead = await postSeen(key, 5);
    expect(ahead.json.seen_transition_id).toBe(3);

    // 본문 없이(암묵) 호출하면 세션의 "현재" last_transition_id(3)로 갱신을 시도한다 - 이미
    // 3까지 올라가 있으므로 MAX(3,3)=3 그대로.
    const implicit = await postSeen(key);
    expect(implicit.json.seen_transition_id).toBe(3);
  });

  it("리뷰 지적 medium: explicit이 세션의 현재 last_transition_id를 넘으면 그 값으로 잘린다(미래 선점 방지)", async () => {
    const sessionId = "seen-clamp";
    const key = `claude-code:${sessionId}`;
    await postEvent(eventPayload({ session_id: sessionId, event: "SessionStart", event_id: nextEventId("clamp") })); // -> idle
    // dashboard_transitions.id는 이 파일의 모든 세션이 공유하는 전역 AUTOINCREMENT라(앞선
    // 테스트들의 전이도 채번에 들어간다) 절대값 1을 가정하지 않고, 지금 세션의 실제
    // last_transition_id를 그대로 상한으로 쓴다.
    const firstId = (await sessionRow(key))?.last_transition_id;
    expect(firstId).not.toBeNull();

    // 악의적(혹은 rebuild 직후 stale 캐시로 인한 사고) 값: Number.MAX_SAFE_INTEGER도 현재 값으로 잘린다.
    const malicious = await postSeen(key, Number.MAX_SAFE_INTEGER);
    expect(malicious.json.seen_transition_id).toBe(firstId);
    expect((await seenRow(key))?.seen_transition_id).toBe(firstId);

    // 그 뒤 실제로 새 전이가 생기면 클램프된 값은 그 전이를 가리지 않는다 - 정상적으로
    // 다시 미확인으로 뜰 수 있어야 한다(이 테스트는 서버 쪽 클램프만 검증하고, 클라이언트의
    // isSessionUnseen 판정은 sync_reducer_seen_test.dart 소관).
    await postEvent(eventPayload({ session_id: sessionId, event: "UserPromptSubmit", event_id: nextEventId("clamp") })); // -> working
    const secondId = (await sessionRow(key))?.last_transition_id;
    expect(secondId).toBeGreaterThan(firstId!);
    expect((await seenRow(key))?.seen_transition_id).toBe(firstId);
  });

  it("리뷰 지적 medium: 세션이 존재하지 않으면(currentLastTransitionId도 null) 자를 상한이 없어 explicit을 그대로 받아들인다(가드 없음 설계 유지)", async () => {
    const key = "claude-code:seen-clamp-missing";
    const res = await postSeen(key, 999);
    expect(res.json.seen_transition_id).toBe(999);
  });
});

describe("POST /dashboard/sessions/:key/ack: seen 연동(확정 설계)", () => {
  it("ack가 실제 전이를 만들면 그 transition_id로 seen도 즉시 따라잡는다(ack 직후 자기 전이로 다시 미확인이 되지 않는다)", async () => {
    const sessionId = "seen-ack-real";
    const key = `claude-code:${sessionId}`;
    await postEvent(eventPayload({ session_id: sessionId, event: "SessionStart", event_id: nextEventId("ack-real") }));
    await postEvent(eventPayload({ session_id: sessionId, event: "Notification", event_id: nextEventId("ack-real") })); // -> waiting_input
    expect((await sessionRow(key))?.state).toBe("waiting_input");
    expect(await seenRowCount(key)).toBe(0); // 아직 seen을 한 번도 부른 적 없다.

    const ack = await postAck(key);
    expect(ack.json.state).toBe("working");
    expect(ack.json.transition_id).toBeGreaterThan(0);

    const after = await sessionRow(key);
    expect(after?.last_transition_id).toBe(ack.json.transition_id); // ack가 만든 전이가 곧 세션의 최신 전이다.
    const seen = await seenRow(key);
    expect(seen?.seen_transition_id).toBe(ack.json.transition_id); // seen이 그 값까지 즉시 따라잡았다 - "미확인"이 아니다.
  });

  it("ack가 no-op(이미 working)이어도 세션의 현재 last_transition_id로 seen을 갱신한다", async () => {
    const sessionId = "seen-ack-noop";
    const key = `claude-code:${sessionId}`;
    await postEvent(eventPayload({ session_id: sessionId, event: "SessionStart", event_id: nextEventId("ack-noop") }));
    await postEvent(eventPayload({ session_id: sessionId, event: "UserPromptSubmit", event_id: nextEventId("ack-noop") })); // -> working
    const before = await sessionRow(key);
    expect(before?.state).toBe("working");
    expect(await seenRowCount(key)).toBe(0);

    const ack = await postAck(key);
    expect(ack.json.state).toBe("working");
    expect(ack.json.transition_id).toBeNull(); // no-op: 전이가 새로 생기지 않았다.

    const seen = await seenRow(key);
    expect(seen?.seen_transition_id).toBe(before?.last_transition_id); // no-op이어도 현재 값까지는 갱신된다.
  });

  it("존재하지 않는 세션에 대한 ack는 dashboard_seen 행을 만들지 않는다(갱신할 last_transition_id 자체가 없다)", async () => {
    const key = "claude-code:seen-ack-missing";
    const ack = await postAck(key);
    expect(ack.json.state).toBeNull();
    expect(await seenRowCount(key)).toBe(0);
  });
});

describe("DELETE /dashboard/sessions/:key: dashboard_seen 동반 삭제", () => {
  it("세션을 지우면 그 세션의 dashboard_seen 행도 함께 지워진다(고아 방지)", async () => {
    const sessionId = "seen-delete";
    const key = `claude-code:${sessionId}`;
    await postEvent(eventPayload({ session_id: sessionId, event: "SessionStart", event_id: nextEventId("del") }));
    await postSeen(key); // 암묵 경로로 seen 행을 만들어 둔다.
    expect(await seenRowCount(key)).toBe(1);

    const res = await deleteSession(key);
    expect(res.status).toBe(200);
    expect(await seenRowCount(key)).toBe(0);
    expect(await sessionRow(key)).toBeNull();
  });
});

describe("0004_dashboard_seen.sql 백필: last_transition_id", () => {
  it("전이가 있던 세션은 MAX(전이 id)로 채워지고, 전이가 없던 세션은 NULL로 남는다", async () => {
    // 이 테스트 파일이 도는 시점에는 이미 0004가 빈 DB에 적용된 뒤라 백필 UPDATE는 대상이 0건이다
    // (setup.ts). 그래서 "마이그레이션 이전(레거시) 행"을 직접 흉내 낸다: appendTransition을
    // 거치지 않고 dashboard_transitions·dashboard_sessions를 원시 SQL로 심어, last_transition_id가
    // 아직 채워지지 않은 상태를 만든 다음 0004의 백필 문(원문 그대로, 위 import)을 다시 한 번
    // 돌려 그 문장 자체가 옳은 값을 계산하는지 검증한다. WHERE last_transition_id IS NULL이라
    // 이미 채워진 다른 세션(이 파일의 앞선 테스트들)에는 영향이 없다(멱등).
    const seededKey = "generic:backfill-seeded";
    const emptyKey = "generic:backfill-empty";
    const now = Date.now();

    const t1 = await testEnv.DB.prepare(
      `INSERT INTO dashboard_transitions
         (session_key, from_state, to_state, source, project, host, message, occurred_at, created_at)
       VALUES (?, NULL, 'idle', 'generic', NULL, NULL, NULL, ?, ?)
       RETURNING id`,
    )
      .bind(seededKey, now, now)
      .first<{ id: number }>();
    const t2 = await testEnv.DB.prepare(
      `INSERT INTO dashboard_transitions
         (session_key, from_state, to_state, source, project, host, message, occurred_at, created_at)
       VALUES (?, 'idle', 'done', 'generic', NULL, NULL, NULL, ?, ?)
       RETURNING id`,
    )
      .bind(seededKey, now + 1000, now + 1000)
      .first<{ id: number }>();
    expect(t2!.id).toBeGreaterThan(t1!.id);

    // last_transition_id 칼럼을 아예 안 주면(ALTER TABLE에 DEFAULT가 없으므로) NULL로 들어간다 -
    // "0004 이전에 만들어진 행"과 같은 모양이다.
    await testEnv.DB.prepare(
      `INSERT INTO dashboard_sessions
         (key, source, session_id, project, host, state, last_event, last_message, last_occurred_at, created_at, updated_at)
       VALUES (?, 'generic', 'backfill-seeded', '', NULL, 'done', 'PostToolUse', NULL, ?, ?, ?)`,
    )
      .bind(seededKey, now, now, now)
      .run();
    await testEnv.DB.prepare(
      `INSERT INTO dashboard_sessions
         (key, source, session_id, project, host, state, last_event, last_message, last_occurred_at, created_at, updated_at)
       VALUES (?, 'generic', 'backfill-empty', '', NULL, 'idle', 'SessionStart', NULL, ?, ?, ?)`,
    )
      .bind(emptyKey, now, now, now)
      .run();

    expect((await sessionRow(seededKey))?.last_transition_id).toBeNull();
    expect((await sessionRow(emptyKey))?.last_transition_id).toBeNull();

    const backfillMatch = migration0004.match(/UPDATE dashboard_sessions[\s\S]*?WHERE last_transition_id IS NULL;/);
    if (!backfillMatch) throw new Error("0004_dashboard_seen.sql에서 백필 UPDATE 문을 찾지 못했다");
    await testEnv.DB.prepare(backfillMatch[0].replace(/;\s*$/, "")).run();

    expect((await sessionRow(seededKey))?.last_transition_id).toBe(t2!.id); // MAX(t1, t2) = t2
    expect((await sessionRow(emptyKey))?.last_transition_id).toBeNull(); // 전이가 없던 세션은 그대로 NULL
  });
});
