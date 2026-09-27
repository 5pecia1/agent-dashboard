import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { HOOK_REV } from "../src/hooks/routes";
import { authHeaders, eventPayload } from "./fixtures";

// POST /dashboard/events(routes.ts 4.5단계)가 갱신하는 dashboard_meta.hook_revs 원장의
// UPSERT 가드 분기 전부를 실제 요청으로 태워 검증한다. sync.test.ts는 이 원장을 "읽는" 쪽
// (hook_skew)만 보고, maintenance.test.ts는 "지우는" 쪽(만료)만 본다 - 이 파일은 "쓰는" 쪽
// (?4 현재rev 무조건수용/단조가드/값불변시무갱신/24시간갱신/NULL처리/host없음·occurred_at
// 미명시 스킵/project 동봉)만 전담한다.
//
// 테스트 위생(팀 리드 실측 지적): 이 가드는 "?3 - 86400000"(24시간 전 절대 시각)을 내장한
// 절대 시각 비교다 - occurred_at으로 실제 epoch ms가 아니라 1000, 5000 같은 작은 값을 쓰면
// 그 값이 86400000보다 작아 "?3 - 86400000"이 음수가 되고, "COALESCE(at,0) < 음수"가 항상
// 거짓이 되어 원래는 참이어야 할 조건이 거짓 차단으로 둔갑한다(신규 host의 첫 NULL 신고를
// "영원히 기록 안 됨"으로 오진했던 사고가 실제로 이래서 났다 - 아래 REALISTIC_BASE 참고).
// 24시간 경계를 실제로 넘나드는 시나리오는 반드시 현실적 epoch ms를 기준으로 삼아야 한다.
const REALISTIC_BASE = Date.UTC(2026, 8, 11, 0, 0, 0); // 2026-09-11 - "오늘"(테스트 실행 시점)과 같은 자릿수의 진짜 epoch ms.
interface MainExport {
  fetch(request: Request, env: unknown, ctx: ExecutionContext): Response | Promise<Response>;
}
const app = (exports as unknown as { default: MainExport }).default;

interface TestEnv {
  DB: D1Database;
}
const testEnv = env as unknown as TestEnv;

async function postEvent(body: Record<string, unknown>): Promise<{ status: number; json: Record<string, unknown> }> {
  const ctx = createExecutionContext();
  const request = new Request("http://dashboard.test/dashboard/events", {
    method: "POST",
    headers: { "content-type": "application/json", ...authHeaders() },
    body: JSON.stringify(body),
  });
  const response = await app.fetch(request, env, ctx);
  await waitOnExecutionContext(ctx);
  return { status: response.status, json: (await response.json()) as Record<string, unknown> };
}

interface HookRevEntry {
  rev: string | null;
  at: number;
  project: string | null;
}

async function readHookRevs(): Promise<Record<string, HookRevEntry>> {
  const row = await testEnv.DB.prepare("SELECT value FROM dashboard_meta WHERE key = 'hook_revs'").first<{
    value: string | null;
  }>();
  return row?.value ? (JSON.parse(row.value) as Record<string, HookRevEntry>) : {};
}

/**
 * 가드 분기를 개별적으로 골라 태우려면 "이전 상태"를 정확히 통제해야 한다 - HTTP 왕복으로
 * 선행 이벤트를 하나씩 보내 만드는 대신, 원장을 원하는 상태로 직접 심어 둔다(merge, 기존
 * host 키는 보존). maintenance.test.ts·sync.test.ts의 writeHookRevs와 같은 패턴이다.
 */
async function seedHookRevs(entries: Record<string, HookRevEntry>): Promise<void> {
  const current = await readHookRevs();
  await testEnv.DB.prepare(
    `INSERT INTO dashboard_meta (key, value) VALUES ('hook_revs', ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
  )
    .bind(JSON.stringify({ ...current, ...entries }))
    .run();
}

// 서버의 실제 HOOK_REV와 절대 같을 수 없는(=늘 "구버전 rev" 취급되는) 두 값. ?4(현재 rev
// 무조건 수용) 분기를 타지 않아야 하는 테스트는 이 값들을 쓴다.
const OLD_REV_A = HOOK_REV === "aaaaaaaa" ? "bbbbbbbb" : "aaaaaaaa";
const OLD_REV_B = HOOK_REV === "cccccccc" ? "dddddddd" : "cccccccc";

let seq = 0;
/** host/session_id/event_id를 매번 새로 발급해 테스트끼리 dashboard_events 멱등(event_id 유니크)에 걸리지 않게 한다. */
function nextIds(): { host: string; sessionId: string } {
  seq += 1;
  return { host: `hook-revs-host-${seq}`, sessionId: `hook-revs-session-${seq}` };
}

/** host/session_id는 호출자가 nextIds()로 직접 채운다 - 여기서는 event_id 기본값만 보탠다. */
function payload(overrides: Record<string, unknown>): Record<string, unknown> {
  return eventPayload({
    event_id: crypto.randomUUID(),
    ...overrides,
  });
}

describe("POST /dashboard/events — dashboard_meta.hook_revs 원장 쓰기 가드(훅 구버전 배너)", () => {
  it("?4: 보고된 rev가 서버의 현재 HOOK_REV와 같으면 occurred_at이 거꾸로 가도(단조 가드 예외) 무조건 수용한다", async () => {
    const { host, sessionId } = nextIds();
    // 기존 at(10000)보다 훨씬 과거인 occurred_at(1000)으로 보고해도 - "지금 막 서버에게서
    // 이 rev를 받아왔다"는 사실 자체가 최신성의 증거이므로 무조건 덮어써야 한다. project도
    // 같은 WHERE 절 아래 함께 실리므로 이 분기에서는 project도 무조건 갱신된다.
    await seedHookRevs({ [host]: { rev: OLD_REV_A, at: 10_000, project: "/proj/old" } });
    await postEvent(
      payload({ session_id: sessionId, host, hook_rev: HOOK_REV, occurred_at: 1_000, project: "/proj/new" }),
    );
    expect((await readHookRevs())[host]).toEqual({ rev: HOOK_REV, at: 1_000, project: "/proj/new" });
  });

  it("단조 가드: 구버전 rev를 보고할 때 occurred_at이 기존 at보다 과거로 가면 막힌다(원장 유지, project도 유지)", async () => {
    const { host, sessionId } = nextIds();
    await seedHookRevs({ [host]: { rev: OLD_REV_A, at: 5_000, project: "/proj/old" } });
    await postEvent(
      payload({ session_id: sessionId, host, hook_rev: OLD_REV_B, occurred_at: 1_000, project: "/proj/new" }),
    );
    // at(5000) <= occurred_at(1000)이 거짓이라 WHERE 전체가 거짓 - 원장은 project까지 그대로다.
    expect((await readHookRevs())[host]).toEqual({ rev: OLD_REV_A, at: 5_000, project: "/proj/old" });
  });

  it("값 불변: 같은 rev + 최근 at이면 다시 쓰지 않는다(at·project 둘 다 그대로) — rev 불변 시 project 미갱신", async () => {
    const { host, sessionId } = nextIds();
    await seedHookRevs({ [host]: { rev: OLD_REV_A, at: 5_000, project: "/proj/old" } });
    // project는 바뀌어 보고됐지만, WHERE 가드는 project를 전혀 보지 않는다(rev·at만 본다) -
    // rev가 그대로이고 at(5000)이 24시간 이내라 마지막 절이 거짓이라 WHERE 전체가 거짓 -
    // json_set 자체가 실행되지 않으므로 project를 포함해 행 전체가 그대로 남는다.
    await postEvent(
      payload({ session_id: sessionId, host, hook_rev: OLD_REV_A, occurred_at: 6_000, project: "/proj/new" }),
    );
    expect((await readHookRevs())[host]).toEqual({ rev: OLD_REV_A, at: 5_000, project: "/proj/old" });
  });

  it("24시간 갱신: rev는 그대로여도 at이 24시간 넘게 오래되면 최신 유지 차원에서 다시 쓴다(이때는 project도 함께 갱신)", async () => {
    const { host, sessionId } = nextIds();
    const DAY_MS = 86_400_000;
    await seedHookRevs({ [host]: { rev: OLD_REV_A, at: 1_000, project: "/proj/old" } });
    const laterAt = 1_000 + DAY_MS + 1;
    await postEvent(
      payload({ session_id: sessionId, host, hook_rev: OLD_REV_A, occurred_at: laterAt, project: "/proj/new" }),
    );
    // rev는 같지만 at(1000)이 (laterAt - 86400000 = 1001)보다 작아 마지막 절의 두 번째
    // 조건이 참 - WHERE 전체가 참이 되어 이번엔 json_set이 실행되고, project도 rev·at과
    // 함께 새 값으로 갱신된다(project 단독으로는 가드를 못 뚫지만, 가드가 뚫리면 묻어간다).
    expect((await readHookRevs())[host]).toEqual({ rev: OLD_REV_A, at: laterAt, project: "/proj/new" });
  });

  it("NULL 불변: 기존 rev가 이미 NULL이면 hook_rev 미보고를 다시 받아도 재기록하지 않는다(project도 그대로)", async () => {
    const { host, sessionId } = nextIds();
    await seedHookRevs({ [host]: { rev: null, at: 1_000, project: "/proj/old" } });
    const body = payload({ session_id: sessionId, host, occurred_at: 2_000, project: "/proj/new" });
    delete body.hook_rev;
    await postEvent(body);
    // 저장된 rev(NULL) IS NOT 보고된 rev(NULL) => false(IS NOT은 NULL끼리를 "같다"로 본다) -
    // != 였다면 NULL != NULL은 항상 UNKNOWN이라 이 분기가 의도와 다르게(늘 갱신) 동작했을
    // 것이다 - 진짜로 IS NOT을 써야 하는 이유가 이 케이스다. at(1000)도 24시간 이내라
    // 마지막 절도 거짓 - project를 포함해 그대로 남는다.
    expect((await readHookRevs())[host]).toEqual({ rev: null, at: 1_000, project: "/proj/old" });
  });

  it("hook_rev가 NULL에서 실제 값으로 바뀌면(값 변화) 그 즉시 반영된다(project도 함께)", async () => {
    const { host, sessionId } = nextIds();
    await seedHookRevs({ [host]: { rev: null, at: 1_000, project: "/proj/old" } });
    await postEvent(
      payload({ session_id: sessionId, host, hook_rev: OLD_REV_A, occurred_at: 2_000, project: "/proj/new" }),
    );
    // 저장된 NULL IS NOT 'aaaaaaaa' => true(값이 바뀌었다) - 갱신되고, project도 함께 새 값이 된다.
    expect((await readHookRevs())[host]).toEqual({ rev: OLD_REV_A, at: 2_000, project: "/proj/new" });
  });

  it("신규 host 첫 NULL 신고: 원장(hook_revs 행 자체)이 이미 다른 host로 존재해도 새 host는 project와 함께 정상적으로 첫 기록이 된다", async () => {
    // json_extract는 존재하지 않는 JSON 키에도 SQL NULL을 돌려주므로, 신규 host 입장에서는
    // COALESCE(...at,0)=0이 된다. 현실적 epoch ms(REALISTIC_BASE)를 쓰면
    // "0 <= occurred_at"과 "0 < occurred_at - 86400000"이 둘 다 참이 되어(occurred_at이
    // 86400000보다 훨씬 크므로) WHERE 전체가 참 - 정상적으로 첫 기록이 이뤄진다. (작은
    // 타임스탬프를 쓰면 두 번째 항이 거짓으로 뒤집혀 거짓 차단이 나는데, 그게 바로 위
    // 테스트 위생 코멘트가 경고하는 사고다.) INSERT 분기의 json_object에도 project(?5)가
    // 같이 들어가므로 신규 host의 첫 기록에도 project가 실린다.
    await seedHookRevs({ "hook-revs-other-host": { rev: OLD_REV_A, at: REALISTIC_BASE, project: "/proj/other" } });
    const { host, sessionId } = nextIds();
    const body = payload({ session_id: sessionId, host, occurred_at: REALISTIC_BASE, project: "/proj/new-host" });
    delete body.hook_rev;
    await postEvent(body);
    expect((await readHookRevs())[host]).toEqual({ rev: null, at: REALISTIC_BASE, project: "/proj/new-host" });
  });

  it("같은 host가 24시간 이내에 NULL을 재신고하면 값 불변이라 재기록하지 않는다(at·project 둘 다 그대로) — 기능 손실 없음", async () => {
    const { host, sessionId } = nextIds();
    await seedHookRevs({ [host]: { rev: null, at: REALISTIC_BASE, project: "/proj/old" } });
    const body = payload({ session_id: sessionId, host, occurred_at: REALISTIC_BASE + 1_000, project: "/proj/new" });
    delete body.hook_rev;
    await postEvent(body);
    // 이미 null로 등재돼 있으므로(hook_skew는 이 값을 그대로 "서버와 다르다"로 잡는다)
    // 24시간 이내 재신고를 무시해도 배너 기능에는 손실이 없다 - "값 변경 시에만 쓴다"는
    // 의도된 절약이지 결함이 아니다. project도 같은 WHERE 절 아래라 함께 무시된다.
    expect((await readHookRevs())[host]).toEqual({ rev: null, at: REALISTIC_BASE, project: "/proj/old" });
  });

  it("24시간 경과 후 같은 host가 NULL을 재신고하면 값은 그대로여도 at·project는 최신화된다", async () => {
    const { host, sessionId } = nextIds();
    const DAY_MS = 86_400_000;
    await seedHookRevs({ [host]: { rev: null, at: REALISTIC_BASE, project: "/proj/old" } });
    const laterAt = REALISTIC_BASE + DAY_MS + 1;
    const body = payload({ session_id: sessionId, host, occurred_at: laterAt, project: "/proj/new" });
    delete body.hook_rev;
    await postEvent(body);
    expect((await readHookRevs())[host]).toEqual({ rev: null, at: laterAt, project: "/proj/new" });
  });

  it("project가 빈 문자열이면(cwd를 모르는 실행 환경) SQL NULL로 저장된다", async () => {
    // routes.ts 4.5단계의 hookProject = project ? project : null - event_payload.fields.project는
    // 빈 문자열을 허용하는 필드(cwd를 모르는 실행 환경)이지 옵셔널이 아니라서, "없음"을
    // "빈 문자열"로 신고하는 경우를 여기서 SQL NULL로 정규화해 둔다.
    const { host, sessionId } = nextIds();
    await postEvent(payload({ session_id: sessionId, host, hook_rev: HOOK_REV, occurred_at: REALISTIC_BASE, project: "" }));
    expect((await readHookRevs())[host]).toEqual({ rev: HOOK_REV, at: REALISTIC_BASE, project: null });
  });

  it("host가 없으면(null) 원장에 전혀 손대지 않는다", async () => {
    const before = await readHookRevs();
    const { sessionId } = nextIds();
    await postEvent(payload({ session_id: sessionId, host: null, hook_rev: OLD_REV_A, occurred_at: 1_000 }));
    expect(await readHookRevs()).toEqual(before);
  });

  it("occurred_at이 명시되지 않으면(서버가 now로 대체) 원장에 전혀 손대지 않는다", async () => {
    const before = await readHookRevs();
    const { host, sessionId } = nextIds();
    const body = payload({ session_id: sessionId, host, hook_rev: OLD_REV_A });
    delete body.occurred_at;
    await postEvent(body);
    expect(await readHookRevs()).toEqual(before);
  });
});
