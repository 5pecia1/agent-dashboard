#!/usr/bin/env bash
# Claude Code / Codex / Devin / Antigravity 공용 이벤트 전송기.
# 사용법: agent-event-hook.sh <source> [event]
#   source: claude-code | codex | devin | antigravity, 기본값 claude-code
#   event:  antigravity 전용. agy는 stdin에 이벤트 이름을 싣지 않아서 hooks.json 명령이
#           두 번째 인자로 넘긴다(PreInvocation | PreToolUse | PostToolUse | Stop).
# Grok은 Claude 설정의 이 명령을 그대로 실행한다. hook 프로세스에 GROK_HOOK_EVENT가
# 있으면 인자 claude-code를 source grok으로 바꿔 보낸다. Codex·Devin 인자는 바꾸지 않는다.
# 세 에이전트 모두 hook 이벤트를 stdin JSON으로 전달하고(Claude Code: hook_event_name,
# session_id, cwd / Codex 공식 hooks: hook_event_name, session_id, cwd 동일 필드 / Devin:
# hook_event_name, session_id, prompt_id + 이벤트별 필드 - cwd는 싣지 않는다. 아래
# project 폴백 참고), 그래서 스크립트 하나를 공유한다.
# Antigravity CLI(agy)도 stdin JSON(camelCase: conversationId, workspacePaths, toolCall 등)을
# 주지만 이벤트 이름과 cwd가 없다. 번역 규칙의 정본은 계약의
# event_state_map.antigravity_hook_translation이다.
# codex의 구버전 notify(argv JSON) fallback은 codex-notify.sh가 맡는다.
#
# 원칙: 이 스크립트는 에이전트 실행을 절대 막지 않는다. 무슨 일이 있어도 exit 0.
# trap으로 한 번 더 못박아 둔다 - 스크립트 어딘가에서 예상 못한 방식으로 종료돼도 이 값이 이긴다.
# (시그널로 죽는 경우는 trap도 막지 못한다 - 아래 Antigravity 응답 출력 참고.)
# 스풀 락을 이 프로세스가 쥐고 있으면(LOCK_OWNED=1) 종료할 때 푼다. TERM·INT·HUP도 exit 0으로
# 돌려 이 trap을 거치게 한다 - 락을 쥔 채 죽으면 30초 동안 다음 hook들이 락 대기로 지연된다.
# SIGKILL은 trap이 못 막으므로 아래 stale 락 정리(LOCK_STALE_SECONDS)가 그 안전망이다.
LOCK_OWNED=0
trap '[ "${LOCK_OWNED:-0}" = 1 ] && rmdir "$LOCK_DIR" 2>/dev/null; exit 0' EXIT
trap 'exit 0' TERM INT HUP

SOURCE="${1:-claude-code}"
# Grok은 ~/.claude/settings.json의 claude-code 훅을 실행하면서 GROK_HOOK_EVENT를 넣는다.
# Claude Code는 이 변수를 넣지 않는다. 부모 셸에 변수가 남아 있어도 Codex·Devin 인자는 유지한다.
if [ "$SOURCE" = "claude-code" ] && [ -n "${GROK_HOOK_EVENT:-}" ]; then
  SOURCE="grok"
fi

# Antigravity(agy)는 hook을 동기로 실행하고 hook stdout을 JSON 응답으로 읽는다. PreToolUse에
# 응답이 없거나 {}이면 agy는 도구를 거부하고, hook이 0이 아닌 코드로 끝나거나 10초를 넘기면
# 실행 자체를 중단한다(근거: .okf/antigravity-hooks.md). 그래서 env 파일도 stdin도 보기 전에
# 응답부터 출력한다. 응답 값의 정본은 계약의 antigravity_hook_translation.stdout_contract다 -
# allow는 모든 도구를 자동 승인하므로 쓰지 않고, ask로 사용자의 권한 설정에 판단을 넘긴다.
# 응답은 서브셸에서 출력한다. agy가 파이프를 먼저 닫으면 printf가 SIGPIPE를 받는데, 위 EXIT
# trap은 시그널 종료를 막지 못해 hook 전체가 141로 죽는다(실측). 서브셸이면 서브셸만 죽는다.
# 출력 뒤에는 stdout·stderr를 모두 /dev/null로 돌린다. stdout에는 응답 외에 아무것도 없어야
# 하고, stderr에 쓰는 에러 메시지 하나도 닫힌 파이프면 같은 SIGPIPE를 부르고 터미널이면 agy
# 화면을 더럽힌다.
if [ "$SOURCE" = "antigravity" ]; then
  ANTIGRAVITY_EVENT="${2:-}"
  case "$ANTIGRAVITY_EVENT" in
    PreToolUse) ANTIGRAVITY_ANSWER='{"decision":"ask"}' ;;
    Stop) ANTIGRAVITY_ANSWER='{"decision":""}' ;;
    *) ANTIGRAVITY_ANSWER='{}' ;;
  esac
  ( printf '%s\n' "$ANTIGRAVITY_ANSWER" ) 2>/dev/null
  exec 1>/dev/null 2>&1
  # 아래 시간 예산의 시계. bash는 환경변수 SECONDS를 물려받아 그 값부터 세므로 0으로 맞춘다.
  SECONDS=0
fi

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
# Antigravity 전용 시간 예산(초, hook 시작부터). agy는 hook이 끝날 때까지 실행을 멈추고
# 10초에 끊는다. 스풀 재전송과 락 대기는 4초가 지나면 새로 시작하지 않고(계약 rules),
# 이번 이벤트 전송은 5초가 지나면 시작하지 않고 스풀에 남긴다. curl 한 번이 최대
# CURL_MAX_TIME(2초)이라 hook은 늦어도 7초 안에 끝난다.
ANTIGRAVITY_REPLAY_BUDGET_SECONDS=4
ANTIGRAVITY_SEND_DEADLINE_SECONDS=5
# 서브에이전트 표시·Stop 래치 파일 자리와 보존 기간(일).
ANTIGRAVITY_DIR="$STATE_DIR/antigravity"
ANTIGRAVITY_MARKER_MAX_AGE_DAYS=7
# 서버가 setup.sh/hooks/files/:name으로 이 스크립트를 내려줄 때 자기 HOOK_REV로 치환하는
# 자리(server/src/hooks/routes.ts) - "훅 구버전 배너" 기능의 원장(dashboard_meta의
# hook_revs, dashboard/sync.ts의 hook_skew)이 이 값과 서버의 현재 rev를 비교해 구버전 훅을
# 쓰는 기계를 찾아낸다. 치환되지 않은 채로(리포에서 직접 실행 등) 남아 있으면 빈 문자열이
# 아니라 플레이스홀더 문자열 그대로 전송된다 - 서버는 그 값을 additive로 저장만 할 뿐 특별
# 취급하지 않으므로 무해하다.
HOOK_REV="__MY_DASHBOARD_HOOK_REV__"
# send_payload가 남기는 마지막 응답 코드(연결 실패·시간 초과는 000). 환경변수로 물려받은 값이
# antigravity_spool_behind 판정에 새지 않게 비워 두고 시작한다.
LAST_SEND_CODE=""

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

# Antigravity hook이 스풀 작업(재전송·락 대기)에 쓸 시간 예산을 다 썼는가.
# 다른 source에는 예산이 없다(항상 거짓).
antigravity_budget_spent() {
  [ "$SOURCE" = "antigravity" ] && [ "$SECONDS" -ge "$ANTIGRAVITY_REPLAY_BUDGET_SECONDS" ]
}

# Antigravity hook이 이번 이벤트 전송을 시작하기에 늦었는가. 다른 source는 항상 거짓.
antigravity_send_deadline_passed() {
  [ "$SOURCE" = "antigravity" ] && [ "$SECONDS" -ge "$ANTIGRAVITY_SEND_DEADLINE_SECONDS" ]
}

# Antigravity hook이 이번 이벤트를 보내지 않고 스풀 끝에 넣어야 하는가. 이번 실행의 재전송이 서버
# 응답을 하나도 받지 못했을 때(curl 코드 000: 연결 실패·시간 초과)만 그렇다 - 서버가 닿지 않는 동안
# 두 번째 curl(최대 CURL_MAX_TIME)을 또 기다리지 않게 한다. 서버가 응답했으면(2xx·4xx·5xx·429)
# 스풀에 줄이 남아 있어도 바로 보낸다. 서버는 occurred_at이 더 오래된 상태 이벤트를 무시하므로 최신
# 이벤트를 먼저 보내도 최종 상태는 맞고, 뒤에 세우면 한 번에 다 비지 않는 백로그(50줄 상한·4초 예산)
# 뒤에서 Stop 같은 최신 상태가 다음 hook까지 묶이거나, 늘 거절되는 줄 뒤에 갇힌다. 락을 못 잡아
# 재전송을 해 보지 못한 경우(LAST_SEND_CODE 없음)도 바로 보낸다. 다른 source는 항상 거짓.
antigravity_spool_behind() {
  [ "$SOURCE" = "antigravity" ] && [ -s "$SPOOL_FILE" ] && [ "${LAST_SEND_CODE:-}" = "000" ]
}

# mkdir은 원자적이라 뮤텍스로 쓴다. 스풀 재작성(trim/flush) 동안만 잠깐 잡는다.
# 짧게 재시도하다 실패하면 포기한다 - hook 지연보다 "이번엔 스풀 정리를 건너뛴다"가 낫다.
# Antigravity hook은 시간 예산을 다 썼으면 더 기다리지 않는다.
acquire_lock() {
  local tries=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    antigravity_budget_spent && return 1
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
    --arg include_content "${MY_DASHBOARD_INCLUDE_CONTENT:-0}" \
    --arg project "${MY_DASHBOARD_PROJECT_LABEL:-}" \
    --arg host "${MY_DASHBOARD_HOST_LABEL:-}" \
    'if $include_content == "1" then . else .message = null | del(.raw, .display_title) end
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
  # 마지막 응답 코드(연결 실패·시간 초과는 000). antigravity_spool_behind가 본다.
  LAST_SEND_CODE="$code"
  case "$code" in
    2??) return 0 ;;
    *) return 1 ;;
  esac
}

# 스풀 앞쪽 최대 50줄을 순서대로 재전송한다. 하나라도 실패하면 그 지점에서 멈추고
# (더 실패할 확률이 높은 서버에 나머지를 계속 두드리지 않는다) 남은 줄 전부를 그대로 되돌린다.
# 순서를 지키는 게 중요하다 - 늦게 온 새 이벤트가 먼저 반영되면 서버의 순서 역행 방어가
# 밀린 옛 이벤트들을 "과거"로 보고 무시해 버린다.
# Antigravity hook은 시간 예산(4초)이 지나면 새 재전송을 시작하지 않고 남은 줄을 다음 hook에
# 넘긴다. 실패 없이 느리기만 한 서버(요청마다 2초 가까이)에 50줄을 다 보내면 agy의 10초
# 제한을 넘겨 사용자의 agy 실행이 중단되기 때문이다.
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
    if [ "$stop_on_failure" -eq 1 ] || antigravity_budget_spent; then
      printf '%s\n' "$line" >> "$remaining_file"
      continue
    fi
    if ! send_payload "$line"; then
      printf '%s\n' "$line" >> "$remaining_file"
      stop_on_failure=1
    fi
  done < "$head_file"

  # 이번 flush가 가져간 줄(앞쪽 최대 50줄) 다음 줄은 전부 되돌린다. 처음부터 있던 51번째 이후 줄뿐
  # 아니라, 재전송하는 동안 다른 hook이 락 없이 append한 줄(append_spool)도 함께 옮겨진다 - 예전에는
  # 시작할 때 50줄 이하였으면 이 단계를 건너뛰어, 그사이 붙은 줄이 아래 mv에 덮여 사라졌다(모든
  # source에 해당하는 정합성 수정). 가져간 줄 수는 head가 실제로 읽은 head_file로 센다 - total은 head
  # 전에 센 값이라, 그 사이 붙은 줄을 이번에 보내고도 또 되돌리게 된다.
  local taken
  taken="$(wc -l < "$head_file" 2>/dev/null | tr -d ' ')"
  case "$taken" in
    ''|*[!0-9]*) taken=0 ;;
  esac
  tail -n +"$((taken + 1))" "$SPOOL_FILE" >> "$remaining_file" 2>/dev/null

  mv -f "$remaining_file" "$SPOOL_FILE" 2>/dev/null
  rm -f "$head_file" 2>/dev/null
  release_lock
}

# ---------- Antigravity(agy) ----------

# pid 하나의 인자 목록을 ANTIGRAVITY_ARGV 배열에 담는다. Linux의 /proc/<pid>/cmdline은
# 인자 경계를 NUL로 그대로 보여 주므로 먼저 쓴다. /proc가 없는 macOS는 ps가 공백으로 이어
# 붙인 문자열을 공백으로 나눈다 - 인자 안의 공백은 구분하지 못하지만 플래그를 찾는 데는 충분하다.
antigravity_read_argv() {
  local arg
  ANTIGRAVITY_ARGV=()
  if [ -r "/proc/$1/cmdline" ]; then
    while IFS= read -r -d '' arg || [ -n "$arg" ]; do
      ANTIGRAVITY_ARGV+=("$arg")
    done < "/proc/$1/cmdline"
  fi
  if [ "${#ANTIGRAVITY_ARGV[@]}" -eq 0 ]; then
    read -r -a ANTIGRAVITY_ARGV <<< "$(ps -ww -o args= -p "$1" 2>/dev/null)"
  fi
}

# pid의 부모 pid. /proc가 있으면 fork 없이 status에서 읽고(ps가 없는 컨테이너도 있다),
# 없으면 ps에 묻는다.
antigravity_parent_pid() {
  local key value
  if [ -r "/proc/$1/status" ]; then
    while IFS=$': \t' read -r key value; do
      if [ "$key" = "PPid" ]; then
        printf '%s\n' "$value"
        return 0
      fi
    done < "/proc/$1/status"
  fi
  ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '
}

# 이 hook이 agy print 모드(agy -p "..." 같은 비대화형 실행) 아래에서 돌고 있는가.
# agy-delegate 같은 자동화가 print 모드로 agy를 자주 부르는데(실측 대화의 절반 가량), 그런
# 실행까지 세션으로 올리면 대시보드가 사람이 지켜볼 필요 없는 카드로 덮인다.
# hooks.json 명령은 agy가 sh -c로 실행하므로 부모에서 최대 4단계까지 올라가며, argv[0]이나
# argv[1](node 같은 인터프리터 아래라면 스크립트 경로)의 basename이 agy인 첫 조상을 agy로
# 보고 그 인자에서 print 플래그(p·print·prompt)를 찾는다. 대화형 첫 프롬프트 플래그
# (i·prompt-interactive)는 제외하고 그 뒤는 프롬프트 문장이라 더 보지 않는다 - macOS의 ps는
# 인자를 공백으로 이어 붙이므로 agy -i "-p 옵션을 고쳐 줘" 같은 문장 속 단어를 플래그로 잘못
# 읽게 된다(실측).
# agy 조상을 못 찾으면(IDE 등) print 모드로 보지 않는다 - 못 보내서 놓치는 쪽이 더 비싸다.
# 정본: 계약 antigravity_hook_translation.print_mode.
antigravity_print_mode() {
  [ "${MY_DASHBOARD_ANTIGRAVITY_INCLUDE_PRINT:-}" = "1" ] && return 1
  local pid="$PPID" depth=0 argv0 argv1 arg name
  while [ "$depth" -lt 4 ]; do
    case "$pid" in
      ''|*[!0-9]*) return 1 ;;
    esac
    [ "$pid" -gt 1 ] || return 1
    antigravity_read_argv "$pid"
    argv0="${ANTIGRAVITY_ARGV[0]:-}"
    argv1="${ANTIGRAVITY_ARGV[1]:-}"
    if [ "${argv0##*/}" = "agy" ] || [ "${argv1##*/}" = "agy" ]; then
      for arg in "${ANTIGRAVITY_ARGV[@]}"; do
        # agy는 Go flag 문법을 따른다: 이름 앞 대시가 하나든 둘이든 같고(-p·--p·-print·--print)
        # =값이 붙을 수 있으며(-p=…), --에서 플래그가 끝난다. 대시를 떼고 = 앞 이름만 비교한다.
        case "$arg" in
          --) return 1 ;;
          --*) name="${arg#--}" ;;
          -*) name="${arg#-}" ;;
          *) continue ;;
        esac
        case "${name%%=*}" in
          p|print|prompt) return 0 ;;
          i|prompt-interactive) return 1 ;;
        esac
      done
      return 1
    fi
    pid="$(antigravity_parent_pid "$pid")"
    depth=$((depth + 1))
  done
  return 1
}

# 번역된 Antigravity 이벤트를 보낼지 정한다(0이면 보낸다). 이름 번역은 jq가 끝냈고, 여기서는
# 이벤트 하나로는 알 수 없는 것만 본다: 서브에이전트 표시, Stop 뒤 래치, print 모드.
# 상태 판단은 하지 않는다 - 보낼지 말지만 정한다(SoC).
antigravity_admit() {
  local key="$ANTIGRAVITY_KEY"
  # 서브에이전트(invoke_subagent)는 부모와 다른 conversationId로 자기 이벤트를 따로 내고 부모
  # 식별자를 싣지 않는다. 그대로 보내면 부모 옆에 떠돌이 세션이 하나 더 생기므로, 첫
  # PreInvocation(invocationNum 0, initialNumSteps 0)에서 대화를 표시해 두고 끝까지 버린다.
  # 부모 세션의 상태는 부모 자신의 이벤트로만 정해진다 - 부모의 턴이 서브에이전트를 남긴 채
  # 끝나면 서브에이전트가 도는 동안에도 done으로 보인다.
  [ -e "$ANTIGRAVITY_DIR/subagent/$key" ] && return 1
  case "$EVENT_NAME" in
    AntigravitySubagentStart)
      # 식별자가 없는 이벤트가 모이는 "unknown"은 표시하지 않는다 - 표시하면 7일 동안 그
      # 묶음 전체가 사라진다.
      if [ "$RAW_ID_SEED" != "unknown" ]; then
        mkdir -p "$ANTIGRAVITY_DIR/subagent" 2>/dev/null && : > "$ANTIGRAVITY_DIR/subagent/$key" 2>/dev/null
      fi
      return 1
      ;;
    AntigravityIgnored)
      return 1
      ;;
    PostToolUse|UserInputResolved)
      # Stop 뒤에도 기록용 PostToolUse가 올 수 있다(다른 agy 연동 구현에서 보고된 동작). 질문
      # 도구의 것은 UserInputResolved로 번역되는데, 하트비트든 해소든 보내면 서버가 끝난 턴을
      # working으로 되살리므로(해소는 상태 이벤트라 하트비트의 승격 가드도 거치지 않는다) 다음 턴
      # 시작까지 버린다. fullyIdle이 false인 Stop 뒤도 같다 - agy가 모델 호출을 다시 시작하면 그
      # PreInvocation(invocationNum과 상관없이 턴 (재)시작)이 UserPromptSubmit이 되어 래치를 푼다.
      [ -e "$ANTIGRAVITY_DIR/stopped/$key" ] && return 1
      ;;
  esac
  # 표시 파일은 대화마다 하나씩 쌓이므로 Stop 때마다 오래된 것을 지운다. print 모드 실행만 쓰는
  # 사람에게도 서브에이전트 표시가 쌓이므로 print 모드 판정보다 먼저 한다.
  if [ "$EVENT_NAME" = "Stop" ]; then
    find "$ANTIGRAVITY_DIR/subagent" "$ANTIGRAVITY_DIR/stopped" -type f \
      -mtime +"$ANTIGRAVITY_MARKER_MAX_AGE_DAYS" -exec rm -f {} + 2>/dev/null
  fi
  antigravity_print_mode && return 1
  case "$EVENT_NAME" in
    UserPromptSubmit)
      rm -f "$ANTIGRAVITY_DIR/stopped/$key" 2>/dev/null
      ;;
    Stop)
      # 래치는 fullyIdle 값과도, 전송 결과와도 상관없이 건다 - 스풀로 떨어져도 턴 실행은 이미 끝났다.
      mkdir -p "$ANTIGRAVITY_DIR/stopped" 2>/dev/null && : > "$ANTIGRAVITY_DIR/stopped/$key" 2>/dev/null
      ;;
  esac
  return 0
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
  if [ "$SOURCE" = "antigravity" ]; then
    # agy의 세션 식별자는 conversationId다. 없으면 agy가 hook 환경에 넣어 주는 같은 값
    # ANTIGRAVITY_CONVERSATION_ID로 채운다. 이 값이 그대로 session_id가 된다(아래 jq).
    # 문자열이 아닌 값은 버린다 - 서버가 거절하는 줄이 스풀 맨 앞에 끼면 재전송이 막힌다.
    RAW_ID_SEED="$(printf '%s' "$INPUT" | jq -r '.conversationId | strings' 2>/dev/null)"
    [ -z "$RAW_ID_SEED" ] && RAW_ID_SEED="${ANTIGRAVITY_CONVERSATION_ID:-}"
  else
    RAW_ID_SEED="$(printf '%s' "$INPUT" | jq -r '.session_id // .sessionId // "unknown"' 2>/dev/null)"
  fi
  [ -z "$RAW_ID_SEED" ] && RAW_ID_SEED="unknown"
  EVENT_ID="${MY_DASHBOARD_EVENT_ID:-${RAW_ID_SEED}-${OCCURRED_AT}-${RANDOM}${RANDOM}}"
  if [ "$SOURCE" = "antigravity" ]; then
    # 대화별 상태 파일(서브에이전트 표시·Stop 래치)의 이름.
    ANTIGRAVITY_KEY="$(printf '%s' "$RAW_ID_SEED" | tr -c 'A-Za-z0-9_-' '_')"
    # Stop 뒤 래치가 걸린 대화인가. 이벤트 하나로는 알 수 없는 대화 상태라 bash가 파일로 보고
    # 아래 jq 번역에 입력으로 넘긴다(래치가 걸린 동안의 PreInvocation은 턴 (재)시작이다).
    ANTIGRAVITY_LATCHED=0
    [ -e "$ANTIGRAVITY_DIR/stopped/$ANTIGRAVITY_KEY" ] && ANTIGRAVITY_LATCHED=1
  fi

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
  #   (A) claude-code·grok Notification: stdin의 notification_type 또는 notificationType이
  #       제외목록 4종(idle_prompt/auth_success/agent_completed/task_complete)과 "정확히"
  #       일치할 때만 합성 이벤트명으로 바꾼다. Grok은 camelCase notificationType만 보낸다.
  #       그 외(모르는 타입 포함)는 Notification 그대로 - 미탐이 오탐보다 비싸서 블랙리스트.
  #       읽은 원본 값은 항상 notification_type 필드로 페이로드에 동봉한다(서버는 저장만).
  #   (F) codex request_user_input(_async): tool_name을 정규화(영숫자만, 소문자)해 완전
  #       일치로만 판별한다. 부분 문자열 매칭 금지(request_user_input_summary류 오인 방지).
  #       Pre & (동기|비동기) -> UserInputRequest. Post & 동기만 -> UserInputResolved.
  #       Post & 비동기는 절대 UserInputResolved로 바꾸지 않는다(질문 직후에 와서 해소로
  #       쓰면 아직 떠 있는 질문을 지워버린다) - 그대로 두어 기존 PostToolUse 하트비트
  #       경로(스로틀 포함)를 타게 한다.
  #   (D) devin SessionStart: source가 "startup"이면 초기화 이벤트로 간주하여 무시한다
  #       (초기화 이벤트). 실제 작업 시작은 UserPromptSubmit부터다.
  #   (G) antigravity: stdin에 이벤트 이름이 없어 hooks.json 명령이 넘긴 두 번째 인자를 쓴다.
  #       PreInvocation은 모델 호출마다 오고 invocationNum은 턴마다 0부터 다시 세므로
  #       invocationNum이 0이거나 없을 때만 UserPromptSubmit(턴 시작)이다. 예외 둘:
  #       invocationNum과 initialNumSteps가 둘 다 0이면 서브에이전트 대화의 시작이라
  #       AntigravitySubagentStart로 표시만 하고(antigravity_admit이 대화를 표시하고 버린다,
  #       이 판정이 가장 먼저다), Stop 뒤 래치가 걸린 대화($antigravity_latched)의 PreInvocation은
  #       invocationNum과 상관없이 턴 (재)시작이다 - 한 실행 안에서 fullyIdle false Stop 뒤 모델
  #       호출이 이어져도(다른 agy 연동 구현에서 보고된 동작) 세션이 done에 머물지 않게 한다.
  #       숫자 필드는 숫자일 때만 비교한다 - jq는 문자열을 모든 숫자보다 크게 봐서 "0" >= 1이 참이다.
  #       question_tools(ask_question·ask_permission)와 toolCall.name이 정확히 같을 때만
  #       PreToolUse -> UserInputRequest, PostToolUse -> UserInputResolved로 바꾼다. 다른
  #       PreToolUse는 버리고 다른 PostToolUse는 하트비트 그대로다. Stop은 fullyIdle 값과
  #       상관없이 Stop이다. fullyIdle이 false면 서브에이전트 같은 백그라운드 작업이 남았다는
  #       뜻이지만 턴 실행은 끝났으므로 done이 맞고(push_states.$note_done_excluded), agy가
  #       실행을 재개하면 다음 PreInvocation(위 래치 예외)이 working으로 되돌린다. 실측(agy
  #       1.2.12): 서브에이전트를 쓰는 턴은 마지막 Stop까지 fullyIdle false로 끝날 수 있어서,
  #       이 Stop을 버리면 세션이 working에 멈추고 stalled 푸시가 잘못 나갔다.
  #       그 밖의 이벤트(PostInvocation·SessionStart 등)는 버린다. 버리는 이벤트는
  #       AntigravityIgnored라는 합성 이름을 받는다.
  #       session_id는 conversationId(RAW_ID_SEED), project는 workspacePaths[0]이다. agy는
  #       hooks.json이 있는 폴더를 cwd로 hook을 실행하므로 pwd 폴백을 쓰지 않고 "unknown"으로
  #       둔다. message는 UserInputRequest의 첫 질문 문장만 싣는다.
  #       정본: 계약 event_state_map.antigravity_hook_translation.
  CORE_PAYLOAD="$(printf '%s' "$INPUT" | jq -c \
    --arg source "$SOURCE" \
    --arg host "$HOST" \
    --arg event_id "$EVENT_ID" \
    --argjson occurred_at "$OCCURRED_AT" \
    --arg hook_rev "$HOOK_REV" \
    --arg project_fallback "$PROJECT_FALLBACK" \
    --arg antigravity_event "${ANTIGRAVITY_EVENT:-}" \
    --arg antigravity_session "$RAW_ID_SEED" \
    --arg antigravity_latched "${ANTIGRAVITY_LATCHED:-0}" \
    '
      def first_question_text:
        try (.tool_input.questions[0].header // .tool_input.questions[0].question) catch null;

      def corr_id:
        if type == "string" and test("\\S") and (length <= 200) then . else null end;

      def antigravity_num:
        if type == "number" then . else null end;

      (if $source == "antigravity" then $antigravity_event else (.hook_event_name // "unknown") end) as $raw_event
      | (.notification_type // .notificationType // null) as $notif_type
      | ((.tool_name // "") | ascii_downcase | gsub("[^a-z0-9]"; "")) as $norm_tool
      | (.source // null) as $source_val
      | (try .toolCall.name catch null) as $antigravity_tool
      | (["ask_question", "ask_permission"] | any(. == $antigravity_tool)) as $antigravity_question
      | (
          if ($source == "claude-code" or $source == "grok") and $raw_event == "Notification" then
            (if $notif_type == "idle_prompt" then "IdleNotification"
             elif $notif_type == "auth_success" then "AuthNotification"
             elif $notif_type == "agent_completed" then "AgentCompletedNotification"
             elif $notif_type == "task_complete" then "AgentCompletedNotification"
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
          elif $source == "antigravity" then
            (if $raw_event == "PreInvocation" then
               (if (.invocationNum | antigravity_num) == 0 and (.initialNumSteps | antigravity_num) == 0 then "AntigravitySubagentStart"
                elif $antigravity_latched == "1" then "UserPromptSubmit"
                elif (.invocationNum | antigravity_num) >= 1 then "AntigravityIgnored"
                else "UserPromptSubmit"
                end)
             elif $raw_event == "PreToolUse" then
               (if $antigravity_question then "UserInputRequest" else "AntigravityIgnored" end)
             elif $raw_event == "PostToolUse" then
               (if $antigravity_question then "UserInputResolved" else "PostToolUse" end)
             elif $raw_event == "Stop" then
               "Stop"
             else
               "AntigravityIgnored"
             end)
          else
            $raw_event
          end
        ) as $final_event
      | (
          if $source == "antigravity" then
            ((if $final_event == "UserInputRequest" then (try .toolCall.args.questions[0].question catch null) else null end)
              | if . == null then null else (tostring | .[0:300]) end)
          elif $final_event == "UserInputRequest" then
            (first_question_text | if . == null then null else (tostring | .[0:300]) end)
          else
            ((.message // .prompt // .last_assistant_message // (if $source == "grok" then .lastAssistantMessage else null end) // null)
              | if . == null then null else (tostring | .[0:300]) end)
          end
        ) as $final_message
      | {
          protocol_version: 1,
          source: $source,
          session_id: (if $source == "antigravity" then $antigravity_session else (.session_id // .sessionId // "unknown") end),
          project: (if $source == "antigravity" then
                      ((try .workspacePaths[0] catch null) | if type == "string" and . != "" then . else "unknown" end)
                    else
                      ((.cwd // "") | if . == "" then $project_fallback else . end)
                    end),
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
    # Antigravity: 버리는 이벤트(합성 이름·서브에이전트·Stop 뒤 래치·print 모드)는 스풀도
    # 건드리지 않고 여기서 끝낸다 - agy는 hook이 끝날 때까지 기다린다.
    if [ "$SOURCE" = "antigravity" ]; then
      antigravity_admit || exit 0
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

# Antigravity: 번역할 입력이 없으면(빈 stdin·깨진 JSON·jq 없음) 네트워크를 쓰지 않고 끝낸다.
if [ "$SOURCE" = "antigravity" ] && [ -z "$PAYLOAD" ]; then
  exit 0
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

if [ "$SKIP_SEND" -eq 0 ] && [ -n "$PAYLOAD" ] && [ "${MY_DASHBOARD_INCLUDE_CONTENT:-0}" = "1" ] && [ "${HERDR_ENV:-}" = "1" ] && command -v python3 >/dev/null 2>&1; then
  HERDR_CONTEXT="$(MY_DASHBOARD_INCLUDE_CONTENT=1 python3 "$(dirname "$0")/herdr-context.py" "$SOURCE" "$SESSION_ID" 2>/dev/null)"
  if [ -n "$HERDR_CONTEXT" ]; then
    ENRICHED_PAYLOAD="$(printf '%s' "$PAYLOAD" | jq -c --argjson context "$HERDR_CONTEXT" '. + $context' 2>/dev/null)"
    [ -n "$ENRICHED_PAYLOAD" ] && PAYLOAD="$ENRICHED_PAYLOAD"
  fi
fi

# 먼저 밀린 스풀을 순서대로 흘려보내고(정합성), 그 다음에 이번 이벤트를 보낸다.
# Antigravity는 이번 실행이 아무것도 보내지 않으면(스로틀된 하트비트) 재전송도 하지 않는다. agy는
# 도구를 쓸 때마다 hook이 끝나기를 기다리므로, 서버 장애 중 스풀이 남아 있으면 도구 호출마다 재전송
# 실패(최대 CURL_MAX_TIME)만큼 멈춘다. 밀린 줄은 실제로 보내는 실행(턴 시작·질문·Stop·분당 한 번의
# 하트비트)이 흘려보낸다.
if [ "$SOURCE" != "antigravity" ] || [ "$SKIP_SEND" -eq 0 ]; then
  flush_spool
fi

if [ -n "$PAYLOAD" ] && [ "$SKIP_SEND" -eq 0 ]; then
  # Antigravity hook은 전송 마감(5초)이 지났거나(위 시간 예산) 이번 재전송이 서버 응답을 하나도
  # 받지 못했으면(antigravity_spool_behind) 보내지 않고 스풀 끝에 넣는다.
  if ! antigravity_send_deadline_passed && ! antigravity_spool_behind && send_payload "$PAYLOAD"; then
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
