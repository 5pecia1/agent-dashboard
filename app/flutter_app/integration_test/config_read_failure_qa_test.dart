/// 실물 실행 QA — 저장된 설정을 읽지 못했을 때의 부팅 실패 화면과, 다시
/// 읽은 뒤 대시보드로 넘기는 과정을 실제 바이너리(`app.main()`)로 확인한다.
/// 위젯 테스트가 대신하지 못하는 실제 파일 권한·실제 타이머·두 번째
/// `runApp`의 루트 교체를 탄다.
///
/// **임시 HOME에서만 실행한다.** 이 테스트는 `$HOME/.local/state/my-dashboard/`
/// 아래에 설정 파일을 만들고, 권한을 바꾸고, 지운다. 그래서 `$HOME`에
/// [kQaHomeMarker] 파일이 있고 그 상태 디렉터리가 아직 없을 때만 시나리오를
/// 실행하고, 그 밖에는 아무것도 건드리지 않고 건너뛴다. `flutter test -d
/// macos`가 띄운 앱은 도구의 환경 변수를 물려받으므로 도구를 임시 HOME으로
/// 실행한다. 부팅은 프로세스마다 한 번이므로 시나리오 하나가 실행 한 번이다.
///
/// ```sh
/// T="$(mktemp -d)" && touch "$T/.my-dashboard-qa-home"
/// HOME="$T" MY_DASHBOARD_QA_SCENARIO=access MY_DASHBOARD_QA_OUT=/tmp/qa \
///   flutter test integration_test/config_read_failure_qa_test.dart -d macos
/// ```
///
/// `PUB_CACHE`·`CARGO_HOME`·`RUSTUP_HOME`은 기존 설치를 가리키게 둔다.
/// 시나리오: `access`, `access_parent`, `corrupt`, `directory`, `normal`,
/// `first_run`. 저장하는 서버 주소는 아무도 듣지 않는 루프백 포트라 요청이
/// 이 기기 밖으로 나가지 않는다. `MY_DASHBOARD_QA_OUT`을 주면 엔진이 그린
/// 화면(PNG)과 관찰 기록(`observations.json`)을 그 아래 시나리오 디렉터리에
/// 남긴다.
///
/// 설치된 앱이 떠 있어도 같은 bundle ID의 두 번째 프로세스로 뜬다. 실행하는
/// 동안 창과 Dock 아이콘이 생기고, 부팅할 때마다 알림 자기 테스트 배너가
/// 하나 나가며(같은 알림 id라 알림 센터에는 하나만 남는다), 대시보드로 넘긴
/// 뒤에는 트레이 아이콘이 생긴다. 모두 프로세스가 끝나면 사라진다.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:my_dashboard/main.dart' as app;
import 'package:my_dashboard/src/app.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/platform/local_notifications_native.dart'
    show currentNotificationBackend;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/theme_mode_provider.dart';
import 'package:my_dashboard/src/ui/config_read_failure.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';
import 'package:my_dashboard/src/ui/setup_page.dart';
import 'package:tray_manager/tray_manager.dart';

/// 임시 HOME 표식. 이 파일이 있는 HOME에서만 설정 파일을 만들고 바꾼다.
const String kQaHomeMarker = '.my-dashboard-qa-home';

/// 실행할 시나리오 이름을 담는 환경 변수.
const String kQaScenarioVariable = 'MY_DASHBOARD_QA_SCENARIO';

/// 화면과 관찰 기록을 남길 디렉터리를 담는 환경 변수(선택).
const String kQaOutputVariable = 'MY_DASHBOARD_QA_OUT';

/// 운영 서버가 아닌 주소 — 루프백의 discard 포트에는 아무도 듣지 않는다.
const String kQaServerUrl = 'http://127.0.0.1:9';

/// 실제 자격증명이 아닌 토큰. 실패 화면에 새어 나오지 않는지도 이 값으로 본다.
const String kQaClientToken = 'qa-dummy-token-not-a-secret';

/// 앱이 해석하지 않는 키 — 읽고 넘기는 동안 그대로 남는지 본다.
const String kQaUnknownKey = 'qa_unknown_key';
const String kQaUnknownValue = 'kept-as-is';

const String _kHomeVariable = 'HOME';
const String _kStateDirectory = '.local/state/my-dashboard';
const String _kConfigFileName = 'config.json';
const String _kObservationsFileName = 'observations.json';

const String _kTitleKey = 'config.read_failed.title';
const String _kBodyKey = 'config.read_failed.body';
const String _kAccessHintKey = 'config.read_failed.access_hint';
const String _kCorruptHintKey = 'config.read_failed.corrupt_hint';
const String _kNothingStoredHintKey = 'config.read_failed.nothing_stored_hint';
const String _kBootNoteKey = 'config.read_failed.boot_note';
const String _kInlineFailureKey = 'config.read_failed.inline';
const String _kRetryKey = 'action.retry';

/// 실패 안내에 OS가 붙이는 오류 번호와 파서가 붙이는 위치.
const String _kPermissionDeniedErrno = 'errno 13';
const String _kIsDirectoryErrno = 'errno 21';
const String _kParserOffset = 'offset';

const String _kChmod = 'chmod';
const String _kUnreadableMode = '000';
const String _kOwnerFileMode = '600';
const String _kOwnerDirectoryMode = '700';
const String _kShasum = 'shasum';
const List<String> _kSha256Arguments = <String>['-a', '256'];

const String _kKorean = 'ko';
const String _kEnglish = 'en';
const String _kLightTheme = 'light';
const String _kDarkTheme = 'dark';

const Duration _kPoll = Duration(milliseconds: 100);
const Duration _kBootTimeout = Duration(seconds: 60);
const Duration _kStepTimeout = Duration(seconds: 10);
const Duration _kAfterHandover = Duration(seconds: 5);
const Duration _kRouteSettle = Duration(seconds: 1);
const Timeout _kScenarioTimeout = Timeout(Duration(minutes: 5));

/// 관찰 구간 동안 지나가야 하는 자동 재시도 횟수와 그 구간에 더하는 여유.
const int _kObservedRetries = 2;
const Duration _kObserveSlack = Duration(seconds: 1);

/// 자동 재시도가 [_kObservedRetries]번 지나갈 시간. 재시도가 있었다면 그
/// 사이에 드러난다.
final Duration _kObserveWindow =
    kConfigReadRetryInterval * _kObservedRetries + _kObserveSlack;

/// 권한이 돌아온 뒤 다음 자동 재시도까지의 최대 간격에 더하는 여유(읽기와
/// 루트 교체, 바쁜 기기의 타이머 지연).
const Duration _kHandoverSlack = Duration(seconds: 2);

/// 세션 화면 위의 설정 화면에서 클라이언트 토큰 입력칸의 순서.
const int _kClientTokenFieldIndex = 1;
const int _kShotNumberWidth = 2;

/// 아이콘 글리프가 쓰는 Private Use Area. 화면 문구 기록에서 뺀다.
const int _kPrivateUseStart = 0xE000;
const int _kPrivateUseEnd = 0xF8FF;
const int _kSupplementaryPrivateUseStart = 0xF0000;

enum _Scenario { access, accessParent, corrupt, directory, normal, firstRun }

const Map<String, _Scenario> _kScenarioNames = <String, _Scenario>{
  'access': _Scenario.access,
  'access_parent': _Scenario.accessParent,
  'corrupt': _Scenario.corrupt,
  'directory': _Scenario.directory,
  'normal': _Scenario.normal,
  'first_run': _Scenario.firstRun,
};

final Finder _failureScreen = find.byType(ConfigReadFailureScreen);
final Finder _failureView = find.byType(ConfigReadFailureView);
final Finder _dashboard = find.byType(SolApp);
final Finder _retryButton = find.descendant(
  of: _failureView,
  matching: find.byType(FilledButton),
);
final Finder _setupFields = find.descendant(
  of: find.byType(SetupPage),
  matching: find.byType(TextField),
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 운영 앱처럼 프레임워크가 요청한 프레임을 모두 그린다.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final qa = _QaRun.fromEnvironment();

  void scenario(
    String description,
    _Scenario which,
    Future<void> Function(WidgetTester tester, _QaRun qa) body,
  ) {
    testWidgets(
      description,
      (tester) async {
        final run = qa!;
        try {
          await body(tester, run);
        } finally {
          run.note('end', await _fileState(run));
        }
      },
      skip: qa?.scenario != which,
      timeout: _kScenarioTimeout,
    );
  }

  scenario(
    '읽을 수 없는 설정 파일은 실패 화면을 띄우고 권한이 돌아오면 저장된 값으로 대시보드를 넘긴다',
    _Scenario.access,
    (tester, qa) => _accessScenario(tester, qa, lockParent: false),
  );
  scenario(
    '검색할 수 없는 상태 디렉터리도 실패 화면을 띄우고 권한이 돌아오면 대시보드를 넘긴다',
    _Scenario.accessParent,
    (tester, qa) => _accessScenario(tester, qa, lockParent: true),
  );
  scenario(
    '손상된 설정은 자동으로 다시 읽지 않고 고친 뒤 다시 시도를 누르면 대시보드를 넘긴다',
    _Scenario.corrupt,
    _corruptScenario,
  );
  scenario(
    '경로의 디렉터리를 치우면 저장된 것이 없다고 멈추고 파일을 되돌린 뒤 다시 시도를 누르면 넘긴다',
    _Scenario.directory,
    _directoryScenario,
  );
  scenario(
    '읽을 수 있는 설정은 실패 화면 없이 대시보드로 시작하고 파일을 바꾸지 않는다',
    _Scenario.normal,
    _normalScenario,
  );
  scenario(
    '저장된 설정이 없으면 예전처럼 설정 화면으로 시작하고 파일을 만들지 않는다',
    _Scenario.firstRun,
    _firstRunScenario,
  );
}

Future<void> _accessScenario(
  WidgetTester tester,
  _QaRun qa, {
  required bool lockParent,
}) async {
  final stored = _storedValues(contrasting: true);
  final bytes = _encode(stored);
  await _writeConfig(qa, bytes);
  final locked = lockParent ? qa.stateDir.path : qa.config.path;
  await _chmod(_kUnreadableMode, locked);
  qa.note('locked', <String, Object?>{'path': locked, ...await _fileState(qa)});

  await _boot(tester, qa);
  _expectFailureScreen(
    tester,
    hintKey: _kAccessHintKey,
    detailParts: <String>[qa.config.path, _kPermissionDeniedErrno],
  );
  await qa.capture(tester, 'access-failure');

  await _pumpFor(tester, _kObserveWindow, everyFrame: _expectNoDashboard);
  _expectFailureScreen(
    tester,
    hintKey: _kAccessHintKey,
    detailParts: <String>[qa.config.path, _kPermissionDeniedErrno],
  );
  await qa.capture(tester, 'access-still-failing');

  await _chmod(lockParent ? _kOwnerDirectoryMode : _kOwnerFileMode, locked);
  qa.note('unlocked', <String, Object?>{'path': locked});
  final elapsed = await _pumpUntil(
    tester,
    'automatic hand-over after the permission came back',
    _handedOver,
  );
  qa.note('handed-over', <String, Object?>{'after_ms': elapsed.inMilliseconds});
  expect(
    elapsed,
    lessThanOrEqualTo(kConfigReadRetryInterval + _kHandoverSlack),
  );
  await _expectDashboardWithStoredValues(tester, qa, stored, bytes);
  await _exerciseDashboard(tester, qa, stored);
  _expectBytes(qa, bytes);
}

Future<void> _corruptScenario(WidgetTester tester, _QaRun qa) async {
  final stored = _storedValues(contrasting: true);
  final bytes = _encode(stored);
  final truncated = bytes.sublist(0, bytes.length ~/ 2);
  await _writeConfig(qa, truncated);

  await _boot(tester, qa);
  final detailParts = <String>[qa.config.path, _kParserOffset];
  _expectFailureScreen(
    tester,
    hintKey: _kCorruptHintKey,
    detailParts: detailParts,
  );
  await qa.capture(tester, 'corrupt-failure');
  await _pumpFor(tester, _kObserveWindow, everyFrame: _expectNoDashboard);
  _expectBytes(qa, truncated);

  qa.config.writeAsBytesSync(bytes, flush: true);
  qa.note('repaired', <String, Object?>{'sha256': await _sha256(qa.config)});
  await _pumpFor(tester, _kObserveWindow, everyFrame: _expectNoDashboard);
  _expectFailureScreen(
    tester,
    hintKey: _kCorruptHintKey,
    detailParts: detailParts,
  );
  await qa.capture(tester, 'corrupt-repaired-waits-for-retry');

  await tester.tap(_retryButton);
  final elapsed = await _pumpUntil(
    tester,
    'hand-over after Retry',
    _handedOver,
  );
  qa.note('handed-over', <String, Object?>{'after_ms': elapsed.inMilliseconds});
  await _expectDashboardWithStoredValues(tester, qa, stored, bytes);
  _expectBytes(qa, bytes);
}

Future<void> _directoryScenario(WidgetTester tester, _QaRun qa) async {
  final stored = _storedValues(contrasting: true);
  final bytes = _encode(stored);
  final directory = Directory(qa.config.path)..createSync(recursive: true);

  await _boot(tester, qa);
  _expectFailureScreen(
    tester,
    hintKey: _kAccessHintKey,
    detailParts: <String>[qa.config.path, _kIsDirectoryErrno],
  );
  await qa.capture(tester, 'directory-failure');

  directory.deleteSync();
  qa.note('directory-removed');
  final elapsed = await _pumpUntil(
    tester,
    'nothing-stored hint after the directory was removed',
    () => _showsFailureText(tester, _kNothingStoredHintKey),
    everyFrame: _expectNoDashboard,
  );
  qa.note('nothing-stored', <String, Object?>{
    'after_ms': elapsed.inMilliseconds,
  });
  _expectNothingStored(tester, qa);
  await qa.capture(tester, 'directory-removed-nothing-stored');

  await _pumpFor(tester, _kObserveWindow, everyFrame: _expectNoDashboard);
  _expectNothingStored(tester, qa);

  await _writeConfig(qa, bytes);
  await _pumpFor(tester, _kObserveWindow, everyFrame: _expectNoDashboard);
  expect(_showsFailureText(tester, _kNothingStoredHintKey), isTrue);
  await qa.capture(tester, 'directory-restored-waits-for-retry');

  await tester.tap(_retryButton);
  final handover = await _pumpUntil(
    tester,
    'hand-over after Retry',
    _handedOver,
  );
  qa.note('handed-over', <String, Object?>{
    'after_ms': handover.inMilliseconds,
  });
  await _expectDashboardWithStoredValues(tester, qa, stored, bytes);
  _expectBytes(qa, bytes);
}

Future<void> _normalScenario(WidgetTester tester, _QaRun qa) async {
  final stored = _storedValues(contrasting: false);
  final bytes = _encode(stored);
  await _writeConfig(qa, bytes);

  await _boot(tester, qa);
  expect(_failureScreen, findsNothing);
  await _expectDashboardWithStoredValues(tester, qa, stored, bytes);
  expect(find.byType(SessionsPage), findsOneWidget);
  await _pumpFor(
    tester,
    _kAfterHandover,
    everyFrame: () => expect(_failureScreen, findsNothing),
  );
  _expectBytes(qa, bytes);
}

Future<void> _firstRunScenario(WidgetTester tester, _QaRun qa) async {
  await _boot(tester, qa);
  expect(_failureScreen, findsNothing);
  expect(_dashboard, findsOneWidget);
  final container = _dashboardContainer(tester);
  expect(container.read(dashboardConfigValuesProvider).isEmpty, isTrue);
  expect(container.read(storedConfigAtBootProvider), isFalse);
  await _pumpUntil(tester, 'setup form', () => _shows(_setupFields));
  await _pumpFor(tester, _kRouteSettle);
  final fields = tester.widgetList<TextField>(_setupFields).toList();
  expect(fields.first.controller?.text, isEmpty);
  expect(fields[_kClientTokenFieldIndex].controller?.text, isEmpty);
  await qa.capture(tester, 'first-run-setup');
  await _pumpFor(tester, _kAfterHandover);
  expect(
    FileSystemEntity.typeSync(qa.config.path, followLinks: false),
    FileSystemEntityType.notFound,
  );
}

/// 실제 `main()`을 부팅하고 첫 화면(실패 화면이나 대시보드)을 기다린다.
Future<void> _boot(WidgetTester tester, _QaRun qa) async {
  qa.note('boot', <String, Object?>{
    'locale': '${WidgetsBinding.instance.platformDispatcher.locale}',
    'brightness':
        WidgetsBinding.instance.platformDispatcher.platformBrightness.name,
  });
  await app.main();
  qa.note('main-returned', <String, Object?>{
    'notification_backend': currentNotificationBackend.name,
  });
  final elapsed = await _pumpUntil(
    tester,
    'first screen',
    () => _shows(_failureScreen) || _shows(_dashboard),
    timeout: _kBootTimeout,
  );
  qa.note('first-screen', <String, Object?>{
    'after_ms': elapsed.inMilliseconds,
    'failure_screen': _shows(_failureScreen),
    'dashboard': _shows(_dashboard),
  });
}

/// 대시보드가 저장된 값으로 조립됐고 그 값(테마·언어)을 실제로 적용했는지
/// 본다. 파일 바이트는 그대로여야 한다.
Future<void> _expectDashboardWithStoredValues(
  WidgetTester tester,
  _QaRun qa,
  DashboardConfigValues stored,
  List<int> bytes,
) async {
  expect(_failureScreen, findsNothing);
  final container = _dashboardContainer(tester);
  final values = container.read(dashboardConfigValuesProvider);
  expect(values.serverUrl, stored.serverUrl);
  expect(values.clientToken, stored.clientToken);
  expect(values.themeMode, stored.themeMode);
  expect(values.uiLang, stored.uiLang);
  expect(values.extra[kQaUnknownKey], kQaUnknownValue);
  expect(container.read(storedConfigAtBootProvider), isTrue);
  await _pumpFor(tester, _kAfterHandover);
  final theme = container.read(themeModeControllerProvider);
  final locale = container.read(localeProvider);
  qa.note('dashboard', <String, Object?>{
    'server_url': values.serverUrl,
    'theme_mode': theme.name,
    'locale': locale.name,
    'stored_at_boot': container.read(storedConfigAtBootProvider),
  });
  if (stored.themeMode != null) expect(theme.name, stored.themeMode);
  if (stored.uiLang != null) expect(locale.name, stored.uiLang);
  expect(_failureScreen, findsNothing);
  await qa.capture(tester, 'dashboard');
  _expectBytes(qa, bytes);
}

/// 넘긴 뒤에도 앱이 동작하는지 본다: 설정 화면이 파일을 다시 읽어 저장된
/// 값을 보여 주고, 돌아와서 새로고침해도 예외가 없고, 트레이 아이콘이 있다.
Future<void> _exerciseDashboard(
  WidgetTester tester,
  _QaRun qa,
  DashboardConfigValues stored,
) async {
  await tester.tap(find.byIcon(Icons.settings_outlined));
  await _pumpUntil(tester, 'setup form', () => _shows(_setupFields));
  await _pumpFor(tester, _kRouteSettle);
  final fields = tester.widgetList<TextField>(_setupFields).toList();
  expect(fields.first.controller?.text, stored.serverUrl);
  final token = fields[_kClientTokenFieldIndex];
  expect(token.controller?.text, stored.clientToken);
  expect(token.obscureText, isTrue);
  expect(
    find.text(_translate(tester, find.byType(SetupPage), _kInlineFailureKey)),
    findsNothing,
  );
  await qa.capture(tester, 'setup-shows-stored-values');

  await tester.pageBack();
  await _pumpUntil(
    tester,
    'sessions page after going back',
    () => _shows(find.byType(SessionsPage)) && !_shows(find.byType(SetupPage)),
  );
  await tester.tap(find.byIcon(Icons.refresh));
  await _pumpFor(tester, _kAfterHandover);
  await qa.capture(tester, 'sessions-after-refresh');

  final tray = await trayManager.getBounds();
  qa.note('tray', <String, Object?>{'bounds': tray?.toString()});
  expect(
    tray,
    isNotNull,
    reason: 'the tray icon is installed after the hand-over',
  );
}

void _expectFailureScreen(
  WidgetTester tester, {
  required String hintKey,
  required List<String> detailParts,
}) {
  expect(_failureScreen, findsOneWidget);
  expect(_dashboard, findsNothing);
  for (final key in <String>[
    _kTitleKey,
    _kBodyKey,
    hintKey,
    _kBootNoteKey,
    _kRetryKey,
  ]) {
    expect(
      find.text(_translate(tester, _failureScreen, key)),
      findsOneWidget,
      reason: key,
    );
  }
  final detail = _failureDetail(tester);
  for (final part in detailParts) {
    expect(detail, contains(part));
  }
  expect(detail, isNot(contains(kQaClientToken)));
}

void _expectNothingStored(WidgetTester tester, _QaRun qa) {
  expect(_showsFailureText(tester, _kNothingStoredHintKey), isTrue);
  expect(_failureDetail(tester), qa.config.path);
  expect(
    FileSystemEntity.typeSync(qa.config.path, followLinks: false),
    FileSystemEntityType.notFound,
  );
}

void _expectNoDashboard() => expect(_dashboard, findsNothing);

void _expectBytes(_QaRun qa, List<int> expected) =>
    expect(qa.config.readAsBytesSync(), expected);

bool _shows(Finder finder) => finder.evaluate().isNotEmpty;

bool _handedOver() => _shows(_dashboard) && !_shows(_failureScreen);

bool _showsFailureText(WidgetTester tester, String key) =>
    _shows(_failureScreen) &&
    _shows(find.text(_translate(tester, _failureScreen, key)));

String _failureDetail(WidgetTester tester) => tester
    .widget<SelectableText>(
      find.descendant(of: _failureView, matching: find.byType(SelectableText)),
    )
    .data!;

ProviderContainer _dashboardContainer(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(_dashboard));

/// 화면이 쓰는 것과 같은 번역(그 화면의 provider와 로케일)으로 문구를 얻는다.
String _translate(WidgetTester tester, Finder within, String key) {
  final container = ProviderScope.containerOf(tester.element(within));
  return container.read(i18nTranslateOverride)(
    key,
    container.read(localeProvider),
  );
}

/// [contrasting]이면 시스템과 반대 테마·언어를 저장해 넘긴 값이 화면에서도
/// 드러나게 한다.
DashboardConfigValues _storedValues({required bool contrasting}) {
  final dispatcher = WidgetsBinding.instance.platformDispatcher;
  final systemKorean = dispatcher.locale.languageCode == _kKorean;
  final systemDark = dispatcher.platformBrightness == Brightness.dark;
  return DashboardConfigValues(
    serverUrl: kQaServerUrl,
    clientToken: kQaClientToken,
    themeMode: contrasting ? (systemDark ? _kLightTheme : _kDarkTheme) : null,
    uiLang: contrasting ? (systemKorean ? _kEnglish : _kKorean) : null,
    extra: const <String, Object?>{kQaUnknownKey: kQaUnknownValue},
  );
}

List<int> _encode(DashboardConfigValues values) =>
    utf8.encode(jsonEncode(values.toJson()));

Future<void> _writeConfig(_QaRun qa, List<int> bytes) async {
  qa.stateDir.createSync(recursive: true);
  qa.config.writeAsBytesSync(bytes, flush: true);
  await _chmod(_kOwnerFileMode, qa.config.path);
  qa.note('written', <String, Object?>{
    'bytes': bytes.length,
    'sha256': await _sha256(qa.config),
  });
}

Future<void> _chmod(String mode, String path) async {
  final result = await Process.run(_kChmod, <String>[mode, path]);
  expect(result.exitCode, 0, reason: '$_kChmod $mode $path: ${result.stderr}');
}

Future<String?> _sha256(File file) async {
  final result = await Process.run(_kShasum, <String>[
    ..._kSha256Arguments,
    file.path,
  ]);
  if (result.exitCode != 0) return null;
  return (result.stdout as String).split(' ').first;
}

Future<Map<String, Object?>> _fileState(_QaRun qa) async {
  final type = FileSystemEntity.typeSync(qa.config.path, followLinks: false);
  final state = <String, Object?>{'config_type': type.toString()};
  if (type == FileSystemEntityType.file) {
    final stat = qa.config.statSync();
    state['config_mode'] = stat.modeString();
    state['config_size'] = stat.size;
    state['config_modified'] = stat.modified.toIso8601String();
    state['config_sha256'] = await _sha256(qa.config);
  }
  try {
    state['state_entries'] = qa.stateDir.existsSync()
        ? (qa.stateDir
              .listSync()
              .map(
                (entry) => entry.uri.pathSegments.lastWhere(
                  (segment) => segment.isNotEmpty,
                ),
              )
              .toList()
            ..sort())
        : null;
  } on FileSystemException catch (error) {
    state['state_entries'] = 'unlistable: ${error.osError?.message}';
  }
  return state;
}

Future<Duration> _pumpUntil(
  WidgetTester tester,
  String what,
  bool Function() done, {
  Duration timeout = _kStepTimeout,
  void Function()? everyFrame,
}) async {
  final clock = Stopwatch()..start();
  while (!done()) {
    if (clock.elapsed > timeout) fail('$what: not seen within $timeout');
    await tester.pump(_kPoll);
    everyFrame?.call();
  }
  return clock.elapsed;
}

Future<void> _pumpFor(
  WidgetTester tester,
  Duration duration, {
  void Function()? everyFrame,
}) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < duration) {
    await tester.pump(_kPoll);
    everyFrame?.call();
  }
}

bool _isIconGlyph(String text) => text.runes.every(
  (rune) =>
      (rune >= _kPrivateUseStart && rune <= _kPrivateUseEnd) ||
      rune >= _kSupplementaryPrivateUseStart,
);

List<String> _visibleTexts(WidgetTester tester) {
  final texts = <String>[];
  for (final widget in tester.widgetList<RichText>(find.byType(RichText))) {
    final text = widget.text.toPlainText().trim();
    if (text.isNotEmpty && !_isIconGlyph(text)) texts.add(text);
  }
  for (final field in tester.widgetList<EditableText>(
    find.byType(EditableText),
  )) {
    texts.add(
      field.obscureText
          ? 'field(obscured, ${field.controller.text.length} chars)'
          : 'field: ${field.controller.text}',
    );
  }
  return texts;
}

/// 한 시나리오 실행의 위치와 기록.
class _QaRun {
  _QaRun._(this.scenario, this.home, this.output);

  /// 임시 HOME 표식이 있고 상태 디렉터리가 아직 없을 때만 실행 대상을 만든다.
  static _QaRun? fromEnvironment() {
    final environment = Platform.environment;
    final home = environment[_kHomeVariable];
    final name = environment[kQaScenarioVariable];
    final scenario = _kScenarioNames[name];
    if (home == null || scenario == null) return null;
    if (!File('$home/$kQaHomeMarker').existsSync()) {
      debugPrint('QA skipped: $home has no $kQaHomeMarker');
      return null;
    }
    final state = '$home/$_kStateDirectory';
    if (FileSystemEntity.typeSync(state, followLinks: false) !=
        FileSystemEntityType.notFound) {
      debugPrint('QA skipped: $state already exists');
      return null;
    }
    final root = environment[kQaOutputVariable];
    final output = root == null
        ? null
        : (Directory('$root/$name')..createSync(recursive: true));
    return _QaRun._(scenario, home, output);
  }

  final _Scenario scenario;
  final String home;
  final Directory? output;
  final Stopwatch _clock = Stopwatch()..start();
  final List<Map<String, Object?>> _entries = <Map<String, Object?>>[];
  int _shots = 0;

  Directory get stateDir => Directory('$home/$_kStateDirectory');
  File get config => File('${stateDir.path}/$_kConfigFileName');

  void note(String what, [Map<String, Object?> data = const {}]) {
    final entry = <String, Object?>{
      't_ms': _clock.elapsedMilliseconds,
      'what': what,
      ...data,
    };
    _entries.add(entry);
    debugPrint('QA ${jsonEncode(entry)}');
    final directory = output;
    if (directory == null) return;
    File(
      '${directory.path}/$_kObservationsFileName',
    ).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(_entries));
  }

  /// 엔진이 그린 현재 화면을 PNG로 남긴다(OS 화면 녹화 권한이 필요 없다).
  Future<void> capture(WidgetTester tester, String label) async {
    _shots++;
    final name = '${'$_shots'.padLeft(_kShotNumberWidth, '0')}-$label';
    final texts = _visibleTexts(tester);
    final directory = output;
    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer;
    if (directory == null || layer is! OffsetLayer) {
      note('screen', <String, Object?>{'name': name, 'texts': texts});
      return;
    }
    final image = await layer.toImage(view.paintBounds);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${directory.path}/$name.png',
      ).writeAsBytesSync(png!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
    note('screen', <String, Object?>{
      'name': name,
      'png': '$name.png',
      'texts': texts,
    });
  }
}
