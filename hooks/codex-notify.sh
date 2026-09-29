#!/usr/bin/env bash
# Codex `notify` 설정용 fallback. 네이티브 hooks(codex-hooks.toml)를 쓸 수 없는 환경에서만 쓴다.
# notify는 JSON을 stdin이 아니라 "마지막 인자"로 전달하고, 키가 kebab-case다.
# 이벤트는 agent-turn-complete 하나뿐이므로 "실행 마침"만 잡을 수 있다.
#
# agent-event-hook.sh와 payload 스키마(event_id/occurred_at/protocol_version/host/raw)와
# 스풀 로직을 그대로 공유한다 - notify 인자 파싱만 다르다.
# 스풀 락을 이 프로세스가 쥐고 있으면(LOCK_OWNED=1) 종료할 때 푼다. TERM·INT·HUP도 exit 0으로
# 돌려 이 trap을 거치게 한다 - 락을 쥔 채 죽으면 30초 동안 다음 hook들이 락 대기로 지연된다.
# SIGKILL은 trap이 못 막으므로 아래 stale 락 정리(LOCK_STALE_SECONDS)가 그 안전망이다.
LOCK_OWNED=0
trap '[ "${LOCK_OWNED:-0}" = 1 ] && rmdir "$LOCK_DIR" 2>/dev/null; exit 0' EXIT
trap 'exit 0' TERM INT HUP

# 설정 우선순위: 환경변수 > env 파일 > 기본값. `.`(source)는 같은 이름의 변수를
# 무조건 덮어쓰므로, 호출 시점에 이미 있던 MY_DASHBOARD_* 환경변수를 통째로 담아 두고
# 소싱 뒤에 되돌린다 — 파일은 환경이 비워 둔 키만 채우게 된다. export -p 출력은 셸이
# 스스로 이스케이프한 `declare -x KEY="value"` 행이라 그대로 eval해도 안전하다.
CONFIG_FILE="${MY_DASHBOARD_ENV:-$HOME/.config/my-dashboard/env}"
if [ -f "$CONFIG_FILE" ]; then
  _MD_ENV_SAVE="$(export -p 2>/dev/null | grep '^declare -x MY_DASHBOARD_')"
  # shellcheck disable=SC1090
  . "$CONFIG_FILE" 2>/dev/null
  [ -n "${_MD_ENV_SAVE:-}" ] && eval "$_MD_ENV_SAVE"
  unset _MD_ENV_SAVE
fi

STATE_DIR="${MY_DASHBOARD_STATE_DIR:-$HOME/.local/state/my-dashboard}"
SPOOL_FILE="$STATE_DIR/spool.ndjson"
LOCK_DIR="$STATE_DIR/spool.lock"
SPOOL_MAX_LINES=500
FLUSH_MAX_LINES=50
CURL_MAX_TIME=2
RAW_MAX_BYTES=4096
LOCK_RETRY_MAX=20
LOCK_STALE_SECONDS=30

# 서버가 setup.sh/hooks/files/:name으로 이 스크립트를 내려줄 때 자기 HOOK_REV로 치환하는
# 자리(server/src/hooks/routes.ts) - "훅 구버전 배너" 기능의 원장(dashboard_meta의
# hook_revs, dashboard/sync.ts의 hook_skew)이 이 값과 서버의 현재 rev를 비교해 구버전 훅을
# 쓰는 기계를 찾아낸다. 치환되지 않은 채로(리포에서 직접 실행 등) 남아 있으면 빈 문자열이
# 아니라 플레이스홀더 문자열 그대로 전송된다 - 서버는 그 값을 additive로 저장만 할 뿐 특별
# 취급하지 않으므로 무해하다.
HOOK_REV="__MY_DASHBOARD_HOOK_REV__"

JSON="${!#}"

mkdir -p "$STATE_DIR" 2>/dev/null

epoch_ms() {
  if command -v python3 >/dev/null 2>&1; then
    local out
    out="$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null)"
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  local sec ns
  sec="$(date +%s 2>/dev/null)"
  [ -z "$sec" ] && sec=0
  ns="$(date +%N 2>/dev/null)"
  case "$ns" in
    ''|*[!0-9]*)
      printf '%s000\n' "$sec"
      ;;
    *)
      printf '%s%s\n' "$sec" "${ns:0:3}"
      ;;
  esac
}

# mtime을 초 단위로. Linux(GNU stat)와 macOS(BSD stat) 둘 다 대응.
# GNU stat의 -f는 --file-system이라 `stat -f %m`이 파일시스템 정보를 stdout에 여러 줄 찍고 실패한다.
# 그 출력이 산술식(age=$((now - mtime)))에 들어가면 문법 오류로 stale 락이 영영 안 지워지므로,
# GNU 형식을 먼저 시도하고 어느 쪽이든 숫자만 받아들인다. 못 읽으면 0이다.
file_mtime() {
  local out
  out="$(stat -c %Y "$1" 2>/dev/null)"
  case "$out" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' "$out"; return 0 ;;
  esac
  out="$(stat -f %m "$1" 2>/dev/null)"
  case "$out" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' "$out"; return 0 ;;
  esac
  echo 0
}

acquire_lock() {
  local tries=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge "$LOCK_RETRY_MAX" ]; then
      if [ -d "$LOCK_DIR" ]; then
        local age now mtime
        now="$(date +%s 2>/dev/null || echo 0)"
        mtime="$(file_mtime "$LOCK_DIR")"
        age=$((now - mtime))
        if [ "$age" -ge "$LOCK_STALE_SECONDS" ]; then
          rmdir "$LOCK_DIR" 2>/dev/null
          continue
        fi
      fi
      return 1
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done
  LOCK_OWNED=1
  return 0
}

release_lock() {
  # 이 프로세스가 잡은 락만 푼다 - 남이 잡은 락을 지우면 뮤텍스가 깨진다.
  if [ "$LOCK_OWNED" = 1 ]; then
    rmdir "$LOCK_DIR" 2>/dev/null
    LOCK_OWNED=0
  fi
  return 0
}

trim_spool() {
  [ -f "$SPOOL_FILE" ] || return 0
  acquire_lock || return 0
  local total
  total="$(wc -l < "$SPOOL_FILE" 2>/dev/null | tr -d ' ')"
  [ -z "$total" ] && total=0
  if [ "$total" -gt "$SPOOL_MAX_LINES" ]; then
    local tmp
    tmp="$STATE_DIR/spool.trim.$$"
    tail -n "$SPOOL_MAX_LINES" "$SPOOL_FILE" > "$tmp" 2>/dev/null
    mv -f "$tmp" "$SPOOL_FILE" 2>/dev/null
  fi
  release_lock
}

# 상세 입력은 명시적으로 켠 경우만 전송한다. 별칭은 프로젝트·호스트 메타데이터를 대체한다.
privacy_payload() {
  printf '%s' "$1" | jq -c \
    --arg include_content "${MY_DASHBOARD_INCLUDE_CONTENT:-0}" \
    --arg project "${MY_DASHBOARD_PROJECT_LABEL:-}" \
    --arg host "${MY_DASHBOARD_HOST_LABEL:-}" \
    'if $include_content == "1" then . else .message = null | del(.raw) end
     | if $project != "" then .project = $project else . end
     | if $host != "" then .host = $host else . end' 2>/dev/null
}

append_spool() {
  local payload
  payload="$(privacy_payload "$1")" || return 0
  [ -n "$payload" ] || return 0
  printf '%s\n' "$payload" >> "$SPOOL_FILE" 2>/dev/null
  trim_spool
}

send_payload() {
  local payload
  payload="$(privacy_payload "$1")" || return 1
  [ -n "$payload" ] || return 1
  local url="${MY_DASHBOARD_URL%/}/dashboard/events"
  local code
  code="$(curl -sS --max-time "$CURL_MAX_TIME" -o /dev/null -w '%{http_code}' -X POST "$url" \
    -H "Authorization: Bearer $MY_DASHBOARD_TOKEN" \
    -H "Content-Type: application/json" \
    --data-raw "$payload" 2>/dev/null)"
  case "$code" in
    2??) return 0 ;;
    *) return 1 ;;
  esac
}

flush_spool() {
  [ -f "$SPOOL_FILE" ] || return 0
  acquire_lock || return 0

  local total
  total="$(wc -l < "$SPOOL_FILE" 2>/dev/null | tr -d ' ')"
  [ -z "$total" ] && total=0
  if [ "$total" -eq 0 ]; then
    release_lock
    return 0
  fi

  local head_file remaining_file
  head_file="$STATE_DIR/spool.flush.$$"
  remaining_file="$STATE_DIR/spool.remaining.$$"
  head -n "$FLUSH_MAX_LINES" "$SPOOL_FILE" > "$head_file" 2>/dev/null
  : > "$remaining_file"

  local stop_on_failure=0
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    if [ "$stop_on_failure" -eq 1 ]; then
      printf '%s\n' "$line" >> "$remaining_file"
      continue
    fi
    if ! send_payload "$line"; then
      printf '%s\n' "$line" >> "$remaining_file"
      stop_on_failure=1
    fi
  done < "$head_file"

  if [ "$total" -gt "$FLUSH_MAX_LINES" ]; then
    tail -n +"$((FLUSH_MAX_LINES + 1))" "$SPOOL_FILE" >> "$remaining_file" 2>/dev/null
  fi

  mv -f "$remaining_file" "$SPOOL_FILE" 2>/dev/null
  rm -f "$head_file" 2>/dev/null
  release_lock
}

if [ -z "${MY_DASHBOARD_URL:-}" ] || [ -z "${MY_DASHBOARD_TOKEN:-}" ] || [ -z "$JSON" ]; then
  exit 0
fi

PAYLOAD=""

if command -v jq >/dev/null 2>&1; then
  HOST="$(hostname -s 2>/dev/null)"
  OCCURRED_AT="$(epoch_ms)"
  RAW_ID_SEED="$(printf '%s' "$JSON" | jq -r '."thread-id" // "unknown"' 2>/dev/null)"
  [ -z "$RAW_ID_SEED" ] && RAW_ID_SEED="unknown"
  EVENT_ID="${MY_DASHBOARD_EVENT_ID:-${RAW_ID_SEED}-${OCCURRED_AT}-${RANDOM}${RANDOM}}"

  CORE_PAYLOAD="$(printf '%s' "$JSON" | jq -c \
    --arg host "$HOST" \
    --arg event_id "$EVENT_ID" \
    --argjson occurred_at "$OCCURRED_AT" \
    --arg hook_rev "$HOOK_REV" \
    '{
      protocol_version: 1,
      source: "codex",
      session_id: (."thread-id" // "unknown"),
      project: (.cwd // "unknown"),
      event: (.type // "unknown"),
      host: (if $host == "" then null else $host end),
      event_id: $event_id,
      occurred_at: $occurred_at,
      message: ((."last-assistant-message" // null)
                | if . == null then null else (tostring | .[0:300]) end),
      hook_rev: $hook_rev
    }' 2>/dev/null)"

  if [ -n "$CORE_PAYLOAD" ]; then
    RAW_SAFE="$(printf '%s' "$JSON" | head -c "$RAW_MAX_BYTES" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)"
    WITH_RAW="$(printf '%s' "$CORE_PAYLOAD" | jq -c --arg raw "$RAW_SAFE" '. + {raw: $raw}' 2>/dev/null)"
    if [ -n "$WITH_RAW" ]; then
      PAYLOAD="$WITH_RAW"
    else
      PAYLOAD="$CORE_PAYLOAD"
    fi
  fi
fi

flush_spool

if [ -n "$PAYLOAD" ]; then
  if ! send_payload "$PAYLOAD"; then
    append_spool "$PAYLOAD"
  fi
fi

exit 0
