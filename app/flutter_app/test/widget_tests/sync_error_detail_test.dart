/// 동기화 오류 상세 문구(`sessions_page.dart`의 `syncErrorDetailText`)가 표시
/// 언어를 따르는지 닫는다.
///
/// 결함(2026-09-10~): 데이터 계층이 전송 실패·타임아웃·응답 해석 실패·프로토콜
/// 불일치를 한국어 문장으로 만들고 화면이 그 원문을 그대로 그려, 영어 화면에도
/// 한국어 조각이 보였다. 이제 데이터 계층은 사실만 [DashboardFault]로 싣고,
/// 화면이 `sync.error.*` 키로 문장을 만든다. 런타임 원문(`SocketException:
/// ...`, `FormatException: ...`)은 번역하지 않고 그대로 끼운다.
///
/// 위젯 테스트는 네이티브 카탈로그를 로드하지 않는다. 그래서 이 키들만
/// i18n.rs의 EN/KO 문구를 그대로 옮긴 가짜 카탈로그로 렌더링하고
/// (`session_card_test.dart`의 `realEn`과 같은 관례), 그 문구가 i18n.rs와
/// 같은지는 이 파일의 첫 테스트가 i18n.rs를 직접 읽어 대조한다. 렌더링 결과
/// 문장은 app-core의
/// `동기화_오류_문구는_로케일별_문장에_요청과_런타임_원문을_그대로_끼운다`
/// 테스트가 같은 값으로 고정한다. 그 밖의 키는 키 그대로 돌려준다.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart' show LocaleDto;
import 'package:my_dashboard/src/state/config_provider.dart'
    show DashboardConfigValues, dashboardConfigValuesProvider;
import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show isSessionStaleFnProvider, stateLabelKeyFnProvider;
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';
import 'package:my_dashboard/src/ui/widgets/alert_banner.dart';
import 'package:riverpod/misc.dart' show Override;
import '../test_helpers/capture_logs.dart';
import '../test_helpers/unconfigured_api_error.dart';

/// 패키지 루트(`flutter test`의 작업 디렉터리) 기준 카탈로그 원본.
const String _catalogSourcePath = '../app-core/src/i18n.rs';

/// i18n.rs의 동기화 오류 문구(EN/KO) 그대로.
const Map<String, Map<LocaleDto, String>> _syncErrorCatalog = {
  'sync.error.transport_failed': {
    LocaleDto.en: 'Request failed: {method} {path} ({cause})',
    LocaleDto.ko: '요청이 실패했습니다: {method} {path} ({cause})',
  },
  'sync.error.timeout': {
    LocaleDto.en: 'No response within {timeout_ms} ms: {method} {path}',
    LocaleDto.ko: '{timeout_ms}ms 안에 응답이 없습니다: {method} {path}',
  },
  'sync.error.malformed_response': {
    LocaleDto.en:
        "The response wasn't a JSON object: {method} {path} ({detail})",
    LocaleDto.ko: '응답이 JSON 객체가 아닙니다: {method} {path} ({detail})',
  },
  'sync.error.protocol_update_app': {
    LocaleDto.en:
        'The server and this app use different protocol versions '
        '(server: {server_version}, app: {supported_version}). Update the app.',
    LocaleDto.ko:
        '서버와 앱의 프로토콜 버전이 다릅니다(서버: {server_version}, '
        '앱: {supported_version}). 앱을 업데이트하세요.',
  },
  'sync.error.protocol_update_server': {
    LocaleDto.en:
        'The server and this app use different protocol versions '
        '(server: {server_version}, app: {supported_version}). '
        'Update the server.',
    LocaleDto.ko:
        '서버와 앱의 프로토콜 버전이 다릅니다(서버: {server_version}, '
        '앱: {supported_version}). 서버를 업데이트하세요.',
  },
  'sync.error.unexpected': {
    LocaleDto.en: 'Syncing failed unexpectedly. Try again.',
    LocaleDto.ko: '동기화 중 예상하지 못한 오류가 발생했습니다. 다시 시도하세요.',
  },
};

/// [DashboardApiException]이 아닌 실패가 화면에 그려야 하는 일반 문장.
const String _unexpectedEn = 'Syncing failed unexpectedly. Try again.';
const String _unexpectedKo = '동기화 중 예상하지 못한 오류가 발생했습니다. 다시 시도하세요.';

String _catalogArgs(
  String key,
  LocaleDto locale,
  List<String> argKeys,
  List<String> argVals,
) {
  final template = _syncErrorCatalog[key]?[locale];
  if (template == null) return key;
  var text = template;
  for (var i = 0; i < argKeys.length; i++) {
    text = text.replaceAll('{${argKeys[i]}}', argVals[i]);
  }
  return text;
}

/// 시임이 던지는 `dart:io` 소켓 예외 흉내.
class _SocketFailure implements Exception {
  const _SocketFailure();

  @override
  String toString() => _cause;
}

const String _cause = 'SocketException: Connection refused';
const String _sync = 'GET $kSyncPath';
const int _timeoutMs = 10000;
const String _decodeDetail =
    'FormatException: Unexpected character (at character 1)';
const int _newerServer = kDashboardProtocolVersion + 1;
const int _olderServer = kDashboardProtocolVersion - 1;
const String _app = '$kDashboardProtocolVersion';

/// 실패의 사실 하나와 그 사실이 en/ko 화면에 그려져야 하는 문장.
typedef _DetailCase = ({
  String name,
  DashboardFault fault,
  String en,
  String ko,
});

const _DetailCase _newerServerCase = (
  name: '서버가 더 새 프로토콜',
  fault: ProtocolMismatchFault(
    serverVersion: _newerServer,
    supportedVersion: kDashboardProtocolVersion,
  ),
  en:
      'The server and this app use different protocol versions '
      '(server: $_newerServer, app: $_app). Update the app.',
  ko:
      '서버와 앱의 프로토콜 버전이 다릅니다(서버: $_newerServer, 앱: $_app). '
      '앱을 업데이트하세요.',
);

const List<_DetailCase> _cases = [
  (
    name: '전송 실패',
    fault: TransportFault(method: 'GET', path: kSyncPath, cause: _cause),
    en: 'Request failed: $_sync ($_cause)',
    ko: '요청이 실패했습니다: $_sync ($_cause)',
  ),
  (
    name: '타임아웃',
    fault: TimeoutFault(method: 'GET', path: kSyncPath, timeoutMs: _timeoutMs),
    en: 'No response within $_timeoutMs ms: $_sync',
    ko: '${_timeoutMs}ms 안에 응답이 없습니다: $_sync',
  ),
  (
    name: '응답 해석 실패',
    fault: MalformedResponseFault(
      method: 'GET',
      path: kSyncPath,
      detail: _decodeDetail,
    ),
    en: "The response wasn't a JSON object: $_sync ($_decodeDetail)",
    ko: '응답이 JSON 객체가 아닙니다: $_sync ($_decodeDetail)',
  ),
  _newerServerCase,
  (
    name: '서버가 더 오래된 프로토콜',
    fault: ProtocolMismatchFault(
      serverVersion: _olderServer,
      supportedVersion: kDashboardProtocolVersion,
    ),
    en:
        'The server and this app use different protocol versions '
        '(server: $_olderServer, app: $_app). Update the server.',
    ko:
        '서버와 앱의 프로토콜 버전이 다릅니다(서버: $_olderServer, 앱: $_app). '
        '서버를 업데이트하세요.',
  ),
];

/// 실제 컨트롤러와 API 아래에 꽂을 전송 하나와, 그 전송이 en/ko 화면에
/// 남겨야 하는 문장. [wait]는 발화 뒤 흘릴 시간이다.
typedef _TransportCase = ({
  String name,
  HttpSendFn send,
  Duration wait,
  String en,
  String ko,
});

SyncErrorInfo _errorFor(DashboardFault fault) => SyncErrorInfo(
  kind: SyncErrorKind.network,
  message: 'DashboardApiException(null): $fault',
  atMs: 0,
  fault: fault,
);

String _expected(_DetailCase detailCase, LocaleDto locale) =>
    locale == LocaleDto.en ? detailCase.en : detailCase.ko;

final RegExp _hangul = RegExp('[가-힣]');

const SessionViewDto _activeSession = SessionViewDto(
  key: 'claude-code:s1',
  state: 'working',
  source: 'claude-code',
  sessionId: 's1',
  project: 'my-dashboard',
  host: 'dev-mac',
  updatedAt: 1000,
);

class _FixedSyncController extends SyncController {
  _FixedSyncController(this._state);

  final SyncControllerState _state;

  @override
  SyncControllerState build() => _state;
}

/// 시간을 흘리지 않는 `Timer` 대체물(`sync_controller_test.dart`와 같은 관용).
class _FakeTimer implements Timer {
  bool _active = true;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required LocaleDto locale,
  required List<Override> syncOverrides,
}) => tester.pumpWidget(
  ProviderScope(
    overrides: [
      // 자리표시자가 없는 문구(`sync.error.unexpected`)는 인자 없는 조회를
      // 탄다 — 카탈로그에 있는 키만 문장으로, 그 밖의 키는 그대로 돌려준다.
      i18nTranslateOverride.overrideWithValue(
        (key, locale) => _syncErrorCatalog[key]?[locale] ?? key,
      ),
      i18nTranslateArgsOverride.overrideWithValue(_catalogArgs),
      localeProvider.overrideWithValue(locale),
      stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
      isSessionStaleFnProvider.overrideWithValue(
        ({required int now, required int updatedAt, required int staleMs}) =>
            false,
      ),
      ...syncOverrides,
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const SessionsPage()),
  ),
);

Future<void> _pumpFixedState(
  WidgetTester tester,
  SyncControllerState state, {
  required LocaleDto locale,
}) => _pumpPage(
  tester,
  locale: locale,
  syncOverrides: [
    syncControllerProvider.overrideWith(() => _FixedSyncController(state)),
    dashboardConfigValuesProvider.overrideWithValue(
      const DashboardConfigValues(),
    ),
  ],
);

/// 실제 [SyncController]와 [DashboardApi]를 [send] 위에 조립해 부팅 즉시
/// 1회를 발화하고 [wait]만큼 시간을 흘린다.
Future<void> _bootWithTransport(
  WidgetTester tester, {
  required LocaleDto locale,
  required DashboardApiConfig config,
  required HttpSendFn send,
  required Duration wait,
}) async {
  final scheduled = <void Function()>[];
  await _pumpPage(
    tester,
    locale: locale,
    syncOverrides: [
      dashboardConfigValuesProvider.overrideWithValue(
        DashboardConfigValues(serverUrl: '${config.baseUrl}'),
      ),
      dashboardApiConfigProvider.overrideWithValue(config),
      httpSendProvider.overrideWithValue(send),
      syncScheduleFnProvider.overrideWithValue((delay, callback) {
        scheduled.add(callback);
        return _FakeTimer();
      }),
      syncNowMsFnProvider.overrideWithValue(() => 1000),
      syncActivityWatchFnProvider.overrideWithValue(
        () => const Stream<bool>.empty(),
      ),
      syncWakeWatchFnProvider.overrideWithValue(
        () => const Stream<void>.empty(),
      ),
    ],
  );

  // 부팅 즉시 1회(`_scheduleNext(Duration.zero)`)를 발화한다.
  scheduled.removeAt(0)();
  await tester.pump(wait);
  await tester.pump();
  await tester.pump();
}

/// [body]를 JSON으로 읽을 때 디코더가 던지는 원문 — 화면이 그대로 끼운다.
String _decodeErrorFor(String body) {
  try {
    jsonDecode(body);
  } on FormatException catch (error) {
    return '$error';
  }
  throw ArgumentError.value(body, 'body', 'is valid JSON');
}

/// 응답 필드의 타입이 어긋날 때 `SyncResponseDto.fromJson`이 던지는 실제 오류
/// (`type 'String' is not a subtype of ...`) — `DashboardApiException`으로
/// 접히지 않고 그대로 새어 나오는 개발자용 영어 원문이다.
Object _fieldTypeMismatch() {
  try {
    SyncResponseDto.fromJson(<String, dynamic>{'protocol_version': 'one'});
  } on Object catch (error) {
    return error;
  }
  throw StateError('타입이 어긋난 응답을 읽었는데 던지지 않았다');
}

/// 예상하지 못한 실패 하나와 그 원문의 첫 줄(화면 어디에도 없어야 한다).
typedef _UnexpectedCase = ({String name, Object error, String rawFirstLine});

_UnexpectedCase _unexpectedCase(String name, Object error) => (
  name: name,
  error: error,
  rawFirstLine: '$error'.split('\n').first,
);

/// 원문을 로그로 남기는 [SyncErrorInfo.fromError]의 출력을 테스트 출력에
/// 섞지 않고 만든다.
Future<SyncErrorInfo> _unexpectedInfo(Object error) async {
  late final SyncErrorInfo info;
  await captureDebugPrint(
    () => info = SyncErrorInfo.fromError(error, atMs: 0),
  );
  return info;
}

/// 서버 주소는 있다고 보고 부팅하지만 `dashboardApiConfigProvider`는 값이 없는
/// 컨트롤러 — 첫 실행에서 서버 주소를 저장한 직후 동기화가 만나던 상황이다.
/// 로그로 나가는 원문은 테스트 출력에 섞지 않는다.
Future<void> _bootWithoutApiConfig(
  WidgetTester tester, {
  required LocaleDto locale,
}) async {
  final scheduled = <void Function()>[];
  await _pumpPage(
    tester,
    locale: locale,
    syncOverrides: [
      dashboardConfigValuesProvider.overrideWithValue(
        const DashboardConfigValues(serverUrl: 'https://example.test'),
      ),
      syncScheduleFnProvider.overrideWithValue((delay, callback) {
        scheduled.add(callback);
        return _FakeTimer();
      }),
      syncNowMsFnProvider.overrideWithValue(() => 1000),
      syncActivityWatchFnProvider.overrideWithValue(
        () => const Stream<bool>.empty(),
      ),
      syncWakeWatchFnProvider.overrideWithValue(
        () => const Stream<void>.empty(),
      ),
    ],
  );
  await captureDebugPrint(() async {
    scheduled.removeAt(0)();
    await tester.pump();
    await tester.pump();
  });
}

void main() {
  test('가짜 카탈로그 문구는 i18n.rs의 EN/KO 문구와 같다', () {
    final source = File(_catalogSourcePath).readAsStringSync();
    for (final MapEntry(key: key, value: byLocale)
        in _syncErrorCatalog.entries) {
      final row = RegExp('"${RegExp.escape(key)}"\\s*=>\\s*"([^"]*)"');
      // EN 맵이 KO 맵보다 먼저 나온다.
      expect(row.allMatches(source).map((match) => match.group(1)).toList(), [
        byLocale[LocaleDto.en],
        byLocale[LocaleDto.ko],
      ], reason: key);
    }
  });

  group('첫 동기화 오류 화면', () {
    for (final detailCase in _cases) {
      group(detailCase.name, () {
        testWidgets('영어 화면은 영어 문장으로 보여주고 한글 조각이 없다', (tester) async {
          await _pumpFixedState(
            tester,
            SyncControllerState(lastError: _errorFor(detailCase.fault)),
            locale: LocaleDto.en,
          );
          await tester.pump();

          expect(find.text('session.list.error.title'), findsOneWidget);
          expect(find.text(detailCase.en), findsOneWidget);
          expect(find.textContaining(_hangul), findsNothing);
          expect(find.textContaining('DashboardApiException'), findsNothing);
          expect(tester.takeException(), isNull);
        });

        testWidgets('한국어 화면은 한국어 문장으로 보여준다', (tester) async {
          await _pumpFixedState(
            tester,
            SyncControllerState(lastError: _errorFor(detailCase.fault)),
            locale: LocaleDto.ko,
          );
          await tester.pump();

          expect(find.text(detailCase.ko), findsOneWidget);
          expect(find.textContaining('DashboardApiException'), findsNothing);
          expect(tester.takeException(), isNull);
        });
      });
    }
  });

  group('StaleDataBanner', () {
    SyncControllerState staleState(SyncErrorInfo error) => SyncControllerState(
      sync: const SyncState(
        cursor: 1000,
        sessions: {'claude-code:s1': _activeSession},
      ),
      lastError: error,
    );

    for (final detailCase in _cases) {
      for (final locale in LocaleDto.values) {
        testWidgets('${detailCase.name} 상세를 표시 언어(${locale.name}) 문장으로 보여준다', (
          tester,
        ) async {
          await _pumpFixedState(
            tester,
            staleState(_errorFor(detailCase.fault)),
            locale: locale,
          );
          await tester.pump();

          expect(
            find.descendant(
              of: find.byType(StaleDataBanner),
              matching: find.text(_expected(detailCase, locale)),
            ),
            findsOneWidget,
          );
          if (locale == LocaleDto.en) {
            expect(find.textContaining(_hangul), findsNothing);
          }
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('사실이 없는 오류는 번역하지 않은 원문을 그대로 보여준다', (tester) async {
      const serverRaw = 'DashboardServerError(503): GET /dashboard/sync: busy';
      await _pumpFixedState(
        tester,
        staleState(
          const SyncErrorInfo(
            kind: SyncErrorKind.server,
            message: serverRaw,
            atMs: 0,
          ),
        ),
        locale: LocaleDto.ko,
      );
      await tester.pump();

      expect(
        find.descendant(
          of: find.byType(StaleDataBanner),
          matching: find.text(serverRaw),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('예상하지 못한 오류 — DashboardApiException이 아닌 실패', () {
    // 원문은 런타임이 만든 개발자용 덤프다: 여러 줄의 스택 트레이스, 한국어
    // StateError 문장, 영어 타입 오류. 화면에는 표시 언어의 일반 문장 하나만
    // 있어야 하고 원문은 로그로만 남는다.
    final cases = <_UnexpectedCase>[
      _unexpectedCase(
        '서버 주소 없이 읽은 API(ProviderException 덤프)',
        unconfiguredApiReadError(),
      ),
      _unexpectedCase('응답 필드 타입 불일치', _fieldTypeMismatch()),
      _unexpectedCase('StateError', StateError('Bad state: seam bug')),
    ];

    for (final unexpected in cases) {
      group(unexpected.name, () {
        testWidgets('영어 오류 화면은 일반 문장 하나만 보이고 한글도 원문도 없다', (tester) async {
          final info = await _unexpectedInfo(unexpected.error);
          await _pumpFixedState(
            tester,
            SyncControllerState(lastError: info),
            locale: LocaleDto.en,
          );
          await tester.pump();

          expect(find.text('session.list.error.title'), findsOneWidget);
          expect(find.text(_unexpectedEn), findsOneWidget);
          expect(find.textContaining(_hangul), findsNothing);
          expect(find.textContaining(unexpected.rawFirstLine), findsNothing);
          expect(find.textContaining('Exception'), findsNothing);
          expect(find.textContaining('StateError'), findsNothing);
          expect(tester.takeException(), isNull);
        });

        testWidgets('한국어 오류 화면은 한국어 일반 문장 하나만 보이고 원문은 없다', (tester) async {
          final info = await _unexpectedInfo(unexpected.error);
          await _pumpFixedState(
            tester,
            SyncControllerState(lastError: info),
            locale: LocaleDto.ko,
          );
          await tester.pump();

          expect(find.text(_unexpectedKo), findsOneWidget);
          expect(find.textContaining(unexpected.rawFirstLine), findsNothing);
          expect(find.textContaining('Exception'), findsNothing);
          expect(tester.takeException(), isNull);
        });

        for (final locale in LocaleDto.values) {
          testWidgets('StaleDataBanner도 ${locale.name} 일반 문장 하나만 보인다', (
            tester,
          ) async {
            final info = await _unexpectedInfo(unexpected.error);
            await _pumpFixedState(
              tester,
              SyncControllerState(
                sync: const SyncState(
                  cursor: 1000,
                  sessions: {'claude-code:s1': _activeSession},
                ),
                lastError: info,
              ),
              locale: locale,
            );
            await tester.pump();

            expect(
              find.descendant(
                of: find.byType(StaleDataBanner),
                matching: find.text(
                  locale == LocaleDto.en ? _unexpectedEn : _unexpectedKo,
                ),
              ),
              findsOneWidget,
            );
            expect(find.textContaining(unexpected.rawFirstLine), findsNothing);
            if (locale == LocaleDto.en) {
              expect(find.textContaining(_hangul), findsNothing);
            }
            expect(tester.takeException(), isNull);
          });
        }
      });
    }

    testWidgets('값 없는 API 설정을 읽은 실제 동기화는 영어 화면에 일반 문장만 남긴다(덤프도 한글도 없다)', (
      tester,
    ) async {
      await _bootWithoutApiConfig(tester, locale: LocaleDto.en);

      expect(find.text('session.list.error.title'), findsOneWidget);
      expect(find.text(_unexpectedEn), findsOneWidget);
      // 결함이 되살아나면 `ProviderException: Tried to use a provider that is
      // in error state.`와 4번째 줄의 한국어 StateError 문장이 보인다.
      expect(find.textContaining(_hangul), findsNothing);
      expect(find.textContaining('ProviderException'), findsNothing);
      expect(find.textContaining('dashboardApiConfigProvider'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('값 없는 API 설정을 읽은 실제 동기화는 한국어 화면에 한국어 일반 문장만 남긴다', (
      tester,
    ) async {
      await _bootWithoutApiConfig(tester, locale: LocaleDto.ko);

      expect(find.text(_unexpectedKo), findsOneWidget);
      expect(find.textContaining('ProviderException'), findsNothing);
      expect(find.textContaining('dashboardApiConfigProvider'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('응답 필드 타입이 어긋난 실제 동기화는 영어 화면에 타입 오류 원문 대신 일반 문장을 보인다', (
      tester,
    ) async {
      await captureDebugPrint(
        () => _bootWithTransport(
          tester,
          locale: LocaleDto.en,
          config: DashboardApiConfig(baseUrl: Uri.parse('https://example.test')),
          send: (ApiRequest request) async => ApiResponse(
            statusCode: 200,
            body: jsonEncode(<String, Object?>{'protocol_version': 'one'}),
          ),
          wait: Duration.zero,
        ),
      );

      expect(find.text(_unexpectedEn), findsOneWidget);
      expect(find.textContaining('is not a subtype'), findsNothing);
      expect(find.textContaining('type cast'), findsNothing);
      expect(find.textContaining(_hangul), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('서버가 준 HTTP 오류 원문은 예전처럼 그대로 보인다(API 예외는 일반 문장으로 접지 않는다)', (
      tester,
    ) async {
      const serverRaw = 'DashboardClientError(404): GET /dashboard/sync: gone';
      await _pumpFixedState(
        tester,
        const SyncControllerState(
          lastError: SyncErrorInfo(
            kind: SyncErrorKind.other,
            message: serverRaw,
            atMs: 0,
          ),
        ),
        locale: LocaleDto.en,
      );
      await tester.pump();

      expect(find.text(serverRaw), findsOneWidget);
      expect(find.text(_unexpectedEn), findsNothing);
    });
  });

  group('실제 컨트롤러와 API', () {
    final config = DashboardApiConfig(
      baseUrl: Uri.parse('https://example.test'),
    );
    final timeoutMs = config.timeout.inMilliseconds;
    // 타임아웃이 확실히 지나도록 상한보다 1초 더 흘린다.
    final pastTimeout = config.timeout + const Duration(seconds: 1);
    const html = '<html>login</html>';
    final htmlDetail = _decodeErrorFor(html);
    final futureProtocolBody = jsonEncode(<String, Object?>{
      'protocol_version': _newerServer,
      'reset': true,
      'cursor': 1,
      'has_more': false,
      'server_time': 1000,
      'pruned_below_id': 0,
      'stall_ms': kDefaultStallMs,
      'mute_until': null,
      'sessions': const <Object?>[],
      'transitions': const <Object?>[],
      'sessions_touched': const <String>[],
    });

    final transports = <_TransportCase>[
      (
        name: '소켓 오류',
        send: (ApiRequest request) =>
            Future<ApiResponse>.error(const _SocketFailure()),
        wait: Duration.zero,
        en: 'Request failed: $_sync ($_cause)',
        ko: '요청이 실패했습니다: $_sync ($_cause)',
      ),
      (
        name: '응답 없음',
        send: (ApiRequest request) => Completer<ApiResponse>().future,
        wait: pastTimeout,
        en: 'No response within $timeoutMs ms: $_sync',
        ko: '${timeoutMs}ms 안에 응답이 없습니다: $_sync',
      ),
      (
        name: '200 HTML',
        send: (ApiRequest request) async =>
            const ApiResponse(statusCode: 200, body: html),
        wait: Duration.zero,
        en: "The response wasn't a JSON object: $_sync ($htmlDetail)",
        ko: '응답이 JSON 객체가 아닙니다: $_sync ($htmlDetail)',
      ),
      (
        name: '서버 프로토콜 major+1',
        send: (ApiRequest request) async =>
            ApiResponse(statusCode: 200, body: futureProtocolBody),
        wait: Duration.zero,
        en: _newerServerCase.en,
        ko: _newerServerCase.ko,
      ),
    ];

    for (final transport in transports) {
      testWidgets('${transport.name}: 영어 화면에 한글 조각 없이 영어 문장이 보인다', (
        tester,
      ) async {
        await _bootWithTransport(
          tester,
          locale: LocaleDto.en,
          config: config,
          send: transport.send,
          wait: transport.wait,
        );

        expect(find.text('session.list.error.title'), findsOneWidget);
        // 결함이 되살아나면 여기서 한국어 문장이 담긴 원문이 잡힌다.
        expect(find.textContaining(_hangul), findsNothing);
        expect(find.text(transport.en), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('${transport.name}: 한국어 화면에 한국어 문장이 보인다', (tester) async {
        await _bootWithTransport(
          tester,
          locale: LocaleDto.ko,
          config: config,
          send: transport.send,
          wait: transport.wait,
        );

        expect(find.text(transport.ko), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
