export const DEFAULT_HISTORY_LIMIT = 200;
export const MAX_HISTORY_LIMIT = 1000;

export interface HistoryQuery {
  sessionKey?: string;
  limit: number;
  beforeId?: number;
  promptsOnly: boolean;
}

export interface HistoryEvent {
  id: number;
  session_key: string;
  source: string;
  event: string;
  message: string | null;
  display_title: string | null;
  received_at: number;
}

export function parseHistoryQuery(query: Record<string, string>): HistoryQuery {
  const rawLimit = query.limit;
  const parsedLimit = rawLimit === undefined ? DEFAULT_HISTORY_LIMIT : Number(rawLimit);
  const limit =
    Number.isSafeInteger(parsedLimit) && parsedLimit > 0
      ? Math.min(parsedLimit, MAX_HISTORY_LIMIT)
      : DEFAULT_HISTORY_LIMIT;
  const beforeId = query.before_id === undefined ? undefined : Number(query.before_id);
  if (beforeId !== undefined && (!Number.isSafeInteger(beforeId) || beforeId <= 0)) {
    throw new Error("invalid before_id");
  }
  if (query.kind !== undefined && query.kind !== "all" && query.kind !== "prompts") {
    throw new Error("invalid kind");
  }
  return {
    sessionKey: query.session_key || undefined,
    limit,
    beforeId,
    promptsOnly: query.kind === "prompts",
  };
}

export async function readHistory(db: D1Database, query: HistoryQuery) {
  const conditions: string[] = [];
  const bindings: (string | number)[] = [];
  if (query.sessionKey) {
    conditions.push("session_key = ?");
    bindings.push(query.sessionKey);
  }
  if (query.beforeId !== undefined) {
    conditions.push("id < ?");
    bindings.push(query.beforeId);
  }
  if (query.promptsOnly) conditions.push("event = 'UserPromptSubmit'");
  const where = conditions.length ? `WHERE ${conditions.join(" AND ")}` : "";
  const { results } = await db
    .prepare(
      `SELECT id, session_key, source, event, message, display_title, received_at FROM dashboard_events ${where} ORDER BY id DESC LIMIT ?`,
    )
    .bind(...bindings, query.limit + 1)
    .all<HistoryEvent>();
  const rows = results ?? [];
  const hasMore = rows.length > query.limit;
  const events = rows.slice(0, query.limit);
  return { events, has_more: hasMore, next_before_id: hasMore ? events[events.length - 1]!.id : null };
}
