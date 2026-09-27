#!/usr/bin/env bash
# hooks/*.sh의 견고성(멱등·스풀·하트비트·오프라인 폴백)을 로컬 wrangler dev로 검증한다.
#
# 사용자의 실제 로컬 개발 상태나 원격 배포에는 절대 손대지 않는다:
#   - 전용 --persist-to 임시 D1 스토리지(매 실행마다 새로 만들고 끝나면 지운다)
#   - 전용 포트, 전용 MY_DASHBOARD_STATE_DIR, 전용(존재하지 않는) MY_DASHBOARD_ENV
#   - 끝나면(성공/실패/중단 모두) wrangler dev를 반드시 죽인다
#
# 종료 코드: 모든 체크 통과 시 0, 하나라도 실패하면 1.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_DIR="${MY_DASHBOARD_TEST_SERVER_DIR:-$REPO_ROOT/server}"
SERVER_CONFIG="${MY_DASHBOARD_TEST_SERVER_CONFIG:-$SERVER_DIR/test/wrangler.jsonc}"
DATABASE_NAME="${MY_DASHBOARD_TEST_DATABASE:-dashboard-package-test}"
WRANGLER="${MY_DASHBOARD_TEST_WRANGLER:-$SERVER_DIR/node_modules/.bin/wrangler}"
log() { printf '%s\n' "$*" >&2; }
HOOK="$SCRIPT_DIR/agent-event-hook.sh"
# PATH를 shadow(jq 없이)로 바꾸는 체크(5)에서도 bash 자체는 PATH 조회 없이 찾을 수 있도록
# 절대 경로를 미리 잡아 둔다.
BASH_BIN="$(command -v bash)"

# 이 스크립트는 repo clone 환경 전용이다 - server/에서 로컬 wrangler dev를 직접
# 띄운다. `curl … /setup.sh | bash` 원커맨드 설치는 hook 스크립트만 내려받고 repo는
# clone하지 않으므로, 그 자리에서 실행하면 서버 fixture가 없어 npx wrangler 단계에서
# 알아보기 힘든 오류로 죽는다 - 먼저 감지해서 원인을 명확히 알려주고 끝낸다.
if [ ! -f "$SERVER_CONFIG" ] || [ ! -x "$WRANGLER" ]; then
  log "이 스크립트는 repo를 clone한 환경 전용이다 - server/ 디렉터리가 없다: $SERVER_DIR"
  log "curl 원커맨드로 설치한 자리($SCRIPT_DIR)에는 hook 스크립트만 내려받아져 있고 repo는 없다."
  log "견고성 점검을 하려면 repo를 clone한 뒤 그 안에서 'bash hooks/test-hooks.sh'를 실행해라."
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/my-dashboard-test-hooks.XXXXXX")"
PERSIST_DIR="$WORK_DIR/wrangler-persist"
PORT=$((20000 + ($$ % 20000)))
SERVER_URL="http://127.0.0.1:$PORT"
BAD_URL="http://127.0.0.1:1"
TOKEN="${MY_DASHBOARD_TEST_TOKEN:-test-auth-token}"
NO_ENV_FILE="$WORK_DIR/no-such-env"
SERVER_PID=""
FAIL_COUNT=0
CHECK_RESULTS=()



# shellcheck disable=SC2329 # trap으로 간접 호출된다 - shellcheck은 trap 등록을 추적하지 못한다.
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    # Terminate only this fixture's descendant tree, even when Wrangler forks workerd.
    python3 - "$SERVER_PID" <<'CLEANUP_PY'
import os, signal, subprocess, sys
root = int(sys.argv[1])
rows = [tuple(map(int, row.split())) for row in subprocess.check_output(
    ['ps', '-axo', 'pid=,ppid='], text=True).splitlines() if row.strip()]
children = {}
for pid, parent in rows:
    children.setdefault(parent, []).append(pid)
def stop(pid):
    for child in children.get(pid, []):
        stop(child)
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
stop(root)
CLEANUP_PY
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [ "${MY_DASHBOARD_TEST_KEEP:-0}" != "1" ]; then
    rm -rf "$WORK_DIR" 2>/dev/null
  else
    log "WORK_DIR 보존됨: $WORK_DIR"
  fi
}
trap cleanup EXIT INT TERM

record() {
  local name="$1" ok="$2" evidence="$3"
  if [ "$ok" -eq 0 ]; then
    log "PASS: $name"
    CHECK_RESULTS+=("PASS|$name|$evidence")
  else
    log "FAIL: $name — $evidence"
    CHECK_RESULTS+=("FAIL|$name|$evidence")
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ---------- D1 헬퍼 ----------

d1_query() {
  (cd "$SERVER_DIR" && "$WRANGLER" d1 execute "$DATABASE_NAME" --config "$SERVER_CONFIG" --local --persist-to "$PERSIST_DIR" --json --command "$1" 2>"$WORK_DIR/d1.err")
}

d1_scalar() {
  # 첫 결과 행의 지정된 컬럼 하나를 뽑는다. 행이 없으면 빈 문자열.
  local sql="$1" col="$2"
  d1_query "$sql" | jq -r --arg c "$col" '(.[0].results[0][$c]) // empty' 2>/dev/null
}

# ---------- hook 호출 헬퍼 ----------

run_hook() {
  # run_hook <stdin-json> <MY_DASHBOARD_URL> <STATE_DIR> [extra_env...]
  local input="$1" url="$2" state_dir="$3"
  shift 3
  env -i PATH="$PATH" HOME="$HOME" \
    MY_DASHBOARD_URL="$url" \
    MY_DASHBOARD_TOKEN="$TOKEN" \
    MY_DASHBOARD_INCLUDE_CONTENT=1 \
    MY_DASHBOARD_STATE_DIR="$state_dir" \
    MY_DASHBOARD_ENV="$NO_ENV_FILE" \
    "$@" \
    "$BASH_BIN" "$HOOK" claude-code <<<"$input"
  echo $?
}

run_hook_src() {
  # run_hook_src <source> <stdin-json> <MY_DASHBOARD_URL> <STATE_DIR> [extra_env...]
  # run_hook과 같지만 source 인자(claude-code|codex)를 고를 수 있다 - A/F 이벤트명
  # 변환 검증에는 두 source를 모두 hook에 넘겨봐야 한다.
  local source="$1" input="$2" url="$3" state_dir="$4"
  shift 4
  env -i PATH="$PATH" HOME="$HOME" \
    MY_DASHBOARD_URL="$url" \
    MY_DASHBOARD_TOKEN="$TOKEN" \
    MY_DASHBOARD_INCLUDE_CONTENT=1 \
    MY_DASHBOARD_STATE_DIR="$state_dir" \
    MY_DASHBOARD_ENV="$NO_ENV_FILE" \
    "$@" \
    "$BASH_BIN" "$HOOK" "$source" <<<"$input"
  echo $?
}

# ---------- 서버 기동 ----------

start_server() {
  mkdir -p "$PERSIST_DIR"
  log "D1 마이그레이션 적용 중..."
  if ! (cd "$SERVER_DIR" && "$WRANGLER" d1 migrations apply "$DATABASE_NAME" --config "$SERVER_CONFIG" --local --persist-to "$PERSIST_DIR" >"$WORK_DIR/migrate.log" 2>&1); then
    log "마이그레이션 실패:"
    cat "$WORK_DIR/migrate.log" >&2
    return 1
  fi

  log "wrangler dev 기동 중 (port $PORT)..."
  (cd "$SERVER_DIR" && exec "$WRANGLER" dev --config "$SERVER_CONFIG" --port "$PORT" --persist-to "$PERSIST_DIR" \
    >"$WORK_DIR/server.log" 2>&1) &
  SERVER_PID=$!

  local tries=0
  while [ "$tries" -lt 60 ]; do
    if curl -sS --max-time 1 "$SERVER_URL/healthz" 2>/dev/null | grep -q '"ok":true'; then
      log "서버 준비 완료."
      return 0
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      log "wrangler dev가 조기 종료됨. 로그:"
      cat "$WORK_DIR/server.log" >&2
      return 1
    fi
    tries=$((tries + 1))
    sleep 0.5
  done
  log "서버가 30초 내에 준비되지 않음. 로그:"
  cat "$WORK_DIR/server.log" >&2
  return 1
}

# ---------- Check 1: payload 필드 존재 ----------

check1_fields() {
  local input='{"session_id":"field-test","cwd":"/tmp/demo","hook_event_name":"UserPromptSubmit","prompt":"hello world"}'
  local code
  code="$(run_hook "$input" "$SERVER_URL" "$WORK_DIR/state-c1")"
  if [ "$code" != "0" ]; then
    record "1. payload 필드 존재" 1 "hook exit code=$code (기대: 0)"
    return
  fi

  local event_id occurred_at host raw
  event_id="$(d1_scalar "SELECT event_id FROM dashboard_events WHERE session_key='claude-code:field-test'" event_id)"
  occurred_at="$(d1_scalar "SELECT occurred_at FROM dashboard_events WHERE session_key='claude-code:field-test'" occurred_at)"
  host="$(d1_scalar "SELECT host FROM dashboard_events WHERE session_key='claude-code:field-test'" host)"
  raw="$(d1_scalar "SELECT raw FROM dashboard_events WHERE session_key='claude-code:field-test'" raw)"

  local expect_host
  expect_host="$(hostname -s 2>/dev/null)"

  local reason=""
  case "$event_id" in
    field-test-*) ;;
    *) reason="event_id='$event_id' (기대 패턴: field-test-<ms>-<random>)" ;;
  esac
  [ -n "$occurred_at" ] || reason="${reason} occurred_at 비어있음"
  if [ "$host" != "$expect_host" ]; then
    reason="${reason} host='$host' (기대: '$expect_host')"
  fi
  for marker in '"protocol_version":1' '"event_id":' '"occurred_at":' '"host":' '"raw":'; do
    case "$raw" in
      *"$marker"*) ;;
      *) reason="${reason} raw에 ${marker} 없음" ;;
    esac
  done

  if [ -z "$reason" ]; then
    record "1. payload 필드 존재" 0 "event_id=$event_id host=$host occurred_at=$occurred_at raw에 5개 필드 마커 모두 존재"
  else
    record "1. payload 필드 존재" 1 "$reason (raw=$raw)"
  fi
}

# ---------- Check 2/3: 스풀 + 복구 flush ----------

check2_3_spool_and_recovery() {
  local state_dir="$WORK_DIR/state-spool"
  local input='{"session_id":"spool-test","cwd":"/tmp/demo","hook_event_name":"UserPromptSubmit","prompt":"x"}'

  for i in 1 2 3; do
    run_hook "$input" "$BAD_URL" "$state_dir" "MY_DASHBOARD_EVENT_ID=spool-$i" >/dev/null
  done

  local spool_file="$state_dir/spool.ndjson"
  local n
  n="$(wc -l < "$spool_file" 2>/dev/null | tr -d ' ')"
  [ -z "$n" ] && n=0
  if [ "$n" = "3" ]; then
    record "2. 실패 3회 → 스풀 3줄" 0 "spool.ndjson 줄 수=$n"
  else
    record "2. 실패 3회 → 스풀 3줄" 1 "spool.ndjson 줄 수=$n (기대: 3)"
  fi

  local code
  code="$(run_hook "$input" "$SERVER_URL" "$state_dir" "MY_DASHBOARD_EVENT_ID=spool-4")"
  local n2
  n2="$(wc -l < "$spool_file" 2>/dev/null | tr -d ' ')"
  [ -z "$n2" ] && n2=0
  local total
  total="$(d1_scalar "SELECT COUNT(*) AS c FROM dashboard_events WHERE session_key='claude-code:spool-test'" c)"

  if [ "$code" = "0" ] && [ "$n2" = "0" ] && [ "$total" = "4" ]; then
    record "3. 복구 시 flush + 총 4건 수신" 0 "flush 후 spool=${n2}줄, DB 총 이벤트=$total"
  else
    record "3. 복구 시 flush + 총 4건 수신" 1 "exit=$code, flush 후 spool=${n2}줄(기대 0), DB 총 이벤트=$total(기대 4)"
  fi
}

# ---------- Check 4: 하트비트 스로틀 ----------

check4_heartbeat_throttle() {
  local state_dir="$WORK_DIR/state-hb"
  local input='{"session_id":"hb-test","cwd":"/tmp/demo","hook_event_name":"PostToolUse"}'

  for _ in 1 2 3 4 5; do
    run_hook "$input" "$SERVER_URL" "$state_dir" >/dev/null
  done

  local n
  n="$(d1_scalar "SELECT COUNT(*) AS c FROM dashboard_events WHERE session_key='claude-code:hb-test' AND event='PostToolUse'" c)"
  if [ "$n" = "1" ]; then
    record "4. 연속 PostToolUse 5회 → 실제 전송 1회" 0 "DB에 실제로 도착한 PostToolUse 이벤트=${n}건"
  else
    record "4. 연속 PostToolUse 5회 → 실제 전송 1회" 1 "DB에 실제로 도착한 PostToolUse 이벤트=${n}건 (기대 1)"
  fi
}

# ---------- Check 5: 방어적 동작 (malformed JSON / empty stdin / jq 부재) ----------

check5_defensive() {
  local state_dir="$WORK_DIR/state-defensive"
  local ok=0
  local details=""

  local code
  code="$(run_hook '' "$SERVER_URL" "$state_dir/empty")"
  if [ "$code" != "0" ]; then ok=1; details="${details} empty-stdin exit=$code;"; fi

  code="$(run_hook '{not valid json at all' "$SERVER_URL" "$state_dir/malformed")"
  if [ "$code" != "0" ]; then ok=1; details="${details} malformed-json exit=$code;"; fi

  # jq만 빠진 PATH를 만든다. /usr/bin에 jq와 curl 등이 같이 있어 jq만 지우는 게 불가능하므로,
  # 필요한 도구를 미리 심볼릭 링크한 shadow 디렉터리로 PATH를 통째로 교체한다.
  local shadow_dir="$WORK_DIR/shadow-no-jq"
  mkdir -p "$shadow_dir"
  local tool resolved
  for tool in cat mkdir head iconv wc tr tail mv rm rmdir stat date hostname sleep curl sed python3 grep; do
    resolved="$(command -v "$tool" 2>/dev/null)"
    [ -n "$resolved" ] && ln -sf "$resolved" "$shadow_dir/$tool"
  done
  if command -v jq >/dev/null 2>&1 && [ -e "$shadow_dir/jq" ]; then
    ok=1; details="${details} shadow PATH에 jq가 남아있음(테스트 버그);"
  fi

  local input='{"session_id":"nojq-test","cwd":"/tmp/demo","hook_event_name":"UserPromptSubmit","prompt":"x"}'
  code="$(env -i PATH="$shadow_dir" HOME="$HOME" \
    MY_DASHBOARD_URL="$SERVER_URL" \
    MY_DASHBOARD_TOKEN="$TOKEN" \
    MY_DASHBOARD_INCLUDE_CONTENT=1 \
    MY_DASHBOARD_STATE_DIR="$state_dir/nojq" \
    MY_DASHBOARD_ENV="$NO_ENV_FILE" \
    "$BASH_BIN" "$HOOK" claude-code <<<"$input"; echo $?)"
  if [ "$code" != "0" ]; then ok=1; details="${details} jq-removed exit=$code;"; fi

  if [ "$ok" -eq 0 ]; then
    record "5. malformed/empty/jq부재에도 exit 0" 0 "세 경우 모두 exit 0"
  else
    record "5. malformed/empty/jq부재에도 exit 0" 1 "$details"
  fi
}

# ---------- Check 6: 동일 event_id 재전송 → 중복 처리 ----------

check6_idempotent() {
  local state_dir="$WORK_DIR/state-dup"
  local input='{"session_id":"dup-test","cwd":"/tmp/demo","hook_event_name":"UserPromptSubmit","prompt":"x"}'

  run_hook "$input" "$SERVER_URL" "$state_dir" "MY_DASHBOARD_EVENT_ID=dup-fixed-1" >/dev/null
  run_hook "$input" "$SERVER_URL" "$state_dir" "MY_DASHBOARD_EVENT_ID=dup-fixed-1" >/dev/null

  local n
  n="$(d1_scalar "SELECT COUNT(*) AS c FROM dashboard_events WHERE event_id='dup-fixed-1'" c)"
  if [ "$n" = "1" ]; then
    record "6. 동일 event_id 재전송 → 중복 처리" 0 "event_id='dup-fixed-1' 행 수=$n"
  else
    record "6. 동일 event_id 재전송 → 중복 처리" 1 "event_id='dup-fixed-1' 행 수=$n (기대 1)"
  fi
}

# ---------- Check 7: A - notification_type 제외목록 3종 → 합성 이벤트명 변환 ----------

check7_notification_exclude_mapping() {
  local ok=0
  local details=""
  local pair notif_type expect_event session_id input event raw code

  for pair in "idle_prompt:IdleNotification" "auth_success:AuthNotification" "agent_completed:AgentCompletedNotification"; do
    notif_type="${pair%%:*}"
    expect_event="${pair##*:}"
    session_id="notif-${notif_type}"
    input="{\"session_id\":\"$session_id\",\"cwd\":\"/tmp/demo\",\"hook_event_name\":\"Notification\",\"notification_type\":\"$notif_type\"}"
    code="$(run_hook "$input" "$SERVER_URL" "$WORK_DIR/state-notif-exclude")"
    if [ "$code" != "0" ]; then
      ok=1; details="${details} [$notif_type] hook exit=$code;"
      continue
    fi
    event="$(d1_scalar "SELECT event FROM dashboard_events WHERE session_key='claude-code:$session_id'" event)"
    raw="$(d1_scalar "SELECT raw FROM dashboard_events WHERE session_key='claude-code:$session_id'" raw)"
    if [ "$event" != "$expect_event" ]; then
      ok=1; details="${details} [$notif_type] event='$event'(기대 $expect_event);"
    fi
    case "$raw" in
      *"\"notification_type\":\"$notif_type\""*) ;;
      *) ok=1; details="${details} [$notif_type] raw에 notification_type 마커 없음;" ;;
    esac
  done

  if [ "$ok" -eq 0 ]; then
    record "7. A: 제외목록 3종 → 합성 이벤트명 변환 + notification_type 동봉" 0 "idle_prompt→IdleNotification, auth_success→AuthNotification, agent_completed→AgentCompletedNotification 모두 확인"
  else
    record "7. A: 제외목록 3종 → 합성 이벤트명 변환 + notification_type 동봉" 1 "$details"
  fi
}

# ---------- Check 8: A - 제외목록 밖(모르는 타입 포함)은 Notification 그대로 ----------

check8_notification_unknown_stays_default() {
  local ok=0
  local details=""

  local input1='{"session_id":"notif-unknown","cwd":"/tmp/demo","hook_event_name":"Notification","notification_type":"permission_prompt"}'
  local code1 event1 raw1
  code1="$(run_hook "$input1" "$SERVER_URL" "$WORK_DIR/state-notif-default")"
  event1="$(d1_scalar "SELECT event FROM dashboard_events WHERE session_key='claude-code:notif-unknown'" event)"
  raw1="$(d1_scalar "SELECT raw FROM dashboard_events WHERE session_key='claude-code:notif-unknown'" raw)"
  if [ "$code1" != "0" ] || [ "$event1" != "Notification" ]; then
    ok=1; details="${details} 모르는 타입(permission_prompt): exit=$code1 event='$event1'(기대 Notification);"
  fi
  case "$raw1" in
    *'"notification_type":"permission_prompt"'*) ;;
    *) ok=1; details="${details} 모르는 타입: raw에 notification_type 마커 없음(원장 additive 필드 누락);" ;;
  esac

  local input2='{"session_id":"notif-none","cwd":"/tmp/demo","hook_event_name":"Notification"}'
  local code2 event2
  code2="$(run_hook "$input2" "$SERVER_URL" "$WORK_DIR/state-notif-default")"
  event2="$(d1_scalar "SELECT event FROM dashboard_events WHERE session_key='claude-code:notif-none'" event)"
  if [ "$code2" != "0" ] || [ "$event2" != "Notification" ]; then
    ok=1; details="${details} notification_type 필드 자체 없음: exit=$code2 event='$event2'(기대 Notification);"
  fi

  if [ "$ok" -eq 0 ]; then
    record "8. A: 제외목록 밖(모르는 타입/필드 없음)은 Notification 유지" 0 "permission_prompt·필드없음 모두 Notification 유지, 부분/오탐 없음 확인"
  else
    record "8. A: 제외목록 밖(모르는 타입/필드 없음)은 Notification 유지" 1 "$details"
  fi
}

# ---------- Check 9: F - codex PreToolUse(동기·비동기) → UserInputRequest ----------

check9_codex_user_input_request() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-codex-uir"

  # 동기: questions[0]에 header와 question이 둘 다 있으면 header 우선.
  local input1='{"session_id":"codex-uir-sync","cwd":"/tmp/demo","hook_event_name":"PreToolUse","tool_name":"request_user_input","tool_input":{"questions":[{"header":"Pick approach","question":"Which one?"}]}}'
  local code1 event1 msg1
  code1="$(run_hook_src codex "$input1" "$SERVER_URL" "$state_dir")"
  event1="$(d1_scalar "SELECT event FROM dashboard_events WHERE session_key='codex:codex-uir-sync'" event)"
  msg1="$(d1_scalar "SELECT message FROM dashboard_events WHERE session_key='codex:codex-uir-sync'" message)"
  if [ "$code1" != "0" ] || [ "$event1" != "UserInputRequest" ] || [ "$msg1" != "Pick approach" ]; then
    ok=1; details="${details} 동기(header 있음) exit=$code1 event='$event1'(기대 UserInputRequest) message='$msg1'(기대 'Pick approach');"
  fi

  # 비동기: header 없으면 question으로 폴백. tool_name 정규화(영숫자만·소문자) 완전일치 판정.
  local input2='{"session_id":"codex-uir-async","cwd":"/tmp/demo","hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_input":{"questions":[{"question":"Only question"}]}}'
  local code2 event2 msg2
  code2="$(run_hook_src codex "$input2" "$SERVER_URL" "$state_dir")"
  event2="$(d1_scalar "SELECT event FROM dashboard_events WHERE session_key='codex:codex-uir-async'" event)"
  msg2="$(d1_scalar "SELECT message FROM dashboard_events WHERE session_key='codex:codex-uir-async'" message)"
  if [ "$code2" != "0" ] || [ "$event2" != "UserInputRequest" ] || [ "$msg2" != "Only question" ]; then
    ok=1; details="${details} 비동기(header 없음→question 폴백) exit=$code2 event='$event2'(기대 UserInputRequest) message='$msg2'(기대 'Only question');"
  fi

  # 부분 문자열 매칭 금지: request_user_input_summary 같은 다른 도구를 오인하면 안 된다.
  local input3='{"session_id":"codex-uir-trap","cwd":"/tmp/demo","hook_event_name":"PreToolUse","tool_name":"request_user_input_summary"}'
  local code3 event3
  code3="$(run_hook_src codex "$input3" "$SERVER_URL" "$state_dir")"
  event3="$(d1_scalar "SELECT event FROM dashboard_events WHERE session_key='codex:codex-uir-trap'" event)"
  if [ "$code3" != "0" ] || [ "$event3" != "PreToolUse" ]; then
    ok=1; details="${details} 부분매칭 트랩(request_user_input_summary) exit=$code3 event='$event3'(기대 PreToolUse — 변환되면 안 됨);"
  fi

  if [ "$ok" -eq 0 ]; then
    record "9. F: codex PreToolUse(동기·비동기) → UserInputRequest, 부분매칭 금지" 0 "header 우선/question 폴백/request_user_input_summary 미변환 모두 확인"
  else
    record "9. F: codex PreToolUse(동기·비동기) → UserInputRequest, 부분매칭 금지" 1 "$details"
  fi
}

# ---------- Check 10: F - codex PostToolUse는 동기만 UserInputResolved(스로틀 없음), 비동기는 하트비트 유지 ----------

check10_codex_user_input_resolved() {
  local ok=0
  local details=""

  # 동기 해소: F는 스로틀이 없다 - 연달아 2번 보내도(각기 다른 event_id) 둘 다 도착해야 한다.
  local state_dir="$WORK_DIR/state-codex-uires"
  local input='{"session_id":"codex-uires","cwd":"/tmp/demo","hook_event_name":"PostToolUse","tool_name":"request_user_input"}'
  run_hook_src codex "$input" "$SERVER_URL" "$state_dir" "MY_DASHBOARD_EVENT_ID=uires-1" >/dev/null
  run_hook_src codex "$input" "$SERVER_URL" "$state_dir" "MY_DASHBOARD_EVENT_ID=uires-2" >/dev/null

  local n
  n="$(d1_scalar "SELECT COUNT(*) AS c FROM dashboard_events WHERE session_key='codex:codex-uires' AND event='UserInputResolved'" c)"
  if [ "$n" != "2" ]; then
    ok=1; details="${details} 동기 해소 연속 2회 → UserInputResolved 도착 건수=$n(기대 2, 스로틀 없어야 함);"
  fi

  # 비동기는 해소로 바꾸면 안 되고 일반 PostToolUse 하트비트(60초 스로틀) 경로 그대로다 -
  # 5회 연속 보내도 체크4와 같은 패턴으로 실제 도착은 1건이어야 하고, UserInputResolved는 0건이어야 한다.
  local state_dir2="$WORK_DIR/state-codex-uires-async"
  local input_async='{"session_id":"codex-uires-async","cwd":"/tmp/demo","hook_event_name":"PostToolUse","tool_name":"request_user_input_async"}'
  local i
  for i in 1 2 3 4 5; do
    run_hook_src codex "$input_async" "$SERVER_URL" "$state_dir2" >/dev/null
  done
  local n2 n3
  n2="$(d1_scalar "SELECT COUNT(*) AS c FROM dashboard_events WHERE session_key='codex:codex-uires-async' AND event='PostToolUse'" c)"
  n3="$(d1_scalar "SELECT COUNT(*) AS c FROM dashboard_events WHERE session_key='codex:codex-uires-async' AND event='UserInputResolved'" c)"
  if [ "$n2" != "1" ] || [ "$n3" != "0" ]; then
    ok=1; details="${details} 비동기 PostToolUse 5회 → PostToolUse 도착=$n2(기대 1, 하트비트 스로틀), UserInputResolved 도착=$n3(기대 0, 해소로 바뀌면 안됨);"
  fi

  if [ "$ok" -eq 0 ]; then
    record "10. F: codex PostToolUse 동기만 UserInputResolved(스로틀 없음), 비동기는 하트비트 유지" 0 "동기 2/2 도착, 비동기 5회→PostToolUse 1건만 도착·UserInputResolved 0건"
  else
    record "10. F: codex PostToolUse 동기만 UserInputResolved(스로틀 없음), 비동기는 하트비트 유지" 1 "$details"
  fi
}

# ---------- Check 11: 훅 구버전 배너 - hook_rev 필드 동봉(repo에서 직접 실행하면 미치환 상태) ----------

check11_hook_rev_field() {
  # 이 스크립트는 서버가 내려준 사본이 아니라 repo의 agent-event-hook.sh를 직접 실행하므로
  # HOOK_REV="__MY_DASHBOARD_HOOK_REV__" 치환이 일어나지 않는다(GET /setup.sh·
  # GET /hooks/files/:name 라우트만 치환한다 - hooks-files.test.ts가 그쪽을 검증한다).
  # 여기서는 그 미치환 리터럴이라도 hook_rev 필드로 그대로 실려서(additive) raw에 남는지만
  # 본다 - 서버는 이 값을 dashboard_meta.hook_revs 원장에 저장만 할 뿐 형식을 검사하지 않는다.
  local input='{"session_id":"hook-rev-field-test","cwd":"/tmp/demo","hook_event_name":"UserPromptSubmit","prompt":"x"}'
  local code
  code="$(run_hook "$input" "$SERVER_URL" "$WORK_DIR/state-hookrev")"
  if [ "$code" != "0" ]; then
    record "11. 훅 구버전 배너: hook_rev 필드 동봉" 1 "hook exit code=$code (기대: 0)"
    return
  fi

  local raw
  raw="$(d1_scalar "SELECT raw FROM dashboard_events WHERE session_key='claude-code:hook-rev-field-test'" raw)"
  case "$raw" in
    *'"hook_rev":"__MY_DASHBOARD_HOOK_REV__"'*)
      record "11. 훅 구버전 배너: hook_rev 필드 동봉" 0 "raw에 hook_rev 마커(미치환 리터럴) 존재"
      ;;
    *)
      record "11. 훅 구버전 배너: hook_rev 필드 동봉" 1 "raw에 hook_rev 마커 없음 (raw=$raw)"
      ;;
  esac
}

# ---------- Check 12: devin - stdin에 cwd가 없을 때 project 폴백 ----------
# Devin은 hook stdin에 cwd를 싣지 않는다(공식 문서상 공통 필드는 session_id·prompt_id
# + 이벤트별 필드뿐). hook은 DEVIN_PROJECT_DIR env → hook 프로세스의 cwd 순으로
# project를 채운다 — 이 체크가 없으면 devin 세션 카드 제목이 "unknown"으로 뜨는
# 회귀를 아무것도 잡지 못한다.

check12_devin_project_fallback() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-devin-proj"

  # (a) stdin에 cwd 없음 + DEVIN_PROJECT_DIR 설정 → project는 env 값.
  local input_a='{"session_id":"devin-envproj","hook_event_name":"UserPromptSubmit","prompt":"x"}'
  local code_a project_a
  code_a="$(run_hook_src devin "$input_a" "$SERVER_URL" "$state_dir" "DEVIN_PROJECT_DIR=/tmp/devin-proj")"
  project_a="$(d1_scalar "SELECT project FROM dashboard_sessions WHERE key='devin:devin-envproj'" project)"
  if [ "$code_a" != "0" ] || [ "$project_a" != "/tmp/devin-proj" ]; then
    ok=1; details="${details} (a) DEVIN_PROJECT_DIR 폴백: exit=$code_a project='$project_a'(기대 /tmp/devin-proj);"
  fi

  # (b) stdin의 cwd가 있으면 env보다 그쪽이 이긴다.
  local input_b='{"session_id":"devin-cwdwins","cwd":"/tmp/stdin-cwd","hook_event_name":"UserPromptSubmit","prompt":"x"}'
  local code_b project_b
  code_b="$(run_hook_src devin "$input_b" "$SERVER_URL" "$state_dir" "DEVIN_PROJECT_DIR=/tmp/devin-proj")"
  project_b="$(d1_scalar "SELECT project FROM dashboard_sessions WHERE key='devin:devin-cwdwins'" project)"
  if [ "$code_b" != "0" ] || [ "$project_b" != "/tmp/stdin-cwd" ]; then
    ok=1; details="${details} (b) stdin cwd 우선: exit=$code_b project='$project_b'(기대 /tmp/stdin-cwd);"
  fi

  # (c) cwd도 env도 없으면 hook 프로세스의 cwd(= 이 스크립트를 실행한 디렉터리)로
  # 둔다 — "unknown"으로 떨어지면 안 된다. 논리 경로/물리 경로 차이(symlink)를
  # 흡수하기 위해 둘 다 허용한다.
  local input_c='{"session_id":"devin-pwdproj","hook_event_name":"UserPromptSubmit","prompt":"x"}'
  local code_c project_c
  code_c="$(run_hook_src devin "$input_c" "$SERVER_URL" "$state_dir")"
  project_c="$(d1_scalar "SELECT project FROM dashboard_sessions WHERE key='devin:devin-pwdproj'" project)"
  case "$project_c" in
    "$(pwd)"|"$(pwd -P)") ;;
    *) ok=1; details="${details} (c) hook cwd 폴백: exit=$code_c project='$project_c'(기대 '$(pwd)');" ;;
  esac

  if [ "$ok" -eq 0 ]; then
    record "12. devin: stdin에 cwd 없으면 DEVIN_PROJECT_DIR→pwd 폴백" 0 "env 폴백·stdin cwd 우선·hook cwd 폴백 모두 확인"
  else
    record "12. devin: stdin에 cwd 없으면 DEVIN_PROJECT_DIR→pwd 폴백" 1 "$details"
  fi
}

# ---------- Check 13: 설정 우선순위 - 환경변수 > env 파일 > 기본값 ----------
# 소싱된 env 파일이 호출 env를 덮어쓰던 시절의 회귀: env로 준 MY_DASHBOARD_URL이
# 묵살되어 이벤트가 파일 속 운영 서버로 나가는 사고가 실제로 있었다. 이 체크가
# 없으면 "파일이 env를 이긴다"로 되돌아가도 아무것도 잡지 못한다.

check13_env_beats_file() {
  local ok=0
  local details=""

  # (a) 파일에는 죽은 URL·잘못된 토큰, env에는 올바른 값 → env가 이겨야 도착한다.
  #     파일이 이기면 127.0.0.1:1로 보내다 실패해 스풀에만 쌓이고 DB에는 영원히 0행이다
  #     (이 state_dir의 스풀은 이 체크에서만 쓰므로 늦게 flush될 경로도 없다).
  local env_file="$WORK_DIR/bad-env"
  printf 'MY_DASHBOARD_URL=%s\nMY_DASHBOARD_TOKEN=%s\n' "$BAD_URL" "wrong-token" > "$env_file"
  local input_a='{"session_id":"env-prio","cwd":"/tmp/demo","hook_event_name":"UserPromptSubmit","prompt":"x"}'
  local code_a n_a
  code_a="$(run_hook "$input_a" "$SERVER_URL" "$WORK_DIR/state-envprio" "MY_DASHBOARD_ENV=$env_file")"
  n_a="$(d1_scalar "SELECT COUNT(*) AS c FROM dashboard_events WHERE session_key='claude-code:env-prio'" c)"
  if [ "$code_a" != "0" ] || [ "$n_a" != "1" ]; then
    ok=1; details="${details} (a) env>파일: exit=$code_a rows=$n_a(기대 1 — 파일이 이겼으면 dead URL로 가서 0);"
  fi

  # (b) env가 비워 둔 키는 파일이 채운다 — env에 URL/TOKEN 없이 파일만 올바른 값.
  #     운영 기계의 실제 경로(파일 단독 제공)가 여기서 보장된다.
  local env_file2="$WORK_DIR/good-env"
  printf 'MY_DASHBOARD_URL=%s\nMY_DASHBOARD_TOKEN=%s\n' "$SERVER_URL" "$TOKEN" > "$env_file2"
  local input_b='{"session_id":"env-file-fills","cwd":"/tmp/demo","hook_event_name":"UserPromptSubmit","prompt":"x"}'
  local code_b n_b
  code_b="$(env -i PATH="$PATH" HOME="$HOME" \
    MY_DASHBOARD_STATE_DIR="$WORK_DIR/state-envfills" \
    MY_DASHBOARD_ENV="$env_file2" \
    "$BASH_BIN" "$HOOK" claude-code <<<"$input_b"; echo $?)"
  n_b="$(d1_scalar "SELECT COUNT(*) AS c FROM dashboard_events WHERE session_key='claude-code:env-file-fills'" c)"
  if [ "$code_b" != "0" ] || [ "$n_b" != "1" ]; then
    ok=1; details="${details} (b) 파일 단독 제공: exit=$code_b rows=$n_b(기대 1);"
  fi

  if [ "$ok" -eq 0 ]; then
    record "13. 설정 우선순위: env > 파일 > 기본값" 0 "env가 파일의 dead URL을 누르고 도착, 파일 단독 제공도 도착"
  else
    record "13. 설정 우선순위: env > 파일 > 기본값" 1 "$details"
  fi
}

check14_devin_ask_translation() {
  local ok=0
  local details=""

  local input_a='{"session_id":"devin-ask","hook_event_name":"PreToolUse","prompt_id":"p-ask","tool_use_id":"u-ask","tool_name":"ask_user_question","tool_input":{"questions":[{"header":"진행할까","question":"which option"}]}}'
  local code_a event_a pid_a tuid_a tname_a msg_a
  code_a="$(run_hook_src devin "$input_a" "$SERVER_URL" "$WORK_DIR/state-devin-ask")"
  event_a="$(d1_scalar "SELECT event FROM dashboard_events WHERE session_key='devin:devin-ask'" event)"
  pid_a="$(d1_scalar "SELECT prompt_id FROM dashboard_events WHERE session_key='devin:devin-ask'" prompt_id)"
  tuid_a="$(d1_scalar "SELECT tool_use_id FROM dashboard_events WHERE session_key='devin:devin-ask'" tool_use_id)"
  tname_a="$(d1_scalar "SELECT tool_name FROM dashboard_events WHERE session_key='devin:devin-ask'" tool_name)"
  msg_a="$(d1_scalar "SELECT message FROM dashboard_events WHERE session_key='devin:devin-ask'" message)"
  if [ "$code_a" != "0" ] || [ "$event_a" != "UserInputRequest" ] \
    || [ "$pid_a" != "p-ask" ] || [ "$tuid_a" != "u-ask" ] || [ "$tname_a" != "ask_user_question" ] \
    || [ "$msg_a" != "진행할까" ]; then
    ok=1; details="${details} (a) 정확 일치 번역: exit=$code_a event='$event_a'(기대 UserInputRequest) prompt_id='$pid_a' tool_use_id='$tuid_a' tool_name='$tname_a' message='$msg_a';"
  fi

  local pair tool_name session_id input event code
  for pair in "ask_user_question_summary:devin-ask-sum" "functions.ask_user_question:devin-ask-fn"; do
    tool_name="${pair%%:*}"
    session_id="${pair##*:}"
    input="{\"session_id\":\"$session_id\",\"hook_event_name\":\"PreToolUse\",\"prompt_id\":\"p-$session_id\",\"tool_use_id\":\"u-$session_id\",\"tool_name\":\"$tool_name\"}"
    code="$(run_hook_src devin "$input" "$SERVER_URL" "$WORK_DIR/state-devin-ask-trap")"
    event="$(d1_scalar "SELECT event FROM dashboard_events WHERE session_key='devin:$session_id'" event)"
    if [ "$code" != "0" ] || [ "$event" != "PreToolUse" ]; then
      ok=1; details="${details} (b) 유사 도구명($tool_name): exit=$code event='$event'(기대 PreToolUse — 번역되면 안 됨);"
    fi
  done

  if [ "$ok" -eq 0 ]; then
    record "14. devin: 정확한 ask_user_question만 UserInputRequest + 상관 식별자·message 전달" 0 "번역·3개 식별자 컬럼·message 추출 확인, 유사 도구명 2종 미번역"
  else
    record "14. devin: 정확한 ask_user_question만 UserInputRequest + 상관 식별자·message 전달" 1 "$details"
  fi
}

check15_devin_completion_throttle() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-devin-throttle"

  local session="devin-corr"
  run_hook_src devin "{\"session_id\":\"$session\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt_id\":\"p1\"}" "$SERVER_URL" "$state_dir" >/dev/null
  run_hook_src devin "{\"session_id\":\"$session\",\"hook_event_name\":\"PermissionRequest\",\"prompt_id\":\"p1\",\"tool_use_id\":\"u-a\",\"tool_name\":\"exec\"}" "$SERVER_URL" "$state_dir" >/dev/null
  run_hook_src devin "{\"session_id\":\"$session\",\"hook_event_name\":\"PermissionRequest\",\"prompt_id\":\"p1\",\"tool_use_id\":\"u-b\",\"tool_name\":\"exec\"}" "$SERVER_URL" "$state_dir" >/dev/null
  run_hook_src devin "{\"session_id\":\"$session\",\"hook_event_name\":\"PostToolUse\",\"prompt_id\":\"p1\",\"tool_use_id\":\"u-a\",\"tool_name\":\"exec\"}" "$SERVER_URL" "$state_dir" >/dev/null
  run_hook_src devin "{\"session_id\":\"$session\",\"hook_event_name\":\"PostToolUse\",\"prompt_id\":\"p1\",\"tool_use_id\":\"u-b\",\"tool_name\":\"exec\"}" "$SERVER_URL" "$state_dir" >/dev/null

  local n_post state_a
  n_post="$(d1_scalar "SELECT COUNT(*) AS c FROM dashboard_events WHERE session_key='devin:$session' AND event='PostToolUse'" c)"
  state_a="$(d1_scalar "SELECT state FROM dashboard_sessions WHERE key='devin:$session'" state)"
  if [ "$n_post" != "2" ] || [ "$state_a" != "working" ]; then
    ok=1; details="${details} (a) 상관된 PostToolUse 2건(60초 창 안): 도착=$n_post(기대 2) state='$state_a'(기대 working);"
  fi

  local session2="devin-plain"
  local input2="{\"session_id\":\"$session2\",\"hook_event_name\":\"PostToolUse\"}"
  local i
  for i in 1 2 3 4 5; do
    run_hook_src devin "$input2" "$SERVER_URL" "$state_dir" >/dev/null
  done
  local n_plain
  n_plain="$(d1_scalar "SELECT COUNT(*) AS c FROM dashboard_events WHERE session_key='devin:$session2' AND event='PostToolUse'" c)"
  if [ "$n_plain" != "1" ]; then
    ok=1; details="${details} (b) 무상관 devin PostToolUse 5회: 도착=$n_plain(기대 1, 스로틀 유지);"
  fi

  if [ "$ok" -eq 0 ]; then
    record "15. devin: 상관된 PostToolUse는 스로틀 면제, 무상관은 60초 스로틀 유지" 0 "상관 2/2 도착·해소, 무상관 5회→1건"
  else
    record "15. devin: 상관된 PostToolUse는 스로틀 면제, 무상관은 60초 스로틀 유지" 1 "$details"
  fi
}

check16_devin_pending_sequence() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-devin-seq"
  local session="devin-seq"

  run_hook_src devin "{\"session_id\":\"$session\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt_id\":\"p1\"}" "$SERVER_URL" "$state_dir" >/dev/null
  run_hook_src devin "{\"session_id\":\"$session\",\"hook_event_name\":\"PermissionRequest\",\"prompt_id\":\"p1\",\"tool_use_id\":\"u-a\",\"tool_name\":\"exec\"}" "$SERVER_URL" "$state_dir" >/dev/null
  run_hook_src devin "{\"session_id\":\"$session\",\"hook_event_name\":\"PermissionRequest\",\"prompt_id\":\"p1\",\"tool_use_id\":\"u-b\",\"tool_name\":\"exec\"}" "$SERVER_URL" "$state_dir" >/dev/null

  local s_mid
  s_mid="$(d1_scalar "SELECT state FROM dashboard_sessions WHERE key='devin:$session'" state)"
  if [ "$s_mid" != "waiting_input" ]; then
    ok=1; details="${details} A·B 요청 후 state='$s_mid'(기대 waiting_input);"
  fi

  run_hook_src devin "{\"session_id\":\"$session\",\"hook_event_name\":\"PostToolUse\",\"prompt_id\":\"p1\",\"tool_use_id\":\"u-a\",\"tool_name\":\"exec\"}" "$SERVER_URL" "$state_dir" >/dev/null
  local s_after_a
  s_after_a="$(d1_scalar "SELECT state FROM dashboard_sessions WHERE key='devin:$session'" state)"
  if [ "$s_after_a" != "waiting_input" ]; then
    ok=1; details="${details} A 해소 후(B 잔존) state='$s_after_a'(기대 waiting_input);"
  fi

  run_hook_src devin "{\"session_id\":\"$session\",\"hook_event_name\":\"PostToolUse\",\"prompt_id\":\"p1\",\"tool_use_id\":\"u-b\",\"tool_name\":\"exec\"}" "$SERVER_URL" "$state_dir" >/dev/null
  local s_after_b pending_b
  s_after_b="$(d1_scalar "SELECT state FROM dashboard_sessions WHERE key='devin:$session'" state)"
  pending_b="$(d1_scalar "SELECT input_state FROM dashboard_sessions WHERE key='devin:$session'" input_state)"
  if [ "$s_after_b" != "working" ]; then
    ok=1; details="${details} B 해소 후 state='$s_after_b'(기대 working);"
  fi
  case "$pending_b" in
    *'"pending":[]'*|*'"pending": \[\]'*) ;;
    *) ok=1; details="${details} B 해소 후 input_state='$pending_b'(기대 pending 비어있음);" ;;
  esac

  if [ "$ok" -eq 0 ]; then
    record "16. devin: A·B 대기를 각각의 PostToolUse가 정확히 해소" 0 "waiting_input → (A 해소) waiting_input → (B 해소) working"
  else
    record "16. devin: A·B 대기를 각각의 PostToolUse가 정확히 해소" 1 "$details"
  fi
}

check17_installer_devin_matcher() {
  local ok=0
  local details=""
  local fake_home="$WORK_DIR/fake-home"
  mkdir -p "$fake_home/.config/devin"

  cat > "$fake_home/.config/devin/config.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "^exec$", "hooks": [{"type": "command", "command": "echo custom-pre"}]}
    ]
  }
}
EOF

  local i
  for i in 1 2; do
    if ! env -i PATH="$PATH" HOME="$fake_home" "$BASH_BIN" "$SCRIPT_DIR/install.sh" --devin >/dev/null 2>&1; then
      ok=1; details="${details} install.sh --devin ${i}회차 실패;"
    fi
  done

  local cfg="$fake_home/.config/devin/config.json"
  local n_matcher n_custom n_unfiltered
  n_matcher="$(jq '[.hooks.PreToolUse[]? | select(.matcher == "^ask_user_question$") | (.hooks // [])[] | select(.command | test("agent-event-hook.sh"))] | length' "$cfg" 2>/dev/null)"
  n_custom="$(jq '[.hooks.PreToolUse[]? | select(.matcher == "^exec$") | (.hooks // [])[] | select(.command == "echo custom-pre")] | length' "$cfg" 2>/dev/null)"
  n_unfiltered="$(jq '[.hooks.PreToolUse[]? | select(has("matcher") | not)] | length' "$cfg" 2>/dev/null)"

  if [ "$n_matcher" != "1" ]; then
    ok=1; details="${details} ^ask_user_question$ + 우리 command 조합=$n_matcher(기대 1 — 두 번 설치해도 하나);"
  fi
  if [ "$n_custom" != "1" ]; then
    ok=1; details="${details} 기존 사용자 PreToolUse(^exec$/echo custom-pre)=$n_custom(기대 1 — 보존돼야 함);"
  fi
  if [ "$n_unfiltered" != "0" ]; then
    ok=1; details="${details} matcher 없는 PreToolUse 그룹=$n_unfiltered(기대 0);"
  fi

  if [ "$ok" -eq 0 ]; then
    record "17. install.sh: devin ^ask_user_question$ matcher 멱등 등록 + 기존 PreToolUse 보존" 0 "두 번 실행해도 matcher 1개, 사용자 matcher 유지, 무필터 등록 없음"
  else
    record "17. install.sh: devin ^ask_user_question$ matcher 멱등 등록 + 기존 PreToolUse 보존" 1 "$details"
  fi
}

# ---------- 실행 ----------

if ! start_server; then
  log "서버를 띄우지 못해 테스트를 진행할 수 없다."
  exit 1
fi

check1_fields
check2_3_spool_and_recovery
check4_heartbeat_throttle
check5_defensive
check6_idempotent
check7_notification_exclude_mapping
check8_notification_unknown_stays_default
check9_codex_user_input_request
check10_codex_user_input_resolved
check11_hook_rev_field
check12_devin_project_fallback
check13_env_beats_file
check14_devin_ask_translation
check15_devin_completion_throttle
check16_devin_pending_sequence
check17_installer_devin_matcher

log ""
log "===== 결과 요약 ====="
for r in "${CHECK_RESULTS[@]}"; do
  log "$r"
done
log "총 ${#CHECK_RESULTS[@]}개 중 실패 ${FAIL_COUNT}개"

exit "$([ "$FAIL_COUNT" -eq 0 ] && echo 0 || echo 1)"
