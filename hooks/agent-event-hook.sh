#!/usr/bin/env bash
# Claude Code / Codex / Devin 공용 이벤트 전송기.
# 사용법: agent-event-hook.sh <source>   (source: claude-code | codex | devin, 기본값 claude-code)
# 세 에이전트 모두 hook 이벤트를 stdin JSON으로 전달하고(Claude Code: hook_event_name,
# session_id, cwd / Codex 공식 hooks: hook_event_name, session_id, cwd 동일 필드 / Devin:
# hook_event_name, session_id, prompt_id + 이벤트별 필드 - cwd는 싣지 않는다. 아래
# project 폴백 참고), 그래서 스크립트 하나를 공유한다.
# codex의 구버전 notify(argv JSON) fallback은 codex-notify.sh가 맡는다.
#
# 원칙: 이 스크립트는 에이전트 실행을 절대 막지 않는다. 무슨 일이 있어도 exit 0.
# trap으로 한 번 더 못박아 둔다 - 스크립트 어딘가에서 예상 못한 방식으로 종료돼도 이 값이 이긴다.
trap 'exit 0' EXIT

SOURCE="${1:-claude-code}"

# 설정 우선순위: 환경변수 > env 파일 > 기본값. `.`(source)는 같은 이름의 변수를
# 무조건 덮어쓰므로, 호출 시점에 이미 있던 MY_DASHBOARD_* 환경변수를 통째로 담아 두고
# 소싱 뒤에 되돌린다 — 파일은 환경이 비워 둔 키만 채우게 된다. export -p 출력은 셸이
# 스스로 이스케이프한 `declare -x KEY="value"` 행이라 그대로 eval해도 안전하다.
# (이 규칙이 없던 시절에는 파일이 env를 덮어써서, 테스트하려고 넘긴
# MY_DASHBOARD_URL이 묵살되고 이벤트가 운영 서버로 나간 사고가 있었다.)
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
HEARTBEAT_DIR="$STATE_DIR/heartbeat"
SPOOL_MAX_LINES=500
FLUSH_MAX_LINES=50
HEARTBEAT_THROTTLE_SECONDS=60
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

INPUT="$(cat 2>/dev/null)"

mkdir -p "$STATE_DIR" "$HEARTBEAT_DIR" 2>/dev/null

# ---------- 유틸 ----------

# 밀리초 epoch. python3가 있으면 그걸 쓰고, 없으면 date의 %N(나노초)을 시도하고,
# 그마저 없는 환경(구버전 BSD date 등)이면 초 단위에 000을 붙인다. 어떤 경로든 실패하지 않는다.
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

# mtime을 초 단위로. macOS(BSD stat)와 Linux(GNU stat) 둘 다 대응.
file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# mkdir은 원자적이라 뮤텍스로 쓴다. 스풀 재작성(trim/flush) 동안만 잠깐 잡는다.
# 짧게 재시도하다 실패하면 포기한다 - hook 지연보다 "이번엔 스풀 정리를 건너뛴다"가 낫다.
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
  return 0
}

release_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null
  return 0
}

# 스풀이 500행을 넘으면 오래된 줄부터 버린다(FIFO).
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

# 한 줄(이미 완성된 JSON payload)을 스풀에 append한다.
# 단일 write(짧은 한 줄)는 O_APPEND 하에서 원자적이라고 보고 락 없이 붙인다.
# 락은 크기를 다시 쓰는 trim/flush에서만 쓴다.
# 상세 입력은 명시적으로 켠 경우만 전송한다. 별칭은 프로젝트·호스트 메타데이터를 대체한다.
privacy_payload() {
  printf '%s' "$1" | jq -c \
    --arg include "${MY_DASHBOARD_INCLUDE_CONTENT:-0}" \
    --arg project "${MY_DASHBOARD_PROJECT_LABEL:-}" \
    --arg host "${MY_DASHBOARD_HOST_LABEL:-}" \
    'if $include == "1" then . else .message = null | del(.raw) end
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

# payload 한 개를 서버로 보낸다. 2xx면 성공(중복 응답도 2xx라 성공으로 친다).
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

# 스풀 앞쪽 최대 50줄을 순서대로 재전송한다. 하나라도 실패하면 그 지점에서 멈추고
# (더 실패할 확률이 높은 서버에 나머지를 계속 두드리지 않는다) 남은 줄 전부를 그대로 되돌린다.
# 순서를 지키는 게 중요하다 - 늦게 온 새 이벤트가 먼저 반영되면 서버의 순서 역행 방어가
# 밀린 옛 이벤트들을 "과거"로 보고 무시해 버린다.
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

# ---------- 본문 ----------

if [ -z "${MY_DASHBOARD_URL:-}" ] || [ -z "${MY_DASHBOARD_TOKEN:-}" ]; then
  exit 0
fi

PAYLOAD=""
EVENT_NAME=""
SESSION_ID=""

if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  HOST="$(hostname -s 2>/dev/null)"
  OCCURRED_AT="$(epoch_ms)"
  RAW_ID_SEED="$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)"
  [ -z "$RAW_ID_SEED" ] && RAW_ID_SEED="unknown"
  EVENT_ID="${MY_DASHBOARD_EVENT_ID:-${RAW_ID_SEED}-${OCCURRED_AT}-${RANDOM}${RANDOM}}"

  # project 폴백: stdin의 .cwd가 없을 때 채운다. Devin은 stdin에 cwd를 싣지 않는다
  # (공식 문서상 공통 필드는 session_id·prompt_id + 이벤트별 필드뿐) - 대신 hook
  # 프로세스 환경에 DEVIN_PROJECT_DIR(프로젝트 루트)를 설정해 준다. 그마저 없으면
  # hook 프로세스 자신의 cwd로, 그래도 없으면 "unknown"으로 둔다 -
  # send-generic.sh의 MY_DASHBOARD_PROJECT:-$(pwd) 폴백과 같은 근거다.
  PROJECT_FALLBACK="${DEVIN_PROJECT_DIR:-}"
  if [ -z "$PROJECT_FALLBACK" ]; then
    PROJECT_FALLBACK="$(pwd 2>/dev/null)"
  fi
  [ -z "$PROJECT_FALLBACK" ] && PROJECT_FALLBACK="unknown"

  # 이벤트명 변환(SoC: 상태 판단은 서버만 한다 - 여기서는 이름만 바꿔치기한다):
  #   (A) claude-code Notification: stdin의 notification_type이 제외목록 3종(idle_prompt/
  #       auth_success/agent_completed)과 "정확히" 일치할 때만 합성 이벤트명으로 바꾼다.
  #       그 외(모르는 타입 포함)는 Notification 그대로 - 미탐이 오탐보다 비싸서 블랙리스트.
  #       notification_type 원본 값은 항상 additive 필드로 페이로드에 동봉한다(서버는 저장만).
  #   (F) codex request_user_input(_async): tool_name을 정규화(영숫자만, 소문자)해 완전
  #       일치로만 판별한다. 부분 문자열 매칭 금지(request_user_input_summary류 오인 방지).
  #       Pre & (동기|비동기) -> UserInputRequest. Post & 동기만 -> UserInputResolved.
  #       Post & 비동기는 절대 UserInputResolved로 바꾸지 않는다(질문 직후에 와서 해소로
  #       쓰면 아직 떠 있는 질문을 지워버린다) - 그대로 두어 기존 PostToolUse 하트비트
  #       경로(스로틀 포함)를 타게 한다.
  #   (D) devin SessionStart: source가 "startup"이면 초기화 이벤트로 간주하여 무시한다
  #       (초기화 이벤트). 실제 작업 시작은 UserPromptSubmit부터다.
  CORE_PAYLOAD="$(printf '%s' "$INPUT" | jq -c \
    --arg source "$SOURCE" \
    --arg host "$HOST" \
    --arg event_id "$EVENT_ID" \
    --argjson occurred_at "$OCCURRED_AT" \
    --arg hook_rev "$HOOK_REV" \
    --arg project_fallback "$PROJECT_FALLBACK" \
    '
      def first_question_text:
        try (.tool_input.questions[0].header // .tool_input.questions[0].question) catch null;

      def corr_id:
        if type == "string" and test("\\S") and (length <= 200) then . else null end;

      (.hook_event_name // "unknown") as $raw_event
      | (.notification_type // null) as $notif_type
      | ((.tool_name // "") | ascii_downcase | gsub("[^a-z0-9]"; "")) as $norm_tool
      | (.source // null) as $source_val
      | (
          if $source == "claude-code" and $raw_event == "Notification" then
            (if $notif_type == "idle_prompt" then "IdleNotification"
             elif $notif_type == "auth_success" then "AuthNotification"
             elif $notif_type == "agent_completed" then "AgentCompletedNotification"
             else $raw_event
             end)
          elif $source == "codex" and $raw_event == "PreToolUse"
               and ($norm_tool == "requestuserinput" or $norm_tool == "requestuserinputasync") then
            "UserInputRequest"
          elif $source == "codex" and $raw_event == "PostToolUse" and $norm_tool == "requestuserinput" then
            "UserInputResolved"
          elif $source == "devin" and $raw_event == "PreToolUse" and .tool_name == "ask_user_question" then
            "UserInputRequest"
          elif $source == "devin" and $raw_event == "SessionStart" and $source_val == "startup" then
            "SessionStartIgnored"
          else
            $raw_event
          end
        ) as $final_event
      | (
          if $final_event == "UserInputRequest" then
            (first_question_text | if . == null then null else (tostring | .[0:300]) end)
          else
            ((.message // .prompt // .last_assistant_message // null)
              | if . == null then null else (tostring | .[0:300]) end)
          end
        ) as $final_message
      | {
          protocol_version: 1,
          source: $source,
          session_id: (.session_id // "unknown"),
          project: ((.cwd // "") | if . == "" then $project_fallback else . end),
          event: $final_event,
          host: (if $host == "" then null else $host end),
          event_id: $event_id,
          occurred_at: $occurred_at,
          message: $final_message,
          notification_type: $notif_type,
          hook_rev: $hook_rev
        }
        + (if $source == "devin" then
            { prompt_id: (.prompt_id | corr_id),
              tool_use_id: (.tool_use_id | corr_id),
              tool_name: (.tool_name | corr_id) }
          else {} end)
    ' 2>/dev/null)"

  if [ -n "$CORE_PAYLOAD" ]; then
    # Devin 초기화 이벤트 무시 (초기화 이벤트)
    EVENT_NAME="$(printf '%s' "$CORE_PAYLOAD" | jq -r '.event' 2>/dev/null)"
    if [ "$EVENT_NAME" = "SessionStartIgnored" ]; then
      exit 0
    fi
    
    RAW_SAFE="$(printf '%s' "$INPUT" | head -c "$RAW_MAX_BYTES" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)"
    WITH_RAW="$(printf '%s' "$CORE_PAYLOAD" | jq -c --arg raw "$RAW_SAFE" '. + {raw: $raw}' 2>/dev/null)"
    if [ -n "$WITH_RAW" ]; then
      PAYLOAD="$WITH_RAW"
    else
      PAYLOAD="$CORE_PAYLOAD"
    fi
    SESSION_ID="$(printf '%s' "$CORE_PAYLOAD" | jq -r '.session_id' 2>/dev/null)"
  fi
fi

# HB_KEY/HB_FILE: 세션별 하트비트 스로틀 타임스탬프 파일 경로. PostToolUse 스로틀 판정과
# (아래) 상태 이벤트 전송 성공 시 스로틀 리셋 양쪽에서 공용으로 쓰므로 여기서 한 번만 계산한다.
HB_KEY=""
HB_FILE=""
if [ -n "$PAYLOAD" ]; then
  HB_KEY="$(printf '%s_%s' "$SOURCE" "$SESSION_ID" | tr -c 'A-Za-z0-9_-' '_')"
  HB_FILE="$HEARTBEAT_DIR/$HB_KEY.ts"
fi

# 하트비트 스로틀: PostToolUse는 세션별 타임스탬프 파일로 60초에 한 번만 실제로 보낸다.
# stalled watchdog의 입력이 목적이라, 신호가 "아직 살아있다"만 확인되면 충분하다.
SKIP_SEND=0
if [ -n "$PAYLOAD" ] && [ "$EVENT_NAME" = "PostToolUse" ]; then
  NOW_S="$(date +%s 2>/dev/null || echo 0)"
  IS_DEVIN_COMPLETION="$(printf '%s' "$PAYLOAD" | jq -r 'if .source == "devin" and (.prompt_id | type) == "string" and (.tool_use_id | type) == "string" and (.tool_name | type) == "string" then "true" else "false" end' 2>/dev/null)"
  if [ "$IS_DEVIN_COMPLETION" = "true" ]; then
    printf '%s' "$NOW_S" > "$HB_FILE" 2>/dev/null
  else
    LAST_HB="$(cat "$HB_FILE" 2>/dev/null)"
    case "$LAST_HB" in
      ''|*[!0-9]*) LAST_HB=0 ;;
    esac
    if [ "$NOW_S" -lt "$((LAST_HB + HEARTBEAT_THROTTLE_SECONDS))" ]; then
      SKIP_SEND=1
    else
      printf '%s' "$NOW_S" > "$HB_FILE" 2>/dev/null
    fi
  fi
fi

# 먼저 밀린 스풀을 순서대로 흘려보내고(정합성), 그 다음에 이번 이벤트를 보낸다.
flush_spool

if [ -n "$PAYLOAD" ] && [ "$SKIP_SEND" -eq 0 ]; then
  if send_payload "$PAYLOAD"; then
    # Stop 직후에도 백그라운드 서브에이전트가 도구를 계속 쓰면, 그 활동은 부모
    # session_key의 PostToolUse로 도착해 서버가 done -> working으로 승격한다
    # (server/src/dashboard/heartbeat.ts resolveHeartbeatPromotion). 문제는
    # 그 PostToolUse가 위 60초 스로틀 창 한가운데 걸리면 전송 자체가 최대 60초 억제돼
    # 승격이 그만큼 늦어진다는 것 - 실측 25~47초 지연, 그 사이 대시보드/앱은 "Done"으로
    # 잘못 보였고 44분 동안 done 전이가 9번(=불필요한 푸시 9회) 발생했다.
    # Stop처럼 서버 쪽 상태 전이를 유발하는 비-PostToolUse 이벤트가 실제로 전송에
    # 성공했다면, 그 이후의 활동을 서버가 최대한 빨리 알아야 하므로 스로틀 창을
    # 리셋한다 - 다음 PostToolUse가 억제 없이 바로 나가 승격이 초 단위로 일어난다.
    # 스풀(오프라인 큐)로 떨어진 경우는 리셋하지 않는다 - 서버가 아직 이 상태 전이를
    # 모르는 상태에서 스로틀만 풀면 의미가 없고, 뒤이은 PostToolUse가 먼저 도착해
    # 순서가 꼬일 위험만 커진다.
    if [ "$EVENT_NAME" != "PostToolUse" ] && [ -n "$HB_FILE" ]; then
      rm -f "$HB_FILE" 2>/dev/null
    fi
  else
    append_spool "$PAYLOAD"
  fi
fi

exit 0
