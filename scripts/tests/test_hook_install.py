"""Verify real managed commands from non-default paths, including shell quoting."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[2]
CONTRACT = ROOT / 'contracts' / 'dashboard-protocol.v1.json'


def bundle_handlers(bundle):
    """Yield (event, matcher, handler) from an agy hooks.json bundle.

    agy 1.2.12 shapes: an event with a matcher is [{matcher, hooks: [handler]}], an event
    without one is a flat [handler].
    """
    for event, entries in bundle.items():
        for entry in entries:
            if 'hooks' in entry:
                for handler in entry['hooks']:
                    yield event, entry.get('matcher'), handler
            else:
                yield event, None, entry


class HookInstallTests(unittest.TestCase):
    def test_실제_설치_경로를_모든_에이전트에_안전하게_등록한다(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            install = root / "custom data $literal's directory"
            install.mkdir()
            for name in ('install.sh', 'codex-hooks.toml'):
                shutil.copy2(ROOT / 'hooks' / name, install / name)
            (install / 'agent-event-hook.sh').write_text('#!/bin/sh\nprintf "%s" "$1" > "$HOOK_CALL_RESULT"\n')
            (install / 'agent-event-hook.sh').chmod(0o755)
            environment = {'HOME': temporary, 'PATH': os.environ['PATH']}
            for _ in range(2):
                subprocess.run(['bash', str(install / 'install.sh'), '--claude', '--codex', '--devin', '--antigravity'],
                               env=environment, capture_output=True, check=True, timeout=20)
            codex = tomllib.loads((root / '.codex/config.toml').read_text())
            commands = []
            for groups in codex['hooks'].values():
                for group in groups:
                    commands.extend((hook['command'], 'codex') for hook in group['hooks'])
            claude = json.loads((root / '.claude/settings.json').read_text())
            devin = json.loads((root / '.config/devin/config.json').read_text())
            for config, source in ((claude, 'claude-code'), (devin, 'devin')):
                for groups in config['hooks'].values():
                    for group in groups:
                        commands.extend((hook['command'], source) for hook in group['hooks'])
            # 기본 경로($HOME/.gemini/config/hooks.json)에 등록된다. 스텁 hook은 첫 인자(source)만 기록한다.
            antigravity = json.loads((root / '.gemini/config/hooks.json').read_text())
            commands.extend((handler['command'], 'antigravity')
                            for _, _, handler in bundle_handlers(antigravity['my-dashboard']))
            self.assertGreater(len(commands), 10)
            for command, source in commands:
                self.assertIn('custom data', command)
                result = root / 'called'
                subprocess.run(['sh', '-c', command], env={**environment, 'HOOK_CALL_RESULT': str(result)},
                               check=True, capture_output=True, timeout=10)
                self.assertEqual(result.read_text(), source)
            for groups in codex['hooks'].values():
                for group in groups:
                    self.assertEqual(len(group['hooks']), 1)


# 셸이 특수하게 다루는 문자를 다 넣은 폴더 이름. hook 경로가 명령 문자열 안에서 정확히 인용되는지 본다.
NASTY_SUFFIX = " $dir's \"quoted\" `tick` ;semi"

# 스텁 hook: 받은 인자와 stdin을 파일로 남기고, 자기가 실행됐다는 표시만 stdout에 낸다.
# shebang은 실제 hook과 같은 `env bash`다 - bash가 PATH에 없을 때의 실패까지 같은 모양으로 재현된다.
STUB_HOOK = """#!/usr/bin/env bash
printf '%s\\n' "$@" > "$HOOK_ARGS_FILE"
cat > "$HOOK_STDIN_FILE"
printf 'stub\\n'
"""

# hook이 stdout에 내야 하는 agy 응답(계약 event_state_map.antigravity_hook_translation.stdout_contract).
# 아래 한 테스트가 이 값이 계약과 같은지 대조하고, 나머지 테스트는 이 정확한 문자열을 기대한다.
ANSWERS = {'PreToolUse': '{"decision":"ask"}', 'Stop': '{"decision":""}'}
DEFAULT_ANSWER = '{}'

# agy 1.2.12가 hook stdin으로 주는 JSON의 실제 모양(camelCase, 이벤트 이름 없음).
PAYLOADS = {
    'PreInvocation': {'conversationId': 'c-1', 'workspacePaths': ['/tmp/work'],
                      'invocationNum': 0, 'initialNumSteps': 1},
    'PreToolUse': {'conversationId': 'c-1', 'workspacePaths': ['/tmp/work'], 'stepIdx': 2,
                   'toolCall': {'name': 'ask_question',
                                'args': {'questions': [{'question': 'Red or blue?'}]}}},
    'PostToolUse': {'conversationId': 'c-1', 'workspacePaths': ['/tmp/work'], 'stepIdx': 2,
                    'toolCall': {'name': 'run_command', 'args': {}}, 'error': ''},
    'Stop': {'conversationId': 'c-1', 'workspacePaths': ['/tmp/work'], 'terminationReason': 'NO_TOOL_CALL',
             'fullyIdle': True, 'executionNum': 1, 'error': ''},
}


def answer_for(event):
    return ANSWERS.get(event, DEFAULT_ANSWER)


def run_command(argv, env, payload, cwd=None):
    """Run argv feeding payload on stdin; return (returncode, stdout, stderr, delivered).

    subprocess.run(input=...) silently ignores a broken pipe, so a command that exits without
    reading stdin (agy would then see EPIPE) could not be told apart. Writing straight to the pipe
    makes that visible as delivered == False.
    """
    process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=env, cwd=cwd)
    delivered = True
    view = memoryview(payload)
    try:
        while view:
            view = view[os.write(process.stdin.fileno(), view):]
    except BrokenPipeError:
        delivered = False
    try:
        # 입력을 넘기지 않으면 communicate가 stdin을 닫아 준다.
        stdout, stderr = process.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        raise
    return process.returncode, stdout.decode(), stderr.decode(), delivered


class AntigravityInstallTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (self.root / 'home').mkdir()
        self.hooks_json = self.root / 'gemini/config/hooks.json'

    # ---------- helpers ----------

    def env(self, **extra):
        """Every installer target points inside the temp dir; nothing of the caller's env leaks in."""
        return {
            'PATH': os.environ['PATH'],
            'HOME': str(self.root / 'home'),
            'MY_DASHBOARD_CLAUDE_SETTINGS': str(self.root / 'claude/settings.json'),
            'MY_DASHBOARD_CODEX_CONFIG': str(self.root / 'codex/config.toml'),
            'MY_DASHBOARD_DEVIN_CONFIG': str(self.root / 'devin/config.json'),
            'MY_DASHBOARD_ANTIGRAVITY_HOOKS': str(self.hooks_json),
            **extra,
        }

    def hook_env(self, **extra):
        """Environment for running a generated hook command: it can never reach a server.

        The hook creates its state dir before it checks for a URL, and it would send to whatever
        MY_DASHBOARD_URL/TOKEN it inherits, so none of those are passed on.
        """
        empty_env = self.root / 'empty.env'
        empty_env.write_text('')
        return {
            'PATH': os.environ['PATH'],
            'HOME': str(self.root / 'home'),
            'MY_DASHBOARD_ENV': str(empty_env),
            'MY_DASHBOARD_STATE_DIR': str(self.root / 'state'),
            **extra,
        }

    def make_installer(self, name, hook_source=None, executable=True, mode=None):
        """A folder holding a copy of install.sh (and optionally the hook next to it)."""
        directory = self.root / f'{name}{NASTY_SUFFIX}'
        directory.mkdir()
        shutil.copy2(ROOT / 'hooks' / 'install.sh', directory / 'install.sh')
        if hook_source is not None:
            hook = directory / 'agent-event-hook.sh'
            hook.write_text(hook_source)
            hook.chmod(mode if mode is not None else 0o755 if executable else 0o644)
        return directory

    def make_tools(self, name, with_bash):
        """A folder to use as PATH: the tools the real hook uses, and bash only if with_bash."""
        directory = self.root / name
        directory.mkdir()
        for tool in ['cat', 'jq', 'curl', 'python3'] + (['bash'] if with_bash else []):
            found = shutil.which(tool)
            if found:
                (directory / tool).symlink_to(found)
        return directory

    def assert_stub_hook_runs(self, installer, **env):
        """Install from installer (which holds STUB_HOOK) and check every command execs the stub.

        The stub must get `antigravity <event>` as arguments and our stdin, and its stdout must reach
        us untouched: no answer of the command's own on top of it.
        """
        self.assertEqual(self.install('--antigravity', installer=installer).returncode, 0)
        args_file, stdin_file = self.root / 'args', self.root / 'stdin'
        env = self.hook_env(HOOK_ARGS_FILE=str(args_file), HOOK_STDIN_FILE=str(stdin_file), **env)
        for event, command in self.commands():
            payload = json.dumps(PAYLOADS[event]).encode()
            for label, argv in (('sh -c', ['/bin/sh', '-c', command]), ('shlex', shlex.split(command))):
                with self.subTest(event=event, how=label):
                    for leftover in (args_file, stdin_file):
                        leftover.unlink(missing_ok=True)
                    code, stdout, stderr, delivered = run_command(argv, env, payload)
                    self.assertEqual((code, stdout, stderr, delivered), (0, 'stub\n', '', True))
                    self.assertEqual(args_file.read_text().splitlines(), ['antigravity', event])
                    self.assertEqual(stdin_file.read_bytes(), payload)

    def assert_answers_by_itself(self, situation, envs, cwd=None):
        """Every installed command answers on its own: one answer, stdin drained, exit 0.

        envs maps a label to the environment to run under. The 1 MiB payload is far larger than a
        pipe buffer, so a command that leaves stdin unread shows up as a broken pipe.
        """
        payload = b'{"pad":"' + b'x' * (1 << 20) + b'"}'
        for event, command in self.commands():
            for label, argv in (('sh -c', ['/bin/sh', '-c', command]), ('shlex', shlex.split(command))):
                for env_label, env in envs.items():
                    with self.subTest(situation=situation, event=event, how=label, env=env_label):
                        code, stdout, stderr, delivered = run_command(argv, env, payload, cwd=cwd)
                        self.assertTrue(delivered, 'stdin을 다 읽지 않고 끝났다(agy는 EPIPE를 본다)')
                        self.assertEqual(code, 0, stderr)
                        self.assertEqual(stdout, answer_for(event) + '\n', '응답은 정확히 한 번')
                        self.assertEqual(stderr, '')

    def install(self, *flags, installer=None):
        script = (installer or ROOT / 'hooks') / 'install.sh'
        return subprocess.run(['bash', str(script), *flags], env=self.env(), text=True,
                              capture_output=True, timeout=20)

    def installed(self):
        return json.loads(self.hooks_json.read_text(encoding='utf-8'))

    def bundle(self):
        return self.installed()['my-dashboard']

    def backups(self):
        return sorted(self.hooks_json.parent.glob(f'{self.hooks_json.name}.bak.*'))

    def translation(self):
        contract = json.loads(CONTRACT.read_text(encoding='utf-8'))
        return contract['event_state_map']['antigravity_hook_translation']

    def commands(self):
        return [(event, handler['command']) for event, _, handler in bundle_handlers(self.bundle())]

    # ---------- registration content ----------

    def test_번들이_계약의_등록_규칙과_같다(self):
        result = self.install('--antigravity')
        self.assertEqual(result.returncode, 0, result.stderr)
        registration = self.translation()['registration']
        bundle = self.bundle()

        self.assertEqual(sorted(bundle), sorted(registration['events']))
        handlers = list(bundle_handlers(bundle))
        self.assertEqual(sorted(event for event, _, _ in handlers), sorted(registration['events']),
                         '이벤트마다 handler는 정확히 하나')
        for event, matcher, handler in handlers:
            self.assertEqual(matcher, registration['matchers'].get(event), event)
            self.assertEqual(set(handler), {'type', 'command', 'timeout'}, event)
            self.assertEqual(handler['type'], 'command')
            self.assertEqual(handler['timeout'], registration['timeout_seconds'], event)
        for event, entries in bundle.items():
            shape = [['hooks', 'matcher']] if event in registration['matchers'] else [['command', 'timeout', 'type']]
            self.assertEqual([sorted(entry) for entry in entries], shape, event)

    def test_질문_도구만_PreToolUse_matcher에_걸린다(self):
        self.install('--antigravity')
        translation = self.translation()
        matcher = translation['registration']['matchers']['PreToolUse']
        # agy의 matcher는 전체 일치 정규식이다(agy 1.2.12 실측: view_file은 걸리고 view_f는 안 걸린다).
        for tool in translation['question_tools']:
            self.assertIsNotNone(re.fullmatch(matcher, tool), tool)
        for other in ('run_command', 'view_file', 'ask_question_extra', 'my_ask_question', 'ask_', 'ask', ''):
            self.assertIsNone(re.fullmatch(matcher, other), other)

    def test_응답_문자열이_계약의_stdout_contract와_같다(self):
        contract = self.translation()['stdout_contract']
        self.assertEqual(json.loads(ANSWERS['PreToolUse']), contract['PreToolUse'])
        self.assertEqual(json.loads(ANSWERS['Stop']), contract['Stop'])
        self.assertEqual(json.loads(DEFAULT_ANSWER), contract['default'])
        # agy가 읽는 응답은 이 정확한 글자다(공백 없는 한 줄 JSON).
        self.assertEqual(ANSWERS['PreToolUse'], '{"decision":"ask"}')
        self.assertEqual(ANSWERS['Stop'], '{"decision":""}')
        self.assertEqual(DEFAULT_ANSWER, '{}')

    # ---------- writing the file ----------

    def test_파일이_없으면_폴더째_만들고_번들만_담는다(self):
        result = self.install('--antigravity')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.installed()), ['my-dashboard'])
        self.assertTrue(self.hooks_json.read_text().endswith('\n'))
        self.assertEqual(self.backups(), [], '원본이 없으니 백업도 없다')

    def test_다른_번들과_무관한_키는_값도_순서도_그대로_둔다(self):
        original = {
            'other-tool': {
                'PreToolUse': [{'matcher': '*', 'hooks': [{'type': 'command', 'command': 'other-tool PreToolUse',
                                                           'timeout': 10}]}],
                'Stop': [{'type': 'command', 'command': 'other-tool Stop', 'timeout': 10}],
            },
            '한글-번들': {'메모': '유니코드 보존', 'n': [1, 2.5, None, True]},
            'unrelated': 42,
        }
        self.hooks_json.parent.mkdir(parents=True)
        original_text = json.dumps(original, indent=2, ensure_ascii=False) + '\n'
        self.hooks_json.write_text(original_text, encoding='utf-8')

        result = self.install('--antigravity')
        self.assertEqual(result.returncode, 0, result.stderr)
        after = self.installed()
        self.assertEqual(list(after), [*original, 'my-dashboard'])
        for key, value in original.items():
            self.assertEqual(after[key], value, key)
        # 유니코드는 \\uXXXX로 바뀌지 않고 그대로 남는다.
        self.assertIn('유니코드 보존', self.hooks_json.read_text(encoding='utf-8'))
        backups = self.backups()
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(encoding='utf-8'), original_text)

    def test_두_번째_실행은_변경_없음이고_백업을_늘리지_않는다(self):
        self.hooks_json.parent.mkdir(parents=True)
        self.hooks_json.write_text('{"other-tool": {"Stop": []}}\n')
        first = self.install('--antigravity')
        self.assertEqual(first.returncode, 0, first.stderr)
        after_first = self.hooks_json.read_bytes()
        self.assertEqual(len(self.backups()), 1)

        second = self.install('--antigravity')
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn('변경 없음', second.stdout)
        self.assertNotIn('백업', second.stdout)
        self.assertEqual(self.hooks_json.read_bytes(), after_first)
        self.assertEqual(len(self.backups()), 1)

    def test_들여쓰기가_달라도_내용이_같으면_변경_없음이다(self):
        self.install('--antigravity')
        compact = json.dumps(self.installed(), separators=(',', ':'))
        self.hooks_json.write_text(compact)
        result = self.install('--antigravity')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('변경 없음', result.stdout)
        self.assertEqual(self.hooks_json.read_text(), compact, '의미가 같으면 다시 쓰지 않는다')
        self.assertEqual(self.backups(), [])

    def test_옛_my_dashboard_번들은_통째로_바뀌고_자리를_지킨다(self):
        self.hooks_json.parent.mkdir(parents=True)
        stale = {'Stop': [{'type': 'command', 'command': '/old/place/agent-event-hook.sh antigravity',
                           'timeout': 3}], 'SessionEnd': []}
        self.hooks_json.write_text(json.dumps({'first': 1, 'my-dashboard': stale, 'last': 2}))
        result = self.install('--antigravity')
        self.assertEqual(result.returncode, 0, result.stderr)
        after = self.installed()
        self.assertEqual(list(after), ['first', 'my-dashboard', 'last'])
        self.assertEqual((after['first'], after['last']), (1, 2))
        self.assertEqual(sorted(after['my-dashboard']),
                         sorted(self.translation()['registration']['events']), 'SessionEnd 같은 옛 키가 남지 않는다')
        self.assertNotIn('/old/place', json.dumps(after))

    def test_다른_경로에서_다시_설치하면_새_경로_하나만_남는다(self):
        first = self.make_installer('first', STUB_HOOK)
        second = self.make_installer('second', STUB_HOOK)
        self.assertEqual(self.install('--antigravity', installer=first).returncode, 0)
        self.assertEqual(self.install('--antigravity', installer=second).returncode, 0)
        self.assertEqual(list(self.installed()), ['my-dashboard'])
        commands = self.commands()
        self.assertEqual(len(commands), 4)
        for _, command in commands:
            self.assertEqual(os.path.realpath(shlex.split(command)[3]),
                             os.path.realpath(second / 'agent-event-hook.sh'))

    def test_심볼릭_링크인_hooks_json은_링크를_유지한_채_대상을_고친다(self):
        # dotfiles 관리 도구가 hooks.json을 링크로 두는 경우가 있다. 임시 파일로 바꿔치면 링크가 끊어진다.
        real = self.root / 'dotfiles/hooks.json'
        real.parent.mkdir()
        real.write_text('{"other-tool": {"Stop": []}}\n')
        self.hooks_json.parent.mkdir(parents=True)
        self.hooks_json.symlink_to(real)
        result = self.install('--antigravity')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.hooks_json.is_symlink())
        self.assertEqual(self.hooks_json.resolve(), real.resolve())
        self.assertEqual(list(json.loads(real.read_text())), ['other-tool', 'my-dashboard'])

    def test_기존_파일의_권한을_유지한다(self):
        self.hooks_json.parent.mkdir(parents=True)
        self.hooks_json.write_text('{}\n')
        self.hooks_json.chmod(0o600)
        self.assertEqual(self.install('--antigravity').returncode, 0)
        self.assertEqual(self.hooks_json.stat().st_mode & 0o777, 0o600)

    def test_출력_인코딩이_UTF8이_아니어도_한글_경로와_내용을_보존한다(self):
        installer = self.make_installer('설치 폴더', STUB_HOOK)
        self.hooks_json.parent.mkdir(parents=True)
        self.hooks_json.write_text(json.dumps({'한글-번들': {'메모': '유니코드 보존'}}, ensure_ascii=False),
                                   encoding='utf-8')
        result = subprocess.run(['bash', str(installer / 'install.sh'), '--antigravity'],
                                env=self.env(PYTHONIOENCODING='latin-1'), text=True, encoding='utf-8',
                                capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        after = self.installed()
        self.assertEqual(after['한글-번들'], {'메모': '유니코드 보존'})
        for _, command in self.commands():
            self.assertEqual(os.path.realpath(shlex.split(command)[3]),
                             os.path.realpath(installer / 'agent-event-hook.sh'))
        self.assertIn('설치 폴더', self.hooks_json.read_text(encoding='utf-8'), '경로가 \\uXXXX로 바뀌지 않는다')

    # ---------- refusing and previewing ----------

    def test_JSON_객체가_아니면_쓰지_않고_멈춘다(self):
        bom = b'\xef\xbb\xbf'
        cases = {'깨진 JSON': b'{', '배열': b'[]', 'null': b'null', '문자열': b'"str"', '숫자': b'42',
                 '뒤쪽 쉼표': b'{"a": 1,}', 'BOM과 깨진 JSON': bom + b'{', 'BOM과 배열': bom + b'[]',
                 'UTF-16 BOM': b'\xff\xfe{}',
                 # 느슨하게 읽으면 유효한 JSON이 돼 U+FFFD로 바뀐 채 다시 써질 파일이다.
                 'UTF-8이 아닌 바이트가 든 문자열': b'{"a": "\xff"}'}
        self.hooks_json.parent.mkdir(parents=True)
        for label, content in cases.items():
            with self.subTest(label):
                self.hooks_json.write_bytes(content)
                result = self.install('--antigravity')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(str(self.hooks_json), result.stderr)
                self.assertIn('손으로 고친 뒤', result.stderr)
                self.assertEqual(self.hooks_json.read_bytes(), content, '건드리지 않는다')
                self.assertEqual(self.backups(), [])

    def test_비어_있거나_공백뿐이거나_BOM뿐인_파일은_빈_객체로_보고_쓴다(self):
        # setup.sh는 마지막 단계에서 이 설치기를 부른다. 빈 파일 때문에 멈추면 설치가 거기서 끊긴다.
        cases = {'빈 파일': b'', '공백뿐': b'  \n\t\r\n', 'BOM뿐': b'\xef\xbb\xbf', 'BOM과 공백': b'\xef\xbb\xbf \n'}
        self.hooks_json.parent.mkdir(parents=True)
        for label, content in cases.items():
            with self.subTest(label):
                for old in self.backups():
                    old.unlink()
                self.hooks_json.write_bytes(content)
                result = self.install('--antigravity')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(list(self.installed()), ['my-dashboard'])
                self.assertEqual([backup.read_bytes() for backup in self.backups()], [content])

    def test_BOM이_붙은_파일도_읽어서_BOM_없이_다시_쓰고_다른_키를_지킨다(self):
        original = {'other-tool': {'Stop': [{'type': 'command', 'command': 'other-tool Stop', 'timeout': 10}]},
                    '한글-번들': {'메모': '유니코드 보존'}}
        original_bytes = b'\xef\xbb\xbf' + json.dumps(original, ensure_ascii=False).encode()
        self.hooks_json.parent.mkdir(parents=True)
        self.hooks_json.write_bytes(original_bytes)
        result = self.install('--antigravity')
        self.assertEqual(result.returncode, 0, result.stderr)
        after = self.installed()
        self.assertEqual(list(after), [*original, 'my-dashboard'])
        for key, value in original.items():
            self.assertEqual(after[key], value, key)
        written = self.hooks_json.read_bytes()
        self.assertFalse(written.startswith(b'\xef\xbb\xbf'), '쓸 때는 BOM을 붙이지 않는다')
        self.assertIn('유니코드 보존'.encode(), written)
        self.assertEqual([backup.read_bytes() for backup in self.backups()], [original_bytes],
                         '백업에는 원래 바이트가 그대로 남는다')

    def test_dry_run은_빈_파일과_BOM_파일도_그대로_두고_미리보기를_낸다(self):
        self.hooks_json.parent.mkdir(parents=True)
        for label, content in {'빈 파일': b'', 'BOM 파일': b'\xef\xbb\xbf{"a": 1}'}.items():
            with self.subTest(label):
                self.hooks_json.write_bytes(content)
                result = self.install('--dry-run')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('"PreInvocation"', result.stdout)
                self.assertEqual(self.hooks_json.read_bytes(), content)
                self.assertEqual(self.backups(), [])

    def test_dry_run은_없는_파일도_폴더도_만들지_않는다(self):
        for flags in (('--dry-run',), ()):
            with self.subTest(flags=flags):
                result = self.install(*flags)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('== Antigravity:', result.stdout)
                self.assertIn('--dry-run', result.stdout)
                self.assertIn('"PreInvocation"', result.stdout, '넣을 번들을 보여준다')
                self.assertFalse(self.hooks_json.exists())
                self.assertFalse(self.hooks_json.parent.exists())

    def test_dry_run은_있는_파일을_바꾸지_않고_백업도_남기지_않는다(self):
        self.hooks_json.parent.mkdir(parents=True)
        original = '{"other-tool": {"Stop": []}}\n'
        self.hooks_json.write_text(original)
        for flags in (('--dry-run',), ()):
            with self.subTest(flags=flags):
                result = self.install(*flags)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('"PreInvocation"', result.stdout)
                # 다른 번들의 내용까지 화면에 쏟지 않는다: 미리보기는 우리 번들만 보여준다.
                self.assertNotIn('other-tool', result.stdout.split('== Antigravity:')[1])
                self.assertEqual(self.hooks_json.read_text(), original)
                self.assertEqual(self.backups(), [])

    def test_이미_최신이면_dry_run도_변경_없음이라고_말한다(self):
        self.install('--antigravity')
        result = self.install('--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('변경 없음', result.stdout.split('== Antigravity:')[1])

    # ---------- flag dispatch ----------

    def test_대상_플래그는_서로의_파일을_건드리지_않는다(self):
        others = [self.root / 'claude/settings.json', self.root / 'codex/config.toml',
                  self.root / 'devin/config.json']
        self.assertEqual(self.install('--antigravity').returncode, 0)
        self.assertTrue(self.hooks_json.exists())
        for path in others:
            self.assertFalse(path.exists(), path)

        self.hooks_json.unlink()
        for flag, path in zip(('--claude', '--codex', '--devin'), others):
            self.assertEqual(self.install(flag).returncode, 0)
            self.assertTrue(path.exists(), flag)
            self.assertFalse(self.hooks_json.exists(), f'{flag}는 hooks.json을 건드리지 않는다')

    def test_네_대상을_한_번에_쓴다(self):
        result = self.install('--claude', '--codex', '--devin', '--antigravity')
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in (self.root / 'claude/settings.json', self.root / 'codex/config.toml',
                     self.root / 'devin/config.json', self.hooks_json):
            self.assertTrue(path.exists(), path)
        self.assertEqual(len(self.commands()), 4)

    def test_도움말이_antigravity_사용법을_끝까지_보여준다(self):
        result = self.install('--help')
        self.assertEqual(result.returncode, 0, result.stderr)
        # 도움말은 헤더 주석의 줄 범위를 그대로 출력한다. 범위가 짧으면 사용법이 잘리고 길면 코드가 섞인다.
        self.assertIn('bash hooks/install.sh --antigravity ', result.stdout)
        self.assertIn('~/.gemini/config/hooks.json만 실제로 쓴다', result.stdout)
        self.assertIn('bash hooks/install.sh --claude --codex --devin --antigravity ', result.stdout)
        self.assertNotIn('set -euo pipefail', result.stdout)
        self.assertFalse(self.hooks_json.exists())

    # ---------- the generated commands ----------

    def test_명령은_셸_없이_쪼개도_hook_경로가_한_인자로_남는다(self):
        installer = self.make_installer('split', STUB_HOOK)
        self.assertEqual(self.install('--antigravity', installer=installer).returncode, 0)
        hook = os.path.realpath(installer / 'agent-event-hook.sh')
        for event, command in self.commands():
            parts = shlex.split(command)
            self.assertEqual(len(parts), 4, event)
            self.assertEqual(parts[:2], ['/bin/sh', '-c'], event)
            self.assertEqual(os.path.realpath(parts[3]), hook, event)
            self.assertIn(f'antigravity {event};', parts[2], event)

    def test_hook이_있으면_source와_이벤트_이름을_넘기고_stdin과_stdout을_그대로_잇는다(self):
        self.assert_stub_hook_runs(self.make_installer('stub', STUB_HOOK))

    def test_hook_파일이_없거나_실행할_수_없으면_명령이_스스로_응답하고_stdin을_비우고_0으로_끝난다(self):
        # 두 번째 경우의 스크립트는 실행됐다면 exit 1로 agy를 멈췄을 것이다.
        installers = {
            '파일 없음': self.make_installer('missing'),
            '실행 권한 없음': self.make_installer('noexec', '#!/bin/sh\nexit 1\n', executable=False),
        }
        for situation, installer in installers.items():
            self.assertEqual(self.install('--antigravity', installer=installer).returncode, 0)
            # PATH가 비어도 command -p cat이 stdin을 비운다.
            self.assert_answers_by_itself(situation, {'PATH 그대로': self.hook_env(),
                                                      '빈 PATH': self.hook_env(PATH='')})

    def test_hook의_bash를_PATH에서_찾을_수_없으면_실행하지_않고_명령이_스스로_응답한다(self):
        # 스텁은 실행 권한이 있고 shebang이 실제 hook과 같은 `env bash`다. 그대로 exec하면 env가 127로
        # 끝나 셸이 폴백에 닿기 전에 죽고 agy 실행이 중단된다(PATH가 줄어든 환경에서 명령을 못 찾아
        # 셸이 폴백 전에 죽는 것과 같은 종류다).
        installer = self.make_installer('nobash', STUB_HOOK)
        self.assertEqual(self.install('--antigravity', installer=installer).returncode, 0)
        empty_cwd = self.root / 'empty-cwd'  # 빈 PATH는 현재 폴더를 뜻하므로 bash가 없는 폴더에서 돌린다
        empty_cwd.mkdir()
        tools = self.make_tools('tools-without-bash', with_bash=False)
        self.assert_answers_by_itself('bash 없음', {
            'PATH=/nonexistent': self.hook_env(PATH='/nonexistent'),
            'PATH=bash만 없는 도구 폴더': self.hook_env(PATH=str(tools)),
            'PATH가 빈 문자열': self.hook_env(PATH=''),
        }, cwd=empty_cwd)

    def test_같은_도구_폴더에_bash만_더하면_hook이_실행된다(self):
        # 위 테스트와 PATH의 도구가 같고 bash 하나만 다르다: 폴백은 bash를 찾을 수 없을 때만 나온다.
        tools = self.make_tools('tools-with-bash', with_bash=True)
        self.assertTrue((tools / 'bash').exists(), 'bash를 찾을 수 없는 환경에서는 이 테스트를 돌릴 수 없다')
        self.assert_stub_hook_runs(self.make_installer('withbash', STUB_HOOK), PATH=str(tools))

    # exec하면 응답 없이 끝나는 hook 경로들: 아래 셋은 모두 exec 앞에서 걸러져 명령이 스스로 응답해야 한다.

    def test_hook_경로가_디렉터리면_명령이_스스로_응답한다(self):
        # 디렉터리는 -x가 참이지만 exec하면 126으로 끝난다.
        installer = self.make_installer('dir')
        (installer / 'agent-event-hook.sh').mkdir()
        self.assertEqual(self.install('--antigravity', installer=installer).returncode, 0)
        self.assert_answers_by_itself('디렉터리', {'PATH 그대로': self.hook_env()})

    @unittest.skipIf(os.geteuid() == 0, 'root는 모드 0111 파일도 읽을 수 있어 이 상황을 만들 수 없다')
    def test_hook을_읽을_수_없으면_명령이_스스로_응답한다(self):
        # 실행 권한만 있는 스크립트는 kernel이 띄우지만 bash가 스크립트를 읽지 못해 126으로 끝난다.
        installer = self.make_installer('unreadable', STUB_HOOK, mode=0o111)
        self.assertEqual(self.install('--antigravity', installer=installer).returncode, 0)
        self.assert_answers_by_itself('모드 0111', {'PATH 그대로': self.hook_env()})

    def test_hook이_빈_실행_파일이면_명령이_스스로_응답한다(self):
        # 빈 실행 파일을 exec하면 아무것도 출력하지 않고 끝나 agy가 PreToolUse를 거부한다.
        installer = self.make_installer('empty', '')
        self.assertEqual(self.install('--antigravity', installer=installer).returncode, 0)
        self.assert_answers_by_itself('빈 파일', {'PATH 그대로': self.hook_env()})

    def test_BASH_ENV가_출력하거나_exit해도_hook의_stdout과_종료_코드에_끼어들지_못한다(self):
        # bash는 스크립트 첫 줄보다 먼저 $BASH_ENV 파일을 실행한다. 거기서 나온 출력이 응답 앞에 붙거나
        # exit가 응답을 막지 못하도록 명령이 exec 직전에 BASH_ENV를 지운다.
        installer = self.make_installer('bashenv', STUB_HOOK)
        for label, content in {'출력': 'echo junk\n', 'exit': 'echo junk\nexit 7\n'}.items():
            with self.subTest(label):
                bash_env = self.root / f'{label}.env'
                bash_env.write_text(content)
                self.assert_stub_hook_runs(installer, BASH_ENV=str(bash_env))

    def assert_real_hook_answers(self, **env):
        """The repo's real hooks/agent-event-hook.sh, run through every installed command, prints
        only the answer the contract prescribes and exits 0.

        MY_DASHBOARD_ENV is an empty file, so the hook sends nothing, and its state dir is a temp dir.
        """
        result = self.install('--antigravity')
        self.assertEqual(result.returncode, 0, result.stderr)
        contract = self.translation()['stdout_contract']
        env = self.hook_env(**env)
        for event, command in self.commands():
            payload = json.dumps(PAYLOADS[event]).encode()
            expected = contract.get(event, contract['default'])
            for label, argv in (('sh -c', ['/bin/sh', '-c', command]), ('shlex', shlex.split(command))):
                with self.subTest(event=event, how=label):
                    code, stdout, stderr, delivered = run_command(argv, env, payload)
                    self.assertEqual(code, 0, stderr)
                    self.assertTrue(delivered)
                    # 계약이 정한 JSON 그 글자만 나와야 한다(줄바꿈 하나는 허용).
                    self.assertEqual(stdout.rstrip('\n'), json.dumps(expected, separators=(',', ':')))
                    self.assertEqual(json.loads(stdout), expected)

    def test_실제_hook은_같은_응답만_stdout에_내고_0으로_끝난다(self):
        self.assert_real_hook_answers()

    def test_BASH_ENV가_출력하거나_exit해도_실제_hook의_응답은_그대로다(self):
        # 이 상황에서 BASH_ENV가 살아 있으면 PreToolUse의 stdout이 `junk\n{"decision":"ask"}`가 돼
        # agy가 JSON으로 읽지 못하고 도구를 거부한다.
        for label, content in {'출력': 'echo junk\n', 'exit': 'echo junk\nexit 7\n'}.items():
            with self.subTest(label):
                bash_env = self.root / f'{label}.env'
                bash_env.write_text(content)
                self.assert_real_hook_answers(BASH_ENV=str(bash_env))
