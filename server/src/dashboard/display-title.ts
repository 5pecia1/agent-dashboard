export const DISPLAY_TITLE_MAX_CHARS = 120;

export function normalizeDisplayTitle(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const text = value.replace(/\s+/gu, " ").replace(/[\p{Cc}\p{Cf}]/gu, "").trim();
  return Array.from(text).slice(0, DISPLAY_TITLE_MAX_CHARS).join("") || null;
}
