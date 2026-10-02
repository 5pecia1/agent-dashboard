#!/usr/bin/env bash
# hooks/*.sh의 견고성(멱등·스풀·하트비트·오프라인 폴백)과 에이전트별 이벤트 번역
# (Antigravity stdout 응답·시간 예산 포함)을 로컬 wrangler dev로 검증한다.
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
# 체크 28이 띄우는 느린·먹통 서버(python3)의 pid들. 중간에 끝나도 cleanup이 죽인다.
AUX_PIDS=""
FAIL_COUNT=0
CHECK_RESULTS=()



# shellcheck disable=SC2329 # trap으로 간접 호출된다 - shellcheck은 trap 등록을 추적하지 못한다.
cleanup() {
  local pid
  for pid in $AUX_PIDS; do
    kill "$pid" 2>/dev/null
  done
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

d1_rows() {
  # 결과 행마다 "열1|열2|..." 한 줄(열 순서는 SELECT 순서, NULL은 null). 행이 없으면 빈 출력.
  # wrangler 호출 하나가 느리므로 여러 이벤트를 한 번에 읽을 때 쓴다.
  d1_query "$1" | jq -r '.[0].results[]? | [.[] | tostring] | join("|")' 2>/dev/null
}

d1_events() {
  # d1_events <session_key> - 도착 순서대로 event 이름을 쉼표로 잇는다. 없으면 빈 문자열.
  d1_query "SELECT event FROM dashboard_events WHERE session_key='$1' ORDER BY id" \
    | jq -r '[.[0].results[]?.event] | join(",")' 2>/dev/null
}

now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
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

# agy가 hook에 넘기는 stdin 한 건. ag_input <conversationId> <나머지 필드(JSON 객체 안쪽 조각)>
# workspacePaths는 늘 /tmp/ag-proj다 - 체크들이 project가 이 값인지(hook cwd가 아닌지) 본다.
# hook은 깨진 JSON을 조용히 버리므로, 조각을 잘못 쓰면 hook 결함처럼 보인다 - 여기서 먼저 알린다.
AG_PROJECT="/tmp/ag-proj"
ag_input() {
  local json
  json="$(printf '{"conversationId":"%s","workspacePaths":["%s"],%s}' "$1" "$AG_PROJECT" "$2")"
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 || log "테스트 버그: ag_input이 만든 stdin이 JSON이 아니다: $json"
  printf '%s' "$json"
}

# agy가 hook stdout에서 읽는 응답(계약 antigravity_hook_translation.stdout_contract). 줄바꿈 포함.
AG_ANSWER_ASK=$'{"decision":"ask"}\n'
AG_ANSWER_STOP=$'{"decision":""}\n'
AG_ANSWER_DEFAULT=$'{}\n'

run_hook_ag() {
  # run_hook_ag <event> <stdin> <MY_DASHBOARD_URL> <STATE_DIR> [extra_env...]
  # run_hook과 달리 stdout·stderr·종료 코드를 따로 담는다(AG_OUT, AG_ERR, AG_CODE) - agy는
  # stdout을 JSON 응답으로 읽으므로 응답이 정확히 그 한 줄인지 바이트 단위로 봐야 한다.
  # stdin은 printf로 그대로 넘긴다(<<<는 줄바꿈을 붙여 빈 입력도 "\n"이 된다).
  # AG_CWD가 있으면 그 디렉터리에서 실행한다 - agy는 hooks.json이 있는 폴더를 cwd로 hook을 실행한다.
  local event="$1" input="$2" url="$3" state_dir="$4"
  shift 4
  (
    if [ -n "${AG_CWD:-}" ]; then cd "$AG_CWD" || exit 97; fi
    printf '%s' "$input" | env -i PATH="$PATH" HOME="$HOME" \
      MY_DASHBOARD_URL="$url" \
      MY_DASHBOARD_TOKEN="$TOKEN" \
      MY_DASHBOARD_INCLUDE_CONTENT=1 \
      MY_DASHBOARD_STATE_DIR="$state_dir" \
      MY_DASHBOARD_ENV="$NO_ENV_FILE" \
      "$@" \
      "$BASH_BIN" "$HOOK" antigravity "$event"
  ) >"$WORK_DIR/ag.out" 2>"$WORK_DIR/ag.err"
  AG_CODE=$?
  AG_OUT="$(cat "$WORK_DIR/ag.out"; printf x)"
  AG_OUT="${AG_OUT%x}"
  AG_ERR="$(cat "$WORK_DIR/ag.err")"
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

# jq만 빠진 PATH용 디렉터리를 만들고 경로를 낸다. /usr/bin에 jq와 curl 등이 같이 있어 jq만
# 지우는 게 불가능하므로, 필요한 도구를 미리 심볼릭 링크한 shadow 디렉터리로 PATH를 통째로
# 교체한다(체크 5·27).
make_shadow_no_jq() {
  local shadow_dir="$WORK_DIR/shadow-no-jq"
  mkdir -p "$shadow_dir"
  local tool resolved
  for tool in cat mkdir head iconv wc tr tail mv rm rmdir stat date hostname sleep curl sed python3 grep ps find; do
    resolved="$(command -v "$tool" 2>/dev/null)"
    [ -n "$resolved" ] && ln -sf "$resolved" "$shadow_dir/$tool"
  done
  printf '%s\n' "$shadow_dir"
}

check5_defensive() {
  local state_dir="$WORK_DIR/state-defensive"
  local ok=0
  local details=""

  local code
  code="$(run_hook '' "$SERVER_URL" "$state_dir/empty")"
  if [ "$code" != "0" ]; then ok=1; details="${details} empty-stdin exit=$code;"; fi

  code="$(run_hook '{not valid json at all' "$SERVER_URL" "$state_dir/malformed")"
  if [ "$code" != "0" ]; then ok=1; details="${details} malformed-json exit=$code;"; fi

  local shadow_dir
  shadow_dir="$(make_shadow_no_jq)"
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

# ---------- Check 7: A - notification_type 제외목록 4종 → 합성 이벤트명 변환 ----------

check7_notification_exclude_mapping() {
  local ok=0
  local details=""
  local pair notif_type expect_event session_id input event raw code

  for pair in "idle_prompt:IdleNotification" "auth_success:AuthNotification" "agent_completed:AgentCompletedNotification" "task_complete:AgentCompletedNotification"; do
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
    record "7. A: 제외목록 4종 → 합성 이벤트명 변환 + notification_type 동봉" 0 "idle_prompt→IdleNotification, auth_success→AuthNotification, agent_completed·task_complete→AgentCompletedNotification 모두 확인"
  else
    record "7. A: 제외목록 4종 → 합성 이벤트명 변환 + notification_type 동봉" 1 "$details"
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

# ---------- Check 18: Grok camelCase 알림·sessionId·GROK_HOOK_EVENT 출처 ----------

check18_grok_notification_and_source() {
  local ok=0
  local details=""
  local code event raw source

  local input1='{"session_id":"grok-idle-camel","cwd":"/tmp/demo","hook_event_name":"Notification","notificationType":"idle_prompt","message":"Waiting for your next prompt"}'
  code="$(run_hook "$input1" "$SERVER_URL" "$WORK_DIR/state-grok-camel")"
  event="$(d1_scalar "SELECT event FROM dashboard_events WHERE session_key='claude-code:grok-idle-camel'" event)"
  raw="$(d1_scalar "SELECT raw FROM dashboard_events WHERE session_key='claude-code:grok-idle-camel'" raw)"
  if [ "$code" != "0" ] || [ "$event" != "IdleNotification" ]; then
    ok=1; details="${details} camelCase idle_prompt: exit=$code event='$event'(기대 IdleNotification);"
  fi
  case "$raw" in
    *'"notification_type":"idle_prompt"'*) ;;
    *) ok=1; details="${details} camelCase idle_prompt: raw에 notification_type 없음;" ;;
  esac

  local input2='{"session_id":"grok-perm-camel","cwd":"/tmp/demo","hook_event_name":"Notification","notificationType":"permission_prompt"}'
  code="$(run_hook "$input2" "$SERVER_URL" "$WORK_DIR/state-grok-perm")"
  event="$(d1_scalar "SELECT event FROM dashboard_events WHERE session_key='claude-code:grok-perm-camel'" event)"
  if [ "$code" != "0" ] || [ "$event" != "Notification" ]; then
    ok=1; details="${details} camelCase permission_prompt: exit=$code event='$event'(기대 Notification);"
  fi

  local input3='{"sessionId":"grok-sid-camel","cwd":"/tmp/demo","hook_event_name":"UserPromptSubmit","prompt":"hi"}'
  code="$(run_hook "$input3" "$SERVER_URL" "$WORK_DIR/state-grok-sid")"
  event="$(d1_scalar "SELECT event FROM dashboard_events WHERE session_key='claude-code:grok-sid-camel'" event)"
  if [ "$code" != "0" ] || [ "$event" != "UserPromptSubmit" ]; then
    ok=1; details="${details} sessionId만: exit=$code event='$event'(기대 UserPromptSubmit, key claude-code:grok-sid-camel);"
  fi

  local input4='{"session_id":"grok-src","cwd":"/tmp/demo","hook_event_name":"Stop","message":"done"}'
  code="$(run_hook "$input4" "$SERVER_URL" "$WORK_DIR/state-grok-src" GROK_HOOK_EVENT=stop)"
  event="$(d1_scalar "SELECT event FROM dashboard_events WHERE session_key='grok:grok-src'" event)"
  source="$(d1_scalar "SELECT source FROM dashboard_events WHERE session_key='grok:grok-src'" source)"
  if [ "$code" != "0" ] || [ "$event" != "Stop" ] || [ "$source" != "grok" ]; then
    ok=1; details="${details} GROK_HOOK_EVENT: exit=$code source='$source' event='$event'(기대 grok/Stop);"
  fi

  if [ "$ok" -eq 0 ]; then
    record "18. Grok: camelCase 알림·sessionId·GROK_HOOK_EVENT 출처" 0 "idle_prompt→IdleNotification, permission_prompt→Notification, sessionId 유지, GROK_HOOK_EVENT면 source grok"
  else
    record "18. Grok: camelCase 알림·sessionId·GROK_HOOK_EVENT 출처" 1 "$details"
  fi
}

# ---------- Antigravity(agy) 체크 공통 ----------
# agy는 hook을 동기로 실행하고 stdout을 JSON 응답으로 읽는다. PreToolUse 무응답은 도구 거부,
# 0이 아닌 종료 코드나 10초 초과는 agy 실행 중단이다. 번역 규칙의 정본은 계약의
# event_state_map.antigravity_hook_translation이다.

# ---------- Check 19: antigravity stdout 응답 ----------
# 응답은 이벤트마다 정확히 한 줄이어야 하고(뒤에 아무것도 붙으면 agy가 JSON으로 못 읽는다),
# 설정이 없거나 입력이 비어도 나와야 한다. 다른 source는 여전히 stdout에 아무것도 쓰지 않는다.

check19_antigravity_stdout() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-ag-stdout"
  local input
  input="$(ag_input ag-stdout '"invocationNum":1,"initialNumSteps":2,"toolCall":{"name":"view_file","args":{}},"fullyIdle":false')"

  local pair event expect
  for pair in "PreInvocation:default" "PreToolUse:ask" "PostToolUse:default" "Stop:stop" \
    "PostInvocation:default" "SessionStart:default" ":default"; do
    event="${pair%%:*}"
    case "${pair##*:}" in
      ask) expect="$AG_ANSWER_ASK" ;;
      stop) expect="$AG_ANSWER_STOP" ;;
      *) expect="$AG_ANSWER_DEFAULT" ;;
    esac
    run_hook_ag "$event" "$input" "$BAD_URL" "$state_dir"
    if [ "$AG_CODE" != "0" ] || [ "$AG_OUT" != "$expect" ] || [ -n "$AG_ERR" ]; then
      ok=1; details="${details} [${event:-인자없음}] exit=$AG_CODE stdout='$AG_OUT' stderr='$AG_ERR';"
    fi
  done

  # 설정이 없어도(URL 없음·토큰 없음) 응답은 나온다 - 응답은 env 파일을 읽기 전에 낸다.
  run_hook_ag PreToolUse "$input" "" "$state_dir"
  if [ "$AG_CODE" != "0" ] || [ "$AG_OUT" != "$AG_ANSWER_ASK" ]; then
    ok=1; details="${details} [URL 없음] exit=$AG_CODE stdout='$AG_OUT';"
  fi
  run_hook_ag Stop "$input" "$SERVER_URL" "$state_dir" MY_DASHBOARD_TOKEN=
  if [ "$AG_CODE" != "0" ] || [ "$AG_OUT" != "$AG_ANSWER_STOP" ]; then
    ok=1; details="${details} [토큰 없음] exit=$AG_CODE stdout='$AG_OUT';"
  fi

  # 다른 source는 전과 같이 stdout에 아무것도 쓰지 않는다.
  local cc_out
  cc_out="$(env -i PATH="$PATH" HOME="$HOME" MY_DASHBOARD_URL="$BAD_URL" MY_DASHBOARD_TOKEN="$TOKEN" \
    MY_DASHBOARD_STATE_DIR="$WORK_DIR/state-ag-stdout-cc" MY_DASHBOARD_ENV="$NO_ENV_FILE" \
    "$BASH_BIN" "$HOOK" claude-code PreToolUse <<<'{"session_id":"cc-silent","cwd":"/tmp/demo","hook_event_name":"PreToolUse"}'; printf x)"
  if [ "$cc_out" != "x" ]; then
    ok=1; details="${details} [claude-code] stdout='${cc_out%x}'(기대: 빈 출력);"
  fi

  if [ "$ok" -eq 0 ]; then
    record "19. antigravity: stdout은 이벤트별 응답 JSON 한 줄뿐(설정 없음 포함), 다른 source는 무출력" 0 "PreToolUse→{\"decision\":\"ask\"}, Stop→{\"decision\":\"\"}, 그 밖→{}; exit 0·stderr 없음; claude-code stdout 비어 있음"
  else
    record "19. antigravity: stdout은 이벤트별 응답 JSON 한 줄뿐(설정 없음 포함), 다른 source는 무출력" 1 "$details"
  fi
}

# ---------- Check 20: antigravity 턴 시작 번역·session/project 필드 ----------
# PreInvocation은 모델 호출마다 오고 invocationNum은 턴마다 0부터 다시 센다. 0(또는 없음)만
# 턴 시작이다. project는 workspacePaths[0]이고 hook의 cwd(= hooks.json 폴더)는 쓰지 않는다.

check20_antigravity_turn_start() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-ag-turn"
  local agy_cwd="$WORK_DIR/gemini-config"
  mkdir -p "$agy_cwd"

  AG_CWD="$agy_cwd" run_hook_ag PreInvocation "$(ag_input ag-turn '"invocationNum":0,"initialNumSteps":2')" "$SERVER_URL" "$state_dir"
  [ "$AG_CODE" = "0" ] || { ok=1; details="${details} invocationNum 0 exit=$AG_CODE;"; }
  AG_CWD="$agy_cwd" run_hook_ag PreInvocation "$(ag_input ag-turn '"invocationNum":1,"initialNumSteps":2')" "$SERVER_URL" "$state_dir"
  AG_CWD="$agy_cwd" run_hook_ag PreInvocation "$(ag_input ag-turn '"invocationNum":2,"initialNumSteps":2')" "$SERVER_URL" "$state_dir"
  # invocationNum이 없으면 턴 시작으로 본다.
  AG_CWD="$agy_cwd" run_hook_ag PreInvocation "$(ag_input ag-turn-noinv '"initialNumSteps":2')" "$SERVER_URL" "$state_dir"
  # conversationId가 없으면 ANTIGRAVITY_CONVERSATION_ID, workspacePaths가 없으면 "unknown"(pwd 아님).
  AG_CWD="$agy_cwd" run_hook_ag PreInvocation '{"invocationNum":0,"initialNumSteps":1}' "$SERVER_URL" "$state_dir" \
    ANTIGRAVITY_CONVERSATION_ID=ag-turn-envid

  local rows expected
  rows="$(d1_rows "SELECT session_key, event, json_extract(raw, '\$.project') AS project, message FROM dashboard_events WHERE session_key IN ('antigravity:ag-turn', 'antigravity:ag-turn-noinv', 'antigravity:ag-turn-envid') ORDER BY id")"
  expected="antigravity:ag-turn|UserPromptSubmit|$AG_PROJECT|null
antigravity:ag-turn-noinv|UserPromptSubmit|$AG_PROJECT|null
antigravity:ag-turn-envid|UserPromptSubmit|unknown|null"
  if [ "$rows" != "$expected" ]; then
    ok=1; details="${details} 도착 행이 다르다 — 실제:[$(printf '%s' "$rows" | tr '\n' ';')] 기대:[$(printf '%s' "$expected" | tr '\n' ';')] (hook cwd=$agy_cwd);"
  fi

  if [ "$ok" -eq 0 ]; then
    record "20. antigravity: PreInvocation(0·없음)만 UserPromptSubmit, session=conversationId, project=workspacePaths[0]" 0 "invocationNum 1·2 미전송, conversationId→ANTIGRAVITY_CONVERSATION_ID 폴백, workspacePaths 없으면 unknown(hook cwd 미사용)"
  else
    record "20. antigravity: PreInvocation(0·없음)만 UserPromptSubmit, session=conversationId, project=workspacePaths[0]" 1 "$details"
  fi
}

# ---------- Check 21: antigravity 서브에이전트 대화는 통째로 보내지 않는다 ----------
# 서브에이전트는 부모와 다른 conversationId를 쓰고 부모 식별자를 싣지 않는다. 첫
# PreInvocation(invocationNum 0, initialNumSteps 0)으로 알아보고 그 대화의 이벤트를 모두 버린다.

check21_antigravity_subagent() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-ag-sub"

  run_hook_ag PreInvocation "$(ag_input ag-parent '"invocationNum":0,"initialNumSteps":3')" "$SERVER_URL" "$state_dir"
  run_hook_ag PreInvocation "$(ag_input ag-sub '"invocationNum":0,"initialNumSteps":0')" "$SERVER_URL" "$state_dir"
  run_hook_ag PreToolUse "$(ag_input ag-sub '"toolCall":{"name":"ask_question","args":{"questions":[{"question":"sub?"}]}}')" "$SERVER_URL" "$state_dir"
  # 버리는 질문이어도 응답은 ask여야 한다 - 무응답이면 agy가 서브에이전트의 도구를 거부한다.
  if [ "$AG_OUT" != "$AG_ANSWER_ASK" ]; then
    ok=1; details="${details} 서브에이전트 PreToolUse stdout='$AG_OUT'(기대 ask 응답);"
  fi
  run_hook_ag PostToolUse "$(ag_input ag-sub '"toolCall":{"name":"view_file","args":{}}')" "$SERVER_URL" "$state_dir"
  run_hook_ag Stop "$(ag_input ag-sub '"fullyIdle":true')" "$SERVER_URL" "$state_dir"
  run_hook_ag PreInvocation "$(ag_input ag-sub '"invocationNum":0,"initialNumSteps":4')" "$SERVER_URL" "$state_dir"
  run_hook_ag PostToolUse "$(ag_input ag-parent '"toolCall":{"name":"view_file","args":{}}')" "$SERVER_URL" "$state_dir"

  if [ ! -e "$state_dir/antigravity/subagent/ag-sub" ]; then
    ok=1; details="${details} 서브에이전트 표시 파일 없음;"
  fi
  local rows expected
  rows="$(d1_rows "SELECT session_key, event FROM dashboard_events WHERE session_key IN ('antigravity:ag-parent', 'antigravity:ag-sub') ORDER BY id")"
  expected="antigravity:ag-parent|UserPromptSubmit
antigravity:ag-parent|PostToolUse"
  if [ "$rows" != "$expected" ]; then
    ok=1; details="${details} 도착 행이 다르다 — 실제:[$(printf '%s' "$rows" | tr '\n' ';')] 기대:[$(printf '%s' "$expected" | tr '\n' ';')];"
  fi

  if [ "$ok" -eq 0 ]; then
    record "21. antigravity: 서브에이전트(initialNumSteps 0) 대화는 이후 이벤트까지 미전송" 0 "서브에이전트 5개 이벤트 0건 도착(질문 응답은 ask), 부모 UserPromptSubmit·PostToolUse 도착"
  else
    record "21. antigravity: 서브에이전트(initialNumSteps 0) 대화는 이후 이벤트까지 미전송" 1 "$details"
  fi
}

# ---------- Check 22: antigravity 질문 도구 번역 ----------
# question_tools(ask_question·ask_permission)와 이름이 정확히 같을 때만 번역한다.
# 서버 상태까지 따라가 hook 번역과 서버 어댑터가 맞물리는지도 본다.

check22_antigravity_questions() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-ag-ask"
  local c="ag-ask"

  run_hook_ag PreInvocation "$(ag_input "$c" '"invocationNum":0,"initialNumSteps":2')" "$SERVER_URL" "$state_dir"
  run_hook_ag PreToolUse "$(ag_input "$c" '"toolCall":{"name":"ask_question","args":{"questions":[{"question":"Do you prefer red or blue?","options":["Red","Blue"],"is_multi_select":false}]}},"stepIdx":3')" "$SERVER_URL" "$state_dir"
  local state_wait
  state_wait="$(d1_scalar "SELECT state FROM dashboard_sessions WHERE key='antigravity:$c'" state)"
  run_hook_ag PostToolUse "$(ag_input "$c" '"toolCall":{"name":"ask_question","args":{}},"stepIdx":3,"error":""')" "$SERVER_URL" "$state_dir"
  local state_resolved
  state_resolved="$(d1_scalar "SELECT state FROM dashboard_sessions WHERE key='antigravity:$c'" state)"
  run_hook_ag PreToolUse "$(ag_input "$c" '"toolCall":{"name":"ask_permission","args":{}}')" "$SERVER_URL" "$state_dir"
  run_hook_ag PostToolUse "$(ag_input "$c" '"toolCall":{"name":"ask_permission","args":{}}')" "$SERVER_URL" "$state_dir"
  # 비슷한 이름은 번역하지 않는다: PreToolUse는 버리고 PostToolUse는 하트비트 그대로다.
  # 이름을 끼운 조각은 변수로 넘긴다. bash 3.2는 "$(...)" 안의 큰따옴표 인자에 든
  # {...,...}를 중괄호 확장해서 JSON이 아닌 stdin을 만든다.
  local name fragment
  for name in run_command ask_question_v2 Ask_Question ask_permissions; do
    fragment="\"toolCall\":{\"name\":\"$name\",\"args\":{}}"
    run_hook_ag PreToolUse "$(ag_input "$c" "$fragment")" "$SERVER_URL" "$state_dir"
    if [ "$AG_OUT" != "$AG_ANSWER_ASK" ]; then
      ok=1; details="${details} PreToolUse($name) stdout='$AG_OUT'(기대 ask 응답);"
    fi
  done
  run_hook_ag PostToolUse "$(ag_input "$c" '"toolCall":{"name":"ask_question_v2","args":{}}')" "$SERVER_URL" "$state_dir"

  local rows expected
  rows="$(d1_rows "SELECT event, message FROM dashboard_events WHERE session_key='antigravity:$c' ORDER BY id")"
  expected="UserPromptSubmit|null
UserInputRequest|Do you prefer red or blue?
UserInputResolved|null
UserInputRequest|null
UserInputResolved|null
PostToolUse|null"
  if [ "$rows" != "$expected" ]; then
    ok=1; details="${details} 도착 행이 다르다 — 실제:[$(printf '%s' "$rows" | tr '\n' ';')] 기대:[$(printf '%s' "$expected" | tr '\n' ';')];"
  fi
  if [ "$state_wait" != "waiting_input" ] || [ "$state_resolved" != "working" ]; then
    ok=1; details="${details} 서버 상태: 질문 뒤='$state_wait'(기대 waiting_input) 답 뒤='$state_resolved'(기대 working);"
  fi

  if [ "$ok" -eq 0 ]; then
    record "22. antigravity: ask_question·ask_permission만 UserInputRequest/Resolved(정확 일치), message=첫 질문" 0 "질문→waiting_input→답→working, 유사 이름 4종 PreToolUse 미전송(응답은 ask), 유사 이름 PostToolUse는 하트비트"
  else
    record "22. antigravity: ask_question·ask_permission만 UserInputRequest/Resolved(정확 일치), message=첫 질문" 1 "$details"
  fi
}

# ---------- Check 23: antigravity PostToolUse 하트비트 스로틀 ----------

check23_antigravity_heartbeat_throttle() {
  local state_dir="$WORK_DIR/state-ag-hb"
  # 체크 22와 같은 이유로 조각을 변수로 넘긴다(bash 3.2 중괄호 확장).
  local i fragment
  for i in 1 2 3 4 5; do
    fragment="\"toolCall\":{\"name\":\"view_file\",\"args\":{}},\"stepIdx\":$i"
    run_hook_ag PostToolUse "$(ag_input ag-hb "$fragment")" "$SERVER_URL" "$state_dir"
  done
  local events
  events="$(d1_events antigravity:ag-hb)"
  if [ "$events" = "PostToolUse" ]; then
    record "23. antigravity: 연속 PostToolUse 5회 → 하트비트 1회" 0 "도착=$events"
  else
    record "23. antigravity: 연속 PostToolUse 5회 → 하트비트 1회" 1 "도착='$events'(기대 PostToolUse 1건)"
  fi
}

# ---------- Check 24: antigravity Stop - fullyIdle 값과 상관없이 모두 Stop, 모두 래치 ----------
# fullyIdle false는 백그라운드 작업(서브에이전트 등)이 남았다는 뜻일 뿐 턴 실행은 끝났다.
# 버리면 세션이 working에 멈춘다(agy 1.2.12 실측, 체크 30).

check24_antigravity_stop_fully_idle() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-ag-stop"

  run_hook_ag Stop "$(ag_input ag-stop '"fullyIdle":false,"terminationReason":"NO_TOOL_CALL","executionNum":1')" "$SERVER_URL" "$state_dir"
  if [ "$AG_OUT" != "$AG_ANSWER_STOP" ]; then
    ok=1; details="${details} fullyIdle false Stop stdout='$AG_OUT';"
  fi
  if [ ! -e "$state_dir/antigravity/stopped/ag-stop" ]; then
    ok=1; details="${details} fullyIdle false Stop 뒤 래치 파일 없음;"
  fi
  run_hook_ag Stop "$(ag_input ag-stop '"fullyIdle":true,"terminationReason":"NO_TOOL_CALL","executionNum":2')" "$SERVER_URL" "$state_dir"
  run_hook_ag Stop "$(ag_input ag-stop-nofield '"terminationReason":"NO_TOOL_CALL"')" "$SERVER_URL" "$state_dir"

  local rows expected
  rows="$(d1_rows "SELECT session_key, event FROM dashboard_events WHERE session_key IN ('antigravity:ag-stop', 'antigravity:ag-stop-nofield') ORDER BY id")"
  expected="antigravity:ag-stop|Stop
antigravity:ag-stop|Stop
antigravity:ag-stop-nofield|Stop"
  if [ "$rows" != "$expected" ]; then
    ok=1; details="${details} 도착 행이 다르다 — 실제:[$(printf '%s' "$rows" | tr '\n' ';')] 기대:[$(printf '%s' "$expected" | tr '\n' ';')];"
  fi

  if [ "$ok" -eq 0 ]; then
    record "24. antigravity: fullyIdle false·true·필드 없음 모두 Stop 전송, fullyIdle false도 래치" 0 "Stop 3건 도착, fullyIdle false Stop 뒤 래치 파일 확인"
  else
    record "24. antigravity: fullyIdle false·true·필드 없음 모두 Stop 전송, fullyIdle false도 래치" 1 "$details"
  fi
}

# ---------- Check 25: antigravity Stop 뒤 PostToolUse 래치 ----------
# Stop(fullyIdle 값과 상관없이) 뒤에 기록용 PostToolUse가 올 수 있다. 하트비트로 보내면 서버가
# 끝난 턴을 working으로 되살리므로 다음 턴 시작(PreInvocation 0)까지 버린다.

check25_antigravity_post_stop_latch() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-ag-latch"
  local c="ag-latch"
  local tool='"toolCall":{"name":"view_file","args":{}}'

  run_hook_ag PreInvocation "$(ag_input "$c" '"invocationNum":0,"initialNumSteps":2')" "$SERVER_URL" "$state_dir"
  run_hook_ag PostToolUse "$(ag_input "$c" "$tool")" "$SERVER_URL" "$state_dir"
  run_hook_ag Stop "$(ag_input "$c" '"fullyIdle":true')" "$SERVER_URL" "$state_dir"
  # Stop 성공이 스로틀을 리셋했으므로 래치가 없으면 이 하트비트는 바로 나간다. 래치는 다음
  # PreInvocation까지 계속 걸려 있다(래치 중 PreInvocation이 턴을 다시 여는 경우는 체크 31).
  run_hook_ag PostToolUse "$(ag_input "$c" "$tool")" "$SERVER_URL" "$state_dir"
  # 질문 도구의 기록용 PostToolUse는 UserInputResolved로 번역된다 - 상태 이벤트라 보내면 끝난 턴이
  # 하트비트 가드 없이 working으로 돌아가므로 이것도 래치가 버린다.
  run_hook_ag PostToolUse "$(ag_input "$c" '"toolCall":{"name":"ask_question","args":{}}')" "$SERVER_URL" "$state_dir"
  run_hook_ag PostToolUse "$(ag_input "$c" "$tool")" "$SERVER_URL" "$state_dir"
  local state_latched
  state_latched="$(d1_scalar "SELECT state FROM dashboard_sessions WHERE key='antigravity:$c'" state)"
  run_hook_ag PreInvocation "$(ag_input "$c" '"invocationNum":0,"initialNumSteps":5')" "$SERVER_URL" "$state_dir"
  run_hook_ag PostToolUse "$(ag_input "$c" "$tool")" "$SERVER_URL" "$state_dir"

  local events
  events="$(d1_events "antigravity:$c")"
  if [ "$events" != "UserPromptSubmit,PostToolUse,Stop,UserPromptSubmit,PostToolUse" ]; then
    ok=1; details="${details} 도착='$events'(기대 UserPromptSubmit,PostToolUse,Stop,UserPromptSubmit,PostToolUse);"
  fi
  if [ "$state_latched" != "done" ]; then
    ok=1; details="${details} Stop 뒤 PostToolUse 이후 state='$state_latched'(기대 done - 되살아나면 안 됨);"
  fi
  if [ -e "$state_dir/antigravity/stopped/$c" ]; then
    ok=1; details="${details} 다음 턴 시작 뒤에도 래치 파일이 남아 있음;"
  fi

  if [ "$ok" -eq 0 ]; then
    record "25. antigravity: Stop 뒤 PostToolUse(질문 도구 포함)는 다음 턴 시작까지 미전송" 0 "Stop 뒤 PostToolUse 3건(ask_question 1건 포함) 미전송·state done 유지, 다음 PreInvocation(0) 뒤 하트비트 재개"
  else
    record "25. antigravity: Stop 뒤 PostToolUse(질문 도구 포함)는 다음 턴 시작까지 미전송" 1 "$details"
  fi
}

# ---------- Check 26: antigravity print 모드(agy -p) 실행은 보내지 않는다 ----------
# 이름이 정확히 agy인 가짜 실행 파일이 hook을 자식으로 실행한다. 받은 인자는 그 프로세스의
# argv로 ps·/proc에 그대로 보이므로 hook의 조상 탐색이 실제와 같은 조건에서 돈다.

check26_antigravity_print_mode() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-ag-print"
  local fake_dir="$WORK_DIR/fake-agy"
  local fake_agy="$fake_dir/agy"
  mkdir -p "$fake_dir"
  cat > "$fake_agy" <<'FAKE_AGY'
#!/usr/bin/env bash
# 가짜 agy: agy처럼 hook을 자식 프로세스로 실행하고 hook stdout을 그대로 내보낸다.
if [ "${FAKE_AGY_VIA_SH:-0}" = "1" ]; then
  # 실제 hooks.json 명령처럼 sh -c를 한 단계 거친다. 뒤의 exit가 sh의 exec 최적화를 막아
  # agy가 hook의 부모가 아니라 조부모가 된다.
  sh -c '"$0" "$1" antigravity "$2"; exit $?' "$FAKE_AGY_BASH" "$FAKE_AGY_HOOK" "$FAKE_AGY_EVENT"
else
  "$FAKE_AGY_BASH" "$FAKE_AGY_HOOK" antigravity "$FAKE_AGY_EVENT"
fi
status=$?
exit "$status"
FAKE_AGY
  chmod +x "$fake_agy"

  # run_fake_agy <conversationId> <via_sh 0|1> <include_print 0|1> [agy 인자...]
  run_fake_agy() {
    local conv="$1" via_sh="$2" include_print="$3"
    shift 3
    local out code
    out="$(ag_input "$conv" '"invocationNum":0,"initialNumSteps":2' | env -i PATH="$PATH" HOME="$HOME" \
      MY_DASHBOARD_URL="$SERVER_URL" \
      MY_DASHBOARD_TOKEN="$TOKEN" \
      MY_DASHBOARD_STATE_DIR="$state_dir" \
      MY_DASHBOARD_ENV="$NO_ENV_FILE" \
      MY_DASHBOARD_ANTIGRAVITY_INCLUDE_PRINT="$include_print" \
      FAKE_AGY_BASH="$BASH_BIN" FAKE_AGY_HOOK="$HOOK" FAKE_AGY_EVENT=PreInvocation FAKE_AGY_VIA_SH="$via_sh" \
      "$fake_agy" "$@"; code=$?; printf x; exit "$code")"
    code=$?
    if [ "$code" != "0" ] || [ "${out%x}" != "$AG_ANSWER_DEFAULT" ]; then
      ok=1; details="${details} [agy $*] exit=$code stdout='${out%x}';"
    fi
  }

  run_fake_agy ag-print-short 0 0 -p "summarize this"
  run_fake_agy ag-print-long 0 0 --print "x"
  run_fake_agy ag-print-eq 0 0 --print=json "x"
  run_fake_agy ag-print-prompt 0 0 --prompt "x"
  run_fake_agy ag-print-prompt-eq 0 0 --prompt=x
  run_fake_agy ag-print-via-sh 1 0 -p "x"
  # agy는 Go flag 문법이라 대시 하나짜리 긴 이름과 =값도 같은 플래그다.
  run_fake_agy ag-print-go-single 0 0 -print "x"
  run_fake_agy ag-print-go-eq 0 0 -p=x
  run_fake_agy ag-print-interactive 0 0 --prompt-interactive "hello"
  # 대화형 첫 프롬프트 속 "-p"는 플래그가 아니다(macOS ps는 인자를 공백으로 이어 붙인다).
  run_fake_agy ag-print-i 0 0 -i "fix the -p flag"
  run_fake_agy ag-print-go-interactive 0 0 -prompt-interactive "fix the -p flag"
  run_fake_agy ag-print-plain 1 0
  run_fake_agy ag-print-included 0 1 -p "x"

  local rows expected
  rows="$(d1_rows "SELECT session_key FROM dashboard_events WHERE session_key LIKE 'antigravity:ag-print-%' ORDER BY id")"
  expected="antigravity:ag-print-interactive
antigravity:ag-print-i
antigravity:ag-print-go-interactive
antigravity:ag-print-plain
antigravity:ag-print-included"
  if [ "$rows" != "$expected" ]; then
    ok=1; details="${details} 도착 세션이 다르다 — 실제:[$(printf '%s' "$rows" | tr '\n' ';')] 기대:[$(printf '%s' "$expected" | tr '\n' ';')];"
  fi

  if [ "$ok" -eq 0 ]; then
    record "26. antigravity: agy print 모드(p·print·prompt, Go flag 표기) 조상이면 미전송, INCLUDE_PRINT=1이면 전송" 0 "print 플래그 8가지(sh -c 한 단계·-print·-p=x 포함) 미전송·응답 {} 유지, --prompt-interactive·-i·-prompt-interactive(프롬프트 속 -p 포함)·인자 없음·include 전송"
  else
    record "26. antigravity: agy print 모드(p·print·prompt, Go flag 표기) 조상이면 미전송, INCLUDE_PRINT=1이면 전송" 1 "$details"
  fi
}

# ---------- Check 27: antigravity 빈 stdin·깨진 JSON·jq 없음 ----------
# 응답만 내고 0으로 끝나며 네트워크를 쓰지 않는다(스풀 재전송도 하지 않는다).

check27_antigravity_empty_input() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-ag-empty"
  mkdir -p "$state_dir"
  printf '%s\n' '{"protocol_version":1,"source":"claude-code","session_id":"ag-empty-spooled","project":"/tmp/demo","event":"UserPromptSubmit","event_id":"ag-empty-spooled-1"}' \
    > "$state_dir/spool.ndjson"

  run_hook_ag PreToolUse "" "$SERVER_URL" "$state_dir"
  if [ "$AG_CODE" != "0" ] || [ "$AG_OUT" != "$AG_ANSWER_ASK" ]; then
    ok=1; details="${details} 빈 stdin exit=$AG_CODE stdout='$AG_OUT';"
  fi
  run_hook_ag Stop '{"conversationId":' "$SERVER_URL" "$state_dir"
  if [ "$AG_CODE" != "0" ] || [ "$AG_OUT" != "$AG_ANSWER_STOP" ]; then
    ok=1; details="${details} 깨진 JSON exit=$AG_CODE stdout='$AG_OUT';"
  fi
  local shadow_dir
  shadow_dir="$(make_shadow_no_jq)"
  run_hook_ag PreToolUse "$(ag_input ag-empty-nojq '"toolCall":{"name":"ask_question","args":{}}')" "$SERVER_URL" "$state_dir" \
    PATH="$shadow_dir"
  if [ "$AG_CODE" != "0" ] || [ "$AG_OUT" != "$AG_ANSWER_ASK" ]; then
    ok=1; details="${details} jq 없음 exit=$AG_CODE stdout='$AG_OUT';"
  fi

  local n_spool n_db
  n_spool="$(wc -l < "$state_dir/spool.ndjson" 2>/dev/null | tr -d ' ')"
  n_db="$(d1_scalar "SELECT COUNT(*) AS c FROM dashboard_events WHERE session_key IN ('claude-code:ag-empty-spooled', 'antigravity:ag-empty-nojq')" c)"
  if [ "$n_spool" != "1" ] || [ "$n_db" != "0" ]; then
    ok=1; details="${details} 스풀 ${n_spool}줄(기대 1 — 재전송하면 안 됨), DB 도착 ${n_db}건(기대 0);"
  fi

  if [ "$ok" -eq 0 ]; then
    record "27. antigravity: 빈 stdin·깨진 JSON·jq 없음이면 응답만 내고 exit 0, 네트워크 없음" 0 "세 경우 모두 응답·exit 0, 스풀 1줄 유지, DB 0건"
  else
    record "27. antigravity: 빈 stdin·깨진 JSON·jq 없음이면 응답만 내고 exit 0, 네트워크 없음" 1 "$details"
  fi
}

# ---------- Check 28: antigravity 스풀 재전송 시간 예산 ----------
# agy는 hook이 끝날 때까지 실행을 멈추고 10초에 끊는다. 느리지만 성공하는 서버(요청마다
# 1.5초)에 밀린 20줄을 다 보내면 30초가 걸리므로, hook은 4초가 지나면 재전송을 멈추고
# 남은 줄을 다음 hook에 넘겨야 한다. 응답하지 않는 서버도 실패 한 번에서 멈춘다.

# start_aux_server <slow|hang|poison> <지연 초> <요청 기록 파일> - 포트를 AUX_PORT에 담는다(실패면 빈 값).
# $(...)로 부르면 서브셸이라 AUX_PIDS가 사라져 cleanup이 서버를 못 죽이므로 전역 변수로 돌려준다.
start_aux_server() {
  local mode="$1" delay="$2" log_file="$3"
  local port_file="$WORK_DIR/aux-port.$mode"
  # 앞 체크가 남긴 포트 파일(이미 죽은 서버)을 새 서버의 포트로 읽지 않게 지운다.
  rm -f "$port_file"
  python3 - "$mode" "$delay" "$log_file" "$port_file" >/dev/null 2>&1 <<'AUX_PY' &
import http.server, json, os, re, socket, sys, time
mode, delay, log_file, port_file = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]
if mode == "hang":
    # 연결은 커널 backlog가 받아 주지만 accept하지 않으므로 응답이 영영 오지 않는다.
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(64)
    port = server.getsockname()[1]
else:
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            # 받은 요청의 event_id를 한 줄씩 적는다(도착 순서 확인용). poison 모드는 event_id에
            # poison이 들어간 줄을 늘 거절한다 - poison500처럼 뒤에 붙은 세 자리가 응답 코드다(없으면 400).
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            try:
                event_id = str(json.loads(body).get("event_id"))
            except (ValueError, AttributeError):
                event_id = "?"
            if mode == "poison" and "poison" in event_id:
                code = re.search(r"poison(\d{3})", event_id)
                with open(log_file, "a") as f:
                    f.write(f"rejected:{event_id}\n")
                self.send_response(int(code.group(1)) if code else 400)
                self.end_headers()
                return
            time.sleep(delay)
            with open(log_file, "a") as f:
                f.write(event_id + "\n")
            self.send_response(200)
            self.end_headers()

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    port = server.server_port
with open(port_file + ".tmp", "w") as f:
    f.write(str(port))
os.rename(port_file + ".tmp", port_file)
if mode == "hang":
    while True:
        time.sleep(3600)
server.serve_forever()
AUX_PY
  AUX_PIDS="$AUX_PIDS $!"
  local tries=0
  while [ ! -s "$port_file" ] && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  AUX_PORT="$(cat "$port_file" 2>/dev/null)"
}

check28_antigravity_spool_budget() {
  local ok=0
  local details=""
  local mode port state_dir started elapsed n_spool n_sent cur_sent last_spooled i
  for mode in slow hang; do
    state_dir="$WORK_DIR/state-ag-budget-$mode"
    mkdir -p "$state_dir"
    for i in $(seq 1 20); do
      printf '{"protocol_version":1,"source":"claude-code","session_id":"ag-budget-old","project":"/tmp/demo","event":"PostToolUse","event_id":"ag-budget-%s-%s"}\n' "$mode" "$i"
    done > "$state_dir/spool.ndjson"
    : > "$WORK_DIR/aux-$mode.log"
    start_aux_server "$mode" 1.5 "$WORK_DIR/aux-$mode.log"
    port="$AUX_PORT"
    if [ -z "$port" ]; then
      ok=1; details="${details} [$mode] 보조 서버를 띄우지 못함;"
      continue
    fi

    started="$(now_ms)"
    run_hook_ag PreInvocation "$(ag_input "ag-budget-$mode" '"invocationNum":0,"initialNumSteps":2')" \
      "http://127.0.0.1:$port" "$state_dir" "MY_DASHBOARD_EVENT_ID=ag-budget-cur-$mode"
    elapsed=$(( $(now_ms) - started ))
    n_spool="$(wc -l < "$state_dir/spool.ndjson" 2>/dev/null | tr -d ' ')"
    n_sent="$(grep -c "^ag-budget-$mode-" "$WORK_DIR/aux-$mode.log" 2>/dev/null)"
    cur_sent="$(grep -c "^ag-budget-cur-$mode\$" "$WORK_DIR/aux-$mode.log" 2>/dev/null)"
    last_spooled="$(tail -n 1 "$state_dir/spool.ndjson" 2>/dev/null | jq -r '.event_id' 2>/dev/null)"

    if [ "$AG_CODE" != "0" ] || [ "$AG_OUT" != "$AG_ANSWER_DEFAULT" ]; then
      ok=1; details="${details} [$mode] exit=$AG_CODE stdout='$AG_OUT';"
    fi
    if [ "$mode" = "slow" ]; then
      # 예산이 없으면 20줄×1.5초=30초가 걸린다. 4초 안에 시작한 재전송(각 1.5초)까지만 하므로 몇 줄만
      # 보내고(1~19줄) 나머지는 남긴다. 서버가 응답했으므로 이번 이벤트는 남은 줄과 상관없이 바로
      # 보낸다 - 단 그 시점에 5초 전송 마감이 지났으면 스풀 끝에 넣는다(초 단위 시계라 어느 쪽이든 맞다).
      if [ "$elapsed" -ge 7500 ] || [ "${n_sent:-0}" -lt 1 ] || [ "${n_sent:-0}" -gt 19 ]; then
        ok=1; details="${details} [slow] ${elapsed}ms(기대 7500ms 미만)·밀린 줄 수신 ${n_sent}건(기대 1~19);"
      elif [ "${cur_sent:-0}" = "1" ]; then
        if [ "${n_spool:-0}" != "$((20 - n_sent))" ] || [ "$last_spooled" = "ag-budget-cur-slow" ]; then
          ok=1; details="${details} [slow] 이번 이벤트는 보냈는데 스풀 ${n_spool}줄·끝 줄 $last_spooled(기대 $((20 - n_sent))줄, 밀린 줄만);"
        fi
      elif [ "$last_spooled" != "ag-budget-cur-slow" ] || [ "${n_spool:-0}" != "$((21 - n_sent))" ]; then
        ok=1; details="${details} [slow] 이번 이벤트가 전달도 전송 마감 대기도 아니다 — 스풀 ${n_spool}줄·끝 줄 $last_spooled;"
      fi
    else
      # 먹통 서버: 첫 재전송이 2초 뒤 응답 없이(000) 실패하므로 이번 이벤트는 보내 보지도 않고 스풀
      # 끝에 선다 - curl 제한 시간 한 번이면 끝난다(두 번째 curl을 기다리지 않는다).
      if [ "$elapsed" -ge 3500 ] || [ "${n_spool:-0}" != "21" ] || [ "$last_spooled" != "ag-budget-cur-hang" ]; then
        ok=1; details="${details} [hang] ${elapsed}ms(기대 3500ms 미만)·스풀 ${n_spool}줄·끝 줄 $last_spooled(기대 21줄, 이번 이벤트가 끝);"
      fi
    fi
    details="${details} [$mode] ${elapsed}ms·밀린 줄 수신 ${n_sent}·이번 이벤트 전달 ${cur_sent}·스풀 ${n_spool};"
  done
  local pid
  for pid in $AUX_PIDS; do
    kill "$pid" 2>/dev/null
  done
  AUX_PIDS=""

  if [ "$ok" -eq 0 ]; then
    record "28. antigravity: 스풀 재전송 4초 예산 - 느린 서버 7.5초 안, 먹통 서버(응답 없음)는 이번 이벤트를 스풀 끝에 넣고 3.5초 안" 0 "$details"
  else
    record "28. antigravity: 스풀 재전송 4초 예산 - 느린 서버 7.5초 안, 먹통 서버(응답 없음)는 이번 이벤트를 스풀 끝에 넣고 3.5초 안" 1 "$details"
  fi
}

# ---------- Check 29: antigravity 스로틀된 하트비트는 스풀 재전송도 하지 않는다 ----------
# agy는 도구를 쓸 때마다 hook을 기다린다. 서버 장애 중 스풀이 남아 있을 때 보낼 것 없는
# 하트비트까지 재전송을 시도하면 도구 호출마다 curl 제한 시간(2초)만큼 멈춘다. 다른 source는
# 전처럼 매번 재전송을 시도해야 한다(대조군).

check29_antigravity_throttled_heartbeat_skips_replay() {
  local ok=0
  local details=""
  local hang_url state_ag state_cc started elapsed i
  : > "$WORK_DIR/aux-hang29.log"
  start_aux_server hang 0 "$WORK_DIR/aux-hang29.log"
  if [ -z "$AUX_PORT" ]; then
    record "29. antigravity: 스로틀된 하트비트는 재전송 없이 바로 끝남(다른 source는 그대로 재전송)" 1 "먹통 서버를 띄우지 못함"
    return
  fi
  hang_url="http://127.0.0.1:$AUX_PORT"
  state_ag="$WORK_DIR/state-ag-hb-hang"
  state_cc="$WORK_DIR/state-cc-hb-hang"

  # 1) 정상 서버로 하트비트를 한 번 보내 60초 스로틀 창을 연다(스풀은 아직 없다).
  local tool='"toolCall":{"name":"view_file","args":{}}'
  run_hook_ag PostToolUse "$(ag_input ag-hb-hang "$tool")" "$SERVER_URL" "$state_ag"
  run_hook '{"session_id":"cc-hb-hang","cwd":"/tmp/demo","hook_event_name":"PostToolUse"}' "$SERVER_URL" "$state_cc" >/dev/null
  # 2) 밀린 줄 5개를 심는다.
  for i in 1 2 3 4 5; do
    printf '{"protocol_version":1,"source":"claude-code","session_id":"hb-hang-old","project":"/tmp/demo","event":"PostToolUse","event_id":"hb-hang-old-%s"}\n' "$i"
  done > "$WORK_DIR/hb-hang-spool.ndjson"
  cp "$WORK_DIR/hb-hang-spool.ndjson" "$state_ag/spool.ndjson"
  cp "$WORK_DIR/hb-hang-spool.ndjson" "$state_cc/spool.ndjson"

  # 3) 먹통 서버로 스로틀 창 안의 하트비트: antigravity는 네트워크 없이 바로 끝나고 스풀은 그대로다.
  started="$(now_ms)"
  run_hook_ag PostToolUse "$(ag_input ag-hb-hang "$tool")" "$hang_url" "$state_ag"
  elapsed=$(( $(now_ms) - started ))
  if [ "$AG_CODE" != "0" ] || [ "$AG_OUT" != "$AG_ANSWER_DEFAULT" ] || [ "$elapsed" -ge 1000 ] \
    || ! cmp -s "$WORK_DIR/hb-hang-spool.ndjson" "$state_ag/spool.ndjson"; then
    ok=1; details="${details} [antigravity] exit=$AG_CODE stdout='$AG_OUT' ${elapsed}ms(기대 1000ms 미만)·스풀 $(wc -l < "$state_ag/spool.ndjson" | tr -d ' ')줄(기대: 그대로 5줄);"
  else
    details="${details} [antigravity] ${elapsed}ms·스풀 그대로 5줄;"
  fi

  # 4) 대조군 claude-code: 스로틀된 하트비트도 재전송을 시도해 먹통 서버에서 2초 가까이 걸린다.
  started="$(now_ms)"
  run_hook '{"session_id":"cc-hb-hang","cwd":"/tmp/demo","hook_event_name":"PostToolUse"}' "$hang_url" "$state_cc" >/dev/null
  elapsed=$(( $(now_ms) - started ))
  if [ "$elapsed" -lt 1500 ] || ! cmp -s "$WORK_DIR/hb-hang-spool.ndjson" "$state_cc/spool.ndjson"; then
    ok=1; details="${details} [claude-code 대조군] ${elapsed}ms(기대 1500ms 이상 - 재전송 시도)·스풀 $(wc -l < "$state_cc/spool.ndjson" | tr -d ' ')줄(기대: 실패한 재전송 뒤 그대로 5줄);"
  else
    details="${details} [claude-code 대조군] ${elapsed}ms(재전송 시도)·스풀 5줄;"
  fi

  local pid
  for pid in $AUX_PIDS; do
    kill "$pid" 2>/dev/null
  done
  AUX_PIDS=""

  if [ "$ok" -eq 0 ]; then
    record "29. antigravity: 스로틀된 하트비트는 재전송 없이 바로 끝남(다른 source는 그대로 재전송)" 0 "$details"
  else
    record "29. antigravity: 스로틀된 하트비트는 재전송 없이 바로 끝남(다른 source는 그대로 재전송)" 1 "$details"
  fi
}

# ---------- Check 30: antigravity 서브에이전트 턴은 fullyIdle false Stop으로 끝나도 done ----------
# agy 1.2.12 실측(서브에이전트 프롬프트): 부모의 Stop이 서브에이전트가 도는 동안 fullyIdle false로
# 오고, 서브에이전트의 send_message가 부모를 새 실행(PreInvocation 0, initialNumSteps 4)으로 깨운 뒤,
# 서브에이전트의 fullyIdle Stop이 지나고도 부모의 마지막 Stop이 fullyIdle false다. 이 Stop을 버리면
# 부모 세션이 working에 멈춰 stalled 푸시가 잘못 나간다(실제 E2E에서 재현). 그 사이 부모의 기록용
# PostToolUse는 다음 턴 시작까지 래치가 버린다.

check30_antigravity_background_turn_ends_done() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-ag-bg"
  local p="ag-bg-parent" s="ag-bg-sub"
  local tool='"toolCall":{"name":"view_file","args":{}}'

  run_hook_ag PreInvocation "$(ag_input "$p" '"invocationNum":0,"initialNumSteps":1')" "$SERVER_URL" "$state_dir"
  run_hook_ag PostToolUse "$(ag_input "$p" '"toolCall":{"name":"invoke_subagent","args":{}}')" "$SERVER_URL" "$state_dir"
  run_hook_ag PreInvocation "$(ag_input "$p" '"invocationNum":1,"initialNumSteps":3')" "$SERVER_URL" "$state_dir"
  run_hook_ag Stop "$(ag_input "$p" '"fullyIdle":false,"terminationReason":"NO_TOOL_CALL"')" "$SERVER_URL" "$state_dir"
  run_hook_ag PostToolUse "$(ag_input "$p" "$tool")" "$SERVER_URL" "$state_dir"
  local state_first_stop
  state_first_stop="$(d1_scalar "SELECT state FROM dashboard_sessions WHERE key='antigravity:$p'" state)"
  run_hook_ag PreInvocation "$(ag_input "$s" '"invocationNum":0,"initialNumSteps":0')" "$SERVER_URL" "$state_dir"
  run_hook_ag PostToolUse "$(ag_input "$s" "$tool")" "$SERVER_URL" "$state_dir"
  run_hook_ag PreInvocation "$(ag_input "$p" '"invocationNum":0,"initialNumSteps":4')" "$SERVER_URL" "$state_dir"
  run_hook_ag PostToolUse "$(ag_input "$p" "$tool")" "$SERVER_URL" "$state_dir"
  run_hook_ag Stop "$(ag_input "$s" '"fullyIdle":true')" "$SERVER_URL" "$state_dir"
  run_hook_ag Stop "$(ag_input "$p" '"fullyIdle":false,"terminationReason":"NO_TOOL_CALL"')" "$SERVER_URL" "$state_dir"

  local rows expected state_final
  rows="$(d1_rows "SELECT session_key, event FROM dashboard_events WHERE session_key IN ('antigravity:$p', 'antigravity:$s') ORDER BY id")"
  expected="antigravity:$p|UserPromptSubmit
antigravity:$p|PostToolUse
antigravity:$p|Stop
antigravity:$p|UserPromptSubmit
antigravity:$p|PostToolUse
antigravity:$p|Stop"
  state_final="$(d1_scalar "SELECT state FROM dashboard_sessions WHERE key='antigravity:$p'" state)"
  if [ "$rows" != "$expected" ]; then
    ok=1; details="${details} 도착 행이 다르다 — 실제:[$(printf '%s' "$rows" | tr '\n' ';')] 기대:[$(printf '%s' "$expected" | tr '\n' ';')];"
  fi
  if [ "$state_first_stop" != "done" ]; then
    ok=1; details="${details} 첫 fullyIdle false Stop과 래치된 PostToolUse 뒤 state='$state_first_stop'(기대 done);"
  fi
  if [ "$state_final" != "done" ]; then
    ok=1; details="${details} 마지막 fullyIdle false Stop 뒤 state='$state_final'(기대 done - working에 멈추면 stalled 푸시가 잘못 나간다);"
  fi

  if [ "$ok" -eq 0 ]; then
    record "30. antigravity: 서브에이전트 턴이 fullyIdle false Stop으로 끝나도 done, Stop 뒤 PostToolUse는 다음 턴까지 미전송" 0 "UserPromptSubmit·Stop 각 2건과 하트비트 2건 도착, 래치된 하트비트 미전송, 서브에이전트 0건, 첫 Stop 뒤·마지막 state done"
  else
    record "30. antigravity: 서브에이전트 턴이 fullyIdle false Stop으로 끝나도 done, Stop 뒤 PostToolUse는 다음 턴까지 미전송" 1 "$details"
  fi
}

# ---------- Check 31: antigravity 래치 중 PreInvocation은 invocationNum과 상관없이 턴 (재)시작 ----------
# 다른 agy 연동 구현은 fullyIdle false Stop이 한 실행 안의 도구 단계 사이에도 온다고 보고한다. 그러면 다음 모델 호출은
# invocationNum이 1 이상인 PreInvocation이라 턴 시작이 아니게 되어, 세션이 done에 머문 채 하트비트까지
# 래치에 막힌다. 래치가 걸린 동안의 첫 PreInvocation은 턴 (재)시작으로 보내고 래치를 푼다.

check31_antigravity_latched_preinvocation_restarts_turn() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-ag-restart"
  local c="ag-restart"

  run_hook_ag PreInvocation "$(ag_input "$c" '"invocationNum":0,"initialNumSteps":1')" "$SERVER_URL" "$state_dir"
  run_hook_ag Stop "$(ag_input "$c" '"fullyIdle":false,"terminationReason":"NO_TOOL_CALL"')" "$SERVER_URL" "$state_dir"
  run_hook_ag PreInvocation "$(ag_input "$c" '"invocationNum":2,"initialNumSteps":3')" "$SERVER_URL" "$state_dir"
  local state_restarted
  state_restarted="$(d1_scalar "SELECT state FROM dashboard_sessions WHERE key='antigravity:$c'" state)"
  if [ -e "$state_dir/antigravity/stopped/$c" ]; then
    ok=1; details="${details} 래치 중 PreInvocation(2) 뒤에도 래치 파일이 남아 있음;"
  fi
  # 래치가 풀린 뒤의 PreInvocation(1 이상)은 다시 한 턴 안의 모델 호출이라 보내지 않는다.
  run_hook_ag PreInvocation "$(ag_input "$c" '"invocationNum":3,"initialNumSteps":3')" "$SERVER_URL" "$state_dir"
  run_hook_ag Stop "$(ag_input "$c" '"fullyIdle":true')" "$SERVER_URL" "$state_dir"

  local events state_final
  events="$(d1_events "antigravity:$c")"
  state_final="$(d1_scalar "SELECT state FROM dashboard_sessions WHERE key='antigravity:$c'" state)"
  if [ "$events" != "UserPromptSubmit,Stop,UserPromptSubmit,Stop" ]; then
    ok=1; details="${details} 도착='$events'(기대 UserPromptSubmit,Stop,UserPromptSubmit,Stop);"
  fi
  if [ "$state_restarted" != "working" ]; then
    ok=1; details="${details} 래치 중 PreInvocation(2) 뒤 state='$state_restarted'(기대 working);"
  fi
  if [ "$state_final" != "done" ]; then
    ok=1; details="${details} 마지막 Stop 뒤 state='$state_final'(기대 done);"
  fi

  if [ "$ok" -eq 0 ]; then
    record "31. antigravity: Stop 래치 중 PreInvocation(invocationNum 2)은 턴 재시작(UserPromptSubmit·래치 해제), 다음 Stop에 done" 0 "도착 UserPromptSubmit,Stop,UserPromptSubmit,Stop·재시작 뒤 working·래치 해제·PreInvocation(3) 미전송·마지막 done"
  else
    record "31. antigravity: Stop 래치 중 PreInvocation(invocationNum 2)은 턴 재시작(UserPromptSubmit·래치 해제), 다음 Stop에 done" 1 "$details"
  fi
}

# ---------- Check 32: antigravity 서버가 응답하지 않으면 이번 이벤트를 스풀 끝에 넣는다 ----------
# 재전송이 서버 응답을 하나도 받지 못했으면(연결 실패·시간 초과, curl 000) 이번 이벤트도 보내 보지 않고
# 스풀 끝에 넣는다 - 서버가 닿지 않는 동안 hook이 두 번 기다리지 않게 한다. 서버가 다시 닿으면 다음
# hook이 밀린 줄을 순서대로 보낸 뒤 자기 이벤트를 보낸다.

check32_antigravity_unreachable_queues_then_delivers() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-ag-down"
  local log="$WORK_DIR/aux-down.log"
  local i got
  mkdir -p "$state_dir"
  for i in 1 2 3; do
    printf '{"protocol_version":1,"source":"claude-code","session_id":"ag-down-old","project":"/tmp/demo","event":"PostToolUse","event_id":"ag-down-old-%s"}\n' "$i"
  done > "$state_dir/spool.ndjson"
  # 서버가 닿지 않는다(연결 거부 = 응답 없음) -> 이번 이벤트는 스풀 끝.
  run_hook_ag PreInvocation "$(ag_input ag-down '"invocationNum":0,"initialNumSteps":1')" \
    "$BAD_URL" "$state_dir" "MY_DASHBOARD_EVENT_ID=ag-down-cur-1"
  local queued
  queued="$(jq -r '.event_id' "$state_dir/spool.ndjson" 2>/dev/null | tr '\n' ' ')"
  if [ "$queued" != "ag-down-old-1 ag-down-old-2 ag-down-old-3 ag-down-cur-1 " ]; then
    ok=1; details="${details} 응답 없는 동안 스풀=[$queued](기대 밀린 3줄 뒤 이번 이벤트);"
  fi
  # 서버가 다시 닿는다 -> 밀린 줄을 순서대로 보내고 자기 이벤트를 보낸다.
  : > "$log"
  start_aux_server slow 0 "$log"
  if [ -z "$AUX_PORT" ]; then
    record "32. antigravity: 서버 응답이 없으면 이번 이벤트를 스풀 끝에 넣고, 다시 닿으면 순서대로 전달" 1 "보조 서버를 띄우지 못함"
    return
  fi
  run_hook_ag PreInvocation "$(ag_input ag-down '"invocationNum":0,"initialNumSteps":1')" \
    "http://127.0.0.1:$AUX_PORT" "$state_dir" "MY_DASHBOARD_EVENT_ID=ag-down-cur-2"
  got="$(tr '\n' ' ' < "$log")"
  if [ "$got" != "ag-down-old-1 ag-down-old-2 ag-down-old-3 ag-down-cur-1 ag-down-cur-2 " ] || [ -s "$state_dir/spool.ndjson" ]; then
    ok=1; details="${details} 다시 닿은 뒤 도착=[$got](기대 밀린 3줄·cur-1·cur-2 순), 스풀 $(wc -l < "$state_dir/spool.ndjson" | tr -d ' ')줄(기대 0);"
  fi
  local pid
  for pid in $AUX_PIDS; do
    kill "$pid" 2>/dev/null
  done
  AUX_PIDS=""

  if [ "$ok" -eq 0 ]; then
    record "32. antigravity: 서버 응답이 없으면 이번 이벤트를 스풀 끝에 넣고, 다시 닿으면 순서대로 전달" 0 "응답 없는 동안 이번 이벤트가 스풀 끝, 다시 닿은 뒤 밀린 3줄·cur-1·cur-2 순서로 도착하고 스풀 비움"
  else
    record "32. antigravity: 서버 응답이 없으면 이번 이벤트를 스풀 끝에 넣고, 다시 닿으면 순서대로 전달" 1 "$details"
  fi
}

# ---------- Check 33: antigravity 서버가 응답했으면(4xx·5xx·429) 이번 이벤트는 바로 보낸다 ----------
# 스풀 맨 앞 줄이 늘 거절돼도(400·500·429) 그 뒤에 이번 이벤트를 세우면 agy 이벤트가 하나도 나가지
# 않는다. 서버는 더 오래된 occurred_at의 상태 이벤트를 무시하므로 최신 이벤트를 먼저 보내도 된다.

check33_antigravity_responding_server_sends_now() {
  local ok=0
  local details=""
  local log="$WORK_DIR/aux-reject.log"
  local code state_dir got
  : > "$log"
  start_aux_server poison 0 "$log"
  if [ -z "$AUX_PORT" ]; then
    record "33. antigravity: 스풀 맨 앞 줄이 4xx·5xx·429로 거절돼도 이번 이벤트는 바로 전달" 1 "보조 서버를 띄우지 못함"
    return
  fi
  for code in 400 500 429; do
    state_dir="$WORK_DIR/state-ag-reject-$code"
    mkdir -p "$state_dir"
    printf '%s\n' \
      "{\"protocol_version\":1,\"source\":\"claude-code\",\"session_id\":\"ag-reject-old\",\"project\":\"/tmp/demo\",\"event\":\"PostToolUse\",\"event_id\":\"ag-reject-poison$code-1\"}" \
      '{"protocol_version":1,"source":"claude-code","session_id":"ag-reject-old","project":"/tmp/demo","event":"PostToolUse","event_id":"ag-reject-old-2"}' \
      > "$state_dir/spool.ndjson"
    cp "$state_dir/spool.ndjson" "$WORK_DIR/reject-spool-before-$code.ndjson"
    : > "$log"
    run_hook_ag Stop "$(ag_input "ag-reject-$code" '"fullyIdle":true')" \
      "http://127.0.0.1:$AUX_PORT" "$state_dir" "MY_DASHBOARD_EVENT_ID=ag-reject-cur-$code"
    got="$(tr '\n' ' ' < "$log")"
    if [ "$got" != "rejected:ag-reject-poison$code-1 ag-reject-cur-$code " ]; then
      ok=1; details="${details} [$code] 서버 기록=[$got](기대 거절 1건 뒤 이번 Stop);"
    fi
    if ! cmp -s "$WORK_DIR/reject-spool-before-$code.ndjson" "$state_dir/spool.ndjson"; then
      ok=1; details="${details} [$code] 스풀이 바뀌었다(기대: 거절된 줄과 그 뒤 줄이 그대로, 이번 Stop은 없음);"
    fi
  done
  local pid
  for pid in $AUX_PIDS; do
    kill "$pid" 2>/dev/null
  done
  AUX_PIDS=""

  if [ "$ok" -eq 0 ]; then
    record "33. antigravity: 스풀 맨 앞 줄이 4xx·5xx·429로 거절돼도 이번 이벤트는 바로 전달" 0 "400·500·429 모두 거절 1건 뒤 이번 Stop 도착, 스풀 2줄 그대로"
  else
    record "33. antigravity: 스풀 맨 앞 줄이 4xx·5xx·429로 거절돼도 이번 이벤트는 바로 전달" 1 "$details"
  fi
}

# 다른 hook이 스풀 락을 잡을 때까지 기다린다(최대 3초). 잡았으면 0.
wait_for_spool_lock() {
  local tries=0
  while [ ! -d "$1/spool.lock" ] && [ "$tries" -lt 60 ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -d "$1/spool.lock" ]
}

# ---------- Check 34: 다른 hook이 재전송하는 동안(락 점유) agy Stop은 바로 전달된다 ----------
# 락을 못 잡은 hook은 재전송을 해 보지 못했으니 서버가 닿는지 모른다. 이때 이번 이벤트를 스풀에 붙이면
# 락을 쥔 hook의 재작성과 겹칠 수 있으므로, agy 이벤트는 바로 보낸다.

check34_antigravity_sends_while_other_hook_flushes() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-ag-race"
  local log="$WORK_DIR/aux-race.log"
  local i bg got
  mkdir -p "$state_dir"
  for i in $(seq 1 6); do
    printf '{"protocol_version":1,"source":"claude-code","session_id":"ag-race-old","project":"/tmp/demo","event":"PostToolUse","event_id":"ag-race-old-%s"}\n' "$i"
  done > "$state_dir/spool.ndjson"
  : > "$log"
  start_aux_server slow 0.5 "$log"
  if [ -z "$AUX_PORT" ]; then
    record "34. 다른 hook이 스풀을 재전송하는 동안(락 점유) agy Stop은 스풀에 붙지 않고 바로 전달" 1 "느린 서버를 띄우지 못함"
    return
  fi
  # claude-code hook이 6줄×0.5초 동안 락을 쥐고 재전송한다.
  env -i PATH="$PATH" HOME="$HOME" MY_DASHBOARD_URL="http://127.0.0.1:$AUX_PORT" MY_DASHBOARD_TOKEN="$TOKEN" \
    MY_DASHBOARD_STATE_DIR="$state_dir" MY_DASHBOARD_ENV="$NO_ENV_FILE" MY_DASHBOARD_EVENT_ID=ag-race-cc-stop \
    "$BASH_BIN" "$HOOK" claude-code <<<'{"session_id":"ag-race-cc","cwd":"/tmp/demo","hook_event_name":"Stop"}' >/dev/null 2>&1 &
  bg=$!
  if ! wait_for_spool_lock "$state_dir"; then
    ok=1; details="${details} claude-code hook이 락을 잡지 않았다(테스트 전제 실패);"
  fi
  run_hook_ag Stop "$(ag_input ag-race '"fullyIdle":true')" \
    "http://127.0.0.1:$AUX_PORT" "$state_dir" "MY_DASHBOARD_EVENT_ID=ag-race-agy-stop"
  # 락은 재작성(mv) 직후에야 풀리므로, 아직 락이 있으면 agy hook 내내 claude-code가 재전송 중이었다.
  if [ ! -d "$state_dir/spool.lock" ]; then
    ok=1; details="${details} agy hook이 끝나기 전에 claude-code 재전송이 끝났다(테스트 전제 실패);"
  fi
  wait "$bg" 2>/dev/null
  got="$(tr '\n' ' ' < "$log")"
  case " $got" in
    *" ag-race-agy-stop "*) ;;
    *) ok=1; details="${details} agy Stop이 도착하지 않았다 — 서버 기록=[$got];" ;;
  esac
  local n_old
  n_old="$(grep -c '^ag-race-old-' "$log")"
  if [ "$n_old" != "6" ] || [ -s "$state_dir/spool.ndjson" ]; then
    ok=1; details="${details} 밀린 줄 도착 ${n_old}건(기대 6)·스풀 $(wc -l < "$state_dir/spool.ndjson" | tr -d ' ')줄(기대 0);"
  fi
  local pid
  for pid in $AUX_PIDS; do
    kill "$pid" 2>/dev/null
  done
  AUX_PIDS=""

  if [ "$ok" -eq 0 ]; then
    record "34. 다른 hook이 스풀을 재전송하는 동안(락 점유) agy Stop은 스풀에 붙지 않고 바로 전달" 0 "claude-code 재전송 중 agy Stop 도착, 밀린 6줄 모두 도착, 스풀 비움"
  else
    record "34. 다른 hook이 스풀을 재전송하는 동안(락 점유) agy Stop은 스풀에 붙지 않고 바로 전달" 1 "$details"
  fi
}

# ---------- Check 35: 백로그가 한 번에 다 비지 않아도 서버가 응답하면 Stop은 같은 실행에서 전달 ----------
# 재전송은 hook 한 번에 앞쪽 50줄까지다. 60줄이 밀려 있어도 서버가 응답하고 있으면 Stop을 다음 hook까지
# 묶어 두지 않는다 - 묶으면 세션이 working에 멈춘 채 stalled 푸시가 잘못 나간다.

check35_antigravity_stop_not_held_by_backlog() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-ag-backlog"
  local log="$WORK_DIR/aux-backlog.log"
  local i got_tail rest
  mkdir -p "$state_dir"
  for i in $(seq 1 60); do
    printf '{"protocol_version":1,"source":"claude-code","session_id":"ag-backlog-old","project":"/tmp/demo","event":"PostToolUse","event_id":"ag-backlog-old-%s"}\n' "$i"
  done > "$state_dir/spool.ndjson"
  : > "$log"
  start_aux_server slow 0 "$log"
  if [ -z "$AUX_PORT" ]; then
    record "35. antigravity: 60줄 백로그가 남아도 서버가 응답하면 Stop은 같은 실행에서 전달" 1 "보조 서버를 띄우지 못함"
    return
  fi
  run_hook_ag Stop "$(ag_input ag-backlog '"fullyIdle":true')" \
    "http://127.0.0.1:$AUX_PORT" "$state_dir" "MY_DASHBOARD_EVENT_ID=ag-backlog-stop"
  got_tail="$(tail -n 2 "$log" | tr '\n' ' ')"
  rest="$(jq -r '.event_id' "$state_dir/spool.ndjson" 2>/dev/null | tr '\n' ' ')"
  if [ "$(wc -l < "$log" | tr -d ' ')" != "51" ] || [ "$got_tail" != "ag-backlog-old-50 ag-backlog-stop " ]; then
    ok=1; details="${details} 서버 기록 $(wc -l < "$log" | tr -d ' ')건·끝=[$got_tail](기대 밀린 50줄 다음 Stop);"
  fi
  if [ "$rest" != "$(seq -f 'ag-backlog-old-%g' 51 60 | tr '\n' ' ')" ]; then
    ok=1; details="${details} 남은 스풀=[$rest](기대 old-51..60, Stop 없음);"
  fi
  local pid
  for pid in $AUX_PIDS; do
    kill "$pid" 2>/dev/null
  done
  AUX_PIDS=""

  if [ "$ok" -eq 0 ]; then
    record "35. antigravity: 60줄 백로그가 남아도 서버가 응답하면 Stop은 같은 실행에서 전달" 0 "밀린 50줄 다음 Stop 도착, 남은 10줄만 스풀"
  else
    record "35. antigravity: 60줄 백로그가 남아도 서버가 응답하면 Stop은 같은 실행에서 전달" 1 "$details"
  fi
}

# ---------- Check 36: 공통 - 재전송 중 다른 hook이 붙인 스풀 줄은 재작성에서 사라지지 않는다 ----------
# append_spool은 락 없이 붙이고 flush_spool은 끝에 스풀을 통째로 다시 쓴다. 가져간 줄 다음을 전부
# 되돌리지 않으면(예전: 시작할 때 50줄 이하면 건너뜀) 그사이 붙은 줄이 사라진다. 모든 source에 해당한다.

check36_spool_append_during_flush_survives() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-flush-race"
  local log="$WORK_DIR/aux-flush-race.log"
  local i bg got rest
  mkdir -p "$state_dir"
  for i in 1 2 3 4; do
    printf '{"protocol_version":1,"source":"claude-code","session_id":"flush-race-old","project":"/tmp/demo","event":"PostToolUse","event_id":"flush-race-old-%s"}\n' "$i"
  done > "$state_dir/spool.ndjson"
  : > "$log"
  start_aux_server slow 1.0 "$log"
  if [ -z "$AUX_PORT" ]; then
    record "36. 공통: 재전송 중 다른 hook이 스풀에 붙인 줄이 재전송 뒤에도 남는다" 1 "느린 서버를 띄우지 못함"
    return
  fi
  # claude-code hook이 4줄×1초 동안 락을 쥐고 재전송한다(시작할 때 50줄 이하).
  env -i PATH="$PATH" HOME="$HOME" MY_DASHBOARD_URL="http://127.0.0.1:$AUX_PORT" MY_DASHBOARD_TOKEN="$TOKEN" \
    MY_DASHBOARD_STATE_DIR="$state_dir" MY_DASHBOARD_ENV="$NO_ENV_FILE" MY_DASHBOARD_EVENT_ID=flush-race-a \
    "$BASH_BIN" "$HOOK" claude-code <<<'{"session_id":"flush-race-a","cwd":"/tmp/demo","hook_event_name":"UserPromptSubmit"}' >/dev/null 2>&1 &
  bg=$!
  if ! wait_for_spool_lock "$state_dir"; then
    ok=1; details="${details} 첫 hook이 락을 잡지 않았다(테스트 전제 실패);"
  fi
  # 그동안 codex hook이 닿지 않는 서버로 보내다 실패해 스풀에 줄을 붙인다(append_spool, 락 없음).
  run_hook_src codex '{"session_id":"flush-race-b","cwd":"/tmp/demo","hook_event_name":"UserPromptSubmit"}' \
    "$BAD_URL" "$state_dir" MY_DASHBOARD_EVENT_ID=flush-race-appended >/dev/null
  # 락은 재작성(mv) 직후에야 풀리므로, 아직 락이 있으면 줄을 붙인 뒤에 재작성이 온다.
  if [ ! -d "$state_dir/spool.lock" ]; then
    ok=1; details="${details} 줄을 붙이기 전에 첫 hook의 재작성이 끝났다(테스트 전제 실패);"
  fi
  wait "$bg" 2>/dev/null
  got="$(tr '\n' ' ' < "$log")"
  rest="$(jq -r '.event_id' "$state_dir/spool.ndjson" 2>/dev/null | tr '\n' ' ')"
  if [ "$rest" != "flush-race-appended " ]; then
    ok=1; details="${details} 재전송 뒤 스풀=[$rest](기대 재전송 중 붙은 줄 flush-race-appended 하나);"
  fi
  if [ "$got" != "flush-race-old-1 flush-race-old-2 flush-race-old-3 flush-race-old-4 flush-race-a " ]; then
    ok=1; details="${details} 서버 기록=[$got](기대 밀린 4줄 다음 첫 hook의 이벤트);"
  fi
  local pid
  for pid in $AUX_PIDS; do
    kill "$pid" 2>/dev/null
  done
  AUX_PIDS=""

  if [ "$ok" -eq 0 ]; then
    record "36. 공통: 재전송 중 다른 hook이 스풀에 붙인 줄이 재전송 뒤에도 남는다" 0 "claude-code 재전송 중 codex가 붙인 줄이 재작성 뒤 스풀에 남음, 밀린 4줄 전달"
  else
    record "36. 공통: 재전송 중 다른 hook이 스풀에 붙인 줄이 재전송 뒤에도 남는다" 1 "$details"
  fi
}

# ---------- Check 37: 공통 - flush는 실제로 가져간 줄만큼만 건너뛴다 ----------
# flush_spool은 wc로 줄 수를 센 뒤 head로 앞쪽 줄을 가져온다. 그 사이 붙은 줄은 head가 이번에 가져가
# 보내므로, 되돌릴 줄은 head가 실제로 읽은 줄 다음부터여야 한다 - wc로 센 수를 쓰면 그 줄을 보내고도
# 스풀에 또 남겨 한 번 더 보낸다. PATH 앞에 둔 head 대리 스크립트가 flush의 head 직전에 줄을 한 번
# 붙여 그 사이를 정확히 재현한다.

check37_flush_skips_exactly_what_it_took() {
  local ok=0
  local details=""
  local state_dir="$WORK_DIR/state-flush-exact"
  local log="$WORK_DIR/aux-flush-exact.log"
  local shim_dir="$WORK_DIR/head-shim"
  local i got rest
  mkdir -p "$state_dir" "$shim_dir"
  for i in 1 2; do
    printf '{"protocol_version":1,"source":"claude-code","session_id":"flush-exact-old","project":"/tmp/demo","event":"PostToolUse","event_id":"flush-exact-old-%s"}\n' "$i"
  done > "$state_dir/spool.ndjson"
  cat > "$shim_dir/head" <<'HEAD_SHIM'
#!/bin/bash
# flush_spool의 head -n <N> <스풀> 호출에서만, 한 번, 스풀에 줄을 붙이고 진짜 head로 넘긴다.
if [ "${1:-}" = "-n" ] && [ "${3:-}" = "$SHIM_SPOOL" ] && [ ! -e "$SHIM_ONCE" ]; then
  : > "$SHIM_ONCE"
  printf '%s\n' "$SHIM_LINE" >> "$SHIM_SPOOL"
fi
exec "$SHIM_REAL_HEAD" "$@"
HEAD_SHIM
  chmod +x "$shim_dir/head"
  : > "$log"
  start_aux_server slow 0 "$log"
  if [ -z "$AUX_PORT" ]; then
    record "37. 공통: flush는 실제로 가져간 줄만큼만 건너뛴다(wc와 head 사이에 붙은 줄을 두 번 보내지 않는다)" 1 "보조 서버를 띄우지 못함"
    return
  fi
  run_hook '{"session_id":"flush-exact","cwd":"/tmp/demo","hook_event_name":"UserPromptSubmit"}' \
    "http://127.0.0.1:$AUX_PORT" "$state_dir" \
    "PATH=$shim_dir:$PATH" "SHIM_SPOOL=$state_dir/spool.ndjson" "SHIM_ONCE=$WORK_DIR/head-shim.once" \
    "SHIM_REAL_HEAD=$(command -v head)" MY_DASHBOARD_EVENT_ID=flush-exact-cur \
    'SHIM_LINE={"protocol_version":1,"source":"claude-code","session_id":"flush-exact-old","project":"/tmp/demo","event":"PostToolUse","event_id":"flush-exact-late"}' \
    >/dev/null
  if [ ! -e "$WORK_DIR/head-shim.once" ]; then
    ok=1; details="${details} head 대리 스크립트가 flush의 head를 가로채지 못했다(테스트 전제 실패);"
  fi
  got="$(tr '\n' ' ' < "$log")"
  rest="$(jq -r '.event_id' "$state_dir/spool.ndjson" 2>/dev/null | tr '\n' ' ')"
  if [ "$got" != "flush-exact-old-1 flush-exact-old-2 flush-exact-late flush-exact-cur " ]; then
    ok=1; details="${details} 서버 기록=[$got](기대 밀린 2줄·wc 뒤 붙은 줄·이번 이벤트 한 번씩);"
  fi
  if [ -n "$rest" ]; then
    ok=1; details="${details} flush 뒤 스풀=[$rest](기대 비어 있음 - 이미 보낸 줄을 또 남겼다);"
  fi
  local pid
  for pid in $AUX_PIDS; do
    kill "$pid" 2>/dev/null
  done
  AUX_PIDS=""

  if [ "$ok" -eq 0 ]; then
    record "37. 공통: flush는 실제로 가져간 줄만큼만 건너뛴다(wc와 head 사이에 붙은 줄을 두 번 보내지 않는다)" 0 "wc와 head 사이에 붙은 줄이 이번 flush에서 한 번만 전달되고 스풀에 다시 남지 않음"
  else
    record "37. 공통: flush는 실제로 가져간 줄만큼만 건너뛴다(wc와 head 사이에 붙은 줄을 두 번 보내지 않는다)" 1 "$details"
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
check18_grok_notification_and_source
check19_antigravity_stdout
check20_antigravity_turn_start
check21_antigravity_subagent
check22_antigravity_questions
check23_antigravity_heartbeat_throttle
check24_antigravity_stop_fully_idle
check25_antigravity_post_stop_latch
check26_antigravity_print_mode
check27_antigravity_empty_input
check28_antigravity_spool_budget
check29_antigravity_throttled_heartbeat_skips_replay
check30_antigravity_background_turn_ends_done
check31_antigravity_latched_preinvocation_restarts_turn
check32_antigravity_unreachable_queues_then_delivers
check33_antigravity_responding_server_sends_now
check34_antigravity_sends_while_other_hook_flushes
check35_antigravity_stop_not_held_by_backlog
check36_spool_append_during_flush_survives
check37_flush_skips_exactly_what_it_took

log ""
log "===== 결과 요약 ====="
for r in "${CHECK_RESULTS[@]}"; do
  log "$r"
done
log "총 ${#CHECK_RESULTS[@]}개 중 실패 ${FAIL_COUNT}개"

exit "$([ "$FAIL_COUNT" -eq 0 ] && echo 0 || echo 1)"
