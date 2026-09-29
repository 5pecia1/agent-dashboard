#!/usr/bin/env bash
# Claude Code / Codex / Devin CLI / Antigravity CLI(agy)에 my-dashboard hook을 등록하는 설치 스크립트.
#
# *** 코딩 에이전트의 자동화 워크플로 안에서는 이 스크립트를 절대 실행하지
# 않는다. *** ~/.claude/settings.json, ~/.codex/config.toml, ~/.config/devin/config.json,
# ~/.gemini/config/hooks.json은 전역 설정이라 Sol의 명시적
# 승인 없이는 건드릴 수 없다 - 에이전트는 검토만 하고, 사람이 직접 실행해야 한다.
#
# 사람이 직접 실행하는 경로는 두 가지고 결과는 같다(이 파일은 자신이 실제로 있는 위치
# SCRIPT_DIR을 기준으로 경로를 계산하므로 어느 쪽이든 동일하게 동작한다):
#   1. repo를 clone해서 `bash hooks/install.sh ...`로 직접 실행.
#   2. repo clone 없이 `curl -fsSL <서버 origin>/setup.sh | bash` 한 줄로 설치 - setup.sh가
#      이 파일을 ${XDG_DATA_HOME:-$HOME/.local/share}/my-dashboard/hooks/ 에 내려받아 그
#      자리에서 --claude --codex --devin --antigravity로 대신 실행해 준다.
# 대안으로 hooks/README.md의 복사-붙여넣기 스니핏을 손으로 넣어도 된다 - 결과는 동일하다.
#
# 하는 일:
#   1. ~/.claude/settings.json에 SessionStart/UserPromptSubmit/Notification/PostToolUse/
#      Stop/SessionEnd 다섯(+하트비트 하나) hook 등록을 jq로 멱등 병합한다.
#      (같은 command면 그대로 두고, 옛 경로로 등록된 낡은 항목은 지운다 - 중복 전송 방지.)
#   2. ~/.codex/config.toml에 codex-hooks.toml 내용을 마커 블록으로 멱등 삽입한다.
#      (마커가 이미 있으면 그 사이만 갈아 끼운다 - 마커 밖 사용자 설정은 손대지 않는다.)
#   3. ~/.config/devin/config.json (JSONC)에 Devin hook 등록을 추가한다.
#      (JSONC 파싱으로 주석 보존, 기존 hooks 보존.)
#   4. ~/.gemini/config/hooks.json에 Antigravity CLI용 my-dashboard 번들 하나를 멱등으로 넣는다.
#      (같은 파일의 다른 도구가 넣은 번들과 그 밖의 키는 손대지 않는다.
#      파일이 없거나 비어 있으면 새로 만들고(UTF-8 BOM은 벗기고 읽는다), 유효한 JSON 객체가
#      아니면 쓰지 않고 멈춘다.)
#   5. 네 파일 다 수정 직전에 타임스탬프 백업을 남긴다.
#
# 사용법:
#   bash hooks/install.sh --dry-run           # 무엇이 바뀔지만 보여주고 아무 것도 쓰지 않는다(기본값)
#   bash hooks/install.sh --claude            # ~/.claude/settings.json만 실제로 쓴다
#   bash hooks/install.sh --codex             # ~/.codex/config.toml만 실제로 쓴다
#   bash hooks/install.sh --devin             # ~/.config/devin/config.json만 실제로 쓴다
#   bash hooks/install.sh --antigravity       # ~/.gemini/config/hooks.json만 실제로 쓴다
#   bash hooks/install.sh --claude --codex    # Claude Code와 Codex만 실제로 쓴다
#   bash hooks/install.sh --claude --codex --devin --antigravity   # 넷 다 실제로 쓴다
#
# --dry-run이 아닌 모드는 각각 --claude / --codex / --devin / --antigravity를 명시해야 실제로 쓴다(실수로 전체 적용 방지).
set -euo pipefail

command -v python3 >/dev/null 2>&1 || { echo "python3 is required for safe hook command quoting" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/agent-event-hook.sh"
NOTIFY_SCRIPT="$SCRIPT_DIR/codex-notify.sh"
CODEX_HOOKS_TOML="$SCRIPT_DIR/codex-hooks.toml"

CLAUDE_SETTINGS="${MY_DASHBOARD_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
CODEX_CONFIG="${MY_DASHBOARD_CODEX_CONFIG:-$HOME/.codex/config.toml}"
DEVIN_CONFIG="${MY_DASHBOARD_DEVIN_CONFIG:-$HOME/.config/devin/config.json}"
ANTIGRAVITY_HOOKS="${MY_DASHBOARD_ANTIGRAVITY_HOOKS:-$HOME/.gemini/config/hooks.json}"
# hooks.json의 최상위 키 하나가 번들 하나다. 정본: contracts/dashboard-protocol.v1.json의
# event_state_map.antigravity_hook_translation.registration.bundle_key.
ANTIGRAVITY_BUNDLE_KEY="my-dashboard"

MARKER_BEGIN="# BEGIN my-dashboard hooks (managed by hooks/install.sh — do not edit between markers by hand)"
MARKER_END="# END my-dashboard hooks"

DO_CLAUDE=0
DO_CODEX=0
DO_DEVIN=0
DO_ANTIGRAVITY=0
DRY_RUN=1

for arg in "$@"; do
  case "$arg" in
    --claude) DO_CLAUDE=1; DRY_RUN=0 ;;
    --codex) DO_CODEX=1; DRY_RUN=0 ;;
    --devin) DO_DEVIN=1; DRY_RUN=0 ;;
    --antigravity) DO_ANTIGRAVITY=1; DRY_RUN=0 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,38p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "알 수 없는 옵션: $arg (--help 참고)" >&2
      exit 1
      ;;
  esac
done

if [ "$DRY_RUN" -eq 1 ] && { [ "$DO_CLAUDE" -eq 1 ] || [ "$DO_CODEX" -eq 1 ] || [ "$DO_DEVIN" -eq 1 ] || [ "$DO_ANTIGRAVITY" -eq 1 ]; }; then
  DRY_RUN=0
fi
if [ "$DO_CLAUDE" -eq 0 ] && [ "$DO_CODEX" -eq 0 ] && [ "$DO_DEVIN" -eq 0 ] && [ "$DO_ANTIGRAVITY" -eq 0 ]; then
  DRY_RUN=1
  DO_CLAUDE=1
  DO_CODEX=1
  DO_DEVIN=1
  DO_ANTIGRAVITY=1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq가 필요하다 (brew install jq)." >&2
  exit 1
fi

backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  local ts
  ts="$(date +%Y%m%d%H%M%S 2>/dev/null || echo now)"
  cp "$f" "${f}.bak.${ts}"
  echo "백업: ${f}.bak.${ts}"
}

# ---------- Claude Code: ~/.claude/settings.json ----------

install_claude() {
  echo "== Claude Code: $CLAUDE_SETTINGS =="
  mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
  if [ ! -f "$CLAUDE_SETTINGS" ]; then
    echo '{}' > "$CLAUDE_SETTINGS"
  fi
  if ! jq -e . "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
    echo "$CLAUDE_SETTINGS 가 유효한 JSON이 아니다. 손으로 고친 뒤 다시 실행." >&2
    return 1
  fi

  local cmd="$(python3 -c 'import shlex,sys;print(shlex.quote(sys.argv[1])+" claude-code")' "$HOOK_SCRIPT")"
  local events=(SessionStart UserPromptSubmit Notification PostToolUse Stop SessionEnd)

  local merged
  merged="$(jq --arg cmd "$cmd" \
    --argjson events "$(printf '%s\n' "${events[@]}" | jq -R . | jq -s .)" \
    '
    # 낡은 등록 제거. 옛 방식(repo를 clone한 경로의 hooks/agent-event-hook.sh를 직접 등록)
    # 이나 옛 repo 이름(my-deshboard)으로 설치했던 기계는, 정리 없이 재설치하면 정식 경로가
    # "추가로" 들어가 훅이 두 번 등록되고 같은 이벤트가 두 번 전송된다.
    # 판정 기준은 이름이 아니라 "이번에 설치할 정식 $cmd와 다른가"다 - 정식 설치 경로
    # (~/.local/share/my-dashboard/hooks/agent-event-hook.sh)에도 my-dashboard가 들어가므로
    # 이름으로 매치해 지우면 방금 넣은 정식 항목까지 지워진다.
    def strip_stale($cmd):
      map(
        . as $group
        | ($group.hooks // []) as $orig
        | ($orig | map(select(
            (
              (.command? // null) as $c
              | ($c | type) == "string"
                and ($c | contains("agent-event-hook.sh"))
                and ($c != $cmd)
            ) | not
          ))) as $kept
        # 우리 항목만 들어 있던 group은 껍데기만 남으므로 통째로 버린다. 원래부터
        # 비어 있던 group은 우리가 만든 게 아니니 그대로 둔다(무관한 설정 보존).
        | if ($orig | length) > 0 and ($kept | length) == 0 then empty
          elif $kept == $orig then $group
          else $group | .hooks = $kept
          end
      );
    .hooks //= {}
    | reduce ($events[]) as $ev (
        .;
        .hooks[$ev] //= []
        | (if (.hooks[$ev] | type) == "array"
           then .hooks[$ev] |= strip_stale($cmd)
           else . end)
        # 이미 이 command가 있는 group이 하나라도 있으면 그대로 둔다(멱등).
        | if ([.hooks[$ev][]?.hooks[]?.command] | index($cmd)) then .
          else .hooks[$ev] += [{hooks: [{type: "command", command: $cmd}]}]
          end
      )
    ' "$CLAUDE_SETTINGS")"

  if [ "$merged" = "$(cat "$CLAUDE_SETTINGS")" ]; then
    echo "변경 없음 (이미 등록돼 있음)."
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "--dry-run: 아래 내용으로 바뀔 예정 (실제로 쓰지 않음)"
    echo "$merged" | jq .
    return 0
  fi

  backup_file "$CLAUDE_SETTINGS"
  printf '%s\n' "$merged" | jq . > "$CLAUDE_SETTINGS"
  echo "$CLAUDE_SETTINGS 갱신 완료."
}

# ---------- Codex: ~/.codex/config.toml ----------

install_codex() {
  echo "== Codex: $CODEX_CONFIG =="
  mkdir -p "$(dirname "$CODEX_CONFIG")"
  [ -f "$CODEX_CONFIG" ] || : > "$CODEX_CONFIG"

  if [ ! -f "$CODEX_HOOKS_TOML" ]; then
    echo "$CODEX_HOOKS_TOML 이 없다." >&2
    return 1
  fi

  # codex-hooks.toml에서 마커 사이에 넣을 실제 hooks 블록만 뽑는다(주석 설명은 뺀다).
  local block
  block="$(awk '/^\[\[hooks\./{p=1} p{print}' "$CODEX_HOOKS_TOML")"
  if [ -z "$block" ]; then
    echo "$CODEX_HOOKS_TOML 에서 [[hooks. 블록을 찾지 못했다." >&2
    return 1
  fi

  # Serialize each managed command from the actual installation path. JSON basic
  # strings are also valid TOML strings; shlex quotes shell metacharacters safely.
  block="$(HOOK_SCRIPT="$HOOK_SCRIPT" HOOK_BLOCK="$block" python3 - <<'CODEX_PY'
import json, os, re, shlex
command = shlex.quote(os.environ['HOOK_SCRIPT']) + ' codex'
text, count = re.subn(r'^command\s*=.*$', lambda _: 'command = ' + json.dumps(command),
                      os.environ['HOOK_BLOCK'], flags=re.MULTILINE)
if not count:
    raise SystemExit('No managed Codex hook commands found')
print(text)
CODEX_PY
)"

  local new_section
  new_section="$MARKER_BEGIN
$block
$MARKER_END"

  local current
  current="$(cat "$CODEX_CONFIG")"

  local updated
  if printf '%s' "$current" | grep -qF "$MARKER_BEGIN"; then
    # 기존 마커 블록만 통째로 교체한다(마커 밖은 그대로).
    # new_section은 여러 줄 값이라 awk -v로 넘기면 macOS 기본 /usr/bin/awk(BWK awk)가
    # "newline in string"으로 거부한다(POSIX awk -v는 값에 리터럴 개행을 못 담는다).
    # 환경변수 + ENVIRON으로 우회한다 - begin/end는 한 줄 값이라 -v 그대로 둬도 된다.
    updated="$(printf '%s\n' "$current" | REPL="$new_section" awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
      $0 == begin { print ENVIRON["REPL"]; skip=1; next }
      $0 == end { if (skip) { skip=0; next } }
      skip { next }
      { print }
    ')"
  else
    updated="$current

$new_section"
  fi

  if [ "$updated" = "$current" ]; then
    echo "변경 없음 (이미 최신 블록이 등록돼 있음)."
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "--dry-run: 아래 블록이 마커 사이에 들어갈 예정 (실제로 쓰지 않음)"
    echo "$new_section"
    return 0
  fi

  backup_file "$CODEX_CONFIG"
  printf '%s\n' "$updated" > "$CODEX_CONFIG"
  echo "$CODEX_CONFIG 갱신 완료. Codex TUI에서 /hooks로 신뢰(trust) 처리를 잊지 말 것."
}

# ---------- Devin: ~/.config/devin/config.json (JSONC) ----------

install_devin() {
  echo "== Devin: $DEVIN_CONFIG =="
  mkdir -p "$(dirname "$DEVIN_CONFIG")"
  
  # Devin config.json은 JSONC (주석 허용) 형식
  # 파일이 없으면 빈 JSONC 객체 생성
  if [ ! -f "$DEVIN_CONFIG" ]; then
    echo '{}' > "$DEVIN_CONFIG"
  fi
  
  local cmd="$(python3 -c 'import shlex,sys;print(shlex.quote(sys.argv[1])+" devin")' "$HOOK_SCRIPT")"
  local events=(SessionStart UserPromptSubmit Stop PostToolUse SessionEnd PermissionRequest)

  # 간단한 JSONC 처리: 줄 단위 주석 제거 후 JSON 파싱.
  # 한계: 문자열 안의 "//"(URL 등)도 잘라낸다 - URL이 들어간 config는 손으로 확인할 것.
  # 쓰기도 jq 재직렬화라 주석·포맷은 보존되지 않는다. 실제 운영에서는 jsonc-parser
  # 라이브러리 사용 권장 (Orca 패턴).
  local cleaned_config
  cleaned_config=$(sed 's/\/\/.*$//' "$DEVIN_CONFIG" | sed '/^\s*$/d')

  if ! echo "$cleaned_config" | jq -e . >/dev/null 2>&1; then
    echo "$DEVIN_CONFIG 가 유효한 JSONC가 아니다. 손으로 고친 뒤 다시 실행." >&2
    return 1
  fi

  # 주석이 들어간 JSONC는 jq가 바로 못 읽으므로, 비교·업데이트 입력 모두 정제본을 쓴다.
  local current_config
  current_config=$(echo "$cleaned_config" | jq .)

  # hooks 구조 생성/업데이트
  local updated_config
  updated_config=$(echo "$current_config" | jq --arg cmd "$cmd" \
    --argjson events "$(printf '%s\n' "${events[@]}" | jq -R . | jq -s .)" \
    '
    # 낡은 등록 제거 (install_claude의 strip_stale와 같은 이유·같은 모양).
    # 다른 경로(repo clone 등)로 등록된 agent-event-hook.sh devin 항목이 남아 있으면
    # 정식 경로가 "추가로" 들어가 같은 이벤트가 두 번 전송된다. 판정 기준은 이름이
    # 아니라 "이번에 설치할 정식 $cmd와 다른가"다.
    def strip_stale($cmd):
      map(
        . as $group
        | ($group.hooks // []) as $orig
        | ($orig | map(select(
            (
              (.command? // null) as $c
              | ($c | type) == "string"
                and ($c | contains("agent-event-hook.sh"))
                and ($c != $cmd)
            ) | not
          ))) as $kept
        | if ($orig | length) > 0 and ($kept | length) == 0 then empty
          elif $kept == $orig then $group
          else $group | .hooks = $kept
          end
      );
    .hooks //= {}
    | reduce ($events[]) as $ev (
        .;
        .hooks[$ev] //= []
        | (if (.hooks[$ev] | type) == "array"
           then .hooks[$ev] |= strip_stale($cmd)
           else . end)
        | if ([.hooks[$ev][]?.hooks[]?.command] | index($cmd)) then .
          else .hooks[$ev] += [{hooks: [{type: "command", command: $cmd}]}]
          end
      )
    | if (.hooks["PreToolUse"] == null or (.hooks["PreToolUse"] | type) == "array")
      then
        .hooks["PreToolUse"] = (
          ((.hooks["PreToolUse"] // []) | strip_stale($cmd))
          | if ([.[]? | select((.matcher // "") == "^ask_user_question$") | (.hooks // [])[]? | select(.command == $cmd)] | length) > 0
            then .
            else . + [{matcher: "^ask_user_question$", hooks: [{type: "command", command: $cmd}]}]
            end
        )
      else . end
    ')

  if [ "$updated_config" = "$current_config" ]; then
    echo "변경 없음 (이미 등록돼 있음)."
    return 0
  fi
  
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "--dry-run: 아래 내용으로 바뀔 예정 (실제로 쓰지 않음)"
    echo "$updated_config" | jq .
    return 0
  fi
  
  backup_file "$DEVIN_CONFIG"
  printf '%s\n' "$updated_config" > "$DEVIN_CONFIG"
  echo "$DEVIN_CONFIG 갱신 완료."
}

# ---------- Antigravity CLI(agy): ~/.gemini/config/hooks.json ----------

# hooks.json은 최상위 키 하나가 번들 하나고 agy가 번들들을 합쳐 차례로 실행한다(같은 파일에
# 다른 도구가 넣은 번들이 함께 있을 수 있다). 그래서 my-dashboard 키 하나만 통째로
# 갈아 끼우고 나머지 키는 값도 순서도 그대로 둔다. 갈아 끼우는 방식이라 옛 경로로 등록했던
# 항목이 중복으로 남는 일이 없다. 번들의 이벤트·matcher·timeout 정본은 contracts/의
# event_state_map.antigravity_hook_translation.registration이고, scripts/tests/
# test_hook_install.py가 이 스크립트가 만든 결과를 그 정본과 대조한다.
#
# 결과는 종료 코드로 알린다: 0 = 바뀔 전체 내용을 stdout에 JSON으로 냈다, 10 = 이미 최신이라
# 바꿀 게 없다, 11 = 파일을 JSON으로 읽지 못했거나 JSON 객체가 아니다(이유는 stderr).
# 파일이 없으면 빈 객체 {}에서 시작한다. python3로 읽고 합치는 이유는 다른 키의 값·순서·유니코드를
# 그대로 되돌려 내고 명령 문자열의 따옴표를 정확히 만들기 위해서다.
antigravity_merge() {
  HOOK_SCRIPT="$HOOK_SCRIPT" ANTIGRAVITY_HOOKS="$ANTIGRAVITY_HOOKS" \
    ANTIGRAVITY_BUNDLE_KEY="$ANTIGRAVITY_BUNDLE_KEY" python3 - <<'ANTIGRAVITY_PY'
import json, os, shlex, sys

# 로케일과 무관하게 UTF-8로 내보낸다 - stdout은 그대로 hooks.json에 쓰인다.
sys.stdout.reconfigure(encoding='utf-8')
sys.stderr.reconfigure(encoding='utf-8', errors='backslashreplace')

path = os.environ['ANTIGRAVITY_HOOKS']
key = os.environ['ANTIGRAVITY_BUNDLE_KEY']
hook = shlex.quote(os.environ['HOOK_SCRIPT'])

# agy는 hook의 stdout을 JSON 응답으로 읽는다. PreToolUse에 응답이 없으면 도구를 거부하고,
# hook이 0이 아닌 코드로 끝나면 agy 실행이 중단된다. 그래서 hook을 제대로 실행할 수 없을 때는
# 명령이 스스로 같은 응답을 내고 stdin을 비운 뒤 0으로 끝나야 한다. hook 경로는 셸 문자열이
# 아니라 sh -c의 $0 인자로 넘기므로, 셸 없이 shlex.split으로 exec하는 호스트에서도 같다.
# exec은 실패하면 이 셸이 폴백에 닿기 전에 126/127로 끝나거나, 성공해도 아무것도 출력하지 않고
# 끝날 수 있으므로 그런 경우를 exec 앞에서 미리 걸러 낸다(각각 실제로 응답 없이 끝난다):
#   -f  디렉터리 등 일반 파일이 아닌 경로(-x는 디렉터리에도 참이라 exec이 126으로 끝난다)
#   -r  읽을 수 없는 모드(0111): 실행은 되지만 스크립트를 읽어야 하는 bash가 126으로 끝난다
#   -s  빈 파일: exec해도 아무것도 출력하지 않고 끝난다
#   -x  실행 권한이 없는 파일
#   bash가 PATH에 없음: hook의 shebang `env bash`가 127로 끝난다
# exec 없이 hook을 부른 뒤 폴백을 두는 방식은 hook이 응답을 낸 다음 실패했을 때 응답이 두 번
# 나갈 수 있어서 쓰지 않는다. BASH_ENV는 bash가 스크립트의 첫 줄보다 먼저 읽어 실행하는 파일이라
# 거기서 나온 출력이 응답 앞에 붙거나 exit가 응답을 막을 수 있다 - 이 sh는 읽지 않으니(sh로 뜬 bash와
# dash 모두) exec 직전에 지우면 hook의 bash가 읽지 않는다. ENV는 대화형 셸만 읽으므로 손대지 않는다.
ANSWERS = {'PreToolUse': '{"decision":"ask"}', 'Stop': '{"decision":""}'}
SCRIPT = ('if [ -f "$0" ] && [ -r "$0" ] && [ -s "$0" ] && [ -x "$0" ] && command -v bash >/dev/null 2>&1; '
          'then unset BASH_ENV; exec "$0" antigravity @EVENT@; fi; '
          'printf "%s\\n" "@ANSWER@"; '
          '{ command -p cat 2>/dev/null || cat; } >/dev/null 2>&1; exit 0')


def handler(event):
    answer = ANSWERS.get(event, '{}').replace('"', '\\"')
    script = SCRIPT.replace('@EVENT@', event).replace('@ANSWER@', answer)
    return {'type': 'command', 'command': '/bin/sh -c ' + shlex.quote(script) + ' ' + hook, 'timeout': 10}


bundle = {
    'PreInvocation': [handler('PreInvocation')],
    'PreToolUse': [{'matcher': '^(ask_question|ask_permission)$', 'hooks': [handler('PreToolUse')]}],
    'PostToolUse': [{'matcher': '*', 'hooks': [handler('PostToolUse')]}],
    'Stop': [handler('Stop')],
}


def load(path):
    # 파일이 없거나 비어 있거나(공백·UTF-8 BOM뿐 포함) 하면 빈 객체다. setup.sh는 마지막 단계에서
    # 이 설치기를 부르므로 빈 파일 때문에 멈추면 설치가 거기서 끊긴다. utf-8-sig는 BOM이 있으면
    # 벗기고 읽고, 우리는 BOM 없이 쓴다. 깨진 JSON은 그대로 ValueError다.
    try:
        with open(path, encoding='utf-8-sig') as f:
            text = f.read()
    except FileNotFoundError:
        return {}
    return json.loads(text) if text.strip(' \t\r\n') else {}


try:
    current = load(path)
except (OSError, ValueError) as error:
    print(f'{path} 를 JSON으로 읽지 못했다({error}). 손으로 고친 뒤 다시 실행.', file=sys.stderr)
    sys.exit(11)
if not isinstance(current, dict):
    print(f'{path} 의 최상위가 JSON 객체가 아니다. 손으로 고친 뒤 다시 실행.', file=sys.stderr)
    sys.exit(11)

# 기존 키는 자리를 지키고, my-dashboard 키만 갈아 끼우거나 맨 끝에 붙는다.
merged = dict(current)
merged[key] = bundle


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False)


if canonical(merged) == canonical(current):
    sys.exit(10)
print(json.dumps(merged, indent=2, ensure_ascii=False))
ANTIGRAVITY_PY
}

install_antigravity() {
  echo "== Antigravity: $ANTIGRAVITY_HOOKS =="

  local merged rc=0
  merged="$(antigravity_merge)" || rc=$?
  case "$rc" in
    0) ;;
    10)
      echo "변경 없음 (이미 등록돼 있음)."
      return 0
      ;;
    *) return 1 ;;
  esac

  # 다른 대상과 달리 미리보기에서는 파일도 폴더도 만들지 않는다(없는 파일은 위에서 메모리 안의
  # 빈 객체로만 다뤘다). 다른 번들이 함께 든 파일 전체가 아니라 우리가 넣을 번들만 보여준다.
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "--dry-run: 아래 번들이 \"$ANTIGRAVITY_BUNDLE_KEY\" 키로 들어갈 예정 (실제로 쓰지 않음)"
    printf '%s\n' "$merged" | jq --arg key "$ANTIGRAVITY_BUNDLE_KEY" '.[$key]'
    return 0
  fi

  mkdir -p "$(dirname "$ANTIGRAVITY_HOOKS")"
  backup_file "$ANTIGRAVITY_HOOKS"
  printf '%s\n' "$merged" > "$ANTIGRAVITY_HOOKS"
  echo "$ANTIGRAVITY_HOOKS 갱신 완료."
}

# ---------- notify fallback 안내 (구버전 Codex 전용, 파일을 직접 건드리지 않는다) ----------

print_notify_hint() {
  echo
  echo "참고: hooks를 지원하지 않는 구버전 Codex라면 config.toml에 다음 한 줄을 대신 추가한다:"
  echo "  notify = [\"bash\", \"$NOTIFY_SCRIPT\"]"
}

if [ "$DO_CLAUDE" -eq 1 ]; then install_claude; fi
if [ "$DO_CODEX" -eq 1 ]; then install_codex; print_notify_hint; fi
if [ "$DO_DEVIN" -eq 1 ]; then install_devin; fi
if [ "$DO_ANTIGRAVITY" -eq 1 ]; then install_antigravity; fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "(--dry-run 모드였다. 실제로 적용하려면 --claude / --codex / --devin / --antigravity를 붙여서 다시 실행.)"
fi
