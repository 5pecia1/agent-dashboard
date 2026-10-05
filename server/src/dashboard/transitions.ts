import type { PushTransition } from "./dispatch";
import type { SessionState } from "./state";

/**
 * 상태 전이 로그(dashboard_transitions) append 헬퍼.
 *
 * 이 테이블의 AUTOINCREMENT id가 곧 클라이언트 커서다. GET /dashboard/sync?since=<id>가
 * 이 값으로 "내가 마지막으로 본 이후"를 정의하므로, 전이는 상태가 실제로 바뀔 때만 한 줄
 * 쌓여야 한다. 같은 상태 재진입(Stop 연타 등)은 전이가 아니다 - 그 판정은 부르는 쪽이 한다.
 * 여기 오면 "전이가 일어났다"는 뜻이다.
 *
 * push 발송은 여기서 하지 않는다. 적재(정합성의 근거)와 발송(깨워주는 힌트)은 분리한다.
 * 음소거·발송 실패가 전이 적재를 되돌리는 일이 없어야 하기 때문이다.
 *
 * dashboard_sessions.last_transition_id도 여기서 같이 갱신한다(seen 기능의 기준값 - 0004
 * 마이그레이션 참고). RETURNING으로 새 id를 받는 바로 이 자리가 "이 세션의 마지막 전이가
 * 무엇인지"를 아는 유일한 진실이므로, 다른 계층(routes.ts)이 따로 계산해 다시 쓰게 하지
 * 않는다 - SoC 원칙(새 로직은 한 곳에만 둔다)을 "부르는 자리"가 아니라 "이 값을 만드는
 * 자리"에 적용한 것이다. 세션 행은 commitStateTransition이 appendTransition을 부르기
 * 전에 이미 UPSERT로 만들어 두므로(routes.ts), 여기서 하는 UPDATE는 항상 기존 행을 찾는다.
 *
 * 이 UPDATE는 단조 증가만 허용한다(MAX, 리뷰 지적 medium 수정) - INSERT(id 채번)와 이
 * UPDATE는 한 문장이 아니라 별개의 두 왕복이라, 같은 세션에 겹쳐 들어온 두 요청의 INSERT가
 * 순서 A(id=5)·B(id=6)로 끝나도 그 뒤의 UPDATE는 스케줄러 사정으로 B(6)가 먼저, A(5)가
 * 나중에 실행될 수 있다 - 단순 대입이면 이 경우 last_transition_id가 6에서 5로 역행해,
 * 실제로는 있었던 전이(6)가 seen 판정(last_transition_id > seen_transition_id)에서
 * "아직 일어나지 않은 것"처럼 사라진다. seen.ts의 markSeenAtLeast·클라이언트 리듀서의
 * math.max(existing.lastTransitionId, transition.id)와 같은 태도로, 여기도 뒤로 가지
 * 않는다.
 */

/** 전이 한 줄을 만들기 위해 부르는 쪽이 알려주는 값. id·created_at은 서버가 붙인다. */
export interface TransitionInput {
  session_key: string;
  /** 직전 상태. 세션의 첫 전이면 null. */
  from_state: SessionState | null;
  to_state: SessionState;
  source: string;
  project: string | null;
  host: string | null;
  /** 전이를 만든 이벤트의 message(이미 300자로 잘렸고, 저장이 꺼져 있으면 null). */
  message: string | null;
  display_title?: string | null;
  /** 이벤트 발생 시각(epoch ms, 클라이언트 시계). */
  occurred_at: number;
}

export function prepareTransition(
  db: D1Database,
  input: TransitionInput,
  now: number,
  projectionToken?: string,
): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO dashboard_transitions
         (session_key, from_state, to_state, source, project, host, message, display_title, occurred_at, created_at)
       SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
       WHERE (? IS NULL OR EXISTS (SELECT 1 FROM dashboard_sessions WHERE key = ? AND projection_token = ?))
       RETURNING id`,
    )
    .bind(
      input.session_key,
      input.from_state,
      input.to_state,
      input.source,
      input.project,
      input.host,
      input.message,
      input.display_title ?? null,
      input.occurred_at,
      now,
      projectionToken ?? null,
      input.session_key,
      projectionToken ?? null,
    );
}

/**
 * 전이 한 줄을 적재하고, 그 줄을 dispatch가 바로 쓸 수 있는 모양(PushTransition)으로 돌려준다.
 * 돌려주는 id가 곧 이 전이의 커서 값이고, 응답의 transition_id로도 나간다.
 *
 * RETURNING id로 방금 넣은 행의 id를 원자적으로 받는다(같은 문장 안이라 동시 요청과 섞이지 않는다).
 */
export async function appendTransition(
  db: D1Database,
  input: TransitionInput,
  now: number,
): Promise<PushTransition> {
  const row = await prepareTransition(db, input, now).first<{ id: number }>();

  const id = Number(row?.id ?? 0);

  await db
    .prepare(
      "UPDATE dashboard_sessions SET last_transition_id = MAX(COALESCE(last_transition_id, 0), ?) WHERE key = ?",
    )
    .bind(id, input.session_key)
    .run();

  return {
    id,
    session_key: input.session_key,
    from_state: input.from_state,
    to_state: input.to_state,
    source: input.source,
    project: input.project,
    host: input.host,
    message: input.message,
    display_title: input.display_title ?? null,
    occurred_at: input.occurred_at,
  };
}
