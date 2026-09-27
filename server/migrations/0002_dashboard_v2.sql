-- dashboard v2: append-only 이벤트 로그 -> 프로젝션 -> 전이 로그(커서) 구조로 넓힌다.
-- 어휘와 필드 의미의 정본은 src/features/dashboard/protocol.v1.json (repo 루트 contracts/의 사본).
-- 0001의 테이블은 지우지 않고 컬럼만 더한다. 기존 행은 아래 backfill로 새 컬럼을 채운다.

-- ── dashboard_events: 원본 보존 + 멱등 + 발생 시각 ────────────────────────────
-- event_id: hook이 만드는 멱등 키(UUIDv4 권장). 스풀 재전송이 상태를 흔들지 않게 한다.
ALTER TABLE dashboard_events ADD COLUMN event_id TEXT;
-- occurred_at: 이벤트가 "발생한" 시각(epoch ms, 클라이언트 시계). received_at은 수신 시각이라 별개다.
ALTER TABLE dashboard_events ADD COLUMN occurred_at INTEGER;
-- host: 이벤트를 낸 기계의 hostname. 알림 제목에 들어간다.
ALTER TABLE dashboard_events ADD COLUMN host TEXT;
-- raw: 수신 본문 원문을 4096바이트로 잘라 보존한다. 프로젝션이 놓친 정보를 나중에 다시 읽기 위한 원본.
ALTER TABLE dashboard_events ADD COLUMN raw TEXT;

-- event_id가 있는 행만 유일해야 한다. 옛 행과 event_id 없는 요청은 NULL이라 제약을 타지 않는다.
CREATE UNIQUE INDEX idx_dashboard_events_event_id
  ON dashboard_events (event_id) WHERE event_id IS NOT NULL;

-- 세션 상세 화면은 발생 시각 순으로 읽는다.
CREATE INDEX idx_dashboard_events_occurred
  ON dashboard_events (session_key, occurred_at DESC);

-- 보존 정리(기본 14일)가 훑는 축.
CREATE INDEX idx_dashboard_events_received ON dashboard_events (received_at);

-- backfill: 0001 시절 행은 발생 시각을 모른다. 수신 시각으로 대신한다.
UPDATE dashboard_events SET occurred_at = received_at WHERE occurred_at IS NULL;

-- ── dashboard_sessions: 프로젝션에 host와 마지막 발생 시각 ────────────────────
-- host: 세션이 도는 기계. 같은 프로젝트가 여러 기계에 열려 있을 때 구분한다.
ALTER TABLE dashboard_sessions ADD COLUMN host TEXT;
-- last_occurred_at: 마지막으로 반영된 이벤트의 occurred_at. stalled 판정과 순서 역행 방어의 기준값.
ALTER TABLE dashboard_sessions ADD COLUMN last_occurred_at INTEGER;

-- cron이 "working인데 조용한" 세션만 골라내는 축.
CREATE INDEX idx_dashboard_sessions_state ON dashboard_sessions (state, last_occurred_at);

UPDATE dashboard_sessions SET last_occurred_at = updated_at WHERE last_occurred_at IS NULL;

-- ── dashboard_transitions: 상태 전이 로그. id가 곧 sync 커서다 ────────────────
-- 상태가 실제로 바뀔 때만 한 줄 쌓인다. 같은 상태 재진입은 전이가 아니다.
CREATE TABLE dashboard_transitions (
  id INTEGER PRIMARY KEY AUTOINCREMENT, -- 단조 증가 커서. GET /dashboard/sync?since=<id>가 이 값을 쓴다.
  session_key TEXT NOT NULL,            -- "<source>:<session_id>"
  from_state TEXT,                      -- 직전 상태. 세션의 첫 전이면 NULL.
  to_state TEXT NOT NULL,               -- idle|working|waiting_input|done|ended|stalled
  source TEXT NOT NULL,                 -- claude-code | codex | generic
  project TEXT,                         -- 전이 당시 cwd
  host TEXT,                            -- 전이 당시 기계 이름
  message TEXT,                         -- 전이를 만든 이벤트의 message (300자 이내, 저장 끌 수 있음)
  occurred_at INTEGER NOT NULL,         -- 이벤트 발생 시각(epoch ms)
  created_at INTEGER NOT NULL,          -- 전이 기록 시각(서버 시각, epoch ms)
  notified_at INTEGER                   -- push를 실제로 시도한 시각. NULL이면 아직 안 보냈다.
);

-- 세션 상세: 이 세션의 최근 전이.
CREATE INDEX idx_dashboard_transitions_session ON dashboard_transitions (session_key, id DESC);
-- 보존 정리(기본 30일)가 훑는 축.
CREATE INDEX idx_dashboard_transitions_created ON dashboard_transitions (created_at);
-- 아직 안 보낸 전이만 훑는 축(부분 인덱스).
CREATE INDEX idx_dashboard_transitions_pending
  ON dashboard_transitions (id) WHERE notified_at IS NULL;

-- ── dashboard_meta: 서버가 스스로 쓰는 내부 상태 ───────────────────────────────
-- 사람이 바꾸는 값은 dashboard_settings에 둔다. 둘을 섞지 않는다.
CREATE TABLE dashboard_meta (
  key TEXT PRIMARY KEY,
  value TEXT
);
-- pruned_below_id: 보존 정리로 사라진 전이의 경계. since가 이 값보다 작으면 sync가 reset:true를 준다.
INSERT OR IGNORE INTO dashboard_meta (key, value) VALUES ('pruned_below_id', '0');
-- protocol_version: 이 DB가 담고 있는 프로토콜 major. contract_check가 정본과 대조한다.
INSERT OR IGNORE INTO dashboard_meta (key, value) VALUES ('protocol_version', '1');

-- ── dashboard_settings: 사람이 바꾸는 설정 ─────────────────────────────────────
CREATE TABLE dashboard_settings (
  key TEXT PRIMARY KEY,
  value TEXT
);
-- mute_until: 이 시각(epoch ms)까지 push를 건너뛴다. 음소거 중에도 전이 적재는 계속된다. '0'이면 음소거 아님.
INSERT OR IGNORE INTO dashboard_settings (key, value) VALUES ('mute_until', '0');

-- ── dashboard_push_subscriptions: 표준 Web Push 구독 ──────────────────────────
-- RFC 8291 aes128gcm 본문 암호화에 필요한 키를 구독별로 보관한다.
CREATE TABLE dashboard_push_subscriptions (
  endpoint TEXT PRIMARY KEY,             -- 브라우저가 준 push 서비스 endpoint URL
  p256dh TEXT NOT NULL,                  -- 구독의 공개키 (base64url)
  auth TEXT NOT NULL,                    -- 구독의 auth secret (base64url)
  ua TEXT,                               -- 등록 당시 User-Agent (기기 구분용)
  label TEXT,                            -- 사람이 붙이는 이름 ("맥북 크롬")
  enabled INTEGER NOT NULL DEFAULT 1,    -- 0이면 발송 대상에서 뺀다(구독은 남긴다)
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,         -- 클라이언트가 마지막으로 자기 구독을 갱신한 시각
  failure_count INTEGER NOT NULL DEFAULT 0, -- 연속 실패 횟수. 임계값을 넘으면 enabled=0.
  last_error TEXT,                       -- 마지막 실패 요약 (상태코드 + 짧은 본문)
  last_error_at INTEGER
);
CREATE INDEX idx_dashboard_push_subscriptions_enabled
  ON dashboard_push_subscriptions (enabled);

-- ── dashboard_devices 확장: FCM 기기도 같은 어휘로 다룬다 ──────────────────────
-- transport: 이 행이 어느 채널의 대상인지. 0001의 행은 전부 fcm이다.
ALTER TABLE dashboard_devices ADD COLUMN transport TEXT NOT NULL DEFAULT 'fcm';
-- label: 사람이 붙이는 이름.
ALTER TABLE dashboard_devices ADD COLUMN label TEXT;
-- enabled: 0이면 발송 대상에서 뺀다.
ALTER TABLE dashboard_devices ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1;
ALTER TABLE dashboard_devices ADD COLUMN failure_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE dashboard_devices ADD COLUMN last_error TEXT;
ALTER TABLE dashboard_devices ADD COLUMN last_error_at INTEGER;
CREATE INDEX idx_dashboard_devices_enabled ON dashboard_devices (enabled, transport);

-- ── dashboard_push_log: 전이별 발송 결과 감사 로그 ────────────────────────────
-- "왜 알림이 안 왔나"를 나중에 답할 수 있게 남긴다. dispatch.ts가 채널과 무관하게 여기에 쓴다.
CREATE TABLE dashboard_push_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  transition_id INTEGER,                 -- 어떤 전이 때문인지. 수동 test-push는 NULL.
  transport TEXT NOT NULL,               -- web-push | fcm
  target TEXT,                           -- 대상 식별자(endpoint 또는 토큰 요약). 전체 묶음이면 'all'.
  result TEXT NOT NULL,                  -- sent | skipped | muted | failed | no_target
  detail TEXT,                           -- 결과 요약(JSON 문자열 또는 오류 메시지)
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_dashboard_push_log_transition ON dashboard_push_log (transition_id);
CREATE INDEX idx_dashboard_push_log_created ON dashboard_push_log (created_at);
