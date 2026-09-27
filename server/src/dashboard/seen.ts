/**
 * seen: 상태가 변한 카드 중 사용자가 이미 열어본 것을 구분하는 표시(읽음/안읽음).
 *
 * 정본: protocol.v1.json client_actions.MarkSeen 및 두 불변식(rebuild 불가침, push 무영향).
 * 이 기능은 상태 모델 밖에 있다 - dashboard_transitions에 어떤 줄도 남기지 않고
 * (POST /dashboard/sessions/:key/seen은 dashboard_events에도 아무것도 적재하지 않는다 -
 * 예약 이벤트 이름조차 필요 없다, 애초에 로그에 남는 게 없기 때문이다), push 발송 여부에도
 * 어떤 영향을 주지 않는다(push는 전이 시점에 고정되는 힌트다).
 *
 * 기준은 시각이 아니라 전이 id다(클라이언트 시각과 독립 - 시계가 전혀 개입하지
 * 않는다): 미확인 = dashboard_sessions.last_transition_id > dashboard_seen.seen_transition_id.
 * 0004_dashboard_seen.sql 참고.
 *
 * 판정 공유 원칙: "새 로직은 한 곳에 순수 함수로 두고 다른 계층은 호출만 한다." 이 갱신은
 * 서로 다른 두 호출자(POST /sessions/:key/seen, POST /sessions/:key/ack)에서 일어나는데,
 * 둘 다 결국 "이 세션을 이 transition id까지는 봤다"는 같은 사실을 같은 규칙(단조 증가만
 * 허용)으로 기록하는 것이므로 판정과 갱신을 이 파일 하나에 두고 routes.ts는 호출만 한다.
 * heartbeat.ts(resolveHeartbeatPromotion)·client-actions.ts(resolveUserAckTransition)와
 * 같은 전례다.
 */

/**
 * 다음에 seen으로 기록할 목표 transition id를 정한다.
 *
 * - explicit(호출자가 이미 알고 있는 값 - seen 라우트라면 클라이언트가 요청 본문에 실어 보낸
 *   last_transition_id, ack 라우트라면 ack가 방금 만든 전이의 id)가 유효한 정수면 그 값을 쓴다 -
 *   단, currentLastTransitionId로 알려진 상한을 넘지는 못한다(아래 클램프 문단).
 * - 아니면(본문이 없거나, ack가 전이를 만들지 않은 no-op이었거나) 세션의 현재
 *   last_transition_id를 쓴다(그마저 null이면 - 이 세션에 전이가 아직 한 번도 없었다면 - null).
 *
 * ack 쪽 근거: "ack가 전이를 만들면 그 transition_id로 seen도 단조 갱신한다(no-op이면 현재
 * last_transition_id로) - 안 하면 ack 직후 자기 전이 때문에 카드가 다시 미확인으로 켜진다"
 * (확정 설계). ack 자체가 전이를 안 만든 경우(이미 working·ended였거나 순서 역행 등으로
 * commitStateTransition 내부에서 걸러진 경우)에도 세션의 "지금 시점"으로 맞춰 두는 편이
 * 안전하다 - ack라는 조작 자체가 사람이 이 세션을 보고 있다는 신호이기 때문이다.
 *
 * 클램프(리뷰 지적 medium 수정): currentLastTransitionId가 알려져 있으면(세션이 존재하고
 * 전이가 최소 하나 있으면) explicit이 그 값을 넘어서는 "아직 일어나지 않은 미래"를 가리키지
 * 못하게 위로 자른다 - markSeenAtLeast는 단조 MAX만 허용해 한 번 기록되면 절대 되돌릴 수 없으므로
 * (악의적으로 Number.MAX_SAFE_INTEGER를 보내는 경우도, rebuild 직후 클라이언트가 아직 들고
 * 있던 재구성 이전 id를 그대로 보내는 사고도 이 상한 하나로 막는다). currentLastTransitionId가
 * null이면(세션이 없거나, 있어도 아직 전이가 하나도 없다) 자를 상한 자체가 없으므로 explicit을
 * 그대로 받아들인다 - routes.ts 헤더의 "가드 없음"(존재하지 않는 키로 와도 그 값으로 그냥
 * 기록된다) 설계는 그대로 지킨다(존재 확인은 여전히 하지 않는다 - 이건 상한 클램프일 뿐이다).
 */
export function resolveSeenTarget(
  explicit: number | null | undefined,
  currentLastTransitionId: number | null,
): number | null {
  if (typeof explicit === "number" && Number.isInteger(explicit)) {
    if (currentLastTransitionId != null && explicit > currentLastTransitionId) {
      return currentLastTransitionId;
    }
    return explicit;
  }
  return currentLastTransitionId;
}

/**
 * dashboard_seen을 session_key 기준으로 "적어도 transitionId까지는 봤다"로 단조 갱신하고,
 * 갱신 후 최종 seen_transition_id를 돌려준다. 행이 없으면 새로 만든다.
 *
 * 멀티 기기 단조 갱신(확정 설계): 여러 기기가 같은 세션을 동시에 보고 있을 때, 뒤처진
 * 기기가 나중에 보내는 (오래된) 값이 앞선 기기가 이미 올려둔 값을 역행시키면 안 된다.
 * ON CONFLICT DO UPDATE에서 SQL의 MAX로 비교하는 이유다 - 응용 코드가 먼저 읽고 비교해서
 * 다시 쓰는 (조회 후 갱신) 방식은 그 사이 다른 요청이 끼어들 여지(경합)가 있지만, 이 문장은
 * DB 안에서 한 번에 끝난다.
 *
 * NULL 처리: SQLite의 스칼라 max(a,b)는 a·b 중 하나라도 NULL이면 NULL을 돌려준다(행 단위
 * 집계인 MAX()와 다르다) - "아직 전이가 없다/아직 한 번도 seen을 부른 적 없다"는 뜻의 NULL을
 * 그대로 "값 비교"에 넣으면 이미 기록된 숫자가 NULL에 덮여 사라져 버린다(단조 증가가 깨진다).
 * 그래서 COALESCE로 NULL을 절대 충돌하지 않는 안전한 하한(-1 - 실제 전이 id는 1부터 시작하는
 * AUTOINCREMENT다)으로 바꿔 최댓값을 계산한 다음, 그 결과가 다시 -1이면(=양쪽 다 원래
 * NULL이었다면) NULLIF로 NULL로 되돌린다. 이렇게 해야 "seen_transition_id가 null"이라는,
 * 앱이 별도로 다루는 의미(첫 도입 미확인 벽 - null이면 첫 스냅샷 시점에 본 것으로 간주하는
 * isFirstBoot/alertWatermark 재사용 규칙)가 DB를 오가는 동안 숫자로 오염되지 않는다.
 */
export async function markSeenAtLeast(
  db: D1Database,
  sessionKey: string,
  transitionId: number | null,
): Promise<number | null> {
  const row = await db
    .prepare(
      `INSERT INTO dashboard_seen (session_key, seen_transition_id)
       VALUES (?, ?)
       ON CONFLICT(session_key) DO UPDATE SET
         seen_transition_id = NULLIF(
           MAX(COALESCE(excluded.seen_transition_id, -1), COALESCE(dashboard_seen.seen_transition_id, -1)),
           -1
         )
       RETURNING seen_transition_id`,
    )
    .bind(sessionKey, transitionId)
    .first<{ seen_transition_id: number | null }>();
  return row?.seen_transition_id ?? null;
}
