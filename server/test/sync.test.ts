import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { Hono } from "hono";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  buildSync,
  DEFAULT_LIMIT,
  DEFAULT_STALL_MS,
  MAX_LIMIT,
  parseSyncQuery,
  syncRoutes,
  type SyncEnv,
  type SyncResponse,
} from "../src/dashboard/sync";
import { HOOK_REV } from "../src/hooks/routes";
import { lifecycleChain, sourcesWithEventMap } from "./fixtures";

// 배선(src/index.ts, routes.ts)은 다른 task 소유다. 그래서 이 파일은 sync 서브앱만
// 직접 인스턴스화해서 실제 마운트와 같은 모양(GET /dashboard/sync)으로 부른다.
const app = new Hono();
app.route("/dashboard", syncRoutes);

interface TestEnv {
  DB: D1Database;
}
const testEnv = env as unknown as TestEnv;

async function sync(query = ""): Promise<{ status: number; headers: Headers; body: SyncResponse }> {
  const ctx = createExecutionContext();
  const response = await app.fetch(new Request(`http://dashboard.test/dashboard/sync${query}`), env, ctx);
  await waitOnExecutionContext(ctx);
  return { status: response.status, headers: response.headers, body: (await response.json()) as SyncResponse };
}

// ── 테스트용 수집기 ──────────────────────────────────────────────────────────
// 지금 src/features/dashboard/routes.ts의 POST /dashboard/events는 0001 시절 구현이라
// dashboard_transitions에 아무것도 쓰지 않는다(전이를 쌓는 v2 수집기는 별도 task 소유이고,
// routes.ts는 이 TASK의 파일 소유 밖이다). sync는 "전이 로그를 읽는" 계층이므로 읽을 거리를
// 만들어 줄 수집기가 필요하다. 그래서 정본(protocol.v1.json states.invariants)이 규정한
// 프로젝션·전이 기록 규칙만 이 파일 안에서 최소로 재현한다.
//   - 이벤트는 무조건 append
//   - 상태가 "실제로 바뀔 때만" dashboard_transitions에 한 줄
//   - 같은 상태 재진입은 전이가 아니다
let clock = Date.UTC(2026, 8, 8, 9, 0, 0);

interface IngestArgs {
  source: string;
  sessionId: string;
  project?: string;
  host?: string;
  event: string;
  state: string;
  message?: string | null;
}

async function ingest(args: IngestArgs): Promise<void> {
  const { source, sessionId, event, state } = args;
  const project = args.project ?? `/workspace/example/dev/${sessionId}`;
  const host = args.host ?? "sol-mbp";
  const message = args.message ?? null;
  const now = (clock += 1000);
  const key = `${source}:${sessionId}`;

  await testEnv.DB.prepare(
    `INSERT INTO dashboard_events (session_key, source, event, message, received_at, occurred_at, host)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(key, source, event, message, now, now, host)
    .run();

  const current = await testEnv.DB.prepare("SELECT state FROM dashboard_sessions WHERE key = ?")
    .bind(key)
    .first<{ state: string }>();

  await testEnv.DB.prepare(
    `INSERT INTO dashboard_sessions
       (key, source, session_id, project, host, state, last_event, last_message, last_occurred_at, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(key) DO UPDATE SET
       state = excluded.state,
       project = excluded.project,
       host = excluded.host,
       last_event = excluded.last_event,
       last_message = COALESCE(excluded.last_message, dashboard_sessions.last_message),
       last_occurred_at = excluded.last_occurred_at,
       updated_at = excluded.updated_at`,
  )
    .bind(key, source, sessionId, project, host, state, event, message, now, now, now)
    .run();

  // 정본 states.invariants: "상태가 실제로 바뀔 때만 dashboard_transitions에 한 줄이 쌓인다."
  if (current?.state === state) return;
  await testEnv.DB.prepare(
    `INSERT INTO dashboard_transitions
       (session_key, from_state, to_state, source, project, host, message, occurred_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(key, current?.state ?? null, state, source, project, host, message, now, now)
    .run();
}

/** 전이들을 id 오름차순으로 적용해 세션 맵을 재구성한다(클라이언트가 하는 일 그대로). */
type Card = { state: string; source: string; project: string | null; host: string | null };
function applyTransitions(map: Map<string, Card>, transitions: SyncResponse["transitions"]): Map<string, Card> {
  for (const t of transitions) {
    map.set(t.session_key, { state: t.to_state, source: t.source, project: t.project, host: t.host });
  }
  return map;
}

function snapshotMap(sessions: SyncResponse["sessions"]): Map<string, Card> {
  return new Map(
    sessions.map((s) => [s.key, { state: s.state, source: s.source, project: s.project, host: s.host }]),
  );
}

// 파일 전체가 하나의 D1 스냅샷을 공유한다(vitest-pool-workers는 파일 단위로 격리한다).
// 여기서 만든 세션·전이가 이 파일의 모든 테스트가 읽는 유일한 모집단이다.
let injectedSessions = 0;
let injectedTransitions = 0;

beforeAll(async () => {
  const before = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_transitions").first<{ n: number }>();
  expect(before?.n).toBe(0); // 빈 D1에서 시작한다는 증거

  // 로컬 protocol.v1.json 정본의 source별 이벤트 매핑을 그대로 태운다.
  for (const source of sourcesWithEventMap()) {
    for (const suffix of ["a", "b"]) {
      const sessionId = `${source}-${suffix}`;
      injectedSessions += 1;
      for (const step of lifecycleChain(source)) {
        await ingest({ source, sessionId, event: step.event, state: step.state, message: `${step.event} 메시지` });
      }
    }
  }
  // 같은 상태 재진입은 전이가 아니다 — 이벤트만 늘고 커서는 안 움직인다.
  await ingest({ source: "claude-code", sessionId: "claude-code-a", event: "SessionStart", state: "idle" });
  await ingest({ source: "claude-code", sessionId: "claude-code-a", event: "SessionStart", state: "idle" });

  const after = await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM dashboard_transitions").first<{ n: number }>();
  injectedTransitions = after?.n ?? 0;
  expect(injectedTransitions).toBeGreaterThan(0);
});

describe("parseSyncQuery: 질의 인자 파싱", () => {
  it("since가 없거나 정수가 아니면 null(=스냅샷), limit은 1..MAX_LIMIT로 조인다", () => {
    expect(parseSyncQuery(new URLSearchParams("")).since).toBeNull();
    expect(parseSyncQuery(new URLSearchParams("since=")).since).toBeNull();
    expect(parseSyncQuery(new URLSearchParams("since=abc")).since).toBeNull();
    expect(parseSyncQuery(new URLSearchParams("since=1.5")).since).toBeNull();
    expect(parseSyncQuery(new URLSearchParams("since=0")).since).toBe(0);
    expect(parseSyncQuery(new URLSearchParams("since=42")).since).toBe(42);

    expect(parseSyncQuery(new URLSearchParams("")).limit).toBe(DEFAULT_LIMIT);
    expect(parseSyncQuery(new URLSearchParams("limit=0")).limit).toBe(DEFAULT_LIMIT);
    expect(parseSyncQuery(new URLSearchParams("limit=abc")).limit).toBe(DEFAULT_LIMIT);
    expect(parseSyncQuery(new URLSearchParams("limit=5")).limit).toBe(5);
    expect(parseSyncQuery(new URLSearchParams(`limit=${MAX_LIMIT + 1}`)).limit).toBe(MAX_LIMIT);

    expect(parseSyncQuery(new URLSearchParams("")).includeEnded).toBe(false);
    expect(parseSyncQuery(new URLSearchParams("include_ended=1")).includeEnded).toBe(true);
  });
});

describe("GET /dashboard/sync 응답 봉투", () => {
  it("sessions와 transitions 키는 reset과 무관하게 항상 존재하고, no-store로 내려간다", async () => {
    const snapshot = await sync();
    expect(snapshot.status).toBe(200);
    expect(snapshot.headers.get("cache-control")).toBe("no-store");
    expect(Array.isArray(snapshot.body.sessions)).toBe(true);
    expect(Array.isArray(snapshot.body.transitions)).toBe(true);
    expect(snapshot.body.transitions).toEqual([]);

    const delta = await sync(`?since=${snapshot.body.cursor}`);
    expect(Array.isArray(delta.body.sessions)).toBe(true);
    expect(delta.body.sessions).toEqual([]);
    expect(Array.isArray(delta.body.transitions)).toBe(true);

    for (const body of [snapshot.body, delta.body]) {
      expect(body.protocol_version).toBe(1);
      expect(body.stall_ms).toBe(DEFAULT_STALL_MS);
      expect(body.pruned_below_id).toBe(0);
      expect(body.mute_until).toBeNull(); // mute_until seed는 '0' = 음소거 아님
      expect(typeof body.server_time).toBe("number");
      expect(body.server_time).toBeGreaterThan(0);
    }
  });

  it("since가 없으면 reset:true 스냅샷, include_ended=1이면 ended 세션까지 포함한다", async () => {
    const withoutEnded = await sync();
    const withEnded = await sync("?include_ended=1");
    expect(withoutEnded.body.reset).toBe(true);
    expect(withEnded.body.reset).toBe(true);

    expect(withEnded.body.sessions.length).toBe(injectedSessions);
    expect(withEnded.body.sessions.some((s) => s.state === "ended")).toBe(true);
    expect(withoutEnded.body.sessions.every((s) => s.state !== "ended")).toBe(true);
    expect(withoutEnded.body.sessions.length).toBeLessThan(withEnded.body.sessions.length);
  });
});

describe("완료 판정(a): since=0 델타로 재구성한 세션 맵 == reset 스냅샷", () => {
  it("이벤트를 N건 주입한 뒤, 커서 0부터 받은 전이만으로 스냅샷과 같은 세션 맵이 나온다", async () => {
    const snapshot = await sync("?include_ended=1");
    expect(snapshot.body.reset).toBe(true);
    expect(snapshot.body.sessions.length).toBeGreaterThan(0);

    // since=0 = "아직 아무 전이도 못 받았다". pruned_below_id가 0이므로 reset이 아니라 델타다.
    const rebuilt = new Map<string, Card>();
    let cursor = 0;
    let pages = 0;
    for (;;) {
      const page = await sync(`?since=${cursor}&limit=${MAX_LIMIT}`);
      expect(page.body.reset).toBe(false);
      applyTransitions(rebuilt, page.body.transitions);
      cursor = page.body.cursor;
      pages += 1;
      if (!page.body.has_more) break;
      expect(pages).toBeLessThan(50); // 무한 루프 방지
    }

    expect(cursor).toBe(snapshot.body.cursor);
    expect(rebuilt.size).toBe(snapshot.body.sessions.length);
    expect(Object.fromEntries([...rebuilt].sort())).toEqual(
      Object.fromEntries([...snapshotMap(snapshot.body.sessions)].sort()),
    );
  });

  it("전이가 없는 상태 재진입은 커서를 움직이지 않는다 (전이 수 = 커서 최대값)", async () => {
    const snapshot = await sync();
    expect(snapshot.body.cursor).toBe(injectedTransitions);
  });
});

describe("완료 판정(b): since=현재 커서 → 빈 델타, 커서 유지", () => {
  it("따라잡은 클라이언트가 다시 물어도 transitions는 빈 배열이고 cursor는 그대로다", async () => {
    const snapshot = await sync();
    const cursor = snapshot.body.cursor;

    const first = await sync(`?since=${cursor}`);
    expect(first.body.reset).toBe(false);
    expect(first.body.transitions).toEqual([]);
    expect(first.body.sessions_touched).toEqual([]);
    expect(first.body.has_more).toBe(false);
    expect(first.body.cursor).toBe(cursor);

    // 여러 번 폴링해도 같은 자리다.
    const second = await sync(`?since=${first.body.cursor}`);
    expect(second.body.cursor).toBe(cursor);
    expect(second.body.transitions).toEqual([]);
  });

  // 이 자리에는 "커서보다 앞선 since도 빈 델타 + 그 since를 그대로 돌려준다"는 테스트가 있었다.
  // T21 실패 주입에서 그 동작이 조용한 유실의 원인으로 드러나 규칙을 바꿨다: 아직 없는 전이 id를
  // 커서로 되돌려주면 id > since인 전이가 영원히 생기지 않아 클라이언트가 아무것도 못 받는다.
  // 새 규칙(상한을 넘는 커서는 reset)의 테스트는 아래 "전이 로그의 끝을 넘는 커서" 절에 있다.
});

describe("완료 판정(c): since < pruned_below_id → reset:true", () => {
  it("보존 정리 경계보다 오래된 커서는 스냅샷으로 되돌린다", async () => {
    const boundary = 3;
    await testEnv.DB.prepare("UPDATE dashboard_meta SET value = ? WHERE key = 'pruned_below_id'")
      .bind(String(boundary))
      .run();
    try {
      // 다음에 받을 전이(since + 1)가 정리 경계 아래로 사라진 커서만 reset이다.
      for (const since of [0, boundary - 2]) {
        const { body } = await sync(`?since=${since}&include_ended=1`);
        expect(body.reset).toBe(true);
        expect(body.pruned_below_id).toBe(boundary);
        expect(body.transitions).toEqual([]);
        expect(body.sessions.length).toBe(injectedSessions);
        // reset 커서는 경계 위여야 한다. 아니면 클라이언트가 reset을 무한 반복한다.
        expect(body.cursor).toBeGreaterThanOrEqual(boundary);
      }

      // since = boundary - 1은 "경계 직전까지 이미 봤다"는 뜻이라 놓친 것이 없다 → 델타.
      // (여기서 reset을 주면 전이 로그가 빈 순간 reset이 무한 반복되어 알림이 폭주한다.)
      for (const since of [boundary - 1, boundary]) {
        const ok = await sync(`?since=${since}`);
        expect(ok.body.reset).toBe(false);
        expect(ok.body.transitions.every((t) => t.id > since)).toBe(true);
      }
    } finally {
      await testEnv.DB.prepare("UPDATE dashboard_meta SET value = '0' WHERE key = 'pruned_below_id'").run();
    }
  });

  it("음수·비정수 since도 스냅샷으로 수렴한다", async () => {
    expect((await sync("?since=-1")).body.reset).toBe(true);
    expect((await sync("?since=abc")).body.reset).toBe(true);
  });
});

describe("전이 로그의 끝을 넘는 커서는 스냅샷으로 되돌린다 (T21 실패 주입 회귀)", () => {
  // 손상된 커서 파일이 "전부 숫자인 과대 값"이 되면(notifier의 커서 검사는 비숫자만 걸러낸다)
  // 서버가 그 값을 델타의 커서로 그대로 되돌려 주는 바람에 id > since인 전이가 영원히 생기지
  // 않아 클라이언트가 조용히 아무것도 못 받게 됐다. 상한을 넘는 커서는 reset이어야 한다.
  it("max(id)보다 큰 since는 reset:true + 실제 상한 커서를 준다", async () => {
    const maxId = injectedTransitions;
    const { body } = await sync(`?since=${maxId + 1}&include_ended=1`);

    expect(body.reset).toBe(true);
    expect(body.cursor).toBe(maxId);
    expect(body.sessions.length).toBe(injectedSessions);
    expect(body.transitions).toEqual([]);
  });

  it("터무니없이 큰 커서도 한 번의 재조회로 낫는다(스스로 수렴)", async () => {
    const wedged = await sync("?since=999999999");
    expect(wedged.body.reset).toBe(true);
    // 낫는다 = 되돌려받은 커서로 다시 물으면 정상 델타로 돌아온다.
    const healed = await sync(`?since=${wedged.body.cursor}`);
    expect(healed.body.reset).toBe(false);
    expect(healed.body.cursor).toBe(wedged.body.cursor);
  });

  it("상한과 정확히 같은 커서는 reset이 아니다(경계 off-by-one 방어)", async () => {
    const { body } = await sync(`?since=${injectedTransitions}`);
    expect(body.reset).toBe(false);
    expect(body.transitions).toEqual([]);
    expect(body.cursor).toBe(injectedTransitions);
  });

  it("전이 로그가 통째로 비어도 reset이 무한 반복되지 않는다 (알림 폭주 방어)", async () => {
    // 보존 정리가 전이를 전부 지운 상태를 pruned_below_id로 재현한다: 경계가 max(id)보다 크다.
    // 이때 reset이 주는 커서로 다시 물었을 때 또 reset이 나오면, 클라이언트는 매 폴링마다
    // 스냅샷을 "방금 일어난 일"로 재생해 알림이 폭주한다(T21에서 25초 176건 관측).
    const boundary = injectedTransitions + 1;
    await testEnv.DB.prepare("UPDATE dashboard_meta SET value = ? WHERE key = 'pruned_below_id'")
      .bind(String(boundary))
      .run();
    try {
      const first = await sync();
      expect(first.body.reset).toBe(true);

      // 되돌려받은 커서로 다시 묻는다 = 데몬이 다음 폴링에서 하는 일.
      const second = await sync(`?since=${first.body.cursor}`);
      expect(second.body.reset).toBe(false);
      expect(second.body.cursor).toBe(first.body.cursor);

      // 한 번 더 물어도 여전히 델타여야 한다(수렴).
      const third = await sync(`?since=${second.body.cursor}`);
      expect(third.body.reset).toBe(false);
    } finally {
      await testEnv.DB.prepare("UPDATE dashboard_meta SET value = '0' WHERE key = 'pruned_below_id'").run();
    }
  });
});

describe("완료 판정(d): limit 경계에서 빈 구간·중복 없음", () => {
  it("limit보다 많은 전이를 여러 페이지로 나눠 받아도 id가 빠짐없이 한 번씩만 온다", async () => {
    const all = await testEnv.DB.prepare("SELECT id FROM dashboard_transitions ORDER BY id ASC").all<{ id: number }>();
    const expectedIds = (all.results ?? []).map((r) => r.id);
    expect(expectedIds.length).toBeGreaterThan(3);

    const limit = 3; // 전이 수보다 확실히 작다 = 최소 2페이지
    const collected: number[] = [];
    let cursor = 0;
    let pages = 0;
    for (;;) {
      const { body } = await sync(`?since=${cursor}&limit=${limit}`);
      expect(body.reset).toBe(false);
      expect(body.transitions.length).toBeLessThanOrEqual(limit);
      // 페이지 안은 id 오름차순이고, 모든 id가 직전 커서보다 크다(빈 구간·역행 없음).
      for (const t of body.transitions) expect(t.id).toBeGreaterThan(cursor);
      const ids = body.transitions.map((t) => t.id);
      expect([...ids].sort((a, b) => a - b)).toEqual(ids);

      collected.push(...ids);
      cursor = body.cursor;
      pages += 1;

      // has_more는 "limit에 걸려 잘렸다"와 정확히 같은 뜻이어야 한다.
      if (!body.has_more) {
        expect(body.transitions.length).toBeLessThanOrEqual(limit);
        break;
      }
      expect(body.transitions.length).toBe(limit);
      expect(pages).toBeLessThan(50);
    }

    expect(pages).toBeGreaterThan(1); // 진짜로 2페이지 이상 돌았다
    expect(collected).toEqual(expectedIds); // 순서·개수 그대로 = 중복 0, 누락 0
    expect(new Set(collected).size).toBe(collected.length);
    expect(cursor).toBe(expectedIds[expectedIds.length - 1]);
  });

  it("sessions_touched는 그 페이지가 건드린 session_key를 중복 없이 등장 순서로 준다", async () => {
    const { body } = await sync("?since=0&limit=5");
    const keysInOrder: string[] = [];
    for (const t of body.transitions) if (!keysInOrder.includes(t.session_key)) keysInOrder.push(t.session_key);
    expect(body.sessions_touched).toEqual(keysInOrder);
    expect(new Set(body.sessions_touched).size).toBe(body.sessions_touched.length);
  });
});

describe("완료 판정(e): 커서 역행 없음", () => {
  it("스냅샷 → 델타 → 새 전이 → 델타를 이어 달려도 커서는 단조 증가한다", async () => {
    const cursors: number[] = [];

    const snapshot = await sync("?include_ended=1");
    cursors.push(snapshot.body.cursor);

    // 따라잡은 상태에서 폴링 (커서 유지)
    let cursor = snapshot.body.cursor;
    for (let i = 0; i < 3; i += 1) {
      const { body } = await sync(`?since=${cursor}`);
      cursor = body.cursor;
      cursors.push(cursor);
    }

    // 새 전이를 만들고 다시 폴링 (커서 증가)
    await ingest({ source: "claude-code", sessionId: "cursor-monotonic", event: "SessionStart", state: "idle" });
    await ingest({ source: "claude-code", sessionId: "cursor-monotonic", event: "UserPromptSubmit", state: "working" });

    const afterIngest = await sync(`?since=${cursor}`);
    expect(afterIngest.body.transitions.length).toBe(2);
    expect(afterIngest.body.sessions_touched).toEqual(["claude-code:cursor-monotonic"]);
    cursor = afterIngest.body.cursor;
    cursors.push(cursor);

    // 작은 limit으로 다시 처음부터 훑어도 각 페이지의 커서는 증가만 한다
    let paging = 0;
    for (let i = 0; i < 4; i += 1) {
      const { body } = await sync(`?since=${paging}&limit=2`);
      expect(body.cursor).toBeGreaterThanOrEqual(paging);
      paging = body.cursor;
    }

    // 스냅샷을 한 번 더 받아도 커서는 뒤로 가지 않는다
    const resnapshot = await sync();
    cursors.push(resnapshot.body.cursor);

    for (let i = 1; i < cursors.length; i += 1) {
      expect(cursors[i]).toBeGreaterThanOrEqual(cursors[i - 1]!);
    }
    expect(cursors[cursors.length - 1]).toBeGreaterThan(cursors[0]!);
  });
});

describe("응답 필드가 서버 설정을 그대로 알려준다", () => {
  it("mute_until은 미래일 때만 숫자로 나오고 지난 시각은 null이다", async () => {
    const future = Date.now() + 60_000;
    await testEnv.DB.prepare("UPDATE dashboard_settings SET value = ? WHERE key = 'mute_until'")
      .bind(String(future))
      .run();
    try {
      expect((await sync()).body.mute_until).toBe(future);

      await testEnv.DB.prepare("UPDATE dashboard_settings SET value = ? WHERE key = 'mute_until'")
        .bind(String(Date.now() - 60_000))
        .run();
      expect((await sync()).body.mute_until).toBeNull();
    } finally {
      await testEnv.DB.prepare("UPDATE dashboard_settings SET value = '0' WHERE key = 'mute_until'").run();
    }
  });

  it("스냅샷 세션은 정본 sync.session_object의 필드를 갖추고 stale을 계산해 준다", async () => {
    const { body } = await sync("?include_ended=1");
    const session = body.sessions[0]!;
    for (const field of [
      "key",
      "source",
      "session_id",
      "project",
      "host",
      "state",
      "last_event",
      "last_message",
      "last_occurred_at",
      "last_transition_id",
      "created_at",
      "updated_at",
      "stale",
    ]) {
      expect(session).toHaveProperty(field);
    }
    // 읽음 단일 표현(같은 사실의 복수 표현 금지): seen_transition_id는 더 이상 session_object에
    // 없다 - 응답 최상위 seen 배열(sync.seen_object)로 옮겨갔다. 아래
    // "응답 최상위 seen 배열" describe 참고.
    for (const s of body.sessions) {
      expect(s).not.toHaveProperty("seen_transition_id");
    }
    // ingest()의 시계는 2026-09-08이라 실제 now 기준으로는 전부 오래됐다.
    // ended 세션은 stale로 치지 않는다(legacy GET /dashboard/sessions와 같은 규칙).
    for (const s of body.sessions) {
      expect(s.stale).toBe(s.state !== "ended");
    }
  });
});

/**
 * settings.ui_lang이 sync 응답에 편승하는 방식(정본: sync.response.fields.ui_lang) 완료 판정.
 * mute_until과 같은 "절대값 서버 상태"로 무조건 대입된다 - seen처럼 MAX 병합하지 않는다.
 * 이 describe는 dashboard_settings.ui_lang 행을 직접 썼다 지운다 - 다른 describe들이 mute_until을
 * 그렇게 다루는 것과 같은 방식이고, 끝에 원상복구해 이후 테스트에 영향을 주지 않는다.
 */
describe("응답 필드 ui_lang (settings.ui_lang 편승 — mute_until과 같은 절대값, MAX 병합 아님)", () => {
  async function writeUiLangRaw(value: string | null): Promise<void> {
    await testEnv.DB.prepare(
      `INSERT INTO dashboard_settings (key, value) VALUES ('ui_lang', ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
    )
      .bind(value)
      .run();
  }

  afterAll(async () => {
    await testEnv.DB.prepare("DELETE FROM dashboard_settings WHERE key = 'ui_lang'").run();
  });

  it("행 자체가 없으면(한 번도 설정한 적 없음) ui_lang은 null이다", async () => {
    await testEnv.DB.prepare("DELETE FROM dashboard_settings WHERE key = 'ui_lang'").run();
    const { body } = await sync();
    expect(body.ui_lang).toBeNull();
  });

  it("ko/en/null 세 값 모두 그대로 동봉된다(무조건 대입) — null로 되돌리는 것도 정상 값이다", async () => {
    await writeUiLangRaw("ko");
    expect((await sync()).body.ui_lang).toBe("ko");

    await writeUiLangRaw("en");
    expect((await sync()).body.ui_lang).toBe("en");

    // LWW: 마지막 쓰기만 반영된다 — 단조 가드·병합 없음.
    await writeUiLangRaw(null);
    expect((await sync()).body.ui_lang).toBeNull();
  });

  it("손상된 값(ko/en/null이 아닌 문자열)은 null로 취급한다", async () => {
    await writeUiLangRaw("fr");
    expect((await sync()).body.ui_lang).toBeNull();
  });

  it("스냅샷·델타 두 응답 모두 ui_lang을 동봉한다(reset 여부와 무관, mute_until과 같은 선례)", async () => {
    await writeUiLangRaw("en");
    const snapshot = await sync();
    expect(snapshot.body.reset).toBe(true);
    expect(snapshot.body.ui_lang).toBe("en");

    const delta = await sync(`?since=${snapshot.body.cursor}`);
    expect(delta.body.reset).toBe(false);
    expect(delta.body.ui_lang).toBe("en");
  });

  it("readHeader의 dashboard_settings batch 문장 수는 여전히 3이다(ui_lang 편승이 왕복을 늘리지 않는다)", async () => {
    await writeUiLangRaw("ko");

    const batchSizes: number[] = [];
    const spyDB = new Proxy(testEnv.DB, {
      get(target, prop, _receiver) {
        const value = Reflect.get(target as object, prop as PropertyKey, target);
        if (prop === "batch" && typeof value === "function") {
          return (...args: unknown[]) => {
            const stmts = args[0];
            batchSizes.push(Array.isArray(stmts) ? stmts.length : -1);
            return (value as (...callArgs: unknown[]) => unknown).apply(target, args);
          };
        }
        return typeof value === "function" ? (value as (...callArgs: unknown[]) => unknown).bind(target) : value;
      },
    }) as unknown as D1Database;

    const spyEnv = { ...(env as unknown as SyncEnv), DB: spyDB };
    const body = await buildSync(spyEnv, { since: null, limit: DEFAULT_LIMIT, includeEnded: false }, Date.now());

    expect(batchSizes).toEqual([3]);
    expect(body.ui_lang).toBe("ko");
  });
});

describe("응답 최상위 seen 배열 (읽음 단일 표현 — mute_until과 같은 절대값 서버 상태)", () => {
  // 이 파일의 다른 세션은 전부 lifecycleChain이 terminal(ended)까지 가므로 기본 스냅샷(비-ended)
  // 에는 하나도 남지 않는다 - seen 배열의 범위·값 검증에는 최소 하나의 비-ended 세션이 필요하므로
  // 별도로 주입한다(다른 describe의 세션들과 이름이 겹치지 않게 전용 sessionId를 쓴다).
  const probeSessionId = "sync-seen-scope-probe";
  const probeSource = "claude-code";
  const probeKey = `${probeSource}:${probeSessionId}`;

  beforeAll(async () => {
    await ingest({ source: probeSource, sessionId: probeSessionId, event: "UserPromptSubmit", state: "working" });
  });

  it("스냅샷·델타 두 응답 모두 seen 배열을 절대값으로 동봉한다 — 원소 모양은 {key, seen_transition_id}", async () => {
    const snapshot = await sync();
    expect(Array.isArray(snapshot.body.seen)).toBe(true);
    expect(snapshot.body.seen.length).toBeGreaterThan(0);
    for (const row of snapshot.body.seen) {
      expect(typeof row.key).toBe("string");
      expect(row).toHaveProperty("seen_transition_id");
      expect(typeof row.seen_transition_id === "number" || row.seen_transition_id === null).toBe(true);
    }

    // 델타 응답(reset:false)에도 스냅샷과 똑같은 절대값 seen 배열이 실린다 - sessions/transitions와
    // 달리 reset 여부에 따라 한쪽만 채워지는 필드가 아니다(mute_until과 같은 선례).
    const delta = await sync(`?since=${snapshot.body.cursor}`);
    expect(delta.body.reset).toBe(false);
    expect(Array.isArray(delta.body.seen)).toBe(true);
    expect(delta.body.seen).toEqual(snapshot.body.seen);
  });

  it("범위는 스냅샷의 비-ended 세션과 동일하다 — include_ended=1을 줘도 ended 세션은 seen에 들어오지 않는다", async () => {
    const withEnded = await sync("?include_ended=1");
    const withoutEnded = await sync();
    // 두 호출의 seen 배열은 include_ended 쿼리와 무관하게 항상 같다(비-ended 세션 범위 고정).
    expect(withEnded.body.seen).toEqual(withoutEnded.body.seen);

    const endedKeys = new Set(
      withEnded.body.sessions.filter((s) => s.state === "ended").map((s) => s.key),
    );
    expect(endedKeys.size).toBeGreaterThan(0); // 이 파일의 lifecycleChain은 terminal까지 간다 - ended 세션이 실제로 존재한다.
    const seenKeys = new Set(withEnded.body.seen.map((r) => r.key));
    for (const key of endedKeys) {
      expect(seenKeys.has(key)).toBe(false);
    }

    // 반대로 비-ended 세션은 (한 번도 seen을 부른 적 없어도 null로) 전부 seen 배열에 있다 -
    // "범위는 스냅샷과 동일"이 요구하는 세션 키 집합 자체는 LEFT JOIN이라 빠지지 않는다.
    const nonEndedKeys = withoutEnded.body.sessions.map((s) => s.key);
    for (const key of nonEndedKeys) {
      expect(seenKeys.has(key)).toBe(true);
    }
  });

  it("dashboard_seen에 실제로 적힌 값을 정확히 반영하고, 마킹 후에는 스냅샷·델타 양쪽에 곧바로 절대값으로 나타난다(멱등)", async () => {
    const before = await sync();
    const target = before.body.sessions.find((s) => s.key === probeKey);
    expect(target).toBeTruthy();
    const key = target!.key;
    // 이 파일의 ingest()는 정본 프로젝션 규칙만 최소 재현한 픽스처라 dashboard_sessions.
    // last_transition_id 컬럼 자체를 채우지 않는다(파일 헤더 주석 참고) - 실제 마킹 대상 전이
    // id는 dashboard_transitions에서 이 세션의 마지막 행을 직접 읽는다.
    const lastTransition = await testEnv.DB.prepare(
      "SELECT id FROM dashboard_transitions WHERE session_key = ? ORDER BY id DESC LIMIT 1",
    )
      .bind(key)
      .first<{ id: number }>();
    expect(lastTransition).toBeTruthy();
    const markAt = lastTransition!.id;

    await testEnv.DB.prepare(
      `INSERT INTO dashboard_seen (session_key, seen_transition_id) VALUES (?, ?)
         ON CONFLICT(session_key) DO UPDATE SET seen_transition_id = excluded.seen_transition_id`,
    )
      .bind(key, markAt)
      .run();

    // 같은 서버 상태를 두 번 물어도(스냅샷, 델타) 똑같은 값이 절대값으로 나온다 - 서버는 매
    // 응답마다 dashboard_seen을 다시 읽어 그대로 실어 보낼 뿐이라 반복 호출이 값을 바꾸지
    // 않는다(멱등). 이 성질이 있어야 클라이언트의 MAX 병합(낙관 갱신 직후 비행 중이던 옛 응답이
    // 와도 로컬 값을 되돌리지 않는다)이 안전하다 - 서버가 매번 다른 부분 값을 보내면 클라이언트
    // MAX 병합으로도 정합을 보장할 수 없다.
    const snapshot1 = await sync();
    const snapshot2 = await sync();
    const row1 = snapshot1.body.seen.find((r) => r.key === key);
    const row2 = snapshot2.body.seen.find((r) => r.key === key);
    expect(row1?.seen_transition_id).toBe(markAt);
    expect(row2?.seen_transition_id).toBe(markAt);

    const delta = await sync(`?since=${snapshot1.body.cursor}`);
    const rowDelta = delta.body.seen.find((r) => r.key === key);
    expect(rowDelta?.seen_transition_id).toBe(markAt);
  });
});

describe("응답 최상위 hook_skew 배열 (훅 구버전 배너 — mute_until과 같은 절대값 서버 상태, seen과 달리 MAX-merge 아님)", () => {
  // sync.ts는 dashboard_meta.hook_revs를 읽어 서버의 현재 HOOK_REV(hooks/routes.ts, 위에서
  // import)와 비교한다 - 배포 하나에 대해 상수라 이 파일에서도 같은 값을 그대로 쓸 수 있다.
  // project는 옵셔널로 둔다 - 생략하면(기존 원장 형태) buildSync의 `entry.project ?? null`
  // 정규화를 그대로 테스트하는 셈이다.
  async function writeHookRevs(
    entries: Record<string, { rev: string | null; at: number; project?: string | null }>,
  ): Promise<void> {
    await testEnv.DB.prepare(
      `INSERT INTO dashboard_meta (key, value) VALUES ('hook_revs', ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
    )
      .bind(JSON.stringify(entries))
      .run();
  }

  it("서버의 현재 rev와 일치하는 호스트는 배열에서 빠진다", async () => {
    await writeHookRevs({ "up-to-date-host": { rev: HOOK_REV, at: Date.now() } });
    const { body } = await sync();
    expect(body.hook_skew.find((r) => r.host === "up-to-date-host")).toBeUndefined();
  });

  it("서버의 현재 rev와 다른(구버전) 호스트는 {host, rev, project} 그대로 배열에 실린다(project 없으면 null)", async () => {
    await writeHookRevs({ "stale-host": { rev: "deadbeef", at: Date.now() } });
    const { body } = await sync();
    expect(body.hook_skew).toContainEqual({ host: "stale-host", rev: "deadbeef", project: null });
  });

  it("rev를 한 번도 보고한 적 없는(null) 호스트도 '서버와 다르다'로 취급해 배열에 실린다", async () => {
    await writeHookRevs({ "unreported-host": { rev: null, at: Date.now() } });
    const { body } = await sync();
    expect(body.hook_skew).toContainEqual({ host: "unreported-host", rev: null, project: null });
  });

  it("원장에 project가 실려 있으면 hook_skew 항목에 그대로 additive 동봉된다(devcontainer 등 host만으론 식별 불가한 환경 배너용)", async () => {
    await writeHookRevs({ "devcontainer-host": { rev: "deadbeef", at: Date.now(), project: "/workspaces/my-dashboard" } });
    const { body } = await sync();
    expect(body.hook_skew).toContainEqual({
      host: "devcontainer-host",
      rev: "deadbeef",
      project: "/workspaces/my-dashboard",
    });
  });

  it("여러 호스트가 섞여 있으면 구버전·미보고 호스트만 남고 최신 호스트는 제외된다", async () => {
    await writeHookRevs({
      current: { rev: HOOK_REV, at: Date.now() },
      old: { rev: "11111111", at: Date.now() },
      unknown: { rev: null, at: Date.now() },
    });
    const { body } = await sync();
    const hosts = body.hook_skew.map((r) => r.host);
    expect(hosts).not.toContain("current");
    expect(hosts).toContain("old");
    expect(hosts).toContain("unknown");
  });

  it("스냅샷·델타 두 응답 모두 hook_skew를 절대값으로 동봉한다(reset 여부와 무관)", async () => {
    await writeHookRevs({ "absolute-host": { rev: "cafebabe", at: Date.now() } });
    const snapshot = await sync();
    expect(snapshot.body.hook_skew).toContainEqual({ host: "absolute-host", rev: "cafebabe", project: null });

    const delta = await sync(`?since=${snapshot.body.cursor}`);
    expect(delta.body.reset).toBe(false);
    expect(delta.body.hook_skew).toEqual(snapshot.body.hook_skew);
  });

  it("hook_revs 원장이 아예 없으면 빈 배열이다", async () => {
    await testEnv.DB.prepare("DELETE FROM dashboard_meta WHERE key = 'hook_revs'").run();
    const { body } = await sync();
    expect(body.hook_skew).toEqual([]);
  });
});
