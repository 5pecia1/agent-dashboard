import { Hono } from "hono";
import type { Env } from "../env";
import { HOOK_REV } from "../hooks/routes";
import { RESERVED_CLIENT_ACTION_EVENTS, resolveUserAckTransition } from "./client-actions";
import { readDevinCorrelation, resolveDevinInput } from "./devin-input";
import { dispatchPush, type DispatchEnv, type PushTransition } from "./dispatch";
import { resolveHeartbeatPromotion } from "./heartbeat";
import { parseHistoryQuery, readHistory, type HistoryQuery } from "./history";
import { pushRoutes } from "./push";
import { markSeenAtLeast, resolveSeenTarget } from "./seen";
import { adapterFor } from "./sources";
import { prepareTransition } from "./transitions";
import { ACCEPTED_PROTOCOL_VERSIONS, PUSH_STATES, REVIVAL_EVENT, STALE_MS, type SessionState } from "./state";

export const dashboard = new Hono<{ Bindings: Env }>();

/** protocol.v1.json event_payload.fields.raw.max_bytes_stored. 수신 본문 원본 보존 상한. */
const RAW_MAX_BYTES = 4096;
/** event_payload.fields.message.max_length_stored. */
const MESSAGE_MAX_CHARS = 300;
/** event_payload.fields.session_id.max_length / event_id.max_length. */
const ID_MAX_CHARS = 200;

/**
 * UTF-8 바이트 기준으로 자른다(문자 수가 아니라 바이트 수가 상한이라서).
 * 경계에서 잘린 부분 문자는 디코딩 때 U+FFFD가 되므로 결과 문자열은 늘 유효한 UTF-8이다.
 */
function truncateBytes(text: string, maxBytes: number): string {
  const bytes = new TextEncoder().encode(text);
  if (bytes.length <= maxBytes) return text;
  return new TextDecoder().decode(bytes.slice(0, maxBytes));
}

/**
 * Default ingestion retains only fields needed to replay status and correlation.
 * The envelope is never truncated into invalid JSON: oversized normalized metadata is rejected.
 * Arbitrary raw, tool input/output, and unknown properties are never copied in this mode.
 */
const REPLAY_MAX_BYTES = 16384;

/** dashboard_events 한 줄. raw까지 포함해 "받은 그대로"를 남긴다. */
interface EventRow {
  session_key: string;
  source: string;
  event: string;
  message: string | null;
  event_id: string | null;
  occurred_at: number;
  /**
   * occurred_at이 요청 본문에 숫자로 "명시적으로" 있었는가(B 가드3, heartbeat.ts).
   * rebuild.ts가 이 컬럼을 그대로 읽는다 - raw는 RAW_MAX_BYTES로 잘려 저장되므로 재생
   * 시점에 raw를 다시 파싱해 복원하면 큰 페이로드(특히 PostToolUse)에서 항상 실패한다
   * (0003_dashboard_v3.sql 참고). 여기서 원본 진실을 직접 컬럼에 남겨 그 문제를 없앤다.
   */
  occurred_at_provided: boolean;
  host: string | null;
  raw: string;
  prompt_id: string | null;
  tool_use_id: string | null;
  tool_name: string | null;
}

/**
 * append-only 이벤트 로그에 한 줄 넣고 그 id를 돌려준다.
 * 같은 event_id가 이미 있으면 아무것도 넣지 않고 null을 돌려준다(멱등).
 *
 * 조회 후 삽입이 아니라 부분 유니크 인덱스(idx_dashboard_events_event_id)에 기대는
 * 단일 문장이다. 스풀 재전송이 같은 event_id를 동시에 두 번 밀어도 한 줄만 남는다.
 * event_id가 없는 요청은 인덱스 대상이 아니라 늘 새 줄이 된다.
 */
async function insertEvent(db: D1Database, row: EventRow, now: number): Promise<number | null> {
  const inserted = await db
    .prepare(
      `INSERT INTO dashboard_events
         (session_key, source, event, message, received_at, event_id, occurred_at, occurred_at_provided, host, raw, prompt_id, tool_use_id, tool_name)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(event_id) WHERE event_id IS NOT NULL DO NOTHING
       RETURNING id`,
    )
    .bind(
      row.session_key,
      row.source,
      row.event,
      row.message,
      now,
      row.event_id,
      row.occurred_at,
      row.occurred_at_provided ? 1 : 0,
      row.host,
      row.raw,
      row.prompt_id,
      row.tool_use_id,
      row.tool_name,
    )
    .first<{ id: number }>();

  return inserted ? Number(inserted.id) : null;
}

/** commitStateTransition이 바깥에서 이미 알고 있어야 하는, 갱신 대상 세션의 최소 정보. */
interface CurrentSession {
  state: SessionState;
  last_occurred_at: number | null;
  input_state: string | null;
  projection_token: string | null;
}

/** commitStateTransition 호출자가 채워야 하는 값. 세션 프로젝션을 새로 만들 만큼의 정보다. */
interface CommitTransitionInput {
  db: D1Database;
  env: DispatchEnv;
  key: string;
  source: string;
  sessionId: string;
  project: string;
  host: string | null;
  message: string | null;
  /** dashboard_sessions.last_event로 남길 이벤트 이름. ended 불변식(REVIVAL_EVENT 비교)도 이 값을 본다. */
  event: string;
  occurredAt: number;
  now: number;
  /** 세션 행이 이미 있으면 그 상태·last_occurred_at. 신규 세션이면 null. */
  current: CurrentSession | null;
  /** 판정이 이미 끝난 목표 상태(어댑터 verdict, 하트비트 승격, 혹은 UserAck 판정 등). */
  newState: SessionState;
  inputState: string | null;
  /** push 발송을 요청을 막지 않고 예약하기 위한 훅. Hono의 c.executionCtx.waitUntil을 그대로 넘긴다. */
  waitUntil: (promise: Promise<unknown>) => void;
}

interface CommitTransitionResult {
  ok: true;
  state: SessionState | null;
  transition_id: number | null;
  push: string;
}

/**
 * 판정 공유 원칙: "새 로직은 한 곳에 순수 함수로 두고 다른 계층은 호출만 한다."
 *
 * /events(실시간 수집)의 5-b~6단계였던 것을 그대로 뽑아 만든 함수다 - 순서 역행 방어,
 * ended 불변식, 세션 프로젝션 UPSERT, 같은 상태 재진입 스킵, 전이 로그 적재, push 발송
 * 예약까지 "상태가 이미 정해진 다음"의 절차 전부를 담는다. 무엇을 목표 상태로 볼지(judgment)는
 * 호출자의 몫이고(어댑터 verdict냐, 하트비트 승격이냐, UserAck 판정이냐), 여기는 정해진
 * newState를 어떻게 커밋할지(commit)만 안다 - judgment와 commit을 갈라놓아야 새 판정 소스
 * (지금은 POST /sessions/:key/ack)가 생겨도 커밋 절차를 다시 베끼지 않고 그대로 재사용한다.
 *
 * 이 함수를 새로 만들지 않고 /events 핸들러 안에 그대로 두는 대안은 기각했다 - ack 엔드포인트가
 * "세션 행을 직접 UPDATE" 지름길을 쓰지 않고 일반 파이프라인을 타야 한다는 요구(rebuild.ts의
 * A==B 재생과 이 함수가 지키는 순서 역행·ended 가드를 ack도 똑같이 받게 하려는 목적)를
 * 만족시키려면, 두 경로가 실제로 같은 코드를 실행해야 한다 - 나란히 베끼면 한쪽만 고치는
 * 실수(가드가 갈라짐)를 컴파일러가 잡아주지 못한다.
 */
async function commitStateTransition(input: CommitTransitionInput): Promise<CommitTransitionResult | null> {
  const { db, env, key, source, sessionId, project, host, message, event, occurredAt, now, current, newState, inputState, waitUntil } =
    input;

  // 5-b) 순서 역행 방어. 스풀이 며칠 뒤에 밀려와도 과거가 현재를 덮어쓰지 못한다.
  //      이벤트는 이미 적재됐다 - 기록은 남기고 상태만 그대로 둔다.
  if (current && current.last_occurred_at !== null && occurredAt < current.last_occurred_at) {
    return { ok: true, state: current.state, transition_id: null, push: "none" };
  }

  // 5-c) ended 불변식. 끝난 세션은 SessionStart로만 되살아난다.
  if (current?.state === "ended" && event !== REVIVAL_EVENT) {
    return { ok: true, state: current.state, transition_id: null, push: "none" };
  }

  // 상태가 실제로 바뀌는(혹은 승격되는) 경로는 언제나 진척이다 - last_progress_at을 서버
  // 수신 시각(now)으로 민다(A안 원칙: 기록만 되는 이벤트는 호출자 쪽에서 이미 갈라져 여기 오지 않는다).
  const projectionToken = crypto.randomUUID();
  const statements: D1PreparedStatement[] = [];
  if (current === null) {
    statements.push(
      db
        .prepare(
          `INSERT INTO dashboard_sessions
             (key, source, session_id, project, host, state, last_event, last_message, last_occurred_at, last_progress_at, created_at, updated_at, input_state, projection_token)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(key) DO NOTHING
           RETURNING key`,
        )
        .bind(key, source, sessionId, project, host, newState, event, message, occurredAt, now, now, now, inputState, projectionToken),
    );
  } else {
    statements.push(
      db
        .prepare(
          `UPDATE dashboard_sessions SET state = ?, project = ?, host = COALESCE(?, host), last_event = ?, last_message = COALESCE(?, last_message), last_occurred_at = ?, last_progress_at = ?, updated_at = ?, input_state = ?, projection_token = ?
           WHERE key = ? AND projection_token IS ? AND state = ? AND last_occurred_at IS ?
           RETURNING key`,
        )
        .bind(newState, project, host, event, message, occurredAt, now, now, inputState, projectionToken, key, current.projection_token, current.state, current.last_occurred_at),
    );
  }

  // 6) 같은 상태 재진입은 전이가 아니다. 커서도 알림도 늘지 않는다.
  const hasTransition = newState !== current?.state;
  if (hasTransition) {
    statements.push(
      prepareTransition(
        db,
        {
          session_key: key,
          from_state: current?.state ?? null,
          to_state: newState,
          source,
          project,
          host,
          message,
          occurred_at: occurredAt,
        },
        now,
        projectionToken,
      ),
    );
    statements.push(
      db
        .prepare(
          "UPDATE dashboard_sessions SET last_transition_id = MAX(COALESCE(last_transition_id, 0), COALESCE((SELECT MAX(id) FROM dashboard_transitions WHERE session_key = ?), 0)) WHERE key = ? AND projection_token = ?",
        )
        .bind(key, key, projectionToken),
    );
  }

  const results = await db.batch(statements);
  if (((results[0]?.results ?? []) as { key: string }[]).length === 0) return null;

  let transition: PushTransition | null = null;
  if (hasTransition) {
    const transitionRow = ((results[1]?.results ?? []) as { id: number }[])[0];
    if (transitionRow) {
      transition = {
        id: Number(transitionRow.id),
        session_key: key,
        from_state: current?.state ?? null,
        to_state: newState,
        source,
        project,
        host,
        message,
        occurred_at: occurredAt,
      };
    }
  }

  let push = "none";
  if (transition && PUSH_STATES.has(newState)) {
    push = "queued";
    // 발송은 응답을 막지 않는다. 실패해도 전이는 이미 적재됐고 클라이언트는 커서로 따라잡는다.
    waitUntil(dispatchPush(env, transition).catch((err) => console.log(`push 발송 실패(무시): ${String(err)}`)));
  }

  return { ok: true, state: newState, transition_id: transition?.id ?? null, push };
}

/**
 * 에이전트 hook이 호출하는 이벤트 수신 엔드포인트.
 *
 * 순서가 곧 계약이다:
 *  1. 페이로드 검증(프로토콜 major 먼저) - 어긋나면 아무것도 적재하지 않고 400.
 *  2. 미등록 source면 raw까지 보존하고 202. 프로젝션·전이·push는 만들지 않는다.
 *  3. 소스 어댑터가 (event, state) -> 상태를 판정.
 *  4. 이벤트를 append-only 로그에 적재(event_id 멱등).
 *  5. 프로젝션(dashboard_sessions) 갱신. 단 순서 역행·ended 불변식은 상태를 지킨다.
 *  6. 상태가 "실제로" 바뀌었을 때만 전이 한 줄 + (push 대상이면) 발송을 waitUntil로 예약.
 *
 * 발송은 언제나 힌트다. 정합성은 GET /dashboard/sync?since=<cursor> 재조회가 담보하므로
 * push 실패가 이 요청을 실패로 만들지 않는다.
 */
dashboard.post("/events", async (c) => {
  const env = c.env as DispatchEnv;
  const db = c.env.DB;
  const now = Date.now();

  // raw 보존을 위해 원문 문자열을 먼저 잡고 나서 파싱한다.
  const bodyText = await c.req.text();
  let body: Record<string, unknown> | null = null;
  try {
    const parsed: unknown = JSON.parse(bodyText);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      body = parsed as Record<string, unknown>;
    }
  } catch {
    body = null;
  }
  if (!body) return c.json({ error: "잘못된 JSON 본문" }, 400);

  // 1) 프로토콜 major. 나머지 필드를 어떻게 읽을지 정하는 값이라 가장 먼저 본다.
  const version = body.protocol_version;
  if (typeof version !== "number" || !Number.isInteger(version)) {
    return c.json({ error: "protocol_version은 필수 정수" }, 400);
  }
  if (!ACCEPTED_PROTOCOL_VERSIONS.has(version)) {
    // 모르는 major는 추측해서 처리하지 않는다. 의미가 바뀌었을 수 있기 때문이다.
    return c.json({ error: "unsupported protocol_version" }, 400);
  }

  const source = body.source;
  const sessionId = body.session_id;
  const project = body.project;
  const event = body.event;
  if (
    typeof source !== "string" || !source ||
    typeof sessionId !== "string" || !sessionId ||
    typeof project !== "string" || // 빈 문자열은 허용한다(cwd를 모르는 실행 환경)
    typeof event !== "string" || !event
  ) {
    return c.json({ error: "source, session_id, project, event는 필수 문자열" }, 400);
  }

  // client_actions 전용 어휘(위조 차단, 검증 리뷰 지적 high): "UserAck" 같은 이름은 사람의
  // 조작(POST /dashboard/sessions/:key/ack)에서만 dashboard_events에 들어갈 수 있다 - 이
  // 수집 엔드포인트로 오면 source를 무엇으로 자칭하든 거절하고 로그도 남기지 않는다.
  // 어댑터 판정(3번, 아래)보다 먼저 걸러야 한다 - "미매핑이라 기록만 하고 통과"를 허용하면
  // 그 줄은 여기서는 아무 전이도 안 만들지만 POST /dashboard/admin/rebuild(rebuild.ts)가
  // 재생할 때는 event 이름만 보고 client_actions 판정을 다시 적용해 진짜 전이로 둔갑한다
  // (A!=B). client-actions.ts 헤더 코멘트·protocol.v1.json client_actions.reserved_event_names
  // 참고.
  if (RESERVED_CLIENT_ACTION_EVENTS.has(event)) {
    return c.json({ error: `event:"${event}"는 client_actions 전용이라 이 엔드포인트로 적재할 수 없다` }, 400);
  }
  if (sessionId.length > ID_MAX_CHARS) {
    return c.json({ error: `session_id는 ${ID_MAX_CHARS}자 이하여야 한다` }, 400);
  }

  const eventIdRaw = body.event_id;
  if (
    eventIdRaw !== undefined && eventIdRaw !== null &&
    (typeof eventIdRaw !== "string" || !eventIdRaw || eventIdRaw.length > ID_MAX_CHARS)
  ) {
    return c.json({ error: `event_id는 ${ID_MAX_CHARS}자 이하의 문자열이어야 한다` }, 400);
  }
  const eventId = typeof eventIdRaw === "string" && eventIdRaw ? eventIdRaw : null;

  const host = typeof body.host === "string" && body.host ? body.host : null;

  // "훅 구버전 배너" 기능(dashboard_meta.hook_revs 원장, hooks/routes.ts의 HOOK_REV,
  // sync.ts의 hook_skew)의 원재료. additive 필드라 형식이 틀려도 거절하지 않고 그냥 없는
  // 셈 친다(state 판정에도 전혀 관여하지 않는다) - protocol.v1.json
  // event_payload.fields.hook_rev 참고.
  const hookRev = typeof body.hook_rev === "string" && body.hook_rev ? body.hook_rev : null;

  // occurred_at은 클라이언트 시계다. 없으면 수신 시각으로 대신한다.
  // 형식이 틀리면 조용히 고치지 않는다 - 잘못된 시각 하나가 순서 방어를 통째로 망가뜨린다.
  // 서버는 이 값을 고치지 않는다(클램프 없음) - 순서 판정에만 쓰이고 서버 시각과 비교되지
  // 않는다(states.invariants). 서버 시각과 비교해야 하는 stalled 판정 등은 occurred_at이
  // 아니라 last_progress_at(아래, 서버 수신 시각)을 쓴다.
  const occurredRaw = body.occurred_at;
  // 명시적으로 있었는가(가드3, heartbeat.ts)는 기본값 대체와 구분해서 따로 들고 있어야 한다.
  const occurredAtProvided = occurredRaw !== undefined && occurredRaw !== null;
  let occurredAt = now;
  if (occurredAtProvided) {
    if (typeof occurredRaw !== "number" || !Number.isInteger(occurredRaw)) {
      return c.json({ error: "occurred_at은 정수(epoch ms)여야 한다" }, 400);
    }
    occurredAt = occurredRaw;
  }

  const storeMessage = env.DASHBOARD_STORE_MESSAGE === "1";
  const message =
    storeMessage && typeof body.message === "string" ? body.message.slice(0, MESSAGE_MAX_CHARS) : null;
  const correlation =
    source === "devin"
      ? readDevinCorrelation(body)
      : { prompt_id: null, tool_use_id: null, tool_name: null };
  const normalized = JSON.stringify({
    protocol_version: body.protocol_version,
    source, session_id: sessionId, project, event, event_id: eventId, host,
    ...(occurredAtProvided ? { occurred_at: occurredAt } : {}),
    ...(source === "generic" && typeof body.state === "string" ? { state: body.state } : {}),
    hook_rev: hookRev,
    ...correlation,
  });
  if (!storeMessage && new TextEncoder().encode(normalized).length > REPLAY_MAX_BYTES) {
    return c.json({ error: `normalized event metadata must not exceed ${REPLAY_MAX_BYTES} UTF-8 bytes` }, 400);
  }
  const raw = storeMessage ? truncateBytes(bodyText, RAW_MAX_BYTES) : normalized;

  const key = `${source}:${sessionId}`;
  const eventRow: EventRow = {
    session_key: key,
    source,
    event,
    message,
    event_id: eventId,
    occurred_at: occurredAt,
    occurred_at_provided: occurredAtProvided,
    host,
    raw,
    prompt_id: correlation.prompt_id,
    tool_use_id: correlation.tool_use_id,
    tool_name: correlation.tool_name,
  };

  // 2) 미등록 source: 거절하지 않는다. 원본까지 보존해 두면 나중에 어댑터를 붙여 다시 읽을 수 있다.
  //    다만 상태를 지어내지는 않는다 - 프로젝션·전이·push 없음.
  const adapter = adapterFor(source);
  if (!adapter) {
    const loggedId = await insertEvent(db, eventRow, now);
    if (loggedId === null) return c.json({ ok: true, duplicate: true });
    return c.json({ accepted: "logged", reason: "unknown_source" }, 202);
  }

  // 3) 어댑터 판정. state 필드는 그걸 허용한 소스(generic)에만 넘긴다.
  const verdict = adapter.resolve({
    event,
    reportedState: adapter.stateFieldAllowed ? body.state : undefined,
  });
  // 어휘를 어긴 페이로드는 로그도 남기지 않는다(클라이언트 버그이지 관측 대상이 아니다).
  if (verdict.reject) return c.json({ error: verdict.reject }, 400);

  // 4) append-only 로그. 여기서 중복이면 이후 단계는 전부 건너뛴다.
  const eventRowId = await insertEvent(db, eventRow, now);
  if (eventRowId === null) return c.json({ ok: true, duplicate: true });

  // 4.5) "훅 구버전 배너" 원장(dashboard_meta.hook_revs) 갱신 - 상태 판정(전이/세션 로직)이
  // 시작되기 전에, 별도 읽기 없이 이 한 줄로 끝낸다(SoC: 판정 로직과 완전히 분리된 독립
  // 부기). host가 없으면 "어느 기계인지"를 특정할 수 없으니 아예 건너뛴다. occurred_at을
  // 클라이언트가 명시하지 않은 경우(서버가 now로 대신 채운 경우)에도 건너뛴다 - received_at
  // 기반으로 이 원장이 퇴화하는 걸 막기 위해서다(0003 확정 원리: occurred_at은 같은 기계의
  // 같은 시계이므로 그 기계 안에서는 순서 비교가 자기충족적이지만, received_at은 네트워크
  // 지연에 따라 순서가 뒤집힐 수 있어 단조 가드로 못 쓴다).
  //
  // ?4(현재 rev 무조건 수용) - 훅이 방금 서버에게서 받은 그 rev를 그대로 보고하는 흔한
  // 경우, 시계가 거꾸로 가는 극단적 상황이라도 무조건 받아들인다("방금 서버에게서 받았다"는
  // 사실 자체가 최신성의 증거이기 때문).
  // at<=occurred_at(단조 가드) - occurred_at 기준으로만 비교한다(같은 기계 시계라 자기충족적).
  // 마지막 절 - "값이 실제로 바뀔 때만 쓴다" + "값이 그대로여도 at이 24시간(86400000ms)보다
  // 오래됐으면 최신 유지 차원에서 갱신한다"(maintenance.ts pruneRetention의 30일 만료 정책과
  // 짝을 이룬다). rev 미보고(NULL)와 rev 낡음 사이에 우선순위는 없다 - 원장은 마지막으로
  // 보고된 값을 그대로 들고 있을 뿐이고, 읽는 쪽(sync.ts hook_skew)의 판정은
  // `!== HOOK_REV` 한 줄이 전부다.
  //
  // project(?5) - devcontainer 등 host만으로는(예: "235f7d6e85ff" 같은 컨테이너 ID) 어느 세션인지
  // 사람이 식별할 수 없다는 운영 식별을 위해 additive 추가(sync.ts hook_skew에 그대로 실려 앱이
  // "host (project)"로 보여준다). WHERE 가드는 건드리지 않는다 - project는 "이 host가 마지막으로
  // hook_rev를 신고한 세션의 cwd" 힌트일 뿐 판정 대상이 아니라서, project만 바뀌고 rev·24시간
  // 조건이 전부 거짓이면(위 가드) 이 신고는 원장에 전혀 반영되지 않는다 - project도 rev와 마찬가지로
  // "다음 번 rev 변경 또는 24시간 주기 갱신" 타이밍에 묻어서만 갱신된다.
  if (host !== null && occurredAtProvided) {
    const isCurrentRev = hookRev === HOOK_REV ? 1 : 0;
    const hookProject = project ? project : null;
    await db
      .prepare(
        `INSERT INTO dashboard_meta (key, value)
         VALUES ('hook_revs', json_object(?1, json_object('rev', ?2, 'at', ?3, 'project', ?5)))
         ON CONFLICT(key) DO UPDATE SET
           value = json_set(dashboard_meta.value, '$."' || ?1 || '"', json_object('rev', ?2, 'at', ?3, 'project', ?5))
         WHERE ?4 = 1
            OR ( COALESCE(json_extract(dashboard_meta.value,'$."'||?1||'".at'), 0) <= ?3
                 AND ( json_extract(dashboard_meta.value,'$."'||?1||'".rev') IS NOT ?2
                       OR COALESCE(json_extract(dashboard_meta.value,'$."'||?1||'".at'),0) < ?3 - 86400000 ) )`,
      )
      .bind(host, hookRev, occurredAt, isCurrentRev, hookProject)
      .run();
  }

  const casPredicate = "WHERE key = ? AND projection_token IS ? AND state = ? AND last_occurred_at IS ?";
  for (;;) {
    const current = await db
      .prepare("SELECT state, last_occurred_at, input_state, projection_token FROM dashboard_sessions WHERE key = ?")
      .bind(key)
      .first<CurrentSession>();

    // B: heartbeat면서 상태를 바꾸지 않는 판정(verdict.state===null)이라도, 조건부 승격
    // 가드 5종(heartbeat.ts)을 전부 통과하면 working으로 승격한다. 판정은 이 한 함수가
    // 전부이고 routes.ts는 호출만 한다(SoC) - rebuild.ts도 같은 함수를 그대로 호출한다.
    const promotedState =
      !verdict.state && verdict.heartbeat
        ? resolveHeartbeatPromotion({
            currentState: current?.state ?? null,
            occurredAtProvided,
            occurredAt,
            lastOccurredAt: current?.last_occurred_at ?? null,
          })
        : null;
    const effectiveState = verdict.state ?? promotedState;

    const resolved =
      source === "devin"
        ? resolveDevinInput({
            event,
            prompt_id: correlation.prompt_id,
            tool_use_id: correlation.tool_use_id,
            tool_name: correlation.tool_name,
            currentState: current?.state ?? null,
            lastOccurredAt: current?.last_occurred_at ?? null,
            occurredAt,
            occurredAtProvided,
            storedInputState: current?.input_state ?? null,
            proposedState: effectiveState,
          })
        : { state: effectiveState, inputState: current?.input_state ?? null };
    const finalState = resolved.state;

    // 5-a) 상태를 바꾸지 않는 이벤트(승격도 안 된 heartbeat 포함). heartbeat만 last_occurred_at과
    //      last_progress_at을 민다(heartbeat가 아닌 미매핑 이벤트는 기록만 한다 - A안 원칙: 기록만
    //      되는 이벤트는 last_progress_at을 밀지 않는다 - 유휴 알림이 stalled를 미루면 안 된다).
    //      last_occurred_at은 기존처럼 순서 비교(>=)를 거쳐 갱신하고, last_progress_at은 서버
    //      수신 시각이라 그 비교와 무관하게 항상 now로 민다 - 둘은 서로 다른 시계를 잰다.
    if (!finalState) {
      if (!current) {
        return c.json({ ok: true, state: null, transition_id: null, push: "none" });
      }
      const token = crypto.randomUUID();
      let written: { key: string } | null;
      if (verdict.heartbeat && occurredAt >= (current.last_occurred_at ?? 0)) {
        written = await db
          .prepare(
            `UPDATE dashboard_sessions SET last_event = ?, last_occurred_at = ?, last_progress_at = ?, updated_at = ?, projection_token = ? ${casPredicate} RETURNING key`,
          )
          .bind(event, occurredAt, now, now, token, key, current.projection_token, current.state, current.last_occurred_at)
          .first<{ key: string }>();
      } else if (verdict.heartbeat) {
        written = await db
          .prepare(
            `UPDATE dashboard_sessions SET last_event = ?, last_progress_at = ?, updated_at = ?, projection_token = ? ${casPredicate} RETURNING key`,
          )
          .bind(event, now, now, token, key, current.projection_token, current.state, current.last_occurred_at)
          .first<{ key: string }>();
      } else {
        written = await db
          .prepare(
            `UPDATE dashboard_sessions SET last_event = ?, updated_at = ?, projection_token = ? ${casPredicate} RETURNING key`,
          )
          .bind(event, now, token, key, current.projection_token, current.state, current.last_occurred_at)
          .first<{ key: string }>();
      }
      if (!written) continue;
      return c.json({ ok: true, state: current.state, transition_id: null, push: "none" });
    }

    // 5-b~6) 판정(effectiveState)이 끝난 다음의 절차(순서 역행 방어·ended 불변식·프로젝션
    // UPSERT·같은 상태 스킵·전이 적재·push 예약)는 commitStateTransition 하나에만 있고
    // 여기서는 호출만 한다(SoC) - POST /sessions/:key/ack도 판정만 다르고 이 함수를 그대로 쓴다.
    const result = await commitStateTransition({
      db,
      env,
      key,
      source,
      sessionId,
      project,
      host,
      message,
      event,
      occurredAt,
      now,
      current,
      newState: finalState,
      inputState: resolved.inputState,
      waitUntil: (p) => c.executionCtx.waitUntil(p),
    });
    if (result === null) continue;
    return c.json(result);
  }
});

/** 앱이 켜질 때 호출하는 현황 조회. 기본으로 종료된 세션은 제외한다. */
dashboard.get("/sessions", async (c) => {
  const includeEnded = c.req.query("include_ended") === "1";
  const now = Date.now();
  const { results } = await c.env.DB.prepare(
    "SELECT key, source, session_id, project, state, last_event, last_message, created_at, updated_at FROM dashboard_sessions ORDER BY updated_at DESC",
  ).all<{ state: SessionState; updated_at: number }>();
  const sessions = (results ?? [])
    .filter((s) => includeEnded || s.state !== "ended")
    .map((s) => ({ ...s, stale: s.state !== "ended" && now - s.updated_at > STALE_MS }));
  return c.json({ sessions });
});

/** 세션 상세 화면용 이벤트 이력. 정본: protocol.v1.json event_history. */
dashboard.get("/events", async (c) => {
  let query: HistoryQuery;
  try {
    query = parseHistoryQuery(c.req.query());
  } catch {
    return c.json({ error: "invalid history query" }, 400);
  }
  return c.json(await readHistory(c.env.DB, query));
});

/** 대시보드에서 세션 카드를 지울 때 사용한다. */
dashboard.delete("/sessions/:key", async (c) => {
  const key = c.req.param("key");
  await c.env.DB.prepare("DELETE FROM dashboard_sessions WHERE key = ?").bind(key).run();
  await c.env.DB.prepare("DELETE FROM dashboard_events WHERE session_key = ?").bind(key).run();
  // seen 마커도 세션과 함께 지운다 - 세션이 없는데 seen 행만 남으면 고아가 된다(maintenance.ts의
  // 주기적 고아 정리와 별개로, 사람이 직접 지우는 이 경로는 그 자리에서 바로 같이 치운다).
  await c.env.DB.prepare("DELETE FROM dashboard_seen WHERE session_key = ?").bind(key).run();
  return c.json({ ok: true });
});

/**
 * 사람이 대시보드에서 세션 상세를 열어봤다는 신호(protocol.v1.json client_actions.MarkSeen).
 * 상태 전이가 아니다 - dashboard_transitions에 줄을 남기지 않고, dashboard_events에도 아무
 * 것도 적재하지 않는다(순수 마커라 예약 이벤트 이름조차 필요 없다). push에도 영향이 없다.
 *
 * 요청 본문은 선택이다: { last_transition_id?: number }를 실어 보내면 그 값으로(단, 세션의
 * 현재 last_transition_id를 넘지는 못하게 위로 잘린다 - 리뷰 지적 medium 수정, 이유는 seen.ts의
 * resolveSeenTarget 문서 참고), 없거나 형식이 틀리면 세션의 현재 last_transition_id로 단조
 * 갱신한다. 갱신 자체(멀티 기기 역행 차단)는 seen.ts의 markSeenAtLeast 하나에만 있고 여기서는
 * 호출만 한다(SoC) - POST /sessions/:key/ack도 같은 함수를 그대로 쓴다.
 *
 * 세션이 실제로 존재하는지는 확인하지 않는다(가드 없음) - 존재하지 않는 키로 와도(=위 클램프의
 * 상한 자체가 없으므로) 그냥 그 값으로 기록될 뿐이고, 세션이 끝내 생기지 않으면 maintenance.ts의
 * 고아 정리가 나중에 치운다. 존재 여부를 이 라우트가 판단해서 동작을 바꾸면(예: 404) "실패해도
 * 무해하다"는 앱 쪽 설계(낙관적 갱신, 실패는 non-blocking)와 어긋난다.
 */
dashboard.post("/sessions/:key/seen", async (c) => {
  const db = c.env.DB;
  const key = c.req.param("key");

  // 본문은 선택이다(DELETE /sessions/:key와 같은 관례) - JSON이 아니거나 필드가 없거나
  // 형식이 틀리면 조용히 "본문 없음"과 동일하게 취급한다(순수 마커라 실패가 무해해야 한다).
  let explicit: number | undefined;
  const bodyText = await c.req.text();
  if (bodyText) {
    try {
      const parsed: unknown = JSON.parse(bodyText);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        const raw = (parsed as Record<string, unknown>).last_transition_id;
        if (typeof raw === "number" && Number.isInteger(raw)) explicit = raw;
      }
    } catch {
      // 잘못된 JSON도 "본문 없음"과 동일하게 취급한다.
    }
  }

  const session = await db
    .prepare("SELECT last_transition_id FROM dashboard_sessions WHERE key = ?")
    .bind(key)
    .first<{ last_transition_id: number | null }>();

  const target = resolveSeenTarget(explicit, session?.last_transition_id ?? null);
  const seenTransitionId = await markSeenAtLeast(db, key, target);
  return c.json({ ok: true, seen_transition_id: seenTransitionId });
});

/**
 * 사람이 대시보드에서 승인 완료를 직접 눌렀다는 신호(protocol.v1.json client_actions.UserAck).
 * claude-code에는 "approval 완료" 신호가 없어 waiting_input이 Stop이 올 때까지 계속되는
 * 문제를, 사람의 1회성 클릭이라는 1:1 해소 신호로 푼다 - client-actions.ts 헤더 참고.
 *
 * 가드: 세션이 없거나 현재 상태가 waiting_input이 아니면 아무 것도 하지 않는다(no-op,
 * 멱등) - 두 기기에서 동시에 눌러도, 이미 다른 이벤트로 해소된 뒤에 늦게 도착해도 안전하다.
 * 판정 자체(어느 상태에서 어느 상태로)는 이 자리에서 다시 쓰지 않고 resolveUserAckTransition
 * (client-actions.ts) 하나만 부른다 - rebuild.ts도 재생 시 같은 함수를 그대로 부른다.
 *
 * 동작할 때는 UserAck 이벤트를 dashboard_events에 먼저 정식 적재하고 나서 /events(수집
 * 경로)와 같은 커밋 함수(commitStateTransition)를 그대로 호출한다 - 세션 행을 직접
 * UPDATE하는 지름길은 쓰지 않는다: 재생(rebuild.ts)이 dashboard_events를 replay해서
 * 같은 결과를 내려면(A==B) 이 전이도 반드시 이벤트 로그에 남아 있어야 한다.
 *
 * seen 연동(확정 설계): ack는 "사람이 지금 이 세션을 보고 있다"는 신호이기도 하므로, 세션이
 * 존재하는 모든 경로(전이를 실제로 만들었든, 이미 working/ended라 no-op이든)에서 dashboard_seen을
 * 그 시점의 last_transition_id로 단조 갱신한다 - 이걸 안 하면 ack가 방금 만든 자기 전이
 * 때문에 카드가 ack 직후 다시 "미확인"으로 켜진다. 세션 자체가 없으면(current===null) 갱신할
 * last_transition_id가 없으므로 아무 것도 하지 않는다. 판정·갱신은 seen.ts 하나에만 있고
 * 여기서는 호출만 한다(SoC).
 */
dashboard.post("/sessions/:key/ack", async (c) => {
  const env = c.env as DispatchEnv;
  const db = c.env.DB;
  const key = c.req.param("key");
  const now = Date.now();

  const current = await db
    .prepare(
      "SELECT source, session_id, project, host, state, last_occurred_at, last_transition_id, input_state, projection_token FROM dashboard_sessions WHERE key = ?",
    )
    .bind(key)
    .first<{
      source: string;
      session_id: string;
      project: string;
      host: string | null;
      state: SessionState;
      last_occurred_at: number | null;
      last_transition_id: number | null;
      input_state: string | null;
      projection_token: string | null;
    }>();

  if (!current) {
    return c.json({ ok: true, state: null, transition_id: null, push: "none" });
  }

  const newState = resolveUserAckTransition(current.state);
  if (!newState) {
    // 세션은 있지만 waiting_input이 아니라 ack가 할 일이 없다(no-op) - 그래도 ack라는
    // 조작 자체가 "지금 시점까지 봤다"는 신호이므로 seen은 현재 last_transition_id로
    // 단조 갱신한다(위 헤더 코멘트의 seen 연동 근거 참고).
    await markSeenAtLeast(db, key, current.last_transition_id);
    return c.json({ ok: true, state: current.state, transition_id: null, push: "none" });
  }

  // occurred_at 단조 증가(클라이언트 시계 체인, 검증 리뷰 지적 high로 Math.max(now, ...)
  // 제거): ack는 서버가 만드는 이벤트지만 occurred_at은 여전히 "이 세션의 클라이언트 시계
  // 체인" 소속이다(states.invariants - 서버 시각과 비교되지 않는다). last_occurred_at보다
  // 최소 1ms 뒤만 보장하면 충분하고, 여기에 now를 섞으면(Math.max) 시계가 서버보다 뒤처진
  // 기계(혹은 스풀이 밀려 last_occurred_at이 이미 미래인 세션)의 이 ack가 now로 튀어 올라
  // 그 뒤에 도착하는(진짜로는 더 최신인) 훅 이벤트들을 전부 "과거"로 만들어 순서 역행 방어
  // (commitStateTransition의 5-b)에 줄줄이 걷어차인다(교차 시계 오염) - last_occurred_at이
  // 아직 없는 신규 세션에서만 now를 기준으로 삼는다.
  const occurredAt = (current.last_occurred_at ?? now) + 1;

  // 서버가 스스로 만드는 이벤트라 raw도 서버가 구성한다. rebuild.ts(readRawStringField)가
  // raw를 파싱해 project를 복원하므로 project는 반드시 담아야 한다 - 다른 필드는 참고용이다.
  const raw = JSON.stringify({
    source: current.source,
    session_id: current.session_id,
    project: current.project,
    event: "UserAck",
    occurred_at: occurredAt,
  });

  const eventRow: EventRow = {
    session_key: key,
    source: current.source,
    event: "UserAck",
    message: null,
    event_id: crypto.randomUUID(),
    occurred_at: occurredAt,
    occurred_at_provided: true,
    host: current.host,
    raw,
    prompt_id: null,
    tool_use_id: null,
    tool_name: null,
  };
  await insertEvent(db, eventRow, now);

  let lastResult: CommitTransitionResult = {
    ok: true,
    state: current.state,
    transition_id: null,
    push: "none",
  };
  let lastTransitionId = current.last_transition_id;
  for (;;) {
    const fresh = await db
      .prepare(
        "SELECT source, session_id, project, host, state, last_occurred_at, last_transition_id, input_state, projection_token FROM dashboard_sessions WHERE key = ?",
      )
      .bind(key)
      .first<{
        source: string;
        session_id: string;
        project: string;
        host: string | null;
        state: SessionState;
        last_occurred_at: number | null;
        last_transition_id: number | null;
        input_state: string | null;
        projection_token: string | null;
      }>();
    if (!fresh) {
      lastResult = { ok: true, state: null, transition_id: null, push: "none" };
      break;
    }
    lastTransitionId = fresh.last_transition_id;
    const freshState = resolveUserAckTransition(fresh.state);
    if (!freshState) {
      lastResult = { ok: true, state: fresh.state, transition_id: null, push: "none" };
      break;
    }
    const resolved =
      fresh.source === "devin"
        ? resolveDevinInput({
            event: "UserAck",
            prompt_id: null,
            tool_use_id: null,
            tool_name: null,
            currentState: fresh.state,
            lastOccurredAt: fresh.last_occurred_at,
            occurredAt,
            occurredAtProvided: true,
            storedInputState: fresh.input_state,
            proposedState: freshState,
          })
        : { state: freshState, inputState: fresh.input_state };
    const result = await commitStateTransition({
      db,
      env,
      key,
      source: fresh.source,
      sessionId: fresh.session_id,
      project: fresh.project,
      host: fresh.host,
      message: null,
      event: "UserAck",
      occurredAt,
      now,
      current: {
        state: fresh.state,
        last_occurred_at: fresh.last_occurred_at,
        input_state: fresh.input_state,
        projection_token: fresh.projection_token,
      },
      newState: freshState,
      inputState: resolved.inputState,
      waitUntil: (p) => c.executionCtx.waitUntil(p),
    });
    if (result === null) continue;
    lastResult = result;
    break;
  }

  // 전이를 만들었으면(result.transition_id) 그 id로, commitStateTransition 내부에서마저
  // no-op이었으면(순서 역행 방어·ended 불변식·같은 상태 재진입 등) 이 ack 이전부터 이미
  // 알고 있던 current.last_transition_id로 seen을 단조 갱신한다.
  await markSeenAtLeast(db, key, lastResult.transition_id ?? lastTransitionId);
  return c.json(lastResult);
});

/**
 * 기기 등록·해제(/devices)와 클라이언트 push 설정(/push-config)은 push/routes.ts가 맡는다.
 * 여기(수집·조회 라우트)와 같은 "/dashboard" prefix 아래 앉아야 하므로 서브앱으로 얹는다 -
 * 채널·기기 스키마가 바뀔 때 이 파일을 다시 열지 않기 위해서다.
 */
dashboard.route("/", pushRoutes);
