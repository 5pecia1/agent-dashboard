ALTER TABLE dashboard_events ADD COLUMN prompt_id TEXT;
ALTER TABLE dashboard_events ADD COLUMN tool_use_id TEXT;
ALTER TABLE dashboard_events ADD COLUMN tool_name TEXT;
ALTER TABLE dashboard_sessions ADD COLUMN input_state TEXT;
ALTER TABLE dashboard_sessions ADD COLUMN projection_token TEXT;
