#!/usr/bin/env python3
"""my_dashboard Flutter 표면의 하드코딩 사용자 노출 문자열 게이트.

`flutter_app/lib/src` 아래에서 사용자에게 보이는 모든 문자열은 프로젝트가
두는 i18n helper(예: `t()`)를 거치는 것이 원칙이다. 이 게이트는 그 원칙을
우회하는 하드코딩 리터럴을 찾아낸다.

완벽한 Dart 파서는 범위 밖이다 — 실용적인 휴리스틱이다:

  * 후보 지점: `Text('...')` / `Text("...")` 및 사용자 노출용 named
    문자열 파라미터 `labelText:` / `hintText:` / `helperText:` /
    `tooltip:` / `semanticsLabel:`;
  * 후보 리터럴은 한글을 포함하거나, 영단어(2글자 이상)가 연속으로 두 개
    이상 붙어 있을 때 "사용자 노출"로 판정한다.

트리가 게이트보다 먼저 존재할 수 있으므로 기존 위반은
`fixtures/i18n-baseline.json`에 스냅샷한다(다른 fixtures/ drift 게이트와
같은 패턴). 이 스타터는 그 baseline을 빈 상태로 시작한다 — `check`는
baseline 대비 **새로** 생긴 위반에만 실패하고, baseline에서 사라진 항목은
정리 대상으로만 알려준다(실패시키지 않는다).

탈출구: 리터럴과 같은 줄(또는 바로 다음 줄)의 `// i18n-exempt: <사유>`
주석은 그 줄을 건너뛴다(예: 브랜드 워드마크, CLI 문법 예시).

사용법:
  python3 scripts/i18n_check.py write --baseline fixtures/i18n-baseline.json
  python3 scripts/i18n_check.py check --baseline fixtures/i18n-baseline.json

stdlib만 쓴다 — 이 스크립트 자체가 프로젝트에 새 의존성을 얹지 않는다.
"""

import argparse
import json
import re
import sys
from pathlib import Path

SCAN_DIRS = ("flutter_app/lib/src",)
DEFAULT_BASELINE = "fixtures/i18n-baseline.json"
VERSION = 1
EXEMPT_MARKER = "i18n-exempt"

# 후보 추출. `Text(` 뒤 줄바꿈이 있어도 잡는다; named 파라미터는 바로 뒤에
# 리터럴이 와야 후보로 본다.
_QUOTED = r"(?:'(?P<sq>(?:[^'\\\n]|\\.)*)'|\"(?P<dq>(?:[^\"\\\n]|\\.)*)\")"
CANDIDATE_RES = (
    re.compile(r"\bText\(\s*" + _QUOTED),
    re.compile(
        r"\b(?:labelText|hintText|helperText|tooltip|semanticsLabel)\s*:\s*"
        + _QUOTED
    ),
)

HANGUL_RE = re.compile(r"[가-힣]")
ENGLISH_TWO_WORDS_RE = re.compile(r"[A-Za-z]{2,}")


def repo_root():
    return Path(__file__).resolve().parents[1]


def is_user_facing(literal):
    return bool(HANGUL_RE.search(literal) or ENGLISH_TWO_WORDS_RE.search(literal))


def scan_file(path, root):
    """Yield {file, literal} violation records for one Dart file."""
    rel = path.relative_to(root).as_posix()
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    seen = set()
    for pattern in CANDIDATE_RES:
        for m in pattern.finditer(text):
            literal = m.group("sq") if m.group("sq") is not None else m.group("dq")
            if not is_user_facing(literal):
                continue
            # 줄 단위 예외 마커.
            line_no = text.count("\n", 0, m.start())
            window = lines[line_no : line_no + 2]
            if any(re.search(r'//\s*i18n-exempt:\s*\S', ln) for ln in window):
                continue
            key = (rel, literal)
            if key in seen:
                continue
            seen.add(key)
            yield {"file": rel, "literal": literal}


def collect_violations(root):
    records = []
    for scan_dir in SCAN_DIRS:
        base = root / scan_dir
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.dart")):
            records.extend(scan_file(path, root))
    records.sort(key=lambda r: (r["file"], r["literal"]))
    return records


def load_baseline(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    return {(r["file"], r["literal"]) for r in data["violations"]}


def cmd_write(root, baseline_path):
    records = collect_violations(root)
    payload = {
        "project": "my_dashboard",
        "version": VERSION,
        "note": (
            "Snapshot of pre-existing hardcoded user-facing strings in "
            "flutter_app/lib/src. New entries fail "
            "`python3 scripts/i18n_check.py check`; migrate strings to the "
            "project's i18n helper and regenerate via "
            "scripts/i18n_check.py write."
        ),
        "violations": records,
    }
    baseline_path.parent.mkdir(parents=True, exist_ok=True)
    baseline_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n"
    )
    print(f"wrote {len(records)} baseline violation(s) to {baseline_path}")
    return 0


def cmd_check(root, baseline_path):
    if not baseline_path.is_file():
        print(
            f"error: baseline {baseline_path} not found; generate it with\n"
            f"  python3 scripts/i18n_check.py write --baseline {baseline_path}",
            file=sys.stderr,
        )
        return 1
    baseline = load_baseline(baseline_path)
    if baseline:
        print("error: migration baseline must be empty; migrate existing literals instead of ratcheting forever", file=sys.stderr)
        return 1
    current = collect_violations(root)
    current_keys = {(r["file"], r["literal"]) for r in current}

    new = sorted(current_keys - baseline)
    resolved = sorted(baseline - current_keys)

    if resolved:
        print(f"info: {len(resolved)} baseline entr(y/ies) no longer present —")
        print("      prune via: python3 scripts/i18n_check.py write")
        for file, literal in resolved:
            print(f"      resolved: {file}: {literal!r}")

    if new:
        print(
            "error: new hardcoded user-facing string(s) — route them through "
            "the project's i18n helper instead of a literal:",
            file=sys.stderr,
        )
        for file, literal in new:
            print(f"  {file}: {literal!r}", file=sys.stderr)
        return 1

    print(
        f"ok: no new hardcoded user-facing strings "
        f"({len(current)} baselined violation(s) remain to migrate)"
    )
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("write", "check"))
    parser.add_argument("--baseline", default=DEFAULT_BASELINE)
    parser.add_argument("--root", type=Path, default=repo_root())
    parser.add_argument("--scan-dir", action="append")
    args = parser.parse_args()

    root = args.root
    global SCAN_DIRS
    config_path = root / 'quality.json'
    config = json.loads(config_path.read_text(encoding="utf-8")) if config_path.exists() else {}
    SCAN_DIRS = tuple(args.scan_dir or config.get('i18n_dirs', SCAN_DIRS))
    baseline_path = root / args.baseline
    if args.mode == "write":
        return cmd_write(root, baseline_path)
    return cmd_check(root, baseline_path)


if __name__ == "__main__":
    sys.exit(main())
