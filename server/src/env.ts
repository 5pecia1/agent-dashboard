/** Bindings supplied by the host Worker. All credentials belong to its deployment. */
export interface DashboardEnv {
  DB: D1Database;
  /** Compatibility token accepted for both ingestion and client operations. */
  AUTH_TOKEN?: string;
  /** Event ingestion and the non-mutating ingestion credential check only. */
  INGEST_TOKEN?: string;
  /** Read, device registration, and client actions; cannot ingest events. */
  CLIENT_TOKEN?: string;
  /** Comma-separated origins, for example https://dashboard.example,http://localhost:8080. */
  ALLOWED_ORIGINS?: string;
  DASHBOARD_STALE_MS?: string;
  DASHBOARD_STALL_MS?: string;
  /** Explicit "1" permits message and original payload retention; default is normalized metadata only. */
  DASHBOARD_STORE_MESSAGE?: string;
  FCM_SERVICE_ACCOUNT?: string;
  FIREBASE_WEB_CONFIG?: string;
  FIREBASE_APPLE_CONFIG?: string;
  FCM_WEB_VAPID_KEY?: string;
  /** Optional endpoint overrides for isolated transport tests. */
  FCM_TOKEN_URI?: string;
  FCM_BASE_URL?: string;
  DASHBOARD_APP_ORIGIN?: string;
  DASHBOARD_RETAIN_EVENT_DAYS?: string;
  DASHBOARD_RETAIN_SESSION_DAYS?: string;
  DASHBOARD_RETAIN_TRANSITION_DAYS?: string;
  DASHBOARD_RETAIN_PUSH_LOG_DAYS?: string;
}

/** Internal compatibility alias; the public binding type is DashboardEnv. */
export type Env = DashboardEnv;
