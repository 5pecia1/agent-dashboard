"""Register Dashboard event groups in the Codex layer's hooks.json."""
import copy
import fcntl
import json
import os
import re
from pathlib import Path
import shlex
import stat
import sys
import tempfile
import time

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        sys.exit("Codex hook installation requires Python 3.11+ or tomli")

BEGIN = '# BEGIN my-dashboard hooks (managed by hooks/install.sh — do not edit between markers by hand)'
END = '# END my-dashboard hooks'
LEGACY_COMMAND = '"$HOME/.local/share/my-dashboard/hooks/agent-event-hook.sh" codex'


def owned_script(word, script):
    path = Path(word)
    return word == str(script) or (
        path.is_absolute() and path.name == 'agent-event-hook.sh' and path.parent.name == 'hooks'
        and path.parent.parent.name in ('my-dashboard', 'agent-dashboard', 'my-deshboard'))


def dashboard_command(command, script):
    if not isinstance(command, str):
        return False
    if command == LEGACY_COMMAND:
        return True
    try:
        words = shlex.split(command)
    except ValueError:
        words = []
    if not any(owned_script(word, script) for word in words):
        # A broken quote or a shell wrapper can hide a recognizable script from
        # shlex. Preserve the configuration for review instead of adding a duplicate.
        if str(script) in command or re.search(
                r'/(?:my-dashboard|agent-dashboard|my-deshboard)/hooks/agent-event-hook\.sh(?:$|[^\w.-])',
                command):
            raise ValueError("ambiguous Dashboard hook command; review it before reinstalling")
        return False
    if len(words) == 2 and owned_script(words[0], script) and words[1] == 'codex':
        if command == shlex.quote(words[0]) + ' codex':
            return True
    raise ValueError("modified Dashboard hook command; review it before reinstalling")


def groups_for(template, command):
    events = copy.deepcopy(template)
    for groups in events.values():
        for group in groups:
            group['hooks'][0]['command'] = command
    return events


def remove_legacy(source, template, script):
    text = (source or b'').decode('utf-8')
    parsed = tomllib.loads(text)
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if line.rstrip('\r\n') == BEGIN]
    ends = [i for i, line in enumerate(lines) if line.rstrip('\r\n') == END]
    if starts or ends:
        if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
            raise ValueError("incomplete or duplicate Dashboard TOML markers")
        begin, end = starts[0], ends[0]
        block = tomllib.loads(''.join(lines[begin + 1:end]))
        try:
            command = block['hooks']['SessionStart'][0]['hooks'][0]['command']
        except (KeyError, TypeError, IndexError):
            command = None
        if not dashboard_command(command, script) or block != {'hooks': groups_for(template, command)}:
            raise ValueError("modified Dashboard TOML block; review it before reinstalling")
        text = ''.join(lines[:begin] + lines[end + 1:])
        remaining = tomllib.loads(text)
        # Confirm the markers really enclosed active TOML tables (not text in a
        # multiline string) and deleting them cannot change unrelated settings.
        expected = copy.deepcopy(remaining)
        hooks = expected.setdefault('hooks', {})
        if not isinstance(hooks, dict) or set(hooks).intersection(template):
            raise ValueError("move custom Codex TOML hook events into hooks.json before reinstalling")
        hooks.update(block['hooks'])
        if expected != parsed:
            raise ValueError("Dashboard TOML markers overlap other settings")
        parsed = remaining
    hooks = parsed.get('hooks', {})
    if not isinstance(hooks, dict) or set(hooks) - {'state'}:
        raise ValueError("move custom Codex TOML hook events into hooks.json before reinstalling")
    return text.encode('utf-8') if source is not None else None


def unique_keys(pairs):
    result = dict(pairs)
    if len(result) != len(pairs):
        raise ValueError("duplicate JSON property in hooks.json")
    return result


def merge_json(source, template, script):
    config = {} if source is None else json.loads(source.decode('utf-8'), object_pairs_hook=unique_keys)
    if not isinstance(config, dict) or not isinstance(config.setdefault('hooks', {}), dict):
        raise ValueError("expected an object of events under hooks in hooks.json")
    desired = groups_for(template, shlex.quote(str(script)) + ' codex')
    seen = set()
    changed = False
    for event, groups in config['hooks'].items():
        if not isinstance(groups, list):
            if event in desired:
                raise ValueError(f"invalid hook groups for {event}")
            continue
        for i, group in enumerate(groups):
            if not isinstance(group, dict) or not isinstance(group.get('hooks'), list):
                if event in desired:
                    raise ValueError(f"invalid hook group for {event}")
                continue
            for hook in group['hooks']:
                if not isinstance(hook, dict) or not dashboard_command(hook.get('command'), script):
                    continue
                match = (event, group.get('matcher'))
                for target in desired.get(event, []):
                    old = copy.deepcopy(target)
                    old['hooks'][0]['command'] = hook['command']
                    if group == old:
                        break
                else:
                    raise ValueError(f"modified Dashboard group for {event}; review it before reinstalling")
                if match in seen:
                    raise ValueError(f"duplicate Dashboard group for {event}")
                seen.add(match)
                if group != target:
                    groups[i] = target
                    changed = True
    for event, groups in desired.items():
        for group in groups:
            if (event, group.get('matcher')) not in seen:
                config['hooks'].setdefault(event, []).append(group)
                changed = True
    encoded = (json.dumps(config, ensure_ascii=False, allow_nan=False, indent=2) + '\n').encode()
    return encoded if changed else source


def read(path):
    try:
        return path.read_bytes()
    except FileNotFoundError:
        return None


def stage(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.dashboard-hook-', delete=False) as handle:
        temp = Path(handle.name)
        try:
            if path.exists():
                os.fchmod(handle.fileno(), stat.S_IMODE(path.stat().st_mode))
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        except BaseException:
            temp.unlink()
            raise
    return temp


def apply(changes):
    staged, backups, applied = {}, {}, []
    try:
        for path, before, after in changes:
            staged[path] = stage(path, after)
            if before is not None:
                backup = path.with_name(f'{path.name}.bak.{time.time_ns()}')
                candidate = stage(path, before)
                try:
                    os.link(candidate, backup)
                finally:
                    candidate.unlink()
                backups[path] = backup
                print(f'백업: {backup}')
        for path, before, after in changes:
            if read(path) != before:
                raise ValueError(f'{path} changed during installation; retry')
            os.replace(staged[path], path)
            applied.append((path, before, after))
    except BaseException:
        for path, before, after in reversed(applied):
            if read(path) == after:
                if before is None:
                    path.unlink()
                else:
                    os.replace(stage(path, backups[path].read_bytes()), path)
        raise
    finally:
        for temp in staged.values():
            temp.unlink(missing_ok=True)


def install(config, script, preview):
    template_path = Path(__file__).with_name('codex-hooks.toml')
    template = tomllib.loads(template_path.read_text(encoding='utf-8'))['hooks']
    hooks = config.with_name('hooks.json').resolve()
    config = config.resolve()
    if config == hooks:
        raise ValueError("Codex config and hooks.json must be separate files")

    def plan():
        old_toml, old_json = read(config), read(hooks)
        new_toml = remove_legacy(old_toml, template, script)
        new_json = merge_json(old_json, template, script)
        # Commit JSON first. After an interruption, retry recognizes those exact
        # groups and finishes removing the legacy block without duplicating hooks.
        return [(p, old, new) for p, old, new in
                ((hooks, old_json, new_json), (config, old_toml, new_toml)) if old != new]

    if preview:
        for path, _, _ in plan():
            print(f'--dry-run: update {path}')
        return
    hooks.parent.mkdir(parents=True, exist_ok=True)
    directory_fd = os.open(hooks.parent, os.O_RDONLY)
    try:
        fcntl.flock(directory_fd, fcntl.LOCK_EX)
        changes = plan()
        if changes:
            apply(changes)
            print(f'{hooks} updated. Review the new commands in Codex /hooks.')
        else:
            print('변경 없음 (이미 등록돼 있음).')
    finally:
        os.close(directory_fd)


if __name__ == '__main__':
    try:
        install(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3] == '1')
    except (OSError, ValueError) as error:
        sys.exit(f'Codex hook installation: {error}')
