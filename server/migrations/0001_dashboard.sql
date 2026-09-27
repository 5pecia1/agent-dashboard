-- dashboard feature: 코딩 에이전트 세션 상태와 이벤트, 푸시 대상 기기를 저장한다.
-- 테이블 이름은 feature 이름을 접두어로 붙인다 (my-server는 여러 기능을 담는 그릇이므로).

CREATE TABLE dashboard_sessions (
  key TEXT PRIMARY KEY,          -- "<source>:<session_id>"
  source TEXT NOT NULL,          -- claude-code | codex
  session_id TEXT NOT NULL,
  project TEXT NOT NULL,         -- 세션의 cwd
  state TEXT NOT NULL,           -- idle | working | waiting_input | done | ended
  last_event TEXT NOT NULL,
  last_message TEXT,
  created_at INTEGER NOT NULL,   -- epoch ms
  updated_at INTEGER NOT NULL
);

CREATE TABLE dashboard_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_key TEXT NOT NULL,
  source TEXT NOT NULL,
  event TEXT NOT NULL,
  message TEXT,
  received_at INTEGER NOT NULL
);
CREATE INDEX idx_dashboard_events_session ON dashboard_events (session_key, received_at DESC);

CREATE TABLE dashboard_devices (
  token TEXT PRIMARY KEY,        -- FCM 등록 토큰
  platform TEXT NOT NULL,        -- android | web | ...
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL
);
