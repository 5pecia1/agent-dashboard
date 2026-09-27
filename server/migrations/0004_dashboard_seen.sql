-- dashboard v4: 읽음/안읽음(seen) 추적을 상태 모델 밖에 별도로 둔다.
--
-- 목적: 상태가 변한 카드 중 사용자가 이미 열어본 것을 구분한다. 이것은 상태 전이가 아니고
-- (dashboard_transitions에 줄을 남기지 않는다), push에도 영향을 주지 않는다(push는 전이
-- 시점에 고정되는 힌트이고 소급 불변이다 - protocol.v1.json에 명문화된 두 불변식 참고).
--
-- 기준은 시각이 아니라 전이 id다(Opus escalation 판정 E와 무긴장 - 시계 개입이 전혀 없다):
--   미확인 = dashboard_sessions.last_transition_id > dashboard_seen.seen_transition_id
-- (둘 중 하나가 NULL이면, 즉 아직 전이가 없었거나 아직 한 번도 seen을 호출한 적이 없으면
-- 앱이 별도 규칙으로 다룬다 - 서버는 두 정수를 그대로 내려줄 뿐 "미확인" 여부를 계산해
-- 내려주지 않는다.)
--
-- last_transition_id: 이 세션에 대해 dashboard_transitions에 마지막으로 적재된 행의 id.
-- transitions.ts의 appendTransition이 RETURNING으로 새 id를 받는 바로 그 자리에서 기록한다
-- (관련 판정·근거는 transitions.ts 참고). 전이가 한 번도 없던 세션은 NULL이 허용된다.
--
-- 백필: 이 마이그레이션 이전 세션들은 세션별 dashboard_transitions의 MAX(id)로 채운다.
-- 전이가 없던 세션(예: 첫 이벤트가 idle로만 남고 아직 상태가 바뀐 적 없는 경우)은
-- 서브쿼리가 NULL을 돌려주므로 자연히 NULL로 남는다 - 명시적으로 허용된 값이다.
ALTER TABLE dashboard_sessions ADD COLUMN last_transition_id INTEGER;
UPDATE dashboard_sessions
   SET last_transition_id = (
     SELECT MAX(t.id) FROM dashboard_transitions t WHERE t.session_key = dashboard_sessions.key
   )
 WHERE last_transition_id IS NULL;

-- dashboard_seen: 세션별로 "마지막으로 확인 처리된 전이 id" 딱 하나만 담는 마커 테이블.
-- 이벤트 로그가 아니다 - POST /dashboard/sessions/:key/seen은 dashboard_events에 아무것도
-- 남기지 않는다(예약 이벤트 이름도 필요 없다. 애초에 로그에 적재되는 게 없기 때문이다).
--
-- 멀티 기기 단조 갱신: 여러 기기가 같은 세션을 동시에 보고 있을 때, 뒤처진 기기가 나중에
-- 보내는 (오래된) seen 값이 앞선 기기가 이미 올려둔 값을 역행시키면 안 된다. 그래서 갱신은
-- 항상 INSERT ... ON CONFLICT(session_key) DO UPDATE SET seen_transition_id = MAX(...)
-- 형태로만 한다(seen.ts 참고) - 이 테이블에 직접 UPDATE로 값을 낮추는 코드가 있으면 안 된다.
--
-- rebuild.ts는 이 테이블을 절대 건드리지 않는다(불가침) - 재생은 이벤트 로그로부터
-- dashboard_sessions/dashboard_transitions만 처음부터 다시 만들 뿐, 사람이 실제로 무엇을
-- 열어봤는지에 대한 기록인 이 테이블을 지우거나 되돌릴 근거가 없다(재생이 열람 기록을
-- 지우면 안 된다는 계약 명문화 참고).
CREATE TABLE dashboard_seen (
  session_key TEXT PRIMARY KEY,   -- "<source>:<session_id>". dashboard_sessions.key와 같은 값.
  seen_transition_id INTEGER      -- 사용자가 마지막으로 확인 처리한 전이 id. 아직 한 번도 seen을 호출한 적 없으면 행 자체가 없다.
);
