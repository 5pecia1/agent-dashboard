/// 실물 실행 QA — 설정 화면이 저장한 서버 주소와 토큰이 재시작 없이 쓰이는지
/// 실제 바이너리(`app.main()`)로 확인한다. 위젯 테스트
/// (`first_run_sync_config_test.dart`)는 가짜 전송과 가짜 타이머를 쓴다 —
/// 여기서는 실제 `HttpClient`가 실제 루프백 소켓으로 요청하고, 가짜 서버
/// ([QaFakeServer])가 받은 요청을 `Authorization` 헤더와 `since` 그대로 남긴다.
/// 실제 타이머, 실제 설정 파일, macOS push 등록 경로도 탄다.
///
/// 시나리오(`MY_DASHBOARD_QA_SCENARIO`):
///   - `first_run`: 빈 임시 HOME으로 부팅해 설정 화면에서 주소와 토큰을 저장한다.
///     첫 sync 요청이 그 토큰으로 서버에 닿고, 세션 목록이 오류 덤프 없이
///     보이고, 다음 폴링도 같은 연결로 이어진다.
///   - `change_server`: 서버 A로 동기화하던 앱이 설정 화면에서 서버 B와 새
///     토큰으로 바꾼다. 다음 요청은 B로, 새 토큰으로, 옛 커서 없이 나가고
///     A의 세션은 사라진다. 이어서 B가 토큰을 바꿔 401로 멈춘 앱이 설정
///     화면에서 토큰을 고쳐 저장하면 "다시 시도" 없이 복구된다.
///
/// 언어(`MY_DASHBOARD_QA_LANG`): `en`, `ko`. `change_server`는 저장된
/// `ui_lang`과 서버의 `ui_lang`이다. `first_run`은 저장된 설정이 없으니 시스템
/// 로케일을 따른다 — `ko`면 테스트 바인딩의 플랫폼 로케일을 `ko_KR`로 바꿔
/// 한국어 시스템의 첫 실행을 흉내 내고(OS 설정은 건드리지 않는다), `en`이면
/// 실제 시스템 로케일 그대로다(영어가 아니면 이 시나리오는 실패로 알린다).
///
/// ```sh
/// T="$(mktemp -d)" && touch "$T/.my-dashboard-qa-home"
/// HOME="$T" MY_DASHBOARD_QA_SCENARIO=first_run MY_DASHBOARD_QA_LANG=en \
///   MY_DASHBOARD_QA_OUT=/tmp/qa \
///   flutter drive --profile --no-pub -d macos \
///     --target integration_test/sync_config_qa_test.dart \
///     --driver test_driver/sync_qa_driver.dart
/// ```
///
/// 가드와 부작용은 `sync_qa_support.dart` 머리말을 따른다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart' show kPushConfigPath;
import 'package:my_dashboard/src/ui/sessions_page.dart' show SessionsPage;
import 'package:my_dashboard/src/ui/setup_page.dart' show SetupPage;
import 'package:my_dashboard/src/ui/widgets/alert_banner.dart'
    show NeedsSetupBanner, StaleDataBanner;

import 'sync_qa_support.dart';

const String _kFirstRun = 'first_run';
const String _kChangeServer = 'change_server';
const List<String> _kScenarios = <String>[_kFirstRun, _kChangeServer];

/// 실제 자격증명이 아닌 토큰들.
const String _kTokenFirst = 'qa-token-first-run';
const String _kTokenA = 'qa-token-server-a';
const String _kTokenB = 'qa-token-server-b';
const String _kTokenBRotated = 'qa-token-server-b-rotated';

const int _kCursorFirst = 10;
const int _kCursorA = 10;
const int _kCursorB = 50;
const QaSession _kFirstSession = QaSession(
  id: 'first-run',
  message: 'QA session on the first server',
);
const QaSession _kSessionA = QaSession(
  id: 'server-a',
  message: 'QA session on server A',
);
const QaSession _kSessionB = QaSession(
  id: 'server-b',
  message: 'QA session on server B',
);

/// 한국어 시스템의 첫 실행을 흉내 내는 플랫폼 로케일.
const Locale _kKoreanSystemLocale = Locale(kKorean, 'KR');

/// `app-core/src/i18n.rs`의 문구 그대로: 설정 화면 제목(`setup.title`),
/// 저장(`action.save`), 저장 완료(`setup.save_success`), 첫 부팅 오류 제목
/// (`session.list.error.title`), 설정 필요 배너 제목과 버튼
/// (`alert.banner.needs_setup.*`).
const Map<String, String> _kSetupTitle = {kEnglish: 'Setup', kKorean: '설정'};
const Map<String, String> _kSave = {kEnglish: 'Save', kKorean: '저장'};
const Map<String, String> _kSaved = {kEnglish: 'Saved.', kKorean: '저장했습니다.'};

/// 쓸 수 없는 주소를 저장했을 때의 문구(`setup.server_url_invalid`).
const Map<String, String> _kInvalidUrl = {
  kEnglish:
      "Saved, but the server address can't be read. "
      'Check the address and save again.',
  kKorean: '저장했지만 서버 주소를 읽을 수 없습니다. 주소를 확인하고 다시 저장하세요.',
};

/// 쓸 수 있는 주소 끝에 붙여 포트를 읽을 수 없게 만드는 오타.
const String _kAddressTypo = 'x';

/// 설정 화면 목록을 한 번에 내리는 거리(논리 픽셀).
const double _kScrollStep = 300;
const Map<String, String> _kErrorTitle = {
  kEnglish: "Couldn't sync",
  kKorean: '동기화할 수 없습니다',
};
const Map<String, String> _kNeedsSetupTitle = {
  kEnglish: 'Setup needed',
  kKorean: '설정이 필요합니다',
};
const Map<String, String> _kOpenSetup = {
  kEnglish: 'Open Setup',
  kKorean: '설정 열기',
};

/// 설정 화면의 서버 절 입력칸 순서: 서버 주소, 토큰.
const int _kServerUrlField = 0;
const int _kTokenField = 1;

/// 폴링 한 번을 기다리는 상한(비활성 창의 `working` 간격 8초, 백오프, 바쁜
/// 기기의 타이머 지연을 넉넉히 덮는다).
const Duration _kPollTimeout = Duration(seconds: 45);

/// 저장한 뒤 새 연결로 첫 요청이 나가기까지의 상한. 저장이 곧바로 동기화를
/// 깨우므로 폴링 간격을 기다리지 않는다.
const Duration _kSwitchTimeout = Duration(seconds: 5);

/// 401로 멈춘 뒤 재시도가 없는지 지켜보는 구간 — 폴링 간격과 백오프 첫 단계
/// (8초 × 2)보다 길다.
const Duration _kStoppedWindow = Duration(seconds: 20);
const Timeout _kScenarioTimeout = Timeout(Duration(minutes: 5));

final Finder _setupFields = find.descendant(
  of: find.byType(SetupPage),
  matching: find.byType(TextField),
);
final Finder _setupList = find
    .descendant(of: find.byType(SetupPage), matching: find.byType(Scrollable))
    .first;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 운영 앱처럼 프레임워크가 요청한 프레임을 모두 그린다.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final qa = QaRun.fromEnvironment(_kScenarios);

  void scenario(
    String description,
    String which,
    Future<void> Function(WidgetTester tester, QaRun qa) body,
  ) {
    testWidgets(
      description,
      (tester) async {
        final run = qa;
        try {
          await body(tester, run);
        } finally {
          await run.closeServers();
          final exception = tester.takeException();
          run.note('end', <String, Object?>{
            'exception': '$exception',
            'config': run.storedConfig(),
          });
          expect(exception, isNull, reason: 'no uncaught framework error');
        }
      },
      skip: qa.scenario != which,
      timeout: _kScenarioTimeout,
    );
  }

  scenario(
    '첫 실행에서 설정을 저장하면 재시작 없이 그 토큰으로 첫 동기화가 서버에 닿고 세션이 오류 없이 보인다',
    _kFirstRun,
    _firstRunScenario,
  );
  scenario(
    '서버 주소와 토큰을 바꾸면 다음 요청이 새 서버로 새 토큰과 옛 커서 없이 나가고 401로 멈춘 앱은 토큰을 고치면 복구된다',
    _kChangeServer,
    _changeServerScenario,
  );
}

Future<void> _firstRunScenario(WidgetTester tester, QaRun qa) async {
  final dispatcher = tester.platformDispatcher;
  if (qa.korean) {
    dispatcher.localeTestValue = _kKoreanSystemLocale;
    dispatcher.localesTestValue = const <Locale>[_kKoreanSystemLocale];
    addTearDown(dispatcher.clearAllTestValues);
  }
  final server = await qa.server(
    'first',
    token: _kTokenFirst,
    // 서버가 아직 언어를 정하지 않았다 — 화면은 시스템 로케일을 따른다.
    uiLang: null,
    snapshotCursor: _kCursorFirst,
    sessions: const <QaSession>[_kFirstSession],
  );
  await server.switchTo(QaServerMode.healthy);

  await bootApp(tester, qa);
  await pumpUntil(tester, 'setup form', () => shows(_setupFields));
  await pumpFor(tester, kSettle);
  expect(qa.storedConfig(), isNull);
  expect(find.text(_kSetupTitle[qa.language]!), findsOneWidget);
  expect(_fieldText(tester, _kServerUrlField), isEmpty);
  expect(_fieldText(tester, _kTokenField), isEmpty);
  expectScreenLanguage(tester, qa);
  await qa.capture(tester, 'first-run-setup');

  tester.testTextInput.register();
  await _enterConnection(tester, server.baseUrl, _kTokenFirst);
  await qa.capture(tester, 'first-run-filled');
  expect(server.requests, isEmpty, reason: 'no request before the save');

  final savedAt = qa.elapsedMs;
  qa.note('save-tapped');
  await tester.tap(_saveButton(qa));
  final syncedAfter = await pumpUntil(
    tester,
    'first sync and its session',
    () =>
        server.syncRequests.isNotEmpty &&
        shows(find.text(_kFirstSession.message)),
    timeout: _kPollTimeout,
  );
  final first = server.syncRequests.first;
  qa.note('first-sync', <String, Object?>{
    'after_save_ms': syncedAfter.inMilliseconds,
    'request_after_save_ms': (first['t_ms']! as int) - savedAt,
    'request': first,
  });
  expect(first['authorization'], QaFakeServer.bearer(_kTokenFirst));
  expect(QaFakeServer.sinceOf(first), isNull, reason: 'a snapshot first');
  expect(first['status'], 200);

  await pumpFor(tester, kSettle);
  _expectHealthySessions(tester, qa);
  await qa.capture(tester, 'first-sync');
  final stored = qa.storedConfig()!;
  expect(stored['server_url'], '${server.baseUrl}');
  expect(stored['client_token'], _kTokenFirst);

  // 같은 프로세스에서 다음 폴링이 커서를 들고 같은 연결로 이어진다.
  await pumpUntil(
    tester,
    'the next poll with the cursor',
    () => server.syncRequests.any(_hasSince),
    timeout: _kPollTimeout,
  );
  final delta = server.syncRequests.firstWhere(_hasSince);
  qa.note('next-poll', <String, Object?>{'request': delta});
  expect(delta['authorization'], QaFakeServer.bearer(_kTokenFirst));
  expect(QaFakeServer.sinceOf(delta), '$_kCursorFirst');
  _expectEveryRequestCarries(server, _kTokenFirst);
  qa.note('push-config', <String, Object?>{
    'requests': <Object?>[
      for (final request in server.requests)
        if (request['path'] == kPushConfigPath) request,
    ],
  });
  await pumpFor(tester, kSettle);
  _expectHealthySessions(tester, qa);
  expect(qa.storedConfig()!['cursor'], greaterThanOrEqualTo(_kCursorFirst));
  await qa.capture(tester, 'after-next-poll');
}

Future<void> _changeServerScenario(WidgetTester tester, QaRun qa) async {
  final a = await qa.server(
    'A',
    token: _kTokenA,
    uiLang: qa.language,
    snapshotCursor: _kCursorA,
    sessions: const <QaSession>[_kSessionA],
  );
  final b = await qa.server(
    'B',
    token: _kTokenB,
    uiLang: qa.language,
    snapshotCursor: _kCursorB,
    sessions: const <QaSession>[_kSessionB],
  );
  await a.switchTo(QaServerMode.healthy);
  await b.switchTo(QaServerMode.healthy);
  qa.writeConfig(serverUrl: a.baseUrl, token: _kTokenA, uiLang: qa.language);

  await bootApp(tester, qa);
  await pumpUntil(
    tester,
    'server A session and a poll that carries its cursor',
    () => shows(find.text(_kSessionA.message)) && a.syncRequests.any(_hasSince),
    timeout: _kPollTimeout,
  );
  await pumpFor(tester, kSettle);
  _expectHealthySessions(tester, qa);
  await qa.capture(tester, 'server-a');

  tester.testTextInput.register();
  await tester.tap(find.byIcon(Icons.settings_outlined));
  await pumpUntil(
    tester,
    'setup form with server A',
    () =>
        shows(_setupFields) &&
        _fieldText(tester, _kServerUrlField) == '${a.baseUrl}',
  );
  await pumpFor(tester, kSettle);
  expect(_fieldText(tester, _kTokenField), _kTokenA);

  // 쓸 수 없는 주소: 저장은 되지만 실행 중인 연결(A)은 그대로다.
  final typo = '${a.baseUrl}$_kAddressTypo';
  await tester.enterText(_setupFields.at(_kServerUrlField), typo);
  final typoSavedAt = qa.elapsedMs;
  qa.note('save-tapped', <String, Object?>{'to': typo});
  await tester.tap(_saveButton(qa));
  await _expectSaveStatus(tester, qa, _kInvalidUrl, 'invalid-address');
  expect(qa.storedConfig()!['server_url'], typo);
  bool keptA(Map<String, Object?> request) =>
      (request['t_ms']! as int) > typoSavedAt && _hasSince(request);
  await pumpUntil(
    tester,
    'the running connection keeps polling server A',
    () => a.syncRequests.any(keptA),
    timeout: _kPollTimeout,
  );
  qa.note('kept-a', <String, Object?>{
    'request': a.syncRequests.firstWhere(keptA),
  });
  expect(b.requests, isEmpty);
  expect(find.byType(SetupPage), findsOneWidget);
  _scrollSetupToTop(tester);
  await pumpFor(tester, kSettle);

  await _enterConnection(tester, b.baseUrl, _kTokenB);
  final savedAt = qa.elapsedMs;
  qa.note('save-tapped', <String, Object?>{'to': '${b.baseUrl}'});
  await tester.tap(_saveButton(qa));
  await pumpUntil(
    tester,
    'the first request to server B',
    () => b.syncRequests.isNotEmpty,
    timeout: _kSwitchTimeout,
  );
  final firstB = b.syncRequests.first;
  qa.note('switched', <String, Object?>{
    'request_after_save_ms': (firstB['t_ms']! as int) - savedAt,
    'request': firstB,
  });
  expect(firstB['authorization'], QaFakeServer.bearer(_kTokenB));
  expect(
    QaFakeServer.sinceOf(firstB),
    isNull,
    reason: 'the old cursor stays with the old server',
  );
  await _expectSaveStatus(tester, qa, _kSaved, 'saved-server-b');

  await tester.pageBack();
  await pumpUntil(
    tester,
    'server B session without the server A session',
    () =>
        !shows(find.byType(SetupPage)) &&
        shows(find.text(_kSessionB.message)) &&
        !shows(find.text(_kSessionA.message)),
  );
  await pumpUntil(
    tester,
    'a poll to server B that carries its cursor',
    () => b.syncRequests.any(_hasSince),
    timeout: _kPollTimeout,
  );
  expect(
    QaFakeServer.sinceOf(b.syncRequests.firstWhere(_hasSince)),
    '$_kCursorB',
  );
  // 저장은 디스크에 쓴 뒤에 연결을 바꾼다. 그 사이에 돈 폴링은 아직 A로
  // 간다(기록만 한다). 새 연결로 첫 요청이 나간 뒤에는 A에 아무것도 없다.
  final switchedAt = firstB['t_ms']! as int;
  qa.note('a-during-save', <String, Object?>{
    'requests': <Object?>[
      for (final request in a.requests)
        if ((request['t_ms']! as int) > savedAt) request,
    ],
  });
  expect(
    a.requests.where((request) => (request['t_ms']! as int) > switchedAt),
    isEmpty,
    reason: 'nothing goes to server A once server B is in use',
  );
  _expectEveryRequestCarries(a, _kTokenA);
  _expectEveryRequestCarries(b, _kTokenB);
  await pumpFor(tester, kSettle);
  _expectHealthySessions(tester, qa);
  expect(find.text(_kSessionA.message), findsNothing);
  await qa.capture(tester, 'server-b');

  b.acceptedToken = _kTokenBRotated;
  qa.note('token-rotated', <String, Object?>{'server': b.name});
  await pumpUntil(
    tester,
    'needs-setup banner after a 401',
    () => shows(find.byType(NeedsSetupBanner)),
    timeout: _kPollTimeout,
  );
  final unauthorized = b.syncRequests.last;
  expect(unauthorized['status'], 401);
  expect(unauthorized['authorization'], QaFakeServer.bearer(_kTokenB));
  await pumpFor(tester, kSettle);
  expect(find.text(_kNeedsSetupTitle[qa.language]!), findsOneWidget);
  expectScreenLanguage(tester, qa);
  await qa.capture(tester, 'needs-setup');
  final requestsWhenStopped = b.syncRequests.length;
  await pumpFor(tester, _kStoppedWindow);
  expect(
    b.syncRequests.length,
    requestsWhenStopped,
    reason: 'a 401 stops the retries',
  );

  await tester.tap(find.text(_kOpenSetup[qa.language]!));
  await pumpUntil(
    tester,
    'setup form with server B',
    () =>
        shows(_setupFields) &&
        _fieldText(tester, _kServerUrlField) == '${b.baseUrl}',
  );
  await pumpFor(tester, kSettle);
  await tester.enterText(_setupFields.at(_kTokenField), _kTokenBRotated);
  final fixedAt = qa.elapsedMs;
  qa.note('save-tapped', <String, Object?>{'token': 'rotated'});
  await tester.tap(_saveButton(qa));
  bool recovered(Map<String, Object?> request) =>
      request['authorization'] == QaFakeServer.bearer(_kTokenBRotated) &&
      request['status'] == 200;
  await pumpUntil(
    tester,
    'a request with the fixed token',
    () => b.syncRequests.any(recovered),
    timeout: _kSwitchTimeout,
  );
  final fixed = b.syncRequests.firstWhere(recovered);
  qa.note('recovered', <String, Object?>{
    'request_after_save_ms': (fixed['t_ms']! as int) - fixedAt,
    'request': fixed,
  });
  expect(
    QaFakeServer.sinceOf(fixed),
    isNotNull,
    reason: 'the same server keeps its cursor',
  );
  await _expectSaveStatus(tester, qa, _kSaved, 'saved-fixed-token');

  await tester.pageBack();
  await pumpUntil(
    tester,
    'sessions without the needs-setup banner',
    () =>
        !shows(find.byType(SetupPage)) &&
        !shows(find.byType(NeedsSetupBanner)) &&
        shows(find.text(_kSessionB.message)),
  );
  await pumpFor(tester, kSettle);
  _expectHealthySessions(tester, qa);
  await qa.capture(tester, 'recovered');
  final stored = qa.storedConfig()!;
  expect(stored['server_url'], '${b.baseUrl}');
  expect(stored['client_token'], _kTokenBRotated);
  expect(stored['cursor'], greaterThanOrEqualTo(_kCursorB));
}

/// 세션 목록이 정상이다: 오류 화면도 지연 배너도 설정 필요 배너도 없고,
/// 화면 언어가 맞다.
void _expectHealthySessions(WidgetTester tester, QaRun qa) {
  expect(find.byType(SessionsPage), findsOneWidget);
  expect(find.byType(SetupPage), findsNothing);
  expect(find.text(_kErrorTitle[qa.language]!), findsNothing);
  expect(find.byType(StaleDataBanner), findsNothing);
  expect(find.byType(NeedsSetupBanner), findsNothing);
  expectScreenLanguage(tester, qa);
}

void _expectEveryRequestCarries(QaFakeServer server, String token) => expect(
  server.requests.map((request) => request['authorization']).toSet(),
  <String>{QaFakeServer.bearer(token)},
  reason: 'every request to ${server.name} carries its token',
);

bool _hasSince(Map<String, Object?> request) =>
    QaFakeServer.sinceOf(request) != null;

String _fieldText(WidgetTester tester, int index) =>
    tester.widget<TextField>(_setupFields.at(index)).controller!.text;

Future<void> _enterConnection(
  WidgetTester tester,
  Uri serverUrl,
  String token,
) async {
  await tester.enterText(_setupFields.at(_kServerUrlField), '$serverUrl');
  await tester.enterText(_setupFields.at(_kTokenField), token);
  await tester.pump();
}

/// 저장 결과 문구를 본다. 설정 화면은 긴 스크롤 목록이고 이 문구는 목록 맨
/// 끝에 그려진다 — 스크롤하지 않은 채 창 안에 보였는지를 기록한 뒤 그
/// 문구까지 내려가 확인하고 화면을 남긴다.
Future<void> _expectSaveStatus(
  WidgetTester tester,
  QaRun qa,
  Map<String, String> status,
  String label,
) async {
  final text = find.text(status[qa.language]!);
  await pumpFor(tester, kSettle);
  final page = tester.getRect(find.byType(SetupPage));
  final onScreen = shows(text) && page.overlaps(tester.getRect(text));
  await tester.scrollUntilVisible(text, _kScrollStep, scrollable: _setupList);
  await pumpFor(tester, kSettle);
  qa.note('save-status', <String, Object?>{
    'label': label,
    'text': status[qa.language],
    'on_screen_without_scrolling': onScreen,
  });
  expect(text, findsOneWidget);
  expectScreenLanguage(tester, qa);
  await qa.capture(tester, label);
}

void _scrollSetupToTop(WidgetTester tester) =>
    tester.state<ScrollableState>(_setupList).position.jumpTo(0);

Finder _saveButton(QaRun qa) => find.descendant(
  of: find.byType(SetupPage),
  matching: find.widgetWithText(FilledButton, _kSave[qa.language]!),
);
