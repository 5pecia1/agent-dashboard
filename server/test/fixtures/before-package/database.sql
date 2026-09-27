CREATE TABLE "d1_migrations"(
		id         INTEGER PRIMARY KEY AUTOINCREMENT,
		name       TEXT UNIQUE,
		applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);
INSERT INTO "d1_migrations" VALUES(1,'0001_dashboard.sql','2026-09-27 08:09:15');
INSERT INTO "d1_migrations" VALUES(2,'0002_dashboard_v2.sql','2026-09-27 08:09:15');
INSERT INTO "d1_migrations" VALUES(3,'0003_dashboard_v3.sql','2026-09-27 08:09:16');
INSERT INTO "d1_migrations" VALUES(4,'0004_dashboard_seen.sql','2026-09-27 08:09:17');
INSERT INTO "d1_migrations" VALUES(5,'0005_devin_input_tracking.sql','2026-09-27 08:09:18');
CREATE TABLE dashboard_devices (
  token TEXT PRIMARY KEY,        
  platform TEXT NOT NULL,        
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL
, transport TEXT NOT NULL DEFAULT 'fcm', label TEXT, enabled INTEGER NOT NULL DEFAULT 1, failure_count INTEGER NOT NULL DEFAULT 0, last_error TEXT, last_error_at INTEGER);
INSERT INTO "dashboard_devices" VALUES('fixture-fcm-token','web',1790496564274,1790496564274,'fcm','fixture browser',1,0,NULL,NULL);
CREATE TABLE dashboard_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_key TEXT NOT NULL,
  source TEXT NOT NULL,
  event TEXT NOT NULL,
  message TEXT,
  received_at INTEGER NOT NULL
, event_id TEXT, occurred_at INTEGER, host TEXT, raw TEXT, occurred_at_provided INTEGER, prompt_id TEXT, tool_use_id TEXT, tool_name TEXT);
INSERT INTO "dashboard_events" VALUES(1,'generic:upgrade-working','generic','Status',NULL,1790496563627,'upgrade-0',1790496563620,'fixture-host','{"protocol_version":1,"project":"/workspace/example","host":"fixture-host","hook_rev":"1234abcd","event_id":"upgrade-0","occurred_at":1790496563620,"source":"generic","session_id":"upgrade-working","state":"working","event":"Status"}',1,NULL,NULL,NULL);
INSERT INTO "dashboard_events" VALUES(2,'generic:upgrade-waiting','generic','Status',NULL,1790496563646,'upgrade-1',1790496563621,'fixture-host','{"protocol_version":1,"project":"/workspace/example","host":"fixture-host","hook_rev":"1234abcd","event_id":"upgrade-1","occurred_at":1790496563621,"source":"generic","session_id":"upgrade-waiting","state":"waiting_input","event":"Status"}',1,NULL,NULL,NULL);
INSERT INTO "dashboard_events" VALUES(3,'generic:upgrade-ended','generic','Status',NULL,1790496563667,'upgrade-2',1790496563622,'fixture-host','{"protocol_version":1,"project":"/workspace/example","host":"fixture-host","hook_rev":"1234abcd","event_id":"upgrade-2","occurred_at":1790496563622,"source":"generic","session_id":"upgrade-ended","state":"ended","event":"Status"}',1,NULL,NULL,NULL);
INSERT INTO "dashboard_events" VALUES(4,'devin:upgrade-devin','devin','UserPromptSubmit',NULL,1790496564007,'upgrade-3',1790496563623,'fixture-host','{"protocol_version":1,"project":"/workspace/example","host":"fixture-host","hook_rev":"1234abcd","event_id":"upgrade-3","occurred_at":1790496563623,"source":"devin","session_id":"upgrade-devin","event":"UserPromptSubmit","prompt_id":"prompt-fixture"}',1,'prompt-fixture',NULL,NULL);
INSERT INTO "dashboard_events" VALUES(5,'devin:upgrade-devin','devin','PermissionRequest',NULL,1790496564020,'upgrade-4',1790496563624,'fixture-host','{"protocol_version":1,"project":"/workspace/example","host":"fixture-host","hook_rev":"1234abcd","event_id":"upgrade-4","occurred_at":1790496563624,"source":"devin","session_id":"upgrade-devin","event":"PermissionRequest","prompt_id":"prompt-fixture","tool_use_id":"tool-a","tool_name":"exec"}',1,'prompt-fixture','tool-a','exec');
INSERT INTO "dashboard_events" VALUES(6,'devin:upgrade-devin','devin','PermissionRequest',NULL,1790496564035,'upgrade-5',1790496563625,'fixture-host','{"protocol_version":1,"project":"/workspace/example","host":"fixture-host","hook_rev":"1234abcd","event_id":"upgrade-5","occurred_at":1790496563625,"source":"devin","session_id":"upgrade-devin","event":"PermissionRequest","prompt_id":"prompt-fixture","tool_use_id":"tool-b","tool_name":"exec"}',1,'prompt-fixture','tool-b','exec');
CREATE TABLE dashboard_meta (
  key TEXT PRIMARY KEY,
  value TEXT
);
INSERT INTO "dashboard_meta" VALUES('pruned_below_id','0');
INSERT INTO "dashboard_meta" VALUES('protocol_version','1');
INSERT INTO "dashboard_meta" VALUES('hook_revs','{"fixture-host":{"rev":"1234abcd","at":1790496563620.0,"project":"/workspace/example"}}');
CREATE TABLE dashboard_push_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  transition_id INTEGER,                 
  transport TEXT NOT NULL,               
  target TEXT,                           
  result TEXT NOT NULL,                  
  detail TEXT,                           
  created_at INTEGER NOT NULL
);
INSERT INTO "dashboard_push_log" VALUES(1,2,'fcm','all','skipped','FCM_SERVICE_ACCOUNT 미설정',1790496563655);
INSERT INTO "dashboard_push_log" VALUES(2,5,'fcm','all','skipped','FCM_SERVICE_ACCOUNT 미설정',1790496564026);
CREATE TABLE dashboard_push_subscriptions (
  endpoint TEXT PRIMARY KEY,             
  p256dh TEXT NOT NULL,                  
  auth TEXT NOT NULL,                    
  ua TEXT,                               
  label TEXT,                            
  enabled INTEGER NOT NULL DEFAULT 1,    
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,         
  failure_count INTEGER NOT NULL DEFAULT 0, 
  last_error TEXT,                       
  last_error_at INTEGER
);
CREATE TABLE dashboard_seen (
  session_key TEXT PRIMARY KEY,   
  seen_transition_id INTEGER      
);
INSERT INTO "dashboard_seen" VALUES('generic:upgrade-waiting',2);
CREATE TABLE dashboard_sessions (
  key TEXT PRIMARY KEY,          
  source TEXT NOT NULL,          
  session_id TEXT NOT NULL,
  project TEXT NOT NULL,         
  state TEXT NOT NULL,           
  last_event TEXT NOT NULL,
  last_message TEXT,
  created_at INTEGER NOT NULL,   
  updated_at INTEGER NOT NULL
, host TEXT, last_occurred_at INTEGER, last_progress_at INTEGER, last_transition_id INTEGER, input_state TEXT, projection_token TEXT);
INSERT INTO "dashboard_sessions" VALUES('generic:upgrade-working','generic','upgrade-working','/workspace/example','working','Status',NULL,1790496563627,1790496563627,'fixture-host',1790496563620,1790496563627,1,NULL,'c8644452-657e-41a8-94f2-4fede3c3cdcd');
INSERT INTO "dashboard_sessions" VALUES('generic:upgrade-waiting','generic','upgrade-waiting','/workspace/example','waiting_input','Status',NULL,1790496563646,1790496563646,'fixture-host',1790496563621,1790496563646,2,NULL,'5820a4b6-dd5c-4f1f-92ab-589f72e6cf75');
INSERT INTO "dashboard_sessions" VALUES('generic:upgrade-ended','generic','upgrade-ended','/workspace/example','ended','Status',NULL,1790496563667,1790496563667,'fixture-host',1790496563622,1790496563667,3,NULL,'485dd485-0692-49d0-9543-270059177c8f');
INSERT INTO "dashboard_sessions" VALUES('devin:upgrade-devin','devin','upgrade-devin','/workspace/example','waiting_input','PermissionRequest',NULL,1790496564007,1790496564035,'fixture-host',1790496563625,1790496564035,5,'{"prompt_id":"prompt-fixture","pending":[{"tool_use_id":"tool-a","tool_name":"exec"},{"tool_use_id":"tool-b","tool_name":"exec"}],"untracked":false}','fa0fb801-e355-43e0-ae0a-7bf65b47cb5a');
CREATE TABLE dashboard_settings (
  key TEXT PRIMARY KEY,
  value TEXT
);
INSERT INTO "dashboard_settings" VALUES('mute_until','1790500164087');
INSERT INTO "dashboard_settings" VALUES('ui_lang','ko');
CREATE TABLE dashboard_transitions (
  id INTEGER PRIMARY KEY AUTOINCREMENT, 
  session_key TEXT NOT NULL,            
  from_state TEXT,                      
  to_state TEXT NOT NULL,               
  source TEXT NOT NULL,                 
  project TEXT,                         
  host TEXT,                            
  message TEXT,                         
  occurred_at INTEGER NOT NULL,         
  created_at INTEGER NOT NULL,          
  notified_at INTEGER                   
);
INSERT INTO "dashboard_transitions" VALUES(1,'generic:upgrade-working',NULL,'working','generic','/workspace/example','fixture-host',NULL,1790496563620,1790496563627,NULL);
INSERT INTO "dashboard_transitions" VALUES(2,'generic:upgrade-waiting',NULL,'waiting_input','generic','/workspace/example','fixture-host',NULL,1790496563621,1790496563646,1790496563655);
INSERT INTO "dashboard_transitions" VALUES(3,'generic:upgrade-ended',NULL,'ended','generic','/workspace/example','fixture-host',NULL,1790496563622,1790496563667,NULL);
INSERT INTO "dashboard_transitions" VALUES(4,'devin:upgrade-devin',NULL,'working','devin','/workspace/example','fixture-host',NULL,1790496563623,1790496564007,NULL);
INSERT INTO "dashboard_transitions" VALUES(5,'devin:upgrade-devin','working','waiting_input','devin','/workspace/example','fixture-host',NULL,1790496563624,1790496564020,1790496564026);
CREATE INDEX idx_dashboard_events_session ON dashboard_events (session_key, received_at DESC);
CREATE UNIQUE INDEX idx_dashboard_events_event_id
  ON dashboard_events (event_id) WHERE event_id IS NOT NULL;
CREATE INDEX idx_dashboard_events_occurred
  ON dashboard_events (session_key, occurred_at DESC);
CREATE INDEX idx_dashboard_events_received ON dashboard_events (received_at);
CREATE INDEX idx_dashboard_sessions_state ON dashboard_sessions (state, last_occurred_at);
CREATE INDEX idx_dashboard_transitions_session ON dashboard_transitions (session_key, id DESC);
CREATE INDEX idx_dashboard_transitions_created ON dashboard_transitions (created_at);
CREATE INDEX idx_dashboard_transitions_pending
  ON dashboard_transitions (id) WHERE notified_at IS NULL;
CREATE INDEX idx_dashboard_push_subscriptions_enabled
  ON dashboard_push_subscriptions (enabled);
CREATE INDEX idx_dashboard_devices_enabled ON dashboard_devices (enabled, transport);
CREATE INDEX idx_dashboard_push_log_transition ON dashboard_push_log (transition_id);
CREATE INDEX idx_dashboard_push_log_created ON dashboard_push_log (created_at);
DELETE FROM "sqlite_sequence";
INSERT INTO "sqlite_sequence" VALUES('d1_migrations',5);
INSERT INTO "sqlite_sequence" VALUES('dashboard_events',6);
INSERT INTO "sqlite_sequence" VALUES('dashboard_transitions',5);
INSERT INTO "sqlite_sequence" VALUES('dashboard_push_log',2);
