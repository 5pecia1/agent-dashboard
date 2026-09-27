-- dashboard v3: occurred_at이 "명시적으로" 왔는지를 raw 재파싱 없이 직접 기록한다.
--
-- 배경(검증 리뷰 지적, high): B(heartbeat.ts의 resolveHeartbeatPromotion) 가드3은
-- "occurred_at이 페이로드에 명시됐는가"를 요구한다. routes.ts(실시간 수집)는 요청 본문에서
-- 직접 그 값을 읽어 알 수 있지만, rebuild.ts(재생)는 dashboard_events에 그 자체를 남기는
-- 컬럼이 없어 기존에는 저장된 raw 문자열을 다시 JSON.parse해서 복원했다. 그런데 raw는
-- RAW_MAX_BYTES(4096바이트)로 잘려 저장되고, 훅이 실어 보내는 원본 stdin(agent-event-hook.sh의
-- raw 필드, 그 자체가 이미 최대 4096바이트)까지 포함한 요청 본문은 흔히 4096바이트를 넘는다
-- (PostToolUse는 tool_response를 포함해 특히 크다 - 승격 판정이 걸리는 바로 그 이벤트다).
-- 그 결과 저장된 raw는 문자열 중간에서 잘린 깨진 JSON이 되어 JSON.parse가 항상 실패하고,
-- rebuild는 실시간 수집이 승격한 이벤트를 승격하지 못했다(A != B).
--
-- occurred_at_provided: 이 이벤트의 요청 본문에 occurred_at이 숫자로 명시됐으면 1, 서버
-- 수신 시각으로 대체됐으면 0. routes.ts가 삽입 시점에 직접 채운다 - raw 크기와 무관하게
-- 항상 정확하다. 이 마이그레이션 이전 행은 NULL(알 수 없음) - rebuild.ts는 NULL을 0(보수적
-- 기본값, 기존 "복원 실패 시 승격 막음" 원칙과 동일)으로 취급한다.
ALTER TABLE dashboard_events ADD COLUMN occurred_at_provided INTEGER;

-- Opus escalation 판정 E: 순서 판정(역행 방어·승격 가드)은 같은 세션 = 같은 기계 시계라
-- occurred_at 원본이 자기 일관적이므로 서버가 미래로 클램프하던 보정을 없앤다(clampOccurredAt
-- 삭제). 그런데 stalled 판정만은 서버 시계끼리 비교해야 한다(클라이언트 시계가 느리면 살아있는
-- 세션이 즉시 stalled로, 빠르면 죽은 세션이 영영 stalled 아님으로 보이는 비대칭 구멍) - 그래서
-- occurred_at과는 별개로 "서버가 진척 신호를 받은 시각"만 담는 컬럼을 신설한다.
--
-- last_progress_at: 서버 수신 시각(epoch ms). 상태를 바꾼 이벤트와 heartbeat_events만 이 값을
-- now로 민다 - 기록만 되는 이벤트(A안 원칙: 유휴 알림 등)는 밀지 않는다. maintenance.ts의
-- stalled 후보 판정이 last_occurred_at 대신 이 컬럼을 본다.
-- 백필: 이 마이그레이션 이전 행은 updated_at으로 채운다 - 그 시점까지의 마지막 프로젝션
-- 갱신이 곧 서버가 마지막으로 무언가를 받은 시각이었기 때문이다(당시엔 진척/기록-전용 구분이
-- 없었으므로 근사값이다 - 과거 행에 대한 합리적 기본값이지 사후 재구성이 아니다).
ALTER TABLE dashboard_sessions ADD COLUMN last_progress_at INTEGER;
UPDATE dashboard_sessions SET last_progress_at = updated_at WHERE last_progress_at IS NULL;
