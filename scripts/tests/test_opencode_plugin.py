"""hooks/opencode-plugin.mjs의 순수 번역 함수 translate()를 node로 돌려 계약 규칙과 대조한다.

픽스처(fixtures/opencode-events.json)는 OpenCode 2.0.31 실측 로그에서 세션 ID·경로·식별자만 익명화해
뽑은 실제 이벤트열이다. 한 프로세스에 location마다 인스턴스가 하나씩 생기고 모두 같은 이벤트를 받는
실측 조건을 그대로 재현하려고, 여러 ownDir 인스턴스가 레지스트리 하나를 공유한 채 같은 이벤트열을
차례로 번역한다.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / 'hooks' / 'opencode-plugin.mjs'
FIXTURE = Path(__file__).resolve().parent / 'fixtures' / 'opencode-events.json'
CONTRACT = ROOT / 'contracts' / 'dashboard-protocol.v1.json'

# 이벤트열을 인스턴스(ownDir)마다 번역해 {ownDir: [payload...]} 로 낸다. 레지스트리는 공유한다.
REPLAY = """
const { translate, createRegistry } = await import(process.argv[1]);
const { events, dirs } = JSON.parse(process.argv[2]);
const registry = createRegistry();
const out = Object.fromEntries(dirs.map((d) => [d, []]));
for (const event of events) {
  for (const dir of dirs) {
    for (const payload of translate(event, registry, dir)) out[dir].push(payload);
  }
}
console.log(JSON.stringify({ out, registry: Object.fromEntries(registry) }));
"""


def replay(events, dirs):
    result = subprocess.run(
        ['node', '--input-type=module', '-e', REPLAY, PLUGIN.as_uri(), json.dumps({'events': events, 'dirs': dirs})],
        text=True, capture_output=True, timeout=30)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def summary(payloads):
    return [(p['hook_event_name'], p['session_id']) for p in payloads]


@unittest.skipUnless(shutil.which('node'), 'node가 없으면 플러그인 번역을 돌릴 수 없다')
class OpenCodeTranslateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = json.loads(FIXTURE.read_text(encoding='utf-8'))
        cls.translation = json.loads(CONTRACT.read_text(encoding='utf-8'))['event_state_map']['opencode_plugin_translation']

    # ---------- 실측 이벤트열 재생 ----------

    def test_공유_서버_재생_인스턴스마다_자기_location_세션만_한_번씩_보낸다(self):
        events = self.fixture['probe2_shared_server']
        dirs = ['/workspace/server-cwd', '/workspace/alpha', '/workspace/beta']
        result = replay(events, dirs)
        out = result['out']
        # 같은 이벤트를 세 인스턴스가 다 받지만 세션의 location 인스턴스 하나만 보낸다.
        for dir_, payloads in out.items():
            for payload in payloads:
                self.assertEqual(payload['cwd'], dir_, payload)
        all_ids = [p['opencode']['event_id'] for payloads in out.values() for p in payloads
                   if p['hook_event_name'] != 'SessionEnd']
        self.assertEqual(len(all_ids), len(set(all_ids)), '같은 이벤트가 두 인스턴스에서 나갔다')

        alpha = summary(out['/workspace/alpha'])
        self.assertEqual(alpha[:5], [('UserPromptSubmit', 'ses_01'), ('PostToolUse', 'ses_01'), ('Stop', 'ses_01'),
                                     ('UserPromptSubmit', 'ses_04'), ('PostToolUse', 'ses_04')])
        self.assertIn(('UserInputRequest', 'ses_04'), alpha)
        self.assertIn(('UserInputResolved', 'ses_04'), alpha)
        self.assertEqual(alpha.index(('UserInputRequest', 'ses_04')) + 1, alpha.index(('UserInputResolved', 'ses_04')))
        # 질문 도구 form: 생성→답, 생성→취소 둘 다 대기·해소 한 쌍씩.
        form_events = [p for p in out['/workspace/alpha'] if p['session_id'] == 'ses_05'
                       and p['hook_event_name'] in ('UserInputRequest', 'UserInputResolved')]
        self.assertEqual([p['hook_event_name'] for p in form_events],
                         ['UserInputRequest', 'UserInputResolved', 'UserInputRequest', 'UserInputResolved'])
        self.assertEqual([p['opencode']['type'] for p in form_events],
                         ['form.created', 'form.replied', 'form.created', 'form.cancelled'])
        self.assertEqual(form_events[0]['message'], 'Which do you prefer: red or blue?')
        self.assertEqual(form_events[2]['message'], 'Which do you prefer: cats or dogs?')
        self.assertNotIn('message', form_events[1])
        # 세션 삭제 → SessionEnd 는 그 세션의 location 인스턴스에서 한 번.
        self.assertEqual(alpha.count(('SessionEnd', 'ses_01')), 1)
        self.assertEqual(summary(out['/workspace/server-cwd']), [('SessionEnd', 'ses_03')],
                         '서버 cwd 의 세션은 생성만 되고 삭제됐다 - SessionEnd 하나. 다른 location 의 shutdown 은 무시')
        beta = summary(out['/workspace/beta'])
        self.assertEqual(beta, [('UserPromptSubmit', 'ses_02'), ('PostToolUse', 'ses_02'), ('Stop', 'ses_02')])
        # 자기 location 의 shutdown 만: server-cwd 의 shutdown 은 alpha·beta 세션을 끝내지 않는다.
        self.assertNotIn(('SessionEnd', 'ses_04'), alpha)
        self.assertNotIn(('SessionEnd', 'ses_02'), beta)

    def test_standalone_재생_루트_created_없이도_소유_판정과_shutdown_종료가_된다(self):
        events = self.fixture['probe1_standalone']
        out = replay(events, ['/workspace/alpha'])['out']['/workspace/alpha']
        by_session = {}
        for payload in out:
            by_session.setdefault(payload['session_id'], []).append(payload)
        # S1: 단순 턴. 루트 created 를 못 봐도 inbox.enqueued 가 맵을 채워 execution.started 가 UserPromptSubmit 이 된다.
        self.assertEqual([p['hook_event_name'] for p in by_session['ses_06']],
                         ['UserPromptSubmit', 'PostToolUse', 'Stop', 'SessionEnd'])
        self.assertEqual(by_session['ses_06'][0]['prompt'], '"Reply with exactly the word pong."')
        self.assertEqual(by_session['ses_06'][-1]['opencode']['type'], 'location.shutdown')
        # S3: run 모드 자동 reject - 모델이 shell 을 세 번 시도해 권한 대기·해소가 쌍으로 세 번(실측).
        s3 = [p['hook_event_name'] for p in by_session['ses_09'] if p['hook_event_name'].startswith('UserInput')]
        self.assertEqual(s3, ['UserInputRequest', 'UserInputResolved'] * 3)
        first_ask = next(p for p in by_session['ses_09'] if p['hook_event_name'] == 'UserInputRequest')
        self.assertEqual(first_ask['message'], 'shell: echo hi')
        self.assertEqual(first_ask['opencode']['type'], 'permission.asked')
        # S5: 서브에이전트. 자식(ses_11)의 execution·하트비트·succeeded 는 안 나가고 부모(ses_10)만 상태를 가진다.
        self.assertNotIn('ses_11', by_session)
        parent = [p['hook_event_name'] for p in by_session['ses_10']]
        self.assertEqual(parent[0], 'UserPromptSubmit')
        self.assertEqual(parent.count('Stop'), 1)
        self.assertEqual(parent[-1], 'SessionEnd')
        # S6: standalone SIGINT - Stop 없이 location.shutdown 의 SessionEnd 만.
        self.assertEqual([p['hook_event_name'] for p in by_session['ses_12']],
                         ['UserPromptSubmit', 'PostToolUse', 'SessionEnd'])
        # S6b/S10(공유 서비스): interrupted·failed 도 Stop 이고 이유가 메타에 남는다.
        stops = {sid: [p for p in ps if p['hook_event_name'] == 'Stop'] for sid, ps in by_session.items()}
        self.assertEqual(stops['ses_15'][0]['opencode'], {'type': 'session.execution.interrupted',
                                                           'event_id': stops['ses_15'][0]['opencode']['event_id'],
                                                           'reason': 'user'})
        self.assertEqual(stops['ses_16'][0]['opencode']['error_type'], 'provider.auth')
        # S8b: 이미 shutdown 으로 끝난 standalone 세션을 공유 서비스에서 지우면 SessionEnd 를 또 보내지 않는다.
        self.assertEqual([p['hook_event_name'] for p in by_session['ses_10']].count('SessionEnd'), 1)
        # 하트비트는 이름만 PostToolUse 고 어떤 상태 이벤트 이름도 아니다.
        for payload in out:
            self.assertIn(payload['hook_event_name'],
                          {'UserPromptSubmit', 'UserInputRequest', 'UserInputResolved', 'PostToolUse', 'Stop', 'SessionEnd'})
            self.assertEqual(payload['cwd'], '/workspace/alpha')

    # ---------- 규칙 단위 ----------

    def event(self, type_, data, location=None, id_='evt_x'):
        event = {'id': id_, 'created': 0, 'type': type_, 'data': data}
        if location:
            event['location'] = {'directory': location}
        return event

    def test_location_없는_이벤트는_레지스트리에_없으면_버린다(self):
        out = replay([self.event('session.execution.started', {'sessionID': 'ses_a'})], ['/w'])['out']['/w']
        self.assertEqual(out, [])

    def test_자식_세션의_대기와_해소만_루트_세션_ID로_올라간다(self):
        own = '/w'
        events = [
            self.event('session.inbox.enqueued', {'sessionID': 'ses_root', 'item': {'payload': {'text': 'parent prompt'}}}, own),
            self.event('session.execution.started', {'sessionID': 'ses_root'}),
            self.event('session.created', {'sessionID': 'ses_child', 'parentID': 'ses_root', 'location': {'directory': own}}, own),
            self.event('session.created', {'sessionID': 'ses_grandchild', 'parentID': 'ses_child', 'location': {'directory': own}}, own),
            self.event('session.inbox.enqueued', {'sessionID': 'ses_grandchild', 'item': {'payload': {'text': 'child prompt'}}}, own),
            self.event('session.execution.started', {'sessionID': 'ses_grandchild'}),
            self.event('session.step.started', {'sessionID': 'ses_grandchild'}, own),
            self.event('permission.asked', {'id': 'per_1', 'sessionID': 'ses_grandchild', 'action': 'shell', 'resources': ['rm -rf x', 'y']}, own),
            self.event('permission.replied', {'sessionID': 'ses_grandchild', 'requestID': 'per_1', 'reply': 'reject'}, own),
            self.event('form.created', {'form': {'id': 'frm_1', 'sessionID': 'ses_child', 'title': 'Questions',
                                                 'metadata': {'kind': 'question'}, 'fields': [{'title': 'H', 'description': 'Q?'}]}}, own),
            self.event('form.replied', {'id': 'frm_1', 'sessionID': 'ses_child', 'answer': {'q0': 'A'}}, own),
            self.event('session.execution.failed', {'sessionID': 'ses_grandchild', 'error': {'type': 'x'}}),
            self.event('session.deleted', {'sessionID': 'ses_grandchild'}),
            self.event('session.execution.succeeded', {'sessionID': 'ses_root'}),
            self.event('location.shutdown', {}, own),
        ]
        out = replay(events, [own])['out'][own]
        self.assertEqual(summary(out), [
            ('UserPromptSubmit', 'ses_root'),
            ('UserInputRequest', 'ses_root'), ('UserInputResolved', 'ses_root'),
            ('UserInputRequest', 'ses_root'), ('UserInputResolved', 'ses_root'),
            ('Stop', 'ses_root'), ('SessionEnd', 'ses_root'),
        ])
        self.assertEqual(out[0]['prompt'], 'parent prompt')
        self.assertEqual(out[1]['message'], 'shell: rm -rf x, y')
        self.assertEqual(out[1]['opencode'], {'type': 'permission.asked', 'event_id': 'evt_x', 'request_id': 'per_1',
                                              'child_session_id': 'ses_grandchild', 'parent_session_id': 'ses_child'})
        self.assertEqual(out[2]['opencode']['reply'], 'reject')
        self.assertEqual(out[3]['message'], 'Q?')
        self.assertEqual(out[3]['opencode']['form_kind'], 'question')
        self.assertEqual(out[4]['opencode']['form_id'], 'frm_1')

    def test_프롬프트는_가장_최근_inbox_300자이고_없으면_키가_없다(self):
        own = '/w'
        long = 'x' * 400
        events = [
            self.event('session.inbox.enqueued', {'sessionID': 'ses_a', 'item': {'payload': {'text': 'first'}}}, own),
            self.event('session.inbox.enqueued', {'sessionID': 'ses_a', 'item': {'payload': {'text': long}}}, own),
            self.event('session.execution.started', {'sessionID': 'ses_a'}),
            self.event('session.step.started', {'sessionID': 'ses_b'}, own),
            self.event('session.execution.started', {'sessionID': 'ses_b'}),
        ]
        out = replay(events, [own])['out'][own]
        self.assertEqual(out[0]['prompt'], 'x' * 300)
        self.assertEqual(summary(out[1:]), [('PostToolUse', 'ses_b'), ('UserPromptSubmit', 'ses_b')])
        self.assertNotIn('prompt', out[2])

    def test_모든_form은_kind와_상관없이_대기이고_메시지는_description_title_순이다(self):
        own = '/w'
        events = [
            self.event('form.created', {'form': {'id': 'frm_1', 'sessionID': 'ses_a', 'title': 'Setup',
                                                 'metadata': {'kind': 'other'}, 'fields': [{'title': 'Only title'}]}}, own),
            self.event('form.created', {'form': {'id': 'frm_2', 'sessionID': 'ses_a', 'title': 'Fallback title',
                                                 'fields': []}}, own),
            self.event('form.cancelled', {'id': 'frm_2', 'sessionID': 'ses_a'}, own),
        ]
        out = replay(events, [own])['out'][own]
        self.assertEqual(summary(out), [('UserInputRequest', 'ses_a'), ('UserInputRequest', 'ses_a'), ('UserInputResolved', 'ses_a')])
        self.assertEqual([p.get('message') for p in out], ['Only title', 'Fallback title', None])

    def test_하트비트와_Stop_표는_계약과_같고_그_밖의_이벤트는_버린다(self):
        own = '/w'
        events = [self.event('session.inbox.enqueued', {'sessionID': 'ses_a', 'item': {'payload': {'text': 'p'}}}, own)]
        for type_ in self.translation['heartbeat_types']:
            events.append(self.event(type_, {'sessionID': 'ses_a'}, own))
        for type_ in ('session.renamed', 'session.step.ended', 'session.text.delta', 'session.tool.progress',
                      'session.instructions.updated', 'shell.created'):
            events.append(self.event(type_, {'sessionID': 'ses_a'}, own))
        for type_ in ('session.usage.updated', 'worktree.resolved'):
            events.append(self.event(type_, {'sessionID': 'ses_a'}))
        for type_ in self.translation['stop_types']:
            events.append(self.event(type_, {'sessionID': 'ses_a'}))
        out = replay(events, [own])['out'][own]
        self.assertEqual([p['hook_event_name'] for p in out],
                         ['PostToolUse'] * len(self.translation['heartbeat_types']) + ['Stop'] * len(self.translation['stop_types']))
        self.assertEqual([p['opencode']['type'] for p in out],
                         self.translation['heartbeat_types'] + self.translation['stop_types'])

    def test_깨진_입력에도_throw하지_않는다(self):
        events = [None, 1, 'x', {}, {'type': 5}, {'type': 'session.execution.started'},
                  {'type': 'session.execution.started', 'data': None},
                  {'type': 'form.created', 'data': {'form': 'nope'}, 'location': {'directory': '/w'}},
                  {'type': 'permission.asked', 'data': {'sessionID': 'ses_a', 'resources': 'not-a-list'}, 'location': {'directory': '/w'}},
                  {'type': 'location.shutdown', 'location': 'not-an-object'}]
        out = replay(events, ['/w'])['out']['/w']
        self.assertEqual(summary(out), [('UserInputRequest', 'ses_a')])
        self.assertEqual(out[0]['message'], 'permission')

    # ---------- setup(api) 통합 ----------

    def test_setup은_구독을_소비해_hook을_실행하고_정리_함수가_구독을_끊는다(self):
        with tempfile.TemporaryDirectory() as temporary:
            # hook 은 호출마다 따로 떠서(unref, 기다리지 않음) 동시에 돌 수 있으므로 호출마다 파일 하나씩 남긴다.
            calls = Path(temporary) / 'calls'
            calls.mkdir()
            hook = Path(temporary) / 'agent-event-hook.sh'
            hook.write_text('#!/usr/bin/env bash\n{ printf "%s|" "$1"; cat; } > "$CALLS/$$.tmp" && mv "$CALLS/$$.tmp" "$CALLS/$$.done"\n')
            hook.chmod(0o755)
            script = """
const { setup } = await import(process.argv[1]);
const events = [
  { id: "evt_1", type: "session.inbox.enqueued", location: { directory: "/w" }, data: { sessionID: "ses_a", item: { payload: { text: "hi" } } } },
  { id: "evt_2", type: "session.execution.started", data: { sessionID: "ses_a" } },
  { id: "evt_3", type: "session.execution.succeeded", data: { sessionID: "ses_a" } },
];
let aborted = false;
const api = {
  location: { directory: "/w" },
  event: {
    subscribe({ signal }) {
      signal.addEventListener("abort", () => { aborted = true; });
      return (async function* () { for (const e of events) yield e; await new Promise((r) => setTimeout(r, 50)); })();
    },
  },
};
const dispose = setup(api, { hookScript: process.argv[2], registry: new Map() });
await new Promise((r) => setTimeout(r, 400));
dispose();
console.log(JSON.stringify({ aborted }));
"""
            result = subprocess.run(['node', '--input-type=module', '-e', script, PLUGIN.as_uri(), str(hook)],
                                    env={**os.environ, 'CALLS': str(calls)}, text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout.strip().splitlines()[-1]), {'aborted': True})
            # 플러그인은 hook 을 기다리지 않으므로 node 가 끝난 뒤에도 hook 이 아직 쓰는 중일 수 있다.
            deadline = time.monotonic() + 5
            while len(list(calls.glob('*.done'))) < 2 and time.monotonic() < deadline:
                time.sleep(0.05)
            lines = sorted(path.read_text() for path in calls.glob('*.done'))
            self.assertEqual(len(lines), 2)
            for line in lines:
                source, body = line.split('|', 1)
                self.assertEqual(source, 'opencode')
                json.loads(body)
            self.assertEqual(sorted(json.loads(l.split('|', 1)[1])['hook_event_name'] for l in lines), ['Stop', 'UserPromptSubmit'])

    def test_default_export는_id와_setup만_내보내고_hook_경로는_자기_옆_스크립트다(self):
        script = """
const { default: plugin, DEFAULT_HOOK_SCRIPT } = await import(process.argv[1]);
console.log(JSON.stringify({ keys: Object.keys(plugin), id: plugin.id, hook: DEFAULT_HOOK_SCRIPT }));
"""
        result = subprocess.run(['node', '--input-type=module', '-e', script, PLUGIN.as_uri()],
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        info = json.loads(result.stdout)
        self.assertEqual(info['keys'], ['id', 'setup'])
        self.assertEqual(info['id'], 'my-dashboard')
        self.assertEqual(Path(info['hook']), PLUGIN.parent / 'agent-event-hook.sh')


if __name__ == '__main__':
    unittest.main()
