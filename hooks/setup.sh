#!/usr/bin/env bash
# Agent Dashboard 원클릭 부트스트랩. repo를 clone하지 않고도 새 기계에 hook을 설치한다.
#
#   curl -fsSL <서버 origin>/setup.sh | bash                      # 대화형(토큰을 /dev/tty에서 입력)
#   curl -fsSL <서버 origin>/setup.sh | MY_DASHBOARD_TOKEN=... bash  # 비대화형
#   curl -fsSL <서버 origin>/setup.sh | bash -s -- --dry-run         # 미리보기(아무것도 안 씀)
#
# 재실행 = 업데이트다: 훅 파일 6종을 서버에서 다시 받아 덮어쓰고 install.sh를 다시 돌린다.
# ~/.config/my-dashboard/env는 이미 있으면 값은 건드리지 않는다(hook 키 MY_DASHBOARD_TOKEN 누락 시 별칭 한 줄만 보강). 서버를 재배포한 뒤 각
# 기계에서 버전 스큐를 없애는 방법도 이 한 줄을 다시 실행하는 것으로 동일하다.
#
# __MY_DASHBOARD_ORIGIN__ 은 플레이스홀더다 - Worker가 이 파일을 GET /setup.sh로 내려줄 때
# 실제 request origin으로 치환한다(서버 코드에 origin을 하드코딩하지 않기 위해서다). 이
# 파일을 repo에서 직접 실행하면 이 자리가 치환되지 않은 채로 남아 있으니, 항상 curl로 받은
# 사본을 실행할 것. 서버 패키지가 hooks/ 정본을 빌드에 포함해 제공한다.
#
# bash 3.2(macOS 기본 /bin/bash)에서도 그대로 동작해야 한다 - mapfile/nameref/`${v,,}` 등
# bash 4+ 전용 문법을 쓰지 않는다. 모든 경로는 $HOME/$XDG_*에서만 파생시켜서 HOME을
# 오버라이드하기만 하면 완전히 샌드박스 안에서 테스트할 수 있게 한다.
set -eu

ORIGIN="__MY_DASHBOARD_ORIGIN__"

# --help 텍스트는 파일에서 다시 읽지 않고 스크립트 안에 직접 넣는다. `curl … | bash`로
# 실행되면 stdin에서 읽히므로 BASH_SOURCE[0]이 비고 $0은 "/bin/bash"가 돼서, 헤더 주석을
# sed로 다시 읽으려 하면 /bin/bash 실행 바이너리를 그대로 stdout에 쏟는다(터미널 상태가
# 깨질 수 있다) - 파일로 실행할 때만 우연히 동작하던 방식이라 아예 없앤다.
show_help() {
  cat <<'HELP_EOF'
Agent Dashboard 원클릭 부트스트랩. repo를 clone하지 않고도 새 기계에 hook을 설치한다.

사용법:
  curl -fsSL <서버 origin>/setup.sh | bash                        # 대화형(토큰을 /dev/tty에서 입력)
  curl -fsSL <서버 origin>/setup.sh | MY_DASHBOARD_TOKEN=... bash  # 비대화형
  curl -fsSL <서버 origin>/setup.sh | bash -s -- --dry-run         # 미리보기(아무것도 안 씀)

옵션:
  --dry-run   실제로 아무것도 쓰지 않고 무엇을 할지만 보여준다.
  -h, --help  이 도움말을 출력한다.

재실행 = 업데이트다: 훅 파일 6종을 서버에서 다시 받아 덮어쓰고 install.sh를 다시 돌린다.
~/.config/my-dashboard/env는 이미 있으면 값은 건드리지 않는다(hook 키 MY_DASHBOARD_TOKEN 누락 시 별칭 한 줄만 보강). 서버를 재배포한 뒤 각
기계에서 버전 스큐를 없애는 방법도 이 한 줄을 다시 실행하는 것으로 동일하다.
HELP_EOF
}

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "알 수 없는 옵션: $arg (--help 참고)" >&2
      exit 1
      ;;
  esac
done

log() { printf '%s\n' "$*" >&2; }

# ---------- (a) 의존성 확인 ----------

MISSING=""
for tool in curl jq python3; do
  command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
if [ -n "$MISSING" ]; then
  log "다음 도구가 필요하다:$MISSING"
  log "  macOS:            brew install$MISSING"
  log "  Debian/Ubuntu:    sudo apt-get update && sudo apt-get install -y$MISSING"
  log "설치 후 이 한 줄을 다시 실행해라."
  exit 1
fi

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
HOOKS_DIR="$DATA_HOME/my-dashboard/hooks"
CONFIG_DIR="$HOME/.config/my-dashboard"
CONFIG_FILE="$CONFIG_DIR/env"

# setup.sh 자신은 이미 실행 중이라 내려받지 않는다 - 나머지 6종만 GET /hooks/files/<name>로 받는다.
EXECUTABLE_FILES="agent-event-hook.sh codex-notify.sh install.sh send-generic.sh test-hooks.sh"
NON_EXECUTABLE_FILES="codex-hooks.toml"
ALL_FILES="$EXECUTABLE_FILES $NON_EXECUTABLE_FILES"

log "== my-dashboard hooks 설치/갱신: $ORIGIN =="

if [ "$DRY_RUN" -eq 1 ]; then
  log "--dry-run: 아래 작업을 수행할 예정이다 (실제로는 아무것도 쓰지 않음)"
  log "  1) 다운로드: $ALL_FILES"
  log "     -> $HOOKS_DIR/ (실행 파일은 chmod +x)"
  log "  2) $CONFIG_FILE"
  if [ -f "$CONFIG_FILE" ]; then
    log "     이미 있음 - 값은 건드리지 않음(MY_DASHBOARD_TOKEN 누락 시 별칭 한 줄 보강)"
  else
    log "     없음 - 새로 생성 (MY_DASHBOARD_URL=$ORIGIN, MY_DASHBOARD_TOKEN=<입력값>, chmod 600)"
  fi
  log "  3) $HOOKS_DIR/install.sh --claude --codex --devin --antigravity 실행"
  exit 0
fi

# ---------- (b) 훅 파일 다운로드 (재실행 시 덮어써 갱신) ----------

mkdir -p "$HOOKS_DIR"
for f in $ALL_FILES; do
  log "다운로드: $f"
  if ! curl -fsSL "$ORIGIN/hooks/files/$f" -o "$HOOKS_DIR/$f.download"; then
    log "다운로드 실패: $ORIGIN/hooks/files/$f"
    rm -f "$HOOKS_DIR/$f.download"
    exit 1
  fi
  # 실행 파일은 실행 권한을 먼저 주고 나서 제자리로 옮긴다(mv는 원자적 교체다). 옮긴 뒤에 chmod하면
  # 다음 파일을 받는 동안 hook이 실행 불가 상태로 놓여, 그 사이에 실행되는 hook이 exit 126으로
  # 실패하거나(antigravity는 조용히 폴백 응답으로 대신) 이벤트가 사라진다.
  case " $EXECUTABLE_FILES " in
    *" $f "*) chmod +x "$HOOKS_DIR/$f.download" ;;
  esac
  mv -f "$HOOKS_DIR/$f.download" "$HOOKS_DIR/$f"
done
log "설치 위치: $HOOKS_DIR/ (재실행하면 이 자리가 갱신된다 = 업데이트 방법과 동일)"

# ---------- (c) 환경 파일 (있으면 그대로 둔다) ----------

if [ -f "$CONFIG_FILE" ]; then
  # 기존 파일의 값은 건드리지 않지만, hook이 실제로 읽는 키(MY_DASHBOARD_TOKEN)가 있는지는
  # 확인한다 - 구식 명명(INGEST/CLIENT 분리)만 있는 env면 hook이 조용히 아무것도 보내지
  # 않는 함정이 있어서다. 값 노출 없이 존재 여부만 서브셸에서 확인한다.
  # 이 if/elif 둘 다 비상수 경로($CONFIG_FILE)를 source한다 - shellcheck disable을 전체
  # if 복합 명령 앞에 하나만 두면 elif까지 포함해 블록 전체에 적용된다(elif 앞에 따로 두면
  # SC1123로 파싱 자체가 깨진다).
  # shellcheck disable=SC1090
  if ( set +u; . "$CONFIG_FILE" >/dev/null 2>&1; [ -n "${MY_DASHBOARD_TOKEN:-}" ] ); then
    log "$CONFIG_FILE 이미 있음 - 그대로 쓴다(건드리지 않음)."
  elif ( set +u; . "$CONFIG_FILE" >/dev/null 2>&1; [ -n "${MY_DASHBOARD_INGEST_TOKEN:-}" ] ); then
    # shellcheck disable=SC2016 # $MY_DASHBOARD_INGEST_TOKEN은 여기서 펼쳐지면 안 된다 -
    # 파일에 그대로 적어 두고, 나중에 이 CONFIG_FILE을 source할 때(hook 실행 시점) 펼쳐진다.
    printf '\n# hook이 읽는 키 - 위의 INGEST 토큰을 참조 (setup.sh가 보강)\nMY_DASHBOARD_TOKEN="$MY_DASHBOARD_INGEST_TOKEN"\n' >> "$CONFIG_FILE"
    log "$CONFIG_FILE 에 MY_DASHBOARD_TOKEN이 없어 INGEST 토큰 별칭 한 줄을 보강했다(기존 값은 그대로)."
  else
    log "$CONFIG_FILE 에 MY_DASHBOARD_TOKEN이 없다 - 이대로면 hook이 아무것도 보내지 않는다."
    log "파일에 MY_DASHBOARD_TOKEN=<서버 INGEST_TOKEN 값> 한 줄을 추가한 뒤 다시 실행해라."
    exit 1
  fi
else
  TOKEN="${MY_DASHBOARD_TOKEN:-}"
  if [ -z "$TOKEN" ]; then
    # `[ -r /dev/tty ]`는 제어 터미널이 없어도(예: `curl … | bash` 를 -t 없는 ssh, CI,
    # launchd/cron, 에이전트 세션에서 돌릴 때) macOS/Linux 모두에서 true를 반환할 수 있다
    # (stat만 확인하고 실제 open은 하지 않기 때문) - 그러면 아래 read가 ENXIO로 죽어서
    # set -e에 걸리고, 정작 보여주려던 안내문은 한 번도 출력되지 않는다. 그래서 판정을
    # 실제 open(fd 3에 열어 보는 것)으로 한다 - 열리면 진짜 대화형, 안 열리면 즉시 안내.
    # 2>/dev/null을 exec 뒤에 붙이면(`exec 3<>/dev/tty 2>/dev/null`) bash가 리다이렉션을
    # 왼쪽부터 순서대로 적용하다 3<>/dev/tty에서 이미 실패해 버려서 2>/dev/null이 걸리기
    # 전에 "Device not configured" 같은 원시 에러가 먼저 stderr로 새어 나간다. `{ ; }`로
    # 묶어 그룹 전체에 2>/dev/null을 걸면 exec를 시도하기 전에 리다이렉션이 먼저 적용되고,
    # 그룹이 끝나면 자동으로 원래 stderr로 복귀한다(이후 log()는 정상적으로 보인다).
    if { exec 3<>/dev/tty; } 2>/dev/null; then
      printf '%s' "MY_DASHBOARD_TOKEN 입력 (화면에 표시되지 않음): " >&3
      IFS= read -r -s TOKEN <&3 || true
      printf '\n' >&3
      exec 3<&-
    else
      log "제어 터미널이 없는 완전 비대화형 환경이다(/dev/tty를 열 수 없음). 토큰을 환경변수로 넘겨서 다시 실행해라:"
      log "  curl -fsSL $ORIGIN/setup.sh | MY_DASHBOARD_TOKEN=... bash"
      exit 1
    fi
  fi
  if [ -z "$TOKEN" ]; then
    log "토큰이 비어 있다. 설치를 중단한다."
    exit 1
  fi
  # env 파일은 나중에 agent-event-hook.sh 등이 `.`(source)로 읽는다 - 값을 인용부호 없이
  # 쓰면 공백·`#`·`"`·backtick·`$(...)`가 섞인 토큰이 매 이벤트마다 셸 코드로 재해석돼
  # 임의 명령 실행이나 "토큰이 조용히 빈 값이 됨"으로 이어진다. 그래서 쓰기 전에 허용
  # 문자셋(Bearer 토큰에 실제 쓰이는 base64url/표준 base64 문자)만 통과시킨다.
  case "$TOKEN" in
    *[!A-Za-z0-9._~+/=-]*)
      log "토큰에 허용되지 않는 문자가 있다(허용: 영숫자와 . _ ~ + / = -). 복사·붙여넣기 실수인지"
      log "확인하고(앞뒤 공백 포함) 다시 실행해라. 설치를 중단한다."
      exit 1
      ;;
  esac
  mkdir -p "$CONFIG_DIR"
  (
    umask 077
    {
      printf 'MY_DASHBOARD_URL=%s\n' "$ORIGIN"
      printf "MY_DASHBOARD_TOKEN='%s'\n" "$TOKEN"
    } > "$CONFIG_FILE"
  )
  chmod 600 "$CONFIG_FILE"
  log "$CONFIG_FILE 생성 완료 (chmod 600)."

fi

# 기존 설정을 재사용하는 설치도 실제 hook 설정으로 검증한다. 값을 로그에 쓰지 않는다.
TOKEN="$(set +u; . "$CONFIG_FILE" >/dev/null 2>&1; printf '%s' "${MY_DASHBOARD_TOKEN:-}")"
VERIFY_ORIGIN="$(set +u; . "$CONFIG_FILE" >/dev/null 2>&1; printf '%s' "${MY_DASHBOARD_URL:-}")"
VERIFIED=0
VERIFY_HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
  -H "Authorization: Bearer $TOKEN" "${VERIFY_ORIGIN%/}/dashboard/auth/ingest-check" 2>/dev/null)" || VERIFY_HTTP_CODE=000
case "$VERIFY_HTTP_CODE" in
  204) VERIFIED=1; log "수집 토큰 확인: OK" ;;
  401) log "수집 토큰 인증 실패(401). 설정의 MY_DASHBOARD_TOKEN을 확인하세요."; exit 1 ;;
  403)
    log "수집 권한을 확인할 수 없습니다(403). INGEST_TOKEN 및 서버·설치기 버전을 확인하세요."
    log "구 서버는 이 검증 API를 지원하지 않아 403을 반환할 수도 있습니다."
    exit 1 ;;
  404) log "이 서버는 수집 토큰 검증 API를 지원하지 않습니다. 토큰은 검증되지 않았습니다." ;;
  *) log "서버 연결을 확인할 수 없습니다(HTTP $VERIFY_HTTP_CODE). 토큰은 검증되지 않았습니다." ;;
esac

# ---------- (d) Claude Code / Codex / Devin / Antigravity 등록 ----------

# 에이전트가 설치돼 있는지는 확인하지 않는다 - 아직 없는 에이전트의 설정도 미리 만들어 두는
# 것이 이 스크립트의 설계다(Sol 확정).
log ""
log "== $HOOKS_DIR/install.sh --claude --codex --devin --antigravity =="
"$HOOKS_DIR/install.sh" --claude --codex --devin --antigravity

# ---------- (e) 마무리 안내 ----------

log ""
if [ "$VERIFIED" -eq 1 ]; then
  log "설치 및 수집 토큰 검증 완료. 남은 일:"
else
  log "hook 등록 완료. 서버 연결과 토큰 검증은 아직 확인되지 않았습니다."
fi
log "  - Codex를 등록했다면 Codex TUI에서 /hooks 를 실행해 새 hook을 신뢰(trust) 처리해라"
log "    (managed hook이 아니면 trust 전엔 등록만 되고 실행되지 않는다)."
log "  - 견고성(멱등·스풀·하트비트) 점검: $HOOKS_DIR/test-hooks.sh (repo를 clone한 자리에서만"
log "    동작한다 - server/ 개발환경이 필요해서다. curl 설치 자리에서 실행하면 명확한 안내와 함께 종료한다)"
log "  - 갱신하거나 다른 기계에 설치할 때도 이 한 줄을 그대로 다시 실행하면 된다:"
log "      curl -fsSL $ORIGIN/setup.sh | bash"
