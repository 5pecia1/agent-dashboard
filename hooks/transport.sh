# Shared by all hook adapters after loading their environment and STATE_DIR.
dashboard_hook_enabled() {
  [ -n "${MY_DASHBOARD_URL:-}" ] || return 1
  if [ "${MY_DASHBOARD_AUTH:-}" = device ]; then
    [ ! -f "$STATE_DIR/collection-disabled" ]
  else
    [ -n "${MY_DASHBOARD_TOKEN:-}" ]
  fi
}

dashboard_send_payload() {
  if [ "${MY_DASHBOARD_AUTH:-}" = device ]; then
    printf '%s' "$1" | python3 "$(dirname "${BASH_SOURCE[0]}")/device-auth.py" send --server "$MY_DASHBOARD_URL" 2>/dev/null
  else
    curl -sS --max-time "$CURL_MAX_TIME" -o /dev/null -w '%{http_code}' \
      -X POST "${MY_DASHBOARD_URL%/}/dashboard/events" \
      -H "Authorization: Bearer $MY_DASHBOARD_TOKEN" \
      -H "Content-Type: application/json" --data-raw "$1" 2>/dev/null
  fi
}
