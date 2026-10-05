#!/usr/bin/env python3
"""Check the product-owned protocol against server, app, hooks and installed assets.

The root contracts/dashboard-protocol.v1.json is the editing source. Source
checks use server/ by default. --package-root additionally checks an installed
npm package without requiring its internal TypeScript sources.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

CANONICAL_PATH = REPO_ROOT / "contracts" / "dashboard-protocol.v1.json"
PACKAGE_ROOT = REPO_ROOT / "server"
HOOK_MANIFEST_PATH = PACKAGE_ROOT / "contracts/hooks-manifest.json"
GENERATED_HOOKS_PATH = PACKAGE_ROOT / "src/generated/hooks.ts"
SERVER_COPY_PATH: Path  # Set only by explicit --server-root.
DASHBOARD_RS_PATH = REPO_ROOT / "app" / "app-core" / "src" / "dashboard.rs"
PUSH_SW_CANDIDATES = [
    REPO_ROOT / "push_sw.js",
    REPO_ROOT / "app" / "flutter_app" / "web" / "push_sw.js",
]

REQUIRED_EVENT_PAYLOAD_FIELDS = [
    "event_id",
    "occurred_at",
    "protocol_version",
    "host",
    "source",
    "session_id",
    "event",
]

HOOK_SCRIPTS = [
    REPO_ROOT / "hooks" / "agent-event-hook.sh",
    REPO_ROOT / "hooks" / "send-generic.sh",
    REPO_ROOT / "hooks" / "codex-notify.sh",
]

REQUIRED_PUSH_DATA_KEYS = ["title", "body", "link", "session_key", "transition_id"]

HOOKS_DIR = REPO_ROOT / "hooks"
INSTALL_SH_PATH = REPO_ROOT / "hooks" / "install.sh"
HOOKS_DIST_DIR: Path
HOOKS_DIST_FILES = [
    "agent-event-hook.sh",
    "codex-notify.sh",
    "codex-hooks.toml",
    "herdr-context.py",
    "install.sh",
    "send-generic.sh",
    "test-hooks.sh",
    "setup.sh",
]

# hooks/ 안에 있지만 dist로 서빙/동기화되지 않는 것으로 "알려진" 파일들 (check 6이
# hooks/ 실제 디렉터리 목록을 볼 때 이것들은 빼고 비교한다).
HOOKS_DIR_KNOWN_NON_DIST_FILES = {"README.md", "env.example"}

ROUTES_TS_PATH: Path
SETUP_SH_PATH = REPO_ROOT / "hooks" / "setup.sh"
SYNC_HOOKS_DIST_SCRIPT_PATH = REPO_ROOT / "scripts" / "sync_hooks_dist.sh"
HEARTBEAT_TS_PATH: Path
AGENT_EVENT_HOOK_PATH = REPO_ROOT / "hooks" / "agent-event-hook.sh"
CLIENT_ACTIONS_TS_PATH: Path
DASHBOARD_ROUTES_TS_PATH: Path
SEEN_TS_PATH: Path
REBUILD_TS_PATH: Path
SYNC_TS_PATH: Path
DASHBOARD_OPS_ROUTES_TS_PATH: Path
SOURCES_DIR: Path
DASHBOARD_API_DART_PATH = (
    REPO_ROOT / "app" / "flutter_app" / "lib" / "src" / "data" / "dashboard_api.dart"
)


class CheckFailure(Exception):
    """하나의 check 안에서 구체적 실패 지점을 담아 올리는 예외."""


def configure_server_root(root: Path) -> None:
    """Select a product server source tree, never discover a private checkout."""
    root = root.resolve(strict=True)
    paths = {
        "SERVER_COPY_PATH": "contracts/dashboard-protocol.v1.json",
        "ROUTES_TS_PATH": "src/hooks/routes.ts",
        "HEARTBEAT_TS_PATH": "src/dashboard/heartbeat.ts",
        "CLIENT_ACTIONS_TS_PATH": "src/dashboard/client-actions.ts",
        "DASHBOARD_ROUTES_TS_PATH": "src/dashboard/routes.ts",
        "SEEN_TS_PATH": "src/dashboard/seen.ts",
        "REBUILD_TS_PATH": "src/dashboard/rebuild.ts",
        "SYNC_TS_PATH": "src/dashboard/sync.ts",
        "DASHBOARD_OPS_ROUTES_TS_PATH": "src/dashboard/ops.ts",
        "SOURCES_DIR": "src/dashboard/sources",
        "HOOK_MANIFEST_PATH": "contracts/hooks-manifest.json",
        "GENERATED_HOOKS_PATH": "src/generated/hooks.ts",
    }
    if not (root / paths["DASHBOARD_ROUTES_TS_PATH"]).is_file():
        raise CheckFailure("--server-root must contain the product server/src/dashboard source")
    globals().update({name: root / relative for name, relative in paths.items()})


def check_package_assets(root: Path) -> str:
    """Compare public package assets with independent root source files."""
    root = root.resolve(strict=True)
    contract = root / "contracts/dashboard-protocol.v1.json"
    if contract.read_bytes() != CANONICAL_PATH.read_bytes():
        raise CheckFailure("installed package contract differs from the product source")
    manifest = json.loads((root / "contracts/manifest.json").read_text())
    actual = hashlib.sha256(contract.read_bytes()).hexdigest()
    if manifest.get("dashboard-protocol.v1.json") != actual:
        raise CheckFailure("package contract SHA256 does not match its manifest")
    check_hook_manifest(root / "contracts/hooks-manifest.json")
    return "installed package contract and hook manifest match independent product sources"


def load_canonical() -> dict:
    try:
        return json.loads(CANONICAL_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise CheckFailure(f"정본 계약 파일이 없다: {CANONICAL_PATH}") from exc
    except json.JSONDecodeError as exc:
        raise CheckFailure(f"정본 계약 파일이 유효한 JSON이 아니다: {CANONICAL_PATH} ({exc})") from exc


# ---------------------------------------------------------------------------
# Check 1: 정본 ↔ 서버 사본 바이트 동일
# ---------------------------------------------------------------------------


def check_byte_identical() -> str:
    if not CANONICAL_PATH.exists():
        raise CheckFailure(f"정본 파일이 없다: {CANONICAL_PATH}")
    if not SERVER_COPY_PATH.exists():
        raise CheckFailure(f"서버 사본 파일이 없다: {SERVER_COPY_PATH}")

    canonical_bytes = CANONICAL_PATH.read_bytes()
    server_bytes = SERVER_COPY_PATH.read_bytes()

    if canonical_bytes != server_bytes:
        # 어디서부터 갈라졌는지 사람이 바로 찾을 수 있게 첫 차이 바이트 offset을 찍는다.
        min_len = min(len(canonical_bytes), len(server_bytes))
        first_diff = next(
            (i for i in range(min_len) if canonical_bytes[i] != server_bytes[i]),
            min_len,
        )
        raise CheckFailure(
            f"{CANONICAL_PATH} 와 {SERVER_COPY_PATH} 가 바이트 단위로 다르다 "
            f"(첫 차이 offset={first_diff}, 정본 길이={len(canonical_bytes)}, "
            f"서버 사본 길이={len(server_bytes)}). "
            "서버 정본과 소비 snapshot의 의도한 버전을 확인해라. 이 검사는 어느 파일도 덮어쓰지 않는다."
        )

    return f"소비 snapshot({CANONICAL_PATH})과 선택한 서버 정본({SERVER_COPY_PATH})이 바이트 단위로 같다 ({len(canonical_bytes)} bytes)."


# ---------------------------------------------------------------------------
# Check 2: dashboard.rs 상태 코드 · 소스별 event→state 매핑이 정본과 일치
# ---------------------------------------------------------------------------


def _extract_rust_code_match_arms(rust_src: str, enum_name: str) -> list[tuple[str, str]]:
    """`impl <EnumName>` 블록 안 `pub const fn code` 의 match arm을
    [(Variant, "code")] 리스트로 순서 그대로 뽑는다."""
    impl_match = re.search(
        rf"impl\s+{re.escape(enum_name)}\s*\{{(.*?)\n\}}", rust_src, re.DOTALL
    )
    if not impl_match:
        raise CheckFailure(f"dashboard.rs에서 'impl {enum_name} {{ ... }}' 블록을 찾지 못했다.")
    impl_body = impl_match.group(1)

    code_fn_match = re.search(
        r"pub const fn code\(self\)\s*->\s*&'static str\s*\{\s*match self\s*\{(.*?)\}\s*\}",
        impl_body,
        re.DOTALL,
    )
    if not code_fn_match:
        raise CheckFailure(f"dashboard.rs의 {enum_name}에서 'fn code(self)' match 블록을 찾지 못했다.")

    arms_src = code_fn_match.group(1)
    arms = re.findall(r"Self::(\w+)\s*=>\s*\"([^\"]*)\"", arms_src)
    if not arms:
        raise CheckFailure(f"dashboard.rs의 {enum_name}::code()에서 match arm을 하나도 못 뽑았다.")
    return arms


def _extract_event_state_map(rust_src: str) -> list[tuple[str, str, str]]:
    """`EVENT_STATE_MAP` static 배열의 (EventSource, "event", SessionState) 튜플을
    [(source_variant, event, state_variant)] 리스트로 뽑는다."""
    map_match = re.search(
        r"static EVENT_STATE_MAP:\s*&\[.*?\]\s*=\s*&\[(.*?)\n\];",
        rust_src,
        re.DOTALL,
    )
    if not map_match:
        raise CheckFailure("dashboard.rs에서 'static EVENT_STATE_MAP' 배열을 찾지 못했다.")
    body = map_match.group(1)

    # 각 엔트리는 (EventSource::X, "event", SessionState::Y) 형태다.
    # rustfmt가 줄바꿈을 넣어도 잡히도록 콤마/공백/줄바꿈을 전부 유연하게 매칭한다.
    entry_pattern = re.compile(
        r"\(\s*EventSource::(\w+)\s*,\s*\"([^\"]*)\"\s*,\s*SessionState::(\w+)\s*,?\s*\)",
        re.DOTALL,
    )
    entries = entry_pattern.findall(body)
    if not entries:
        raise CheckFailure("EVENT_STATE_MAP 배열에서 엔트리를 하나도 못 뽑았다 — 포맷이 바뀌었나 확인해라.")
    return entries


def _pascal_to_kebab_or_snake(variant: str) -> str:
    """SessionState 변형 이름(PascalCase, 예: WaitingInput)을 계약 코드
    문자열(snake_case, 예: waiting_input)로 바꾼다. EventSource도 같은 규칙을
    쓰지만 kebab-case(claude-code)라 호출부에서 별도 매핑 테이블을 쓴다."""
    return re.sub(r"(?<!^)(?=[A-Z])", "_", variant).lower()


EVENT_SOURCE_VARIANT_TO_CODE = {
    "ClaudeCode": "claude-code",
    "Codex": "codex",
    "Devin": "devin",
    "Generic": "generic",
    "Grok": "grok",
    "Antigravity": "antigravity",
}


def check_dashboard_rs(contract: dict) -> str:
    if not DASHBOARD_RS_PATH.exists():
        raise CheckFailure(f"{DASHBOARD_RS_PATH} 가 없다.")
    rust_src = DASHBOARD_RS_PATH.read_text(encoding="utf-8")

    # --- 2a. SessionState 코드 목록(순서 포함) ---
    expected_states: list[str] = contract["states"]["enum"]
    state_arms = _extract_rust_code_match_arms(rust_src, "SessionState")
    actual_states = [code for _variant, code in state_arms]

    if actual_states != expected_states:
        raise CheckFailure(
            "dashboard.rs::SessionState::code()의 상태 목록이 정본 states.enum과 다르다.\n"
            f"  정본(states.enum)      = {expected_states}\n"
            f"  dashboard.rs::code()   = {actual_states}\n"
            "  -> app/app-core/src/dashboard.rs 의 SessionState 열거형/match를 확인해라."
        )

    # --- 2b. EventSource 코드 목록 ---
    expected_sources = sorted(contract["sources"]["registered"].keys())
    source_arms = _extract_rust_code_match_arms(rust_src, "EventSource")
    actual_sources = sorted(code for _variant, code in source_arms)
    if actual_sources != expected_sources:
        raise CheckFailure(
            "dashboard.rs::EventSource::code()의 소스 목록이 정본 sources.registered와 다르다.\n"
            f"  정본(sources.registered) = {expected_sources}\n"
            f"  dashboard.rs::code()     = {actual_sources}\n"
            "  -> app/app-core/src/dashboard.rs 의 EventSource 열거형/match를 확인해라."
        )

    # variant 이름 -> code 문자열 역방향 조회 테이블(사전순 비교용).
    session_variant_to_code = {variant: code for variant, code in state_arms}

    # --- 2c. EVENT_STATE_MAP: 소스별 (event, state) 집합이 정본과 완전히 같다 ---
    map_entries = _extract_event_state_map(rust_src)

    for source_variant, source_code in EVENT_SOURCE_VARIANT_TO_CODE.items():
        expected_pairs = sorted(
            (entry["event"], entry["state"])
            for entry in contract["event_state_map"]["by_source"].get(source_code, [])
        )
        actual_pairs = sorted(
            (event, session_variant_to_code.get(state_variant, f"<unknown:{state_variant}>"))
            for src_variant, event, state_variant in map_entries
            if src_variant == source_variant
        )
        if actual_pairs != expected_pairs:
            raise CheckFailure(
                f"dashboard.rs::EVENT_STATE_MAP의 '{source_code}' 소스 매핑이 정본과 다르다.\n"
                f"  정본(event_state_map.by_source.{source_code}) = {expected_pairs}\n"
                f"  dashboard.rs::EVENT_STATE_MAP({source_variant} 행들)     = {actual_pairs}\n"
                "  -> app/app-core/src/dashboard.rs 의 EVENT_STATE_MAP 배열을 확인해라."
            )

    return (
        f"dashboard.rs가 정본과 일치한다 — states.enum {len(actual_states)}개, "
        f"sources.registered {len(actual_sources)}개, "
        f"event_state_map 소스 {len(EVENT_SOURCE_VARIANT_TO_CODE)}개 모두 값·순서 일치."
    )


# ---------------------------------------------------------------------------
# Check 3: hook 스크립트 + 정본 event_payload.fields가 필수 필드 7종을 전부 포함
# ---------------------------------------------------------------------------


def check_hook_fields(contract: dict) -> str:
    payload_fields = set(contract.get("event_payload", {}).get("fields", {}).keys())
    missing_in_contract = [f for f in REQUIRED_EVENT_PAYLOAD_FIELDS if f not in payload_fields]
    if missing_in_contract:
        raise CheckFailure(
            "정본 event_payload.fields에 필수 필드가 빠져 있다: "
            f"{missing_in_contract} (contracts/dashboard-protocol.v1.json의 event_payload.fields를 확인해라)."
        )

    missing_by_script: dict[str, list[str]] = {}
    for script_path in HOOK_SCRIPTS:
        if not script_path.exists():
            raise CheckFailure(f"hook 스크립트가 없다: {script_path}")
        text = script_path.read_text(encoding="utf-8")
        missing = [
            field
            for field in REQUIRED_EVENT_PAYLOAD_FIELDS
            # jq 객체 리터럴 키 형태(`field:` 또는 `"field":`)로만 찾는다 — 주석 속
            # 언급과 실제 페이로드 키를 구분하기 위해서다.
            if not re.search(rf'(^|[\s{{,])"?{re.escape(field)}"?\s*:', text, re.MULTILINE)
        ]
        if missing:
            missing_by_script[str(script_path.relative_to(REPO_ROOT))] = missing

    if missing_by_script:
        details = "; ".join(f"{path} 누락: {fields}" for path, fields in missing_by_script.items())
        raise CheckFailure(f"hook 스크립트가 필수 필드를 payload에 채우지 않는다 — {details}")

    return (
        f"필수 필드 {REQUIRED_EVENT_PAYLOAD_FIELDS} 가 정본 event_payload.fields와 "
        f"hook 스크립트 {len(HOOK_SCRIPTS)}개({', '.join(p.name for p in HOOK_SCRIPTS)}) 전부에 있다."
    )


# ---------------------------------------------------------------------------
# Check 4: push_sw.js가 push data 키 계약을 읽는가 (없으면 미구현으로만 보고)
# ---------------------------------------------------------------------------


def check_push_sw() -> tuple[str, bool]:
    """returns (message, is_advisory_skip)."""
    found = next((p for p in PUSH_SW_CANDIDATES if p.exists()), None)
    if found is None:
        checked = ", ".join(str(p.relative_to(REPO_ROOT)) for p in PUSH_SW_CANDIDATES)
        return (
            "push_sw.js가 아직 없다(웹 PWA는 .okf/architecture.md 기준 미구현 상태) — "
            f"확인한 경로: {checked}. 파일이 생기면 이 check가 자동으로 활성화된다.",
            True,
        )

    text = found.read_text(encoding="utf-8")
    missing = [key for key in REQUIRED_PUSH_DATA_KEYS if key not in text]
    if missing:
        raise CheckFailure(
            f"{found.relative_to(REPO_ROOT)} 가 push data 키 계약을 전부 읽지 않는다 — 누락: {missing} "
            f"(필요: {REQUIRED_PUSH_DATA_KEYS})."
        )
    return (
        f"{found.relative_to(REPO_ROOT)} 가 push data 키 {REQUIRED_PUSH_DATA_KEYS} 를 전부 참조한다.",
        False,
    )


# ---------------------------------------------------------------------------
# Check 5: hooks/ 정본 ↔ server/src/hooks/dist/ 사본이 7개 파일 다 바이트 동일
# (Worker가 wrangler Text rules로 이 dist/를 그대로 서빙한다 — src/features/hooks/routes.ts)
# ---------------------------------------------------------------------------


def check_hook_manifest(path: Path) -> str:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    expected = {name: hashlib.sha256((HOOKS_DIR / name).read_bytes()).hexdigest()
                for name in HOOKS_DIST_FILES}
    if manifest.get("sha256") != expected:
        raise CheckFailure("hook manifest names or SHA256 differ from hooks/ source")
    value = 0x811c9dc5
    for byte in b"".join((HOOKS_DIR / name).read_bytes() for name in sorted(HOOKS_DIST_FILES)):
        value = ((value ^ byte) * 0x01000193) & 0xffffffff
    if manifest.get("revision") != f"{value:08x}":
        raise CheckFailure("HOOK_REV differs from sorted, unexpanded hook source")
    return "hook names, SHA256 and revision match their source files"


def check_hooks_dist_byte_identical() -> str:
    check_hook_manifest(HOOK_MANIFEST_PATH)
    text = GENERATED_HOOKS_PATH.read_text(encoding="utf-8")
    match = re.search(r"export const HOOK_FILES:.*? = (\{.*\});", text)
    if not match:
        raise CheckFailure("generated HOOK_FILES module is missing")
    files = json.loads(match.group(1))
    expected = {name: (HOOKS_DIR / name).read_text(encoding="utf-8") for name in HOOKS_DIST_FILES}
    if files != expected:
        raise CheckFailure("generated hook strings differ from source files")
    return "generated hook strings and manifest match all source files"


# ---------------------------------------------------------------------------
# Check 6: hook 파일 "이름 목록" 자체가 hooks/ 실제 디렉터리, routes.ts, setup.sh,
# sync_hooks_dist.sh, 이 스크립트(HOOKS_DIST_FILES) 다섯 곳에서 모두 같은 집합인가.
# check 5)는 이미 목록에 있는 이름들의 바이트 동일성만 보므로 이걸로는 "새 파일을
# 추가하고 한 곳에 반영을 빠뜨림"을 못 잡는다 — 이 check가 그 구멍을 막는다.
# ---------------------------------------------------------------------------


def _hooks_dir_actual_files() -> set[str]:
    if not HOOKS_DIR.exists():
        raise CheckFailure(f"hooks 디렉터리가 없다: {HOOKS_DIR}")
    names = {p.name for p in HOOKS_DIR.iterdir() if p.is_file()}
    return names - HOOKS_DIR_KNOWN_NON_DIST_FILES


def _setup_sh_all_files() -> set[str]:
    text = SETUP_SH_PATH.read_text(encoding="utf-8")
    exec_match = re.search(r'EXECUTABLE_FILES="([^"]*)"', text)
    nonexec_match = re.search(r'NON_EXECUTABLE_FILES="([^"]*)"', text)
    if not exec_match or not nonexec_match:
        raise CheckFailure(f"{SETUP_SH_PATH}에서 EXECUTABLE_FILES=\"...\" / NON_EXECUTABLE_FILES=\"...\" 를 못 찾았다.")
    files = set(exec_match.group(1).split()) | set(nonexec_match.group(1).split())
    # setup.sh 자신은 "이미 실행 중이라 다운로드하지 않는다"는 이유로 이 목록엔 없지만
    # 서빙/동기화 대상으로는 들어가야 하므로 비교를 위해 보충해 준다.
    return files | {"setup.sh"}


def check_hooks_file_lists_consistent(*, include_server: bool = True) -> str:
    expected = set(HOOKS_DIST_FILES)
    sources = [("hooks/", _hooks_dir_actual_files()), ("setup.sh", _setup_sh_all_files())]
    if include_server:
        manifest = json.loads(HOOK_MANIFEST_PATH.read_text(encoding="utf-8"))
        sources.append(("package hook manifest", set(manifest.get("sha256", {}))))
    for label, actual in sources:
        if actual != expected:
            raise CheckFailure(f"{label}: missing={sorted(expected-actual)}, extra={sorted(actual-expected)}")
    return f"all {len(expected)} hook files are present in source, installer and generated manifest"


# ---------------------------------------------------------------------------
# Check 7: 정본의 새 규범 표 3종(heartbeat promote_from / claude-code
# notification_type 제외목록 / codex request_user_input(_async) 번역 규칙)이
# 각자의 코드 사본(heartbeat.ts, agent-event-hook.sh)과 같은가.
# ---------------------------------------------------------------------------


def _normalize_ws(text: str) -> str:
    """여러 줄 jq 파이프라인을 정규식 하나로 매칭하기 쉽게 공백을 한 칸으로 뭉갠다."""
    return re.sub(r"\s+", " ", text)


def check_heartbeat_and_codex_tables(contract: dict) -> str:
    # --- 7a. heartbeat.ts::HEARTBEAT_PROMOTE_FROM == 정본 promote_from ---
    if not HEARTBEAT_TS_PATH.exists():
        raise CheckFailure(f"{HEARTBEAT_TS_PATH} 가 없다.")
    heartbeat_src = HEARTBEAT_TS_PATH.read_text(encoding="utf-8")
    promote_match = re.search(
        r"HEARTBEAT_PROMOTE_FROM:\s*ReadonlySet<SessionState>\s*=\s*new Set<SessionState>\(\[(.*?)\]\)",
        heartbeat_src,
        re.DOTALL,
    )
    if not promote_match:
        raise CheckFailure(
            f"{HEARTBEAT_TS_PATH}에서 'HEARTBEAT_PROMOTE_FROM = new Set<SessionState>([...])' 를 찾지 못했다."
        )
    actual_promote_from = sorted(re.findall(r'"([^"]+)"', promote_match.group(1)))
    expected_promote_from = sorted(contract["heartbeat_events"]["events"]["PostToolUse"]["promote_from"])
    if actual_promote_from != expected_promote_from:
        raise CheckFailure(
            "heartbeat.ts::HEARTBEAT_PROMOTE_FROM이 정본 "
            "heartbeat_events.events.PostToolUse.promote_from과 다르다.\n"
            f"  정본                                  = {expected_promote_from}\n"
            f"  heartbeat.ts::HEARTBEAT_PROMOTE_FROM = {actual_promote_from}\n"
            "  -> server/src/dashboard/heartbeat.ts 를 확인해라."
        )

    return "서버 heartbeat 표 일치. " + check_hook_translations(contract)


def check_hook_translations(contract: dict) -> str:
    # --- 7b. agent-event-hook.sh의 notification_type 제외목록 매핑 == 소비 계약 ---
    if not AGENT_EVENT_HOOK_PATH.exists():
        raise CheckFailure(f"{AGENT_EVENT_HOOK_PATH} 가 없다.")
    hook_src = AGENT_EVENT_HOOK_PATH.read_text(encoding="utf-8")
    norm = _normalize_ws(hook_src)

    notif_block_match = re.search(
        r'\$raw_event == "Notification" then \(if(.*?)else \$raw_event end\)',
        norm,
    )
    if not notif_block_match:
        raise CheckFailure(
            f"{AGENT_EVENT_HOOK_PATH}에서 notification_type -> 합성 이벤트 if/elif 체인을 찾지 못했다."
        )
    actual_exclude_exact = dict(re.findall(r'\$notif_type == "([^"]+)" then "([^"]+)"', notif_block_match.group(1)))
    expected_exclude_exact = contract["sources"]["registered"]["claude-code"]["notification_type_translation"][
        "exclude_exact"
    ]
    if actual_exclude_exact != expected_exclude_exact:
        raise CheckFailure(
            "agent-event-hook.sh의 notification_type 제외목록 매핑이 정본 sources.registered."
            "claude-code.notification_type_translation.exclude_exact와 다르다.\n"
            f"  정본                = {expected_exclude_exact}\n"
            f"  agent-event-hook.sh = {actual_exclude_exact}\n"
            "  -> hooks/agent-event-hook.sh 의 notification_type if/elif 체인을 확인해라(수정 후 "
            "'bash scripts/sync_hooks_dist.sh' 로 dist/도 재동기화해라)."
        )

    # --- 7c. codex request_user_input(_async) 정규화 + 비대칭 3규칙 == 정본 rules ---
    if "ascii_downcase" not in norm or 'gsub("[^a-z0-9]"; "")' not in norm:
        raise CheckFailure(
            f"{AGENT_EVENT_HOOK_PATH}에서 codex tool_name 정규화(ascii_downcase + 영숫자만 남기는 gsub)를 "
            "찾지 못했다 — 정본 event_state_map.codex_request_user_input_translation."
            "tool_name_normalization과 어긋난다."
        )
    rule_pre_to_request = re.search(
        r'\$source == "codex" and \$raw_event == "PreToolUse" '
        r'and \(\$norm_tool == "requestuserinput" or \$norm_tool == "requestuserinputasync"\) then '
        r'"UserInputRequest"',
        norm,
    )
    rule_post_sync_to_resolved = re.search(
        r'\$source == "codex" and \$raw_event == "PostToolUse" and \$norm_tool == "requestuserinput" then '
        r'"UserInputResolved"',
        norm,
    )
    if not rule_pre_to_request or not rule_post_sync_to_resolved:
        raise CheckFailure(
            f"{AGENT_EVENT_HOOK_PATH}에서 F(codex request_user_input) 규칙 중 "
            "'PreToolUse+(동기|비동기) -> UserInputRequest' 또는 'PostToolUse+동기만 -> "
            "UserInputResolved' 분기를 찾지 못했다 — 정본 "
            "event_state_map.codex_request_user_input_translation.rules를 확인해라."
        )
    # 정본 규칙 3번: PostToolUse + 비동기(requestuserinputasync)는 "분기 자체가 없어야"
    # UserInputResolved로 잘못 바뀌지 않는다(비동기는 질문 직후 PostToolUse가 오고 실제
    # 응답은 다음 사용자 메시지이므로, 해소로 쓰면 아직 떠 있는 질문을 지워버린다). 그런
    # 분기가 새로 생겼는지를 음성 공간(negative space)으로 확인한다.
    rule_post_async_wrongly_branched = re.search(
        r'\$raw_event == "PostToolUse" and \$norm_tool == "requestuserinputasync"',
        norm,
    )
    if rule_post_async_wrongly_branched:
        raise CheckFailure(
            f"{AGENT_EVENT_HOOK_PATH}가 PostToolUse + requestuserinputasync 조합을 별도로 분기하려 한다 — "
            "정본 규칙 3번은 이 조합을 UserInputResolved로 바꾸지 않고 일반 PostToolUse 하트비트 경로로 "
            "그대로 흘려보내야 한다(분기가 없는 것이 맞다). 의도적 변경이면 정본 "
            "event_state_map.codex_request_user_input_translation.rules도 같이 갱신하고 이 check의 "
            "정규식을 맞게 고쳐라."
        )

    return (
        "agent-event-hook.sh의 notification_type 제외목록 매핑, "
        "codex request_user_input(_async) 정규화·비대칭 3규칙이 정본 heartbeat_events/sources/"
        "event_state_map과 일치한다."
    )


def check_devin_input_translation(contract: dict):
    tracking = contract.get("event_state_map", {}).get("devin_input_tracking")
    if tracking is None:
        return (
            "소비 계약에 event_state_map.devin_input_tracking이 없다(구버전 pin) — "
            "Devin 입력 해소 규약 검사는 계약이 갱신되면 자동으로 활성화된다.",
            True,
        )

    expected_tracking = {
        "request_events": ["PermissionRequest", "UserInputRequest"],
        "completion_event": "PostToolUse",
        "question_tool": "ask_user_question",
        "correlation_fields": ["prompt_id", "tool_use_id", "tool_name"],
        "pending_limit": 256,
        "reset_events": ["UserPromptSubmit", "SessionStart", "Stop", "SessionEnd", "UserAck"],
    }
    for key, want in expected_tracking.items():
        if tracking.get(key) != want:
            raise CheckFailure(
                f"정본 event_state_map.devin_input_tracking.{key}가 규약 값과 다르다 "
                f"(정본={tracking.get(key)!r}, 규약={want!r})."
            )

    correlation_fields = tracking["correlation_fields"]
    question_tool = tracking["question_tool"]

    fields = contract.get("event_payload", {}).get("fields", {})
    for name in correlation_fields:
        spec = fields.get(name)
        if spec is None or spec.get("max_length") != 200 or spec.get("required") is not False:
            raise CheckFailure(
                f"정본 event_payload.fields.{name}의 정의가 devin_input_tracking과 어긋난다 "
                f"(실제: {spec!r}) — 선택 문자열·max_length 200이어야 한다."
            )

    if not AGENT_EVENT_HOOK_PATH.exists():
        raise CheckFailure(f"{AGENT_EVENT_HOOK_PATH} 가 없다.")
    norm = _normalize_ws(AGENT_EVENT_HOOK_PATH.read_text(encoding="utf-8"))

    if not re.search(
        rf'\$source == "devin" and \$raw_event == "PreToolUse" and '
        rf'\.tool_name == "{re.escape(question_tool)}" then "UserInputRequest"',
        norm,
    ):
        raise CheckFailure(
            f"{AGENT_EVENT_HOOK_PATH}에서 devin PreToolUse + tool_name 정확히 "
            f'"{question_tool}" -> "UserInputRequest" 분기를 찾지 못했다 — '
            "ask_user_question_summary·functions.ask_user_question 같은 유사 이름을 잡지 않는 "
            "정확 일치(.tool_name ==)만 허용된다."
        )
    if re.search(r'\$source == "devin" and [^)]*\$norm_tool', norm):
        raise CheckFailure(
            f"{AGENT_EVENT_HOOK_PATH}의 devin 번역이 정규화 도구명($norm_tool)으로 매칭한다 — "
            "정본 devin_input_tracking은 정확 일치만 허용한다(유사 도구명 오탐 금지)."
        )

    if "def corr_id" not in norm or "length <= 200" not in norm:
        raise CheckFailure(
            f"{AGENT_EVENT_HOOK_PATH}에 상관 식별자 검증기(corr_id, 비어있지 않은 문자열·200자 이하)가 없다."
        )
    for name in correlation_fields:
        if not re.search(rf"{name}:\s*\(\s*\.{name}\s*\|\s*corr_id\s*\)", norm):
            raise CheckFailure(
                f"{AGENT_EVENT_HOOK_PATH}의 payload가 devin {name}를 corr_id로 검증해 전달하지 않는다."
            )
    if not re.search(r'if \$source == "devin" then \{', norm):
        raise CheckFailure(
            f"{AGENT_EVENT_HOOK_PATH}가 상관 필드를 devin 전용으로 한정하지 않는다 — "
            "다른 source payload에도 붙으면 안 된다."
        )

    if not re.search(
        r'\.source == "devin" and \(\.prompt_id \| type\) == "string" and '
        r'\(\.tool_use_id \| type\) == "string" and \(\.tool_name \| type\) == "string"',
        norm,
    ):
        raise CheckFailure(
            f"{AGENT_EVENT_HOOK_PATH}에서 상관 완료 판정(세 식별자가 모두 유효 문자열인 devin "
            "PostToolUse)을 찾지 못했다."
        )
    if not re.search(r'if \[ "\$IS_DEVIN_COMPLETION" = "true" \]', norm):
        raise CheckFailure(
            f"{AGENT_EVENT_HOOK_PATH}에서 상관된 Devin PostToolUse의 스로틀 면제 분기"
            '(\'[ "$IS_DEVIN_COMPLETION" = "true" ]\')를 찾지 못했다 — 정본 '
            "heartbeat_events.events.PostToolUse.throttle_exception_devin_correlated와 어긋난다."
        )

    if not INSTALL_SH_PATH.exists():
        raise CheckFailure(f"{INSTALL_SH_PATH} 가 없다.")
    install_src = INSTALL_SH_PATH.read_text(encoding="utf-8")
    devin_fn = re.search(r"install_devin\(\)\s*\{(.*?)\n\}", install_src, re.DOTALL)
    if not devin_fn:
        raise CheckFailure(f"{INSTALL_SH_PATH}에서 install_devin() 본문을 찾지 못했다.")
    devin_body = devin_fn.group(1)
    if '"^ask_user_question$"' not in devin_body:
        raise CheckFailure(
            f"{INSTALL_SH_PATH}의 install_devin이 PreToolUse에 '^ask_user_question$' matcher를 "
            "등록하지 않는다."
        )
    events_match = re.search(r"local events=\(([^)]*)\)", devin_body)
    if not events_match or "PreToolUse" in events_match.group(1).split():
        raise CheckFailure(
            f"{INSTALL_SH_PATH}의 install_devin이 무필터 PreToolUse를 등록한다 — "
            "^ask_user_question$ matcher가 달린 항목만 허용된다."
        )

    return (
        "devin_input_tracking 규약이 소비 계약·agent-event-hook.sh(정확 일치 번역·상관 필드·"
        "스로틀 면제)·install.sh(^ask_user_question$ matcher)에 일치한다."
    )


# ---------------------------------------------------------------------------
# Antigravity(agy) hook 번역: 정본 event_state_map.antigravity_hook_translation이
# agent-event-hook.sh의 antigravity 분기(bash 응답 case + jq $final_event 분기 + 필드)와 같은가.
#
# agy는 hook을 동기로 실행한다. 응답 JSON이 틀리면 도구가 거부되거나 모두 자동 승인되고,
# 번역 규칙이 틀리면 모델 호출마다 턴이 시작되거나 서브에이전트가 떠돌이 세션이 된다.
# 두 사본이 조용히 갈라지지 않도록 규칙 하나하나를 hook 코드와 대조한다.
# ---------------------------------------------------------------------------


def _antigravity_fail(what: str) -> CheckFailure:
    return CheckFailure(
        f"{AGENT_EVENT_HOOK_PATH}의 antigravity 번역이 정본 "
        f"event_state_map.antigravity_hook_translation과 어긋난다 — {what}"
    )


def _balanced_parens(text: str, open_index: int) -> str | None:
    """text[open_index]의 '('와 짝이 맞는 ')' 사이를 돌려준다. jq 문자열("...") 안의 괄호는 세지 않는다."""
    depth = 0
    in_string = False
    index = open_index
    while index < len(text):
        char = text[index]
        if in_string:
            if char == "\\":
                index += 1
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return text[open_index + 1:index]
        index += 1
    return None


def check_antigravity_hook_translation(contract: dict):
    translation = contract.get("event_state_map", {}).get("antigravity_hook_translation")
    if translation is None:
        if "antigravity" in contract.get("sources", {}).get("registered", {}):
            raise CheckFailure(
                "정본 sources.registered에 antigravity가 있는데 "
                "event_state_map.antigravity_hook_translation이 없다 — hook 번역 규칙의 정본이 빠졌다."
            )
        return (
            "소비 계약에 event_state_map.antigravity_hook_translation이 없다(구버전 pin) — "
            "Antigravity hook 번역 검사는 계약이 갱신되면 자동으로 활성화된다.",
            True,
        )

    if not AGENT_EVENT_HOOK_PATH.exists():
        raise CheckFailure(f"{AGENT_EVENT_HOOK_PATH} 가 없다.")
    hook_src = AGENT_EVENT_HOOK_PATH.read_text(encoding="utf-8")
    norm = _normalize_ws(hook_src)

    # --- 1. stdout 응답: bash case 블록 == 정본 stdout_contract($로 시작하는 주석 키 제외) ---
    expected_answers = {
        key: value for key, value in translation["stdout_contract"].items() if not key.startswith("$")
    }
    case_block = re.search(r'case "\$ANTIGRAVITY_EVENT" in (.*?) esac', norm)
    if not case_block:
        raise _antigravity_fail("응답을 고르는 'case \"$ANTIGRAVITY_EVENT\" in ... esac' 블록을 찾지 못했다.")
    actual_answers = {}
    for label, answer in re.findall(r"(\S+)\) ANTIGRAVITY_ANSWER='([^']*)' ;;", case_block.group(1)):
        try:
            actual_answers["default" if label == "*" else label] = json.loads(answer)
        except json.JSONDecodeError as exc:
            raise _antigravity_fail(f"{label} 응답 {answer!r}이 JSON이 아니다.") from exc
    if actual_answers != expected_answers:
        raise _antigravity_fail(
            "stdout 응답이 stdout_contract와 다르다.\n"
            f"  정본 = {expected_answers}\n"
            f"  hook = {actual_answers}"
        )
    # 응답은 env 파일·stdin보다 먼저 한 번만 나가고, 그 뒤 stdout은 닫혀야 한다(rules).
    answer_pos = hook_src.find("( printf '%s\\n' \"$ANTIGRAVITY_ANSWER\" )")
    close_pos = hook_src.find("exec 1>/dev/null")
    config_pos = hook_src.find('. "$CONFIG_FILE"')
    stdin_pos = hook_src.find('INPUT="$(cat')
    if answer_pos == -1 or close_pos == -1 or config_pos == -1 or stdin_pos == -1:
        raise _antigravity_fail(
            "응답 출력('( printf ... \"$ANTIGRAVITY_ANSWER\" )')·stdout 닫기('exec 1>/dev/null')·"
            "env 파일 소싱·stdin 읽기 중 하나를 찾지 못했다."
        )
    if not answer_pos < close_pos < config_pos < stdin_pos:
        raise _antigravity_fail(
            "응답 출력 → exec 1>/dev/null → env 파일 소싱 → stdin 읽기 순서가 아니다 — agy는 응답이 "
            "늦거나 섞이면 도구를 거부하거나 실행을 멈춘다."
        )

    # --- 2. 이벤트 이름은 stdin이 아니라 두 번째 인자다 ---
    if 'ANTIGRAVITY_EVENT="${2:-}"' not in norm or not re.search(
        r'\(if \$source == "antigravity" then \$antigravity_event else \(\.hook_event_name // "unknown"\) end\) as \$raw_event',
        norm,
    ) or '--arg antigravity_event "${ANTIGRAVITY_EVENT:-}"' not in norm:
        raise _antigravity_fail("이벤트 이름을 두 번째 인자($2 → $antigravity_event → $raw_event)로 받지 않는다.")

    # --- 3. question_tools: jq 배열 리터럴 == 정본(순서까지), toolCall.name 정확 일치 ---
    tools_match = re.search(
        r'\(\[([^\]]*)\] \| any\(\. == \$antigravity_tool\)\) as \$antigravity_question', norm
    )
    if not tools_match:
        raise _antigravity_fail(
            "question_tools 배열 리터럴('([...] | any(. == $antigravity_tool)) as $antigravity_question')을 찾지 못했다."
        )
    actual_tools = json.loads(f"[{tools_match.group(1)}]")
    if actual_tools != translation["question_tools"]:
        raise _antigravity_fail(
            "question_tools가 다르다.\n"
            f"  정본 = {translation['question_tools']}\n"
            f"  hook = {actual_tools}"
        )
    if not re.search(r"\(try \.toolCall\.name catch null\) as \$antigravity_tool", norm):
        raise _antigravity_fail(
            "$antigravity_tool이 toolCall.name 원문이 아니다 — 정본은 정확 일치만 허용한다(정규화 금지)."
        )

    # --- 4. jq $final_event의 antigravity 분기(괄호 짝으로 통째로 잘라 낸다) ---
    branch_head = 'elif $source == "antigravity" then ('
    branch_start = norm.find(branch_head)
    branch = _balanced_parens(norm, branch_start + len(branch_head) - 1) if branch_start != -1 else None
    if branch is None:
        raise _antigravity_fail("jq $final_event 체인에서 'elif $source == \"antigravity\" then (...)' 분기를 찾지 못했다.")
    branch = branch.strip()

    handled = re.findall(r'\$raw_event == "(\w+)"', branch)
    if sorted(handled) != sorted(translation["registration"]["events"]):
        raise _antigravity_fail(
            "분기가 다루는 이벤트가 registration.events와 다르다.\n"
            f"  정본 = {translation['registration']['events']}\n"
            f"  hook = {handled}"
        )
    if "def antigravity_num: if type == \"number\" then . else null end;" not in norm:
        raise _antigravity_fail(
            "antigravity_num이 숫자만 받지 않는다 — jq는 문자열을 모든 숫자보다 크게 비교해서(\"0\" >= 1이 참) "
            "invocationNum·initialNumSteps 규칙이 뒤집힌다."
        )
    rules = {
        "서브에이전트(invocationNum 0이고 initialNumSteps 0이면 표시 후 버림, 가장 먼저 판정)":
            r'\$raw_event == "PreInvocation" then \(if \(\.invocationNum \| antigravity_num\) == 0 and '
            r'\(\.initialNumSteps \| antigravity_num\) == 0 then "AntigravitySubagentStart" elif',
        "Stop 뒤 래치가 걸린 동안의 PreInvocation은 invocationNum과 상관없이 턴 (재)시작":
            r'then "AntigravitySubagentStart" elif \$antigravity_latched == "1" then "UserPromptSubmit" elif',
        "턴 시작(invocationNum이 0이거나 없으면 UserPromptSubmit, 1 이상이면 버림)":
            r'elif \(\.invocationNum \| antigravity_num\) >= 1 then "AntigravityIgnored" '
            r'else "UserPromptSubmit" end\)',
        "PreToolUse(질문 도구만 UserInputRequest, 그 밖은 버림)":
            r'\$raw_event == "PreToolUse" then \(if \$antigravity_question then "UserInputRequest" '
            r'else "AntigravityIgnored" end\)',
        "PostToolUse(질문 도구는 UserInputResolved, 그 밖은 하트비트)":
            r'\$raw_event == "PostToolUse" then \(if \$antigravity_question then "UserInputResolved" '
            r'else "PostToolUse" end\)',
        "Stop(fullyIdle 값과 상관없이 모두 Stop)":
            r'\$raw_event == "Stop" then "Stop" else',
        "그 밖의 이벤트는 버림":
            r'else "AntigravityIgnored" end$',
    }
    for label, pattern in rules.items():
        if not re.search(pattern, branch):
            raise _antigravity_fail(f"규칙 '{label}'에 해당하는 분기를 찾지 못했다.")

    # Stop은 fullyIdle로 거르지 않는다. 서브에이전트를 쓰는 턴은 마지막 Stop까지 fullyIdle false로 끝날 수
    # 있어서(agy 1.2.12 실측), 거르면 세션이 working에 멈추고 stalled 푸시가 잘못 나간다. jq든 bash든
    # 코드 어디에서도 .fullyIdle을 읽지 않아야 한다(주석은 .fullyIdle 형태로 쓰지 않는다).
    stop_rule = next((rule for rule in translation["rules"] if rule.startswith("Stop:")), "")
    if "fullyIdle 값과 상관없이 Stop을 보낸다" not in stop_rule:
        raise CheckFailure(
            "정본 antigravity_hook_translation.rules의 Stop 규칙이 'fullyIdle 값과 상관없이 Stop을 보낸다'가 "
            f"아니다(정본: {stop_rule!r}) — hook이 구현한 규칙과 다르다."
        )
    if ".fullyIdle" in norm:
        raise _antigravity_fail(
            "hook이 .fullyIdle을 읽는다 — 정본 Stop 규칙은 fullyIdle 값과 상관없이 Stop을 보낸다."
        )

    # Stop 뒤 래치: 모든 Stop이 걸고, 턴 시작(UserPromptSubmit)이 풀고, 하트비트 PostToolUse가 확인한다.
    # 래치가 걸린 동안의 PreInvocation은 invocationNum과 상관없이 턴 (재)시작이다 - 한 실행 안에서
    # fullyIdle false Stop 뒤 모델 호출이 이어져도(다른 agy 연동 구현에서 보고된 동작) 세션이 done에 머물지 않게 한다.
    latch_rule = next((rule for rule in translation["rules"] if "기록용" in rule), "")
    if "모든 Stop" not in latch_rule or "질문 도구 포함" not in latch_rule:
        raise CheckFailure(
            "정본 antigravity_hook_translation.rules의 래치 규칙이 모든 Stop(fullyIdle 값과 상관없이) 뒤에 걸리고 "
            f"질문 도구의 PostToolUse도 버린다고 하지 않는다(정본: {latch_rule!r})."
        )
    turn_start_rule = next((rule for rule in translation["rules"] if rule.startswith("PreInvocation:")), "")
    if "래치" not in turn_start_rule or "invocationNum과 상관없이 턴 시작" not in turn_start_rule:
        raise CheckFailure(
            "정본 antigravity_hook_translation.rules의 턴 시작 규칙이 래치가 걸린 동안의 PreInvocation을 "
            f"invocationNum과 상관없이 턴 시작으로 보지 않는다(정본: {turn_start_rule!r})."
        )
    # 래치 여부는 대화 상태라 bash가 Stop이 거는 바로 그 파일로 보고 jq 번역에 입력으로 넘긴다.
    if (
        'ANTIGRAVITY_KEY="$(printf \'%s\' "$RAW_ID_SEED" | tr -c \'A-Za-z0-9_-\' \'_\')"' not in norm
        or '[ -e "$ANTIGRAVITY_DIR/stopped/$ANTIGRAVITY_KEY" ] && ANTIGRAVITY_LATCHED=1' not in norm
        or '--arg antigravity_latched "${ANTIGRAVITY_LATCHED:-0}"' not in norm
    ):
        raise _antigravity_fail(
            "래치 여부(ANTIGRAVITY_LATCHED)를 Stop 래치 파일($ANTIGRAVITY_DIR/stopped/$ANTIGRAVITY_KEY)로 정해 "
            "jq에 --arg antigravity_latched로 넘기는 경로를 찾지 못했다."
        )
    admit = re.search(r"^antigravity_admit\(\) \{\n(.*?)^\}", hook_src, re.MULTILINE | re.DOTALL)
    admit_norm = _normalize_ws(admit.group(1)) if admit else ""
    if 'local key="$ANTIGRAVITY_KEY"' not in admit_norm:
        raise _antigravity_fail("antigravity_admit이 래치 여부를 본 것과 같은 대화 키($ANTIGRAVITY_KEY)를 쓰지 않는다.")
    latch_arms = {
        "Stop이 래치를 건다": (r"\bStop\) (.*?) ;;", ': > "$ANTIGRAVITY_DIR/stopped/$key"'),
        "턴 시작이 래치를 푼다": (r"\bUserPromptSubmit\) (.*?) ;;", 'rm -f "$ANTIGRAVITY_DIR/stopped/$key"'),
        # 질문 도구의 PostToolUse는 UserInputResolved로 번역된다 - 상태 이벤트라 버리지 않으면 끝난 턴을
        # 하트비트 가드 없이 working으로 되살린다.
        "래치가 걸린 PostToolUse(질문 도구의 UserInputResolved 포함)는 버린다":
            (r"\bPostToolUse\|UserInputResolved\) (.*?) ;;", '[ -e "$ANTIGRAVITY_DIR/stopped/$key" ] && return 1'),
    }
    for label, (arm_pattern, needle) in latch_arms.items():
        arm = re.search(arm_pattern, admit_norm)
        if not arm or needle not in arm.group(1):
            raise _antigravity_fail(f"antigravity_admit에서 '{label}' 갈래를 찾지 못했다.")

    # 합성 이름은 bash에서 전송 전에 끝나야 한다(서버로 새면 안 된다): antigravity_admit의
    # case 갈래가 return 1로 끝나고, 호출부가 'antigravity_admit || exit 0'이어야 한다.
    for label in ("AntigravitySubagentStart", "AntigravityIgnored"):
        arm = re.search(rf"{label}\) (.*?) ;;", norm)
        if not arm or not arm.group(1).endswith("return 1"):
            raise _antigravity_fail(f"antigravity_admit의 '{label})' 갈래가 return 1(버림)로 끝나지 않는다.")
    if "antigravity_admit || exit 0" not in norm:
        raise _antigravity_fail("'antigravity_admit || exit 0' 호출을 찾지 못했다 — 버리는 이벤트가 서버로 샌다.")

    # --- 5. fields: session_id·project·message ---
    fields = translation["fields"]
    for name, needles in {
        "session_id": ("conversationId", "ANTIGRAVITY_CONVERSATION_ID", '"unknown"'),
        "project": ("workspacePaths[0]", '"unknown"'),
        "message": ("UserInputRequest", "toolCall.args.questions[0].question"),
    }.items():
        missing = [needle for needle in needles if needle not in fields.get(name, "")]
        if missing:
            raise CheckFailure(
                f"정본 antigravity_hook_translation.fields.{name}가 hook이 구현한 규칙과 다르다 "
                f"(없는 부분: {missing}, 정본: {fields.get(name)!r})."
            )
    if (
        "jq -r '.conversationId | strings'" not in norm
        or 'RAW_ID_SEED="${ANTIGRAVITY_CONVERSATION_ID:-}"' not in norm
        or 'session_id: (if $source == "antigravity" then $antigravity_session' not in norm
    ):
        raise _antigravity_fail("session_id가 conversationId → ANTIGRAVITY_CONVERSATION_ID → \"unknown\" 순서가 아니다.")
    if not re.search(
        r'project: \(if \$source == "antigravity" then \(\(try \.workspacePaths\[0\] catch null\) '
        r'\| if type == "string" and \. != "" then \. else "unknown" end\) else',
        norm,
    ):
        raise _antigravity_fail("project가 workspacePaths[0] → \"unknown\"이 아니다(hook cwd 폴백 금지).")
    if not re.search(
        r'if \$source == "antigravity" then \(\(if \$final_event == "UserInputRequest" then '
        r'\(try \.toolCall\.args\.questions\[0\]\.question catch null\) else null end\)',
        norm,
    ):
        raise _antigravity_fail("message가 UserInputRequest의 toolCall.args.questions[0].question이고 그 밖에 null이 아니다.")

    # --- 6. print_mode: Go flag 문법(대시 하나·둘, =값, -- 종결)으로 이름을 비교한다 ---
    print_mode = translation["print_mode"]
    name_case = re.search(r'case "\$\{name%%=\*\}" in (\S+)\) return 0 ;; (\S+)\) return 1 ;; esac', norm)
    if not name_case:
        raise _antigravity_fail(
            "print·대화형 플래그 이름을 고르는 'case \"${name%%=*}\" in <print>) return 0 ;; <대화형>) return 1 ;;'을 "
            "찾지 못했다."
        )
    for label, actual, expected in (
        ("print 모드 플래그(flags)", name_case.group(1).split("|"), print_mode["flags"]),
        ("대화형 첫 프롬프트 플래그(interactive_flags)", name_case.group(2).split("|"),
         print_mode.get("interactive_flags", [])),
    ):
        if sorted(actual) != sorted(expected):
            raise _antigravity_fail(
                f"{label} 이름이 다르다.\n  정본 = {sorted(expected)}\n  hook = {sorted(actual)}"
            )
    # 이름만 비교하려면 대시 하나·둘을 떼고(=값은 위 case가 ${name%%=*}로 뗀다) -- 에서 멈춰야 한다.
    if not re.search(r'case "\$arg" in --\) return 1 ;; --\*\) name="\$\{arg#--\}" ;; -\*\) name="\$\{arg#-\}" ;; '
                     r'\*\) continue ;; esac', norm):
        raise _antigravity_fail(
            "agy 인자를 Go flag 문법으로 읽지 않는다 — -- 에서 멈추고 대시 하나·둘을 모두 떼어 이름만 비교해야 한다."
        )
    include_env = print_mode["include_env"]
    if f'[ "${{{include_env}:-}}" = "1" ] && return 1' not in norm:
        raise _antigravity_fail(f"print 모드 포함 환경변수 {include_env}=1 분기를 찾지 못했다.")

    # --- 7. 시간 예산: 재전송 예산 == 정본 규칙의 초, 최악 종료 시각 < registration.timeout_seconds ---
    budget_rule = next((rule for rule in translation["rules"] if "스풀 재전송" in rule), None)
    budget_seconds = re.search(r"최대 (\d+)초", budget_rule or "")
    if not budget_seconds:
        raise CheckFailure("정본 antigravity_hook_translation.rules에서 스풀 재전송 시간 예산('최대 N초')을 찾지 못했다.")

    def hook_int(name: str) -> int:
        found = re.search(rf"^{name}=(\d+)$", hook_src, re.MULTILINE)
        if not found:
            raise _antigravity_fail(f"{name}=<정수> 선언을 찾지 못했다.")
        return int(found.group(1))

    replay_budget = hook_int("ANTIGRAVITY_REPLAY_BUDGET_SECONDS")
    send_deadline = hook_int("ANTIGRAVITY_SEND_DEADLINE_SECONDS")
    curl_max = hook_int("CURL_MAX_TIME")
    timeout = translation["registration"]["timeout_seconds"]
    if replay_budget != int(budget_seconds.group(1)):
        raise _antigravity_fail(
            f"스풀 재전송 예산이 {replay_budget}초다(정본 규칙: {budget_seconds.group(1)}초)."
        )
    if not replay_budget <= send_deadline or send_deadline + curl_max >= timeout:
        raise _antigravity_fail(
            f"시간 예산이 agy 제한 안에 들지 않는다 — 재전송 {replay_budget}초 ≤ 전송 마감 {send_deadline}초, "
            f"전송 마감 + curl 최대 {curl_max}초 < registration.timeout_seconds {timeout}초여야 한다."
        )
    # 예산·순서 규칙이 실제로 호출되는 자리까지 본다(함수 이름만 있어도 통과하지 않게).
    def function_body(name: str) -> str:
        found = re.search(rf"^{name}\(\) \{{\n(.*?)^\}}", hook_src, re.MULTILINE | re.DOTALL)
        return _normalize_ws(found.group(1)) if found else ""

    call_sites = {
        "acquire_lock의 재시도 루프가 예산을 넘으면 기다리지 않는다":
            ("acquire_lock", 'while ! mkdir "$LOCK_DIR" 2>/dev/null; do antigravity_budget_spent && return 1'),
        "flush_spool이 예산을 넘으면 새 재전송을 시작하지 않는다":
            ("flush_spool", 'if [ "$stop_on_failure" -eq 1 ] || antigravity_budget_spent; then'),
        "send_payload가 마지막 응답 코드를 남긴다":
            ("send_payload", 'LAST_SEND_CODE="$code"'),
        "재전송이 서버 응답을 하나도 받지 못했을 때(000)만 이번 이벤트를 스풀 끝에 넣는다":
            ("antigravity_spool_behind",
             '[ "$SOURCE" = "antigravity" ] && [ -s "$SPOOL_FILE" ] && [ "${LAST_SEND_CODE:-}" = "000" ]'),
        # 모든 source의 정합성: 재전송하는 동안 락 없이 append된 줄이 재작성(mv)에 덮이지 않게, 가져간 줄
        # 다음은 전부 되돌린다(스풀 끝에 넣은 이벤트가 다른 hook의 flush에 사라지지 않는 근거이기도 하다).
        "flush_spool이 실제로 가져간 줄(head_file) 다음 줄을 전부 되돌린다":
            ("flush_spool",
             'local taken taken="$(wc -l < "$head_file" 2>/dev/null | tr -d \' \')" case "$taken" in '
             "''|*[!0-9]*) taken=0 ;; esac "
             'tail -n +"$((taken + 1))" "$SPOOL_FILE" >> "$remaining_file" 2>/dev/null'),
    }
    for label, (function, needle) in call_sites.items():
        if needle not in function_body(function):
            raise _antigravity_fail(f"{function}에서 '{label}' 자리를 찾지 못했다.")
    if not re.search(r'^LAST_SEND_CODE=""$', hook_src, re.MULTILINE):
        raise _antigravity_fail(
            "LAST_SEND_CODE를 전역에서 비워 두고 시작하지 않는다 — 환경변수로 물려받은 값이 스풀 판정에 샌다."
        )
    if (
        'if [ "$SOURCE" != "antigravity" ] || [ "$SKIP_SEND" -eq 0 ]; then flush_spool fi' not in norm
        or 'if ! antigravity_send_deadline_passed && ! antigravity_spool_behind && send_payload "$PAYLOAD"; then'
        not in norm
    ):
        raise _antigravity_fail(
            "본문에서 스로틀된 하트비트의 재전송 생략이나 이번 전송의 마감·스풀 순서 분기를 찾지 못했다."
        )
    if (
        "응답을 하나도 받지 못했으면" not in budget_rule
        or "스풀 끝에 넣는다" not in budget_rule
        or "바로 보낸다" not in budget_rule
    ):
        raise CheckFailure(
            "정본 antigravity_hook_translation.rules의 스풀 규칙이 '재전송이 응답을 하나도 받지 못했으면 스풀 끝에 "
            f"넣고, 서버가 응답했으면 바로 보낸다'를 말하지 않는다(정본: {budget_rule!r})."
        )

    return (
        "antigravity_hook_translation(stdout 응답·인자 이벤트 이름·question_tools·턴 시작·서브에이전트·"
        "모든 Stop·Stop 뒤 래치(질문 도구 포함)와 래치 중 턴 재시작·필드·Go flag print 모드·시간 예산과 응답이 없을 때만 스풀 대기)이 agent-event-hook.sh와 일치한다."
    )


# ---------------------------------------------------------------------------
# Check 8(선택): 정본 client_actions.UserAck(from_states/to_state)가 코드 사본
# client-actions.ts::USER_ACK_FROM_STATES/USER_ACK_TO_STATE와 같은가. Check 7이
# heartbeat.ts를 검증하는 것과 같은 이유·같은 모양이다 — event_state_map이 아닌
# 별도 표(client_actions)라서 check 7과 합치지 않고 독립된 check로 둔다.
#
# 8c(검증 리뷰 지적 high 수정으로 신설): 정본 client_actions.reserved_event_names가
# client-actions.ts::RESERVED_CLIENT_ACTION_EVENTS 및 dashboard/routes.ts의 실제 거절
# 가드와 세 지점 모두 일치하는가 — "표에 없다"만으로는 위조를 막지 못한다는 게 이번 수정의
# 핵심이라, 실제 코드가 그 표를 근거로 거절하고 있는지까지 본다(단순 존재 비교가 아니다).
#
# 8d/8e(seen 기능 추가로 신설): client_actions에 effect 판별자가 생기면서(UserAck:
# "transition", MarkSeen: "marker") 정본 JSON 자체의 내부 일관성(MarkSeen이 to_state를
# 갖지 않는다, reserved_event_names에 MarkSeen이 없다)과, MarkSeen의 실제 구현(seen.ts의
# markSeenAtLeast, dashboard/routes.ts의 POST /sessions/:key/seen 라우트)이 계약과 계속
# 붙어 있는지를 검증한다.
# ---------------------------------------------------------------------------


def check_client_actions_table(contract: dict) -> str:
    if not CLIENT_ACTIONS_TS_PATH.exists():
        raise CheckFailure(f"{CLIENT_ACTIONS_TS_PATH} 가 없다.")
    src = CLIENT_ACTIONS_TS_PATH.read_text(encoding="utf-8")

    # --- 8a. USER_ACK_FROM_STATES == 정본 client_actions.UserAck.from_states ---
    from_match = re.search(
        r"USER_ACK_FROM_STATES:\s*ReadonlySet<SessionState>\s*=\s*new Set<SessionState>\(\[(.*?)\]\)",
        src,
        re.DOTALL,
    )
    if not from_match:
        raise CheckFailure(
            f"{CLIENT_ACTIONS_TS_PATH}에서 'USER_ACK_FROM_STATES = new Set<SessionState>([...])' 를 찾지 못했다."
        )
    actual_from_states = sorted(re.findall(r'"([^"]+)"', from_match.group(1)))
    expected_from_states = sorted(contract["client_actions"]["UserAck"]["from_states"])
    if actual_from_states != expected_from_states:
        raise CheckFailure(
            "client-actions.ts::USER_ACK_FROM_STATES가 정본 client_actions.UserAck.from_states와 다르다.\n"
            f"  정본                                    = {expected_from_states}\n"
            f"  client-actions.ts::USER_ACK_FROM_STATES = {actual_from_states}\n"
            "  -> server/src/dashboard/client-actions.ts 를 확인해라."
        )

    # --- 8b. USER_ACK_TO_STATE == 정본 client_actions.UserAck.to_state ---
    to_match = re.search(r'USER_ACK_TO_STATE:\s*SessionState\s*=\s*"([^"]+)"', src)
    if not to_match:
        raise CheckFailure(
            f"{CLIENT_ACTIONS_TS_PATH}에서 'USER_ACK_TO_STATE: SessionState = \"...\"' 를 찾지 못했다."
        )
    actual_to_state = to_match.group(1)
    expected_to_state = contract["client_actions"]["UserAck"]["to_state"]
    if actual_to_state != expected_to_state:
        raise CheckFailure(
            "client-actions.ts::USER_ACK_TO_STATE가 정본 client_actions.UserAck.to_state와 다르다.\n"
            f"  정본                                  = {expected_to_state}\n"
            f"  client-actions.ts::USER_ACK_TO_STATE = {actual_to_state}\n"
            "  -> server/src/dashboard/client-actions.ts 를 확인해라."
        )

    # --- 8c. reserved_event_names(위조 차단, 검증 리뷰 지적 high 수정 후 신설) ---
    # 정본 client_actions.reserved_event_names == client-actions.ts::RESERVED_CLIENT_ACTION_EVENTS
    # == POST /dashboard/events(dashboard/routes.ts)가 실제로 400 거절하는 이름 집합. 세
    # 지점 중 하나만 늘고 나머지가 안 늘면 "표에는 있는데 거절은 안 한다"(혹은 그 반대) 회귀가
    # 조용히 들어온다 - Check 1(바이트 동일)이 지켜주지 않는 코드 쪽 사본이라 여기서 직접 본다.
    reserved_match = re.search(
        r"RESERVED_CLIENT_ACTION_EVENTS:\s*ReadonlySet<string>\s*=\s*new Set<string>\(\[(.*?)\]\)",
        src,
        re.DOTALL,
    )
    if not reserved_match:
        raise CheckFailure(
            f"{CLIENT_ACTIONS_TS_PATH}에서 'RESERVED_CLIENT_ACTION_EVENTS = new Set<string>([...])' 를 찾지 못했다."
        )
    actual_reserved = sorted(re.findall(r'"([^"]+)"', reserved_match.group(1)))
    expected_reserved = sorted(contract["client_actions"]["reserved_event_names"])
    if actual_reserved != expected_reserved:
        raise CheckFailure(
            "client-actions.ts::RESERVED_CLIENT_ACTION_EVENTS가 정본 "
            "client_actions.reserved_event_names와 다르다.\n"
            f"  정본                                            = {expected_reserved}\n"
            f"  client-actions.ts::RESERVED_CLIENT_ACTION_EVENTS = {actual_reserved}\n"
            "  -> server/src/dashboard/client-actions.ts 를 확인해라."
        )

    if not DASHBOARD_ROUTES_TS_PATH.exists():
        raise CheckFailure(f"{DASHBOARD_ROUTES_TS_PATH} 가 없다.")
    routes_src = DASHBOARD_ROUTES_TS_PATH.read_text(encoding="utf-8")
    # POST /dashboard/events 핸들러가 RESERVED_CLIENT_ACTION_EVENTS를 실제로 참조해 거절하는지
    # (import뿐 아니라 사용까지) - 이름만 import해 두고 실제 가드를 빠뜨리는 회귀를 잡는다.
    if not re.search(r"RESERVED_CLIENT_ACTION_EVENTS\.has\(event\)", routes_src):
        raise CheckFailure(
            f"{DASHBOARD_ROUTES_TS_PATH}에서 'RESERVED_CLIENT_ACTION_EVENTS.has(event)' 가드를 찾지 못했다 "
            "- POST /dashboard/events가 client_actions 전용 이벤트 이름을 더 이상 거절하지 않을 수 있다."
        )

    # --- 8d(seen 기능 추가로 신설): client_actions.UserAck/MarkSeen의 effect 판별자와
    # MarkSeen의 모양(정본 JSON 레벨 내부 일관성)이 설계와 맞는가. effect는 코드에 있는
    # 상수가 아니라 순수 문서화 필드라 8a/8b처럼 코드 사본과 대조할 수 없다 - 대신 "있어야
    # 할 값"과 "없어야 할 키"를 정본 JSON 자체에서 직접 검증한다.
    user_ack = contract["client_actions"]["UserAck"]
    if user_ack.get("effect") != "transition":
        raise CheckFailure(
            "정본 client_actions.UserAck.effect가 \"transition\"이 아니다 "
            f"(실제: {user_ack.get('effect')!r}) - contracts/dashboard-protocol.v1.json을 확인해라."
        )

    mark_seen = contract["client_actions"].get("MarkSeen")
    if mark_seen is None:
        raise CheckFailure(
            "정본 client_actions에 MarkSeen이 없다 - seen(읽음/안읽음) 기능은 "
            "client_actions.MarkSeen(effect:\"marker\")로 계약에 명문화되어야 한다."
        )
    if mark_seen.get("effect") != "marker":
        raise CheckFailure(
            f"정본 client_actions.MarkSeen.effect가 \"marker\"가 아니다 (실제: {mark_seen.get('effect')!r})."
        )
    if "to_state" in mark_seen:
        raise CheckFailure(
            "정본 client_actions.MarkSeen에 to_state 필드가 있다 - MarkSeen은 상태 전이가 아니므로"
            "(effect:\"marker\") to_state를 가지면 안 된다."
        )
    if "MarkSeen" in contract["client_actions"].get("reserved_event_names", []):
        raise CheckFailure(
            "정본 client_actions.reserved_event_names에 MarkSeen이 들어 있다 - MarkSeen은 "
            "dashboard_events에 아무것도 적재하지 않으므로 예약이 필요 없다(위조 표면이 없다)."
        )

    # --- 8e(seen 기능 추가로 신설): MarkSeen의 실제 구현(seen.ts + dashboard/routes.ts)이
    # 계약이 말하는 endpoint·단조 갱신 로직과 여전히 붙어 있는가. effect가 코드 상수가 아니라서
    # 8a/8b식 표 대조가 안 되는 대신, "그 라우트와 그 단조 갱신 함수가 실제로 존재하고 서로
    # 연결돼 있는지"를 코드에서 직접 grep한다.
    if not SEEN_TS_PATH.exists():
        raise CheckFailure(f"{SEEN_TS_PATH} 가 없다 - client_actions.MarkSeen의 판정/갱신 로직 파일.")
    seen_src = SEEN_TS_PATH.read_text(encoding="utf-8")
    if not re.search(r"export\s+(async\s+)?function\s+markSeenAtLeast", seen_src):
        raise CheckFailure(
            f"{SEEN_TS_PATH}에서 'export function markSeenAtLeast'를 찾지 못했다 - MarkSeen의 단조 "
            "갱신 로직이 옮겨지거나 이름이 바뀌었을 수 있다."
        )
    if "ON CONFLICT" not in seen_src or "MAX(" not in seen_src:
        raise CheckFailure(
            f"{SEEN_TS_PATH}의 markSeenAtLeast가 더 이상 ON CONFLICT ... MAX(...) 단조 갱신 형태가 "
            "아닌 것 같다 - client_actions.MarkSeen.monotonic_rule과 어긋난다."
        )

    if not re.search(r'\.post\(\s*"/sessions/:key/seen"', routes_src):
        raise CheckFailure(
            f"{DASHBOARD_ROUTES_TS_PATH}에서 'POST /sessions/:key/seen' 라우트를 찾지 못했다 - "
            "client_actions.MarkSeen.endpoint와 어긋난다."
        )
    if not re.search(r"markSeenAtLeast", routes_src):
        raise CheckFailure(
            f"{DASHBOARD_ROUTES_TS_PATH}가 markSeenAtLeast를 더 이상 참조하지 않는다 - seen 라우트가 "
            "seen.ts의 단조 갱신 로직을 안 쓰고 있을 수 있다."
        )

    return (
        "client-actions.ts::USER_ACK_FROM_STATES/USER_ACK_TO_STATE/RESERVED_CLIENT_ACTION_EVENTS가 정본 "
        "client_actions.UserAck.from_states/to_state·reserved_event_names와 일치하고, "
        "dashboard/routes.ts가 그 목록으로 실제 거절 가드를 두고 있다. UserAck.effect==transition, "
        "MarkSeen.effect==marker(및 to_state 부재, 예약 불필요)와 MarkSeen의 실제 구현(seen.ts·"
        "dashboard/routes.ts)도 계약과 일치한다."
    )


# ---------------------------------------------------------------------------
# Check 9(계약 판정 A/B로 신설): dashboard_seen이 "리베이스"되는 판정(A)과, seen이
# sync 응답 최상위 단일 표현으로 옮겨간 판정(B)이 정본 JSON 내부 일관성 + 실제 구현
# (rebuild.ts, sync.ts) 양쪽에서 여전히 지켜지고 있는가.
#
# A: 정본 client_actions.MarkSeen.invariants에 "불가침"(rebuild가 dashboard_seen을 절대
# 건드리지 않는다는, 이제는 폐기된 판정) 문구가 남아 있으면 안 되고, 대신 "리베이스"를 뜻하는
# 문구가 있어야 한다. rebuild.ts는 재생 말미에 dashboard_seen을 실제로 UPDATE(리베이스)하고
# 고아 행을 DELETE하는 두 문장을 갖고 있어야 한다.
#
# B: 정본 sync.session_object.fields에 seen_transition_id가 없어야 하고(같은 사실의 복수
# 표현 금지), sync.response.fields에는 seen이 있어야 하며 sync.seen_object 정의가 있어야
# 한다. sync.ts는 SyncSession에 seen_transition_id 필드가 없고, SyncResponse에는
# seen: SyncSeen[] 필드가 있어야 한다.
# ---------------------------------------------------------------------------


def check_seen_rebase_and_top_level_array(contract: dict) -> str:
    # --- A-1: 정본 client_actions.MarkSeen.invariants 내부 일관성 ---
    mark_seen = contract["client_actions"].get("MarkSeen")
    if mark_seen is None:
        raise CheckFailure("정본 client_actions에 MarkSeen이 없다 - check 8d가 먼저 잡아야 할 회귀다.")
    invariants = mark_seen.get("invariants", [])
    invariants_text = "\n".join(invariants)
    if "불가침" in invariants_text:
        raise CheckFailure(
            "정본 client_actions.MarkSeen.invariants에 폐기된 판정(\"불가침\")이 남아 있다 - "
            "계약 판정 A(rebuild는 재생 말미에 각 세션의 seen_transition_id를 새 "
            "last_transition_id로 리베이스한다)로 대체되어야 한다."
        )
    if "새 last_transition_id" not in invariants_text or "seen_transition_id" not in invariants_text:
        raise CheckFailure(
            "정본 client_actions.MarkSeen.invariants에 rebuild의 리베이스 판정(재생 말미에 "
            "seen_transition_id를 새 last_transition_id로 맞춘다)이 보이지 않는다."
        )

    # --- A-2: rebuild.ts가 실제로 리베이스 UPDATE + 고아 DELETE를 하는가 ---
    if not REBUILD_TS_PATH.exists():
        raise CheckFailure(f"{REBUILD_TS_PATH} 가 없다.")
    rebuild_src = REBUILD_TS_PATH.read_text(encoding="utf-8")
    if not re.search(
        r"UPDATE\s+dashboard_seen\s+SET\s+seen_transition_id\s*=\s*\?\s+WHERE\s+session_key\s*=\s*\?",
        rebuild_src,
    ):
        raise CheckFailure(
            f"{REBUILD_TS_PATH}에서 'UPDATE dashboard_seen SET seen_transition_id = ? WHERE "
            "session_key = ?' 리베이스 문장을 찾지 못했다 - 계약 판정 A(무조건 대입, MIN 금지)가 "
            "빠졌을 수 있다."
        )
    if not re.search(
        r"DELETE\s+FROM\s+dashboard_seen\s+WHERE\s+session_key\s+NOT\s+IN\s*\(\s*SELECT\s+key\s+FROM\s+dashboard_sessions\s*\)",
        rebuild_src,
    ):
        raise CheckFailure(
            f"{REBUILD_TS_PATH}에서 재생 결과에 없는 세션의 dashboard_seen 고아 행을 지우는 DELETE "
            "문장을 찾지 못했다 - 계약 판정 A(고아 삭제)가 빠졌을 수 있다."
        )
    # 고아 삭제보다 리베이스 UPDATE가 먼저 실행돼야 한다 - 순서가 바뀌면 리베이스 UPDATE가
    # 고아를 되살릴 여지는 없지만(WHERE session_key = ?가 존재하지 않는 행에 UPDATE해도
    # no-op이다) 의도된 실행 순서(리베이스 -> 고아 정리)를 코드 순서로도 고정해 둔다.
    update_pos = rebuild_src.find("UPDATE dashboard_seen SET seen_transition_id")
    delete_pos = rebuild_src.find("DELETE FROM dashboard_seen WHERE session_key NOT IN")
    if update_pos == -1 or delete_pos == -1 or update_pos > delete_pos:
        raise CheckFailure(
            f"{REBUILD_TS_PATH}에서 리베이스 UPDATE가 고아 DELETE보다 먼저 나오지 않는다."
        )

    # --- B-1: 정본 sync.session_object.fields에 seen_transition_id가 없어야 한다 ---
    session_fields = contract["sync"]["session_object"]["fields"]
    if "seen_transition_id" in session_fields:
        raise CheckFailure(
            "정본 sync.session_object.fields에 seen_transition_id가 아직 남아 있다 - 계약 "
            "판정 B(같은 사실의 복수 표현 금지)에 따라 응답 최상위 sync.response.fields.seen로 "
            "옮겨가고 session_object에서는 제거되어야 한다."
        )

    # --- B-2: 정본 sync.response.fields.seen + sync.seen_object 존재 ---
    response_fields = contract["sync"]["response"]["fields"]
    if "seen" not in response_fields:
        raise CheckFailure(
            "정본 sync.response.fields에 seen이 없다 - 계약 판정 B(스냅샷·델타 공통 절대값 "
            "seen 배열)가 계약에 명문화되지 않았다."
        )
    if "seen_object" not in contract["sync"]:
        raise CheckFailure(
            "정본 sync에 seen_object 정의가 없다 - sync.response.fields.seen의 items_ref가 "
            "가리킬 대상이 없다."
        )
    seen_object_fields = contract["sync"]["seen_object"].get("fields", {})
    if "key" not in seen_object_fields or "seen_transition_id" not in seen_object_fields:
        raise CheckFailure(
            "정본 sync.seen_object.fields는 key와 seen_transition_id를 모두 가져야 한다."
        )

    # --- B-3: sync.ts 실제 구현이 SyncSession에서 seen_transition_id를 뺐고, SyncResponse에
    # seen: SyncSeen[]을 얹었는가 ---
    if not SYNC_TS_PATH.exists():
        raise CheckFailure(f"{SYNC_TS_PATH} 가 없다.")
    sync_src = SYNC_TS_PATH.read_text(encoding="utf-8")
    session_iface_match = re.search(r"export interface SyncSession \{(.*?)\n\}", sync_src, re.DOTALL)
    if not session_iface_match:
        raise CheckFailure(f"{SYNC_TS_PATH}에서 'export interface SyncSession {{...}}'를 찾지 못했다.")
    if re.search(r"^\s*seen_transition_id\s*:", session_iface_match.group(1), re.MULTILINE):
        raise CheckFailure(
            f"{SYNC_TS_PATH}의 SyncSession이 아직 seen_transition_id 필드를 갖고 있다 - 계약 "
            "판정 B에 따라 제거되어야 한다(대신 SyncResponse.seen)."
        )
    response_iface_match = re.search(r"export interface SyncResponse \{(.*?)\n\}", sync_src, re.DOTALL)
    if not response_iface_match:
        raise CheckFailure(f"{SYNC_TS_PATH}에서 'export interface SyncResponse {{...}}'를 찾지 못했다.")
    if not re.search(r"^\s*seen\s*:\s*SyncSeen\[\]", response_iface_match.group(1), re.MULTILINE):
        raise CheckFailure(
            f"{SYNC_TS_PATH}의 SyncResponse에 'seen: SyncSeen[]' 필드가 없다 - 계약 판정 B가 "
            "구현에 반영되지 않았을 수 있다."
        )
    # base 오브젝트(스냅샷·델타 공통 반환값)가 실제로 seen을 채우는지 - mute_until과 같은 자리에
    # 있어야 두 reset 분기 모두에 절대값으로 동봉된다.
    base_match = re.search(r"const base = \{(.*?)\n  \};", sync_src, re.DOTALL)
    if not base_match or not re.search(r"seen\s*:\s*await readSeen\(env\)", base_match.group(1)):
        raise CheckFailure(
            f"{SYNC_TS_PATH}의 buildSync()에서 base 오브젝트가 'seen: await readSeen(env)'를 "
            "포함하지 않는다 - mute_until과 같은 절대값 동봉 자리(스냅샷·델타 공통)에서 빠졌을 수 있다."
        )

    return (
        "정본 client_actions.MarkSeen.invariants가 리베이스 판정으로 갱신되어 있고 rebuild.ts가 "
        "실제로 dashboard_seen을 리베이스(UPDATE)한 뒤 고아 행을 DELETE한다(이 순서로). 정본 "
        "sync.session_object.fields에서 seen_transition_id가 빠지고 sync.response.fields.seen + "
        "sync.seen_object로 옮겨간 것이 sync.ts(SyncSession/SyncResponse/buildSync)와 일치한다."
    )


def check_ui_lang_wire_keys(contract: dict) -> str:
    """settings.ui_lang의 **와이어 키 이름**이 계약·서버·Flutter 클라이언트 세 곳에서 같은가.

    이 check가 왜 따로 필요한가(리뷰 지적 high): 이 엔드포인트는 요청 키(`lang`)와
    응답 키(`ui_lang`)가 다르다 — 명시적 null("선택 해제")이 유효값이라 서버가
    `"lang" in body`로 **키의 존재 자체**를 먼저 보기 때문이다. 그래서 클라이언트가
    `{"ui_lang": ...}`를 보내면 값이 아무리 맞아도 "키 부재" 400으로 떨어지는데,
    양쪽 단위 테스트는 각자 자기 모양만 단언하므로(서버 테스트는 `{lang:...}`만 보내고,
    Flutter 테스트는 클라이언트가 실제로 만든 본문을 그대로 기대값에 박아 둔다) 전부
    초록인 채로 실제 HTTP만 400이 된다. 실제로 그 상태로 게이트를 통과한 전례가 있어
    이 대조를 자동화한다.
    """
    ui_lang = contract.get("settings", {}).get("ui_lang")
    if ui_lang is None:
        raise CheckFailure("정본 settings에 ui_lang 절이 없다.")

    # --- A: 정본이 정한 키 이름 ---
    post = ui_lang["endpoint"]["post"]
    request_keys = sorted(post["request"].keys())
    if request_keys != ["lang"]:
        raise CheckFailure(
            f"정본 settings.ui_lang.endpoint.post.request의 키가 {request_keys}다 - "
            "요청 본문 키는 lang 하나여야 한다."
        )
    if "ui_lang" not in post["response"]:
        raise CheckFailure(
            "정본 settings.ui_lang.endpoint.post.response에 ui_lang이 없다 - 응답 확정값 키다."
        )
    if "ui_lang" not in ui_lang["endpoint"]["get"]["response"]:
        raise CheckFailure("정본 settings.ui_lang.endpoint.get.response에 ui_lang이 없다.")
    if "ui_lang" not in contract["sync"]["response"]["fields"]:
        raise CheckFailure(
            "정본 sync.response.fields에 ui_lang이 없다 - sync 편승 필드 이름이 바뀌었다."
        )

    # --- B: 서버가 그 키로 읽고 쓰는가 ---
    if not DASHBOARD_OPS_ROUTES_TS_PATH.exists():
        raise CheckFailure(f"{DASHBOARD_OPS_ROUTES_TS_PATH} 가 없다.")
    routes_src = DASHBOARD_OPS_ROUTES_TS_PATH.read_text(encoding="utf-8")
    ui_lang_post = re.search(
        r'dashboardOps\.post\(\s*"/ui-lang"\s*,\s*async \(c\) => \{(.*?)\n\}\);',
        routes_src,
        re.DOTALL,
    )
    if not ui_lang_post:
        raise CheckFailure(
            f'{DASHBOARD_OPS_ROUTES_TS_PATH}에서 dashboardOps.post("/ui-lang", ...) 핸들러를 찾지 못했다.'
        )
    handler = ui_lang_post.group(1)
    if not re.search(r'!\("lang" in body\)', handler):
        raise CheckFailure(
            f'{DASHBOARD_OPS_ROUTES_TS_PATH}의 POST /ui-lang이 \'!("lang" in body)\'로 키 부재를 '
            "구분하지 않는다 - 명시적 null(선택 해제)과 키 누락을 구분하는 것이 정본 "
            "settings.ui_lang.endpoint.post.request.lang의 요구다."
        )
    if not re.search(r"\bbody\.lang\b", handler):
        raise CheckFailure(
            f"{DASHBOARD_OPS_ROUTES_TS_PATH}의 POST /ui-lang이 body.lang을 읽지 않는다."
        )
    if not re.search(r"ui_lang:\s*lang", handler):
        raise CheckFailure(
            f"{DASHBOARD_OPS_ROUTES_TS_PATH}의 POST /ui-lang 응답이 ui_lang 키로 확정값을 싣지 않는다."
        )

    return "서버 ui_lang 요청·응답 키 일치. " + check_client_ui_lang_wire_keys(contract)


def check_client_ui_lang_wire_keys(contract: dict) -> str:
    ui_lang = contract["settings"]["ui_lang"]["endpoint"]
    if (set(ui_lang["post"]["request"]) != {"lang"}
            or "ui_lang" not in ui_lang["post"]["response"]
            or "ui_lang" not in ui_lang["get"]["response"]
            or "ui_lang" not in contract["sync"]["response"]["fields"]):
        raise CheckFailure("소비 계약의 ui_lang 요청·응답 필드가 지원 형식과 다르다")
    # --- C: Flutter 클라이언트가 소비 계약과 같은 키로 보내는가 ---
    if not DASHBOARD_API_DART_PATH.exists():
        raise CheckFailure(f"{DASHBOARD_API_DART_PATH} 가 없다.")
    api_src = DASHBOARD_API_DART_PATH.read_text(encoding="utf-8")
    set_ui_lang = re.search(
        r"Future<String\?> setUiLang\(String\? value\) async \{(.*?)\n  \}",
        api_src,
        re.DOTALL,
    )
    if not set_ui_lang:
        raise CheckFailure(
            f"{DASHBOARD_API_DART_PATH}에서 setUiLang(String? value) 본문을 찾지 못했다."
        )
    body_literal = re.search(
        r"body:\s*<String, Object\?>\{(.*?)\}", set_ui_lang.group(1), re.DOTALL
    )
    if not body_literal:
        raise CheckFailure(
            f"{DASHBOARD_API_DART_PATH}의 setUiLang에서 POST 본문 리터럴을 찾지 못했다."
        )
    sent_keys = sorted(set(re.findall(r"'([^']+)'\s*:", body_literal.group(1))))
    if sent_keys != ["lang"]:
        raise CheckFailure(
            f"{DASHBOARD_API_DART_PATH}의 setUiLang이 POST 본문에 {sent_keys} 키를 싣는다 - "
            "정본이 정한 요청 키는 lang 하나다. 특히 'ui_lang'으로 보내면 서버의 "
            '\'!("lang" in body)\' 키 부재 분기에 걸려 항상 400이 된다(응답 키가 ui_lang인 것과 '
            "혼동하기 쉬운 자리다)."
        )
    for reader, label in (
        (r"final Object\? confirmed = json\['ui_lang'\]", "setUiLang의 응답 파싱"),
        (r"final Object\? value = json\['ui_lang'\]", "uiLang()의 응답 파싱"),
    ):
        if not re.search(reader, api_src):
            raise CheckFailure(
                f"{DASHBOARD_API_DART_PATH}의 {label}가 json['ui_lang']을 읽지 않는다 - "
                "응답 키는 계약대로 ui_lang이다."
            )

    return (
        "settings.ui_lang의 요청 키(lang)/응답 키(ui_lang)가 소비 계약·dashboard_api.dart에서 같다. "
        "Flutter 클라이언트는 lang으로 보내고 ui_lang으로 읽는다."
    )


# ---------------------------------------------------------------------------
# 메인 실행부
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Check 11: 서버 sources/ 어댑터가 정본 sources.registered / event_state_map /
# heartbeat_events를 실제로 옮겨 적었는가.
#
# 배경: devin 추가 때 정본 JSON·dashboard.rs·hook 스크립트는 다 갱신됐는데
# sources/devin.ts 어댑터가 없어 서버가 devin 이벤트를 전부 202(로그만)로
# 떨어뜨린 사고가 있었다 — 이 check는 "정본에 등록됐는데 서버 프로젝션에는
# 없는 소스"와 "어댑터는 있는데 표가 정본과 다른" 두 방향 drift를 잡는다.
# ---------------------------------------------------------------------------


def _ts_event_state_pairs(adapter_src: str) -> list[tuple[str, str]]:
    block = re.search(r"const EVENT_STATE[^=]*=\s*\{(.*?)\};", adapter_src, re.DOTALL)
    if not block:
        return []
    pairs = []
    for m in re.finditer(r'(?:("[^"]+")|(\w+))\s*:\s*"([^"]+)"', block.group(1)):
        key = m.group(1) or m.group(2) or ""
        pairs.append((key.strip('"'), m.group(3)))
    return pairs


def check_source_adapters(contract: dict) -> str:
    if not SOURCES_DIR.is_dir():
        raise CheckFailure(f"{SOURCES_DIR} 가 없다.")

    registered = contract["sources"]["registered"]
    by_source = contract["event_state_map"]["by_source"]
    hb_events = contract["heartbeat_events"]["events"]

    # 소스별 기대 하트비트 이벤트 집합 (정본 heartbeat_events.events[*].sources 역조회).
    expected_hb: dict[str, set[str]] = {
        src: {ev for ev, spec in hb_events.items() if src in spec.get("sources", [])}
        for src in registered
    }

    index_src = (SOURCES_DIR / "index.ts").read_text(encoding="utf-8")
    adapters_block = re.search(r"SOURCE_ADAPTERS[^=]*=\s*\{(.*?)\};", index_src, re.DOTALL)
    if not adapters_block:
        raise CheckFailure(f"{SOURCES_DIR}/index.ts 에서 SOURCE_ADAPTERS 리터럴을 찾지 못했다.")
    registered_vars = set(re.findall(r"\[(\w+)\.source\]", adapters_block.group(1)))

    adapter_vars: dict[str, str] = {}  # source -> 어댑터 변수명
    for source, spec in registered.items():
        adapter_path = SOURCES_DIR / f"{source}.ts"
        if not adapter_path.exists():
            raise CheckFailure(
                f"정본 sources.registered에 '{source}'가 있는데 {adapter_path} 가 없다 — "
                "이벤트가 202(로그만)로 떨어지고 세션으로 프로젝션되지 않는다."
            )
        src = adapter_path.read_text(encoding="utf-8")

        var_match = re.search(r"export const (\w+):\s*SourceAdapter", src)
        if not var_match:
            raise CheckFailure(f"{adapter_path} 에서 'export const <name>: SourceAdapter' 를 찾지 못했다.")
        adapter_vars[source] = var_match.group(1)

        decl_match = re.search(r'^\s+source:\s*"([^"]+)"', src, re.MULTILINE)
        if not decl_match or decl_match.group(1) != source:
            raise CheckFailure(f"{adapter_path} 의 source 선언이 '{source}'가 아니다.")

        sfa_match = re.search(r"stateFieldAllowed:\s*(true|false)", src)
        if not sfa_match or (sfa_match.group(1) == "true") != bool(spec.get("state_field_allowed")):
            raise CheckFailure(
                f"{adapter_path} 의 stateFieldAllowed가 정본과 다르다 "
                f"(정본={spec.get('state_field_allowed')})."
            )

        expected_pairs = sorted((e["event"], e["state"]) for e in by_source.get(source, []))
        actual_pairs = sorted(_ts_event_state_pairs(src))
        if actual_pairs != expected_pairs:
            raise CheckFailure(
                f"{adapter_path} 의 EVENT_STATE 표가 정본 event_state_map.by_source.{source}와 다르다.\n"
                f"  정본     = {expected_pairs}\n"
                f"  어댑터   = {actual_pairs}"
            )

        hb_match = re.search(
            r"HEARTBEAT_EVENTS[^=]*=\s*new Set(?:<string>)?\(\[([^\]]*)\]\)", src, re.DOTALL
        )
        actual_hb = set(re.findall(r'"([^"]+)"', hb_match.group(1))) if hb_match else set()
        if actual_hb != expected_hb[source]:
            raise CheckFailure(
                f"{adapter_path} 의 HEARTBEAT_EVENTS가 정본과 다르다.\n"
                f"  정본     = {sorted(expected_hb[source])}\n"
                f"  어댑터   = {sorted(actual_hb)}"
            )

    # 레지스트리 완결성: 모든 어댑터가 SOURCE_ADAPTERS에 등록됐고, 고아 어댑터도 없다.
    missing = {s: v for s, v in adapter_vars.items() if v not in registered_vars}
    if missing:
        raise CheckFailure(
            f"어댑터가 있지만 SOURCE_ADAPTERS에 등록되지 않았다: {missing} — "
            f"{SOURCES_DIR}/index.ts 를 확인해라."
        )
    known_vars = set(adapter_vars.values())
    orphans = registered_vars - known_vars
    if orphans:
        raise CheckFailure(
            f"SOURCE_ADAPTERS에 정본에 없는 어댑터가 등록돼 있다: {sorted(orphans)}."
        )

    return (
        f"sources/ 어댑터 {len(adapter_vars)}개({', '.join(sorted(adapter_vars))})가 "
        "정본 sources.registered와 일치하고 EVENT_STATE·HEARTBEAT_EVENTS 표도 같다."
    )


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-root", type=Path, default=REPO_ROOT / "server",
                        help="product server source directory (default: server/)")
    parser.add_argument("--package-root", type=Path, help="also verify an installed npm package")
    args = parser.parse_args(argv)
    ok = True
    print(f"contract_check.py — product root = {REPO_ROOT}")
    try:
        configure_server_root(args.server_root)
        contract = load_canonical()
    except (CheckFailure, OSError, ValueError, KeyError, TypeError) as exc:
        print(f"[FAIL] contract source: {exc}")
        return 1
    checks = [
        ("Rust state and mapping", lambda: check_dashboard_rs(contract)),
        ("hook required fields", lambda: check_hook_fields(contract)),
        ("push data keys", check_push_sw),
        ("generated hook assets", check_hooks_dist_byte_identical),
        ("hook asset names", check_hooks_file_lists_consistent),
        ("heartbeat and input translation", lambda: check_heartbeat_and_codex_tables(contract)),
        ("client actions", lambda: check_client_actions_table(contract)),
        ("seen and rebuild", lambda: check_seen_rebase_and_top_level_array(contract)),
        ("UI language wire keys", lambda: check_ui_lang_wire_keys(contract)),
        ("source adapters", lambda: check_source_adapters(contract)),
        ("Devin input correlation", lambda: check_devin_input_translation(contract)),
        ("Antigravity hook translation", lambda: check_antigravity_hook_translation(contract)),
    ]
    if args.package_root:
        checks.append(("installed package assets", lambda: check_package_assets(args.package_root)))
    print("Scope: product-owned contract, server source, app and hooks; no private checkout required.")

    for name, fn in checks:
        try:
            result = fn()
        except (CheckFailure, OSError, ValueError, KeyError, TypeError) as exc:
            print(f"[FAIL] {name}\n       {exc}")
            ok = False
            continue

        if isinstance(result, tuple):
            message, advisory = result
            tag = "SKIP" if advisory else "PASS"
            print(f"[{tag}] {name}\n       {message}")
        else:
            print(f"[PASS] {name}\n       {result}")

    if ok:
        print("\n모든 check 통과 (push_sw.js 미구현은 advisory SKIP으로 통과에 포함).")
        return 0

    print("\n하나 이상의 check 실패 — 위 [FAIL] 항목을 고쳐라.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
