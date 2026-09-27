import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/window_connection.dart';

const _host = 'work-mac';
const _project = '/work/my-dashboard';
const _bundleId = 'com.microsoft.VSCode';

WindowCandidate _window(String title, {String bundleId = _bundleId}) =>
    WindowCandidate(
      token: title,
      bundleId: bundleId,
      appName: 'Visual Studio Code',
      title: title,
    );

void main() {
  test('같은 호스트와 전체 경로면 에이전트와 세션이 달라도 연결을 공유한다', () {
    const codex = SessionViewDto(
      key: 'codex:first',
      state: 'working',
      source: 'codex',
      sessionId: 'first',
      host: _host,
      project: _project,
    );
    final claude = codex.copyWith(
      key: 'claude:second',
      source: 'claude',
      sessionId: 'second',
    );

    final first = WindowConnectionKey.fromSession(codex)!;
    final second = WindowConnectionKey.fromSession(claude)!;
    expect(first, second);
    expect({first, second}, hasLength(1));
  });

  test('표시 이름이 같아도 전체 경로나 호스트가 다르면 연결을 분리한다', () {
    final first = WindowConnectionKey(
      host: _host,
      project: '/work/a/dashboard',
    );
    final second = WindowConnectionKey(
      host: _host,
      project: '/work/b/dashboard',
    );
    final remote = WindowConnectionKey(host: 'remote', project: first.project);

    expect({first, second, remote}, hasLength(3));
  });

  test('식별 정보가 없으면 공유 연결을 만들지 않는다', () {
    const session = SessionViewDto(
      key: 'codex:first',
      state: 'working',
      project: _project,
    );
    expect(WindowConnectionKey.fromSession(session), isNull);
    expect(
      WindowConnectionKey.fromSession(session.copyWith(host: '  ')),
      isNull,
    );
    expect(
      WindowConnectionKey.fromSession(
        session.copyWith(host: _host, project: ' '),
      ),
      isNull,
    );
    expect(
      () => WindowConnectionKey(host: '', project: _project),
      throwsFormatException,
    );
  });

  test('호스트 공백만 정리하고 전체 경로의 공백과 별칭을 보존한다', () {
    final key = WindowConnectionKey(host: ' $_host ', project: ' $_project ');
    expect(key, WindowConnectionKey(host: _host, project: ' $_project '));
    expect(key, isNot(WindowConnectionKey(host: _host, project: _project)));
    expect(
      key,
      isNot(WindowConnectionKey(host: _host.toUpperCase(), project: _project)),
    );
    expect(key, isNot(WindowConnectionKey(host: _host, project: '$_project/')));
    expect(
      key,
      isNot(
        WindowConnectionKey(host: _host, project: '/work/a/../my-dashboard'),
      ),
    );
  });

  test('포함 규칙은 같은 앱의 대소문자를 구분하는 리터럴 문자열만 찾는다', () {
    final rule = WindowConnectionRule(
      key: WindowConnectionKey(host: _host, project: _project),
      bundleId: _bundleId,
      titlePattern: '[my-dashboard]',
    );
    expect(rule.matches(_window('README — [my-dashboard]')), isTrue);
    expect(rule.matches(_window('README — my-dashboard')), isFalse);
    expect(rule.matches(_window('README — [MY-DASHBOARD]')), isFalse);
    expect(
      rule.matches(_window('[my-dashboard]', bundleId: 'com.example.other')),
      isFalse,
    );
  });

  test('정확한 제목 규칙은 접두사와 접미사가 붙은 창을 제외한다', () {
    final rule = WindowConnectionRule(
      key: WindowConnectionKey(host: _host, project: _project),
      bundleId: _bundleId,
      titlePattern: 'my-dashboard',
      exactTitle: true,
    );
    expect(rule.matches(_window('my-dashboard')), isTrue);
    expect(rule.matches(_window('README — my-dashboard')), isFalse);
    expect(WindowConnectionRule.fromJson(rule.toJson()), rule);
    expect(rule.toJson(), isNot(contains('token')));
  });

  test('빈 제목 조건과 잘못된 JSON 형식은 규칙으로 허용하지 않는다', () {
    final key = WindowConnectionKey(host: _host, project: _project);
    expect(
      () => WindowConnectionRule(
        key: key,
        bundleId: _bundleId,
        titlePattern: ' ',
      ),
      throwsFormatException,
    );
    expect(
      () => WindowConnectionRule.fromJson({
        'key': key.toJson(),
        'bundleId': _bundleId,
        'titlePattern': 'my-dashboard',
        'exactTitle': 'false',
      }),
      throwsFormatException,
    );
  });

  test('추천은 이름 경계를 확인하고 비슷한 프로젝트와 정규식 문자를 구분한다', () {
    final key = WindowConnectionKey(host: _host, project: _project);
    final exact = _window('my-dashboard');
    final file = _window('README — my-dashboard — Visual Studio Code');
    final longer = _window('my-dashboard-backup');
    final prefixed = _window('old-my-dashboard');
    final unicode = _window('가my-dashboard나');
    expect(
      windowSuggestionsFor(key, [exact, file, longer, prefixed, unicode]),
      [exact, file],
    );

    final regexName = WindowConnectionKey(
      host: _host,
      project: '/work/project[1]',
    );
    final literal = _window('README — project[1]');
    expect(windowSuggestionsFor(regexName, [literal, _window('project1')]), [
      literal,
    ]);
  });

  test('네이티브 조회 결과의 권한과 완전성 및 최소화 상태를 보존한다', () {
    final scan = WindowScan.fromMap({
      'trusted': true,
      'complete': false,
      'localHost': _host,
      'windows': [
        {
          'token': 'volatile-token',
          'bundleId': _bundleId,
          'appName': 'Visual Studio Code',
          'title': 'my-dashboard',
          'minimized': true,
        },
      ],
    });
    expect(scan.trusted, isTrue);
    expect(scan.complete, isFalse);
    expect(scan.localHost, _host);
    expect(scan.windows.single.minimized, isTrue);
    expect(() => scan.windows.clear(), throwsUnsupportedError);
  });

  test('잘못된 조회 항목을 건너뛰며 완전한 결과인 것처럼 취급하지 않는다', () {
    expect(
      () => WindowScan.fromMap({
        'trusted': true,
        'complete': true,
        'localHost': _host,
        'windows': [null],
      }),
      throwsFormatException,
    );
  });
}
