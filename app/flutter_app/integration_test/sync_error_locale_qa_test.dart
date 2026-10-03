/// 실물 실행 QA — 동기화 오류 상세 문구(`sessions_page.dart`의
/// `syncErrorDetailText`)가 표시 언어를 따르는지 실제 바이너리(`app.main()`)로
/// 확인한다. 위젯 테스트(`sync_error_detail_test.dart`)는 가짜 카탈로그와 가짜
/// 전송을 쓴다 — 여기서는 앱에 번들된 Rust 카탈로그, `dart:io` `HttpClient`가
/// 실제 루프백 소켓에서 받는 실패, 실제 요청 타임아웃, 실제 창 폭을 탄다.
///
/// 한 실행이 한 시나리오·한 언어다(부팅은 프로세스마다 한 번). 테스트 안에서
/// 루프백 가짜 서버([QaFakeServer])를 띄우고, 저장된 설정의 서버 주소를 그쪽으로
/// 둔 채 부팅한다.
///   1. 첫 동기화가 실패한다 — 첫 부팅 오류 화면의 상세 문구를 본다.
///   2. 서버를 정상으로 돌리고 "다시 시도"를 누른다 — 세션 하나가 보인다.
///   3. 서버를 다시 같은 방식으로 실패시킨다 — 다음 폴링이 실패하면 뜨는
///      데이터 지연 배너(`StaleDataBanner`)의 상세 문구를 본다.
///
/// 기대 문장은 `app-core/src/i18n.rs`의 EN/KO 문구를 이 파일에 옮겨 적은
/// 값이고, 문장에 끼는 런타임 원문은 테스트가 같은 실패를 직접 일으켜 얻는다 —
/// 앱이 그린 문구를 앱의 번역 함수로 다시 만들어 비교하지 않는다. 영어 화면은
/// 보이는 모든 문구에 한글이 없어야 하고, 한국어 화면은 한국어 문장이어야 한다.
/// API 예외가 아닌 실패(`unexpected`)는 원문 대신 일반 문장만 보이고 원문은
/// 로그(`debugPrint`)에만 남아야 한다.
///
/// 시나리오(`MY_DASHBOARD_QA_SCENARIO`): `transport`(닫힌 루프백 포트),
/// `timeout`(연결을 받고 응답하지 않는 서버), `malformed`(200 + HTML 본문),
/// `protocol_newer`/`protocol_older`(이 앱이 모르는 `protocol_version`),
/// `unexpected`(`cursor`가 정수가 아닌 JSON 객체). 언어
/// (`MY_DASHBOARD_QA_LANG`): `en`, `ko` — 저장된 `ui_lang`이고, 가짜 서버도
/// 같은 값을 돌려준다.
///
/// ```sh
/// T="$(mktemp -d)" && touch "$T/.my-dashboard-qa-home"
/// HOME="$T" MY_DASHBOARD_QA_SCENARIO=transport MY_DASHBOARD_QA_LANG=en \
///   MY_DASHBOARD_QA_OUT=/tmp/qa \
///   flutter drive --profile --no-pub -d macos \
///     --target integration_test/sync_error_locale_qa_test.dart \
///     --driver test_driver/sync_qa_driver.dart
/// ```
///
/// 가드와 부작용은 `sync_qa_support.dart` 머리말을 따른다. 실행하는 동안 창과
/// Dock 아이콘, 트레이 아이콘이 생기고 부팅할 때 알림 자기 테스트 배너가 하나
/// 나간다. 모두 프로세스가 끝나면 사라진다.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart'
    show dashboardApiConfigProvider, kSyncPath;
import 'package:my_dashboard/src/data/dashboard_dto.dart'
    show kDashboardProtocolVersion;
import 'package:my_dashboard/src/ui/sessions_page.dart' show SessionsPage;
import 'package:my_dashboard/src/ui/widgets/alert_banner.dart'
    show StaleDataBanner;

import 'sync_qa_support.dart';

/// 실제 자격증명이 아닌 토큰. 화면에 새어 나오지 않는지도 이 값으로 본다.
const String kQaClientToken = 'qa-dummy-token-not-a-secret';

/// 동기화 요청을 가리키는 메서드(정본 `sync.endpoint`).
const String _kSyncMethod = 'GET';

/// `contracts/dashboard-protocol.v1.json`의 sync endpoint와 major 버전.
/// 기대값은 앱의 상수를 재사용하지 않고 계약의 값을 별도로 고정한다.
const String _kContractSyncPath = '/dashboard/sync';
const int _kContractProtocolVersion = 1;
const int _kNewerServerProtocolVersion = 2;
const int _kOlderServerProtocolVersion = 0;

/// `app-core/src/i18n.rs`의 문구 그대로. `{request}`는 `{method} {path}`
/// 자리다.
const String _kRequestSlot = '{request}';
const String _kCauseSlot = '{cause}';
const String _kTimeoutSlot = '{timeout_ms}';
const String _kServerSlot = '{server_version}';
const String _kAppSlot = '{supported_version}';
const Map<_Fault, Map<String, String>> _kSentences = {
  _Fault.transport: {
    kEnglish: 'Request failed: {request} ({cause})',
    kKorean: '요청이 실패했습니다: {request} ({cause})',
  },
  _Fault.timeout: {
    kEnglish: 'No response within {timeout_ms} ms: {request}',
    kKorean: '{timeout_ms}ms 안에 응답이 없습니다: {request}',
  },
  _Fault.malformed: {
    kEnglish: "The response wasn't a JSON object: {request} ({cause})",
    kKorean: '응답이 JSON 객체가 아닙니다: {request} ({cause})',
  },
  _Fault.protocolNewer: {
    kEnglish:
        'The server and this app use different protocol versions '
        '(server: {server_version}, app: {supported_version}). Update the app.',
    kKorean:
        '서버와 앱의 프로토콜 버전이 다릅니다(서버: {server_version}, '
        '앱: {supported_version}). 앱을 업데이트하세요.',
  },
  _Fault.protocolOlder: {
    kEnglish:
        'The server and this app use different protocol versions '
        '(server: {server_version}, app: {supported_version}). '
        'Update the server.',
    kKorean:
        '서버와 앱의 프로토콜 버전이 다릅니다(서버: {server_version}, '
        '앱: {supported_version}). 서버를 업데이트하세요.',
  },
  _Fault.unexpected: {
    kEnglish: 'Syncing failed unexpectedly. Try again.',
    kKorean: '동기화 중 예상하지 못한 오류가 발생했습니다. 다시 시도하세요.',
  },
};

/// 첫 부팅 오류 화면 제목(`session.list.error.title`), 데이터 지연 배너
/// 제목(`alert.banner.stale_data.title`), "다시 시도"(`action.retry`).
const Map<String, String> _kErrorTitle = {
  kEnglish: "Couldn't sync",
  kKorean: '동기화할 수 없습니다',
};
const Map<String, String> _kBannerTitle = {
  kEnglish: 'Sync issue',
  kKorean: '동기화 문제',
};
const Map<String, String> _kRetry = {kEnglish: 'Retry', kKorean: '다시 시도'};

/// `SyncErrorInfo.fromError`가 API 예외가 아닌 실패의 원문을 남기는 줄의
/// 머리(`sync_controller.dart`).
const String _kUnexpectedLogPrefix = 'sync: unexpected failure';

/// 타입 불일치 원문의 조각 — 로그에는 있고 화면에는 없어야 한다.
const String _kTypeErrorFragment = 'is not a subtype';

const int _kSnapshotCursor = 10;
const QaSession _kSession = QaSession(
  id: 'sync-error-locale',
  message: 'QA session for the sync error line',
);

/// 실패가 화면에 닿기까지 요청 타임아웃에 더하는 여유(첫 요청 지연, 백오프).
const Duration _kFailureSlack = Duration(seconds: 20);

/// 성공 뒤 다음 폴링이 실패해 배너가 뜨기까지 요청 타임아웃에 더하는 여유
/// (비활성 창의 폴링 간격, 백오프, 바쁜 기기의 타이머 지연).
const Duration _kStaleSlack = Duration(seconds: 40);
const Timeout _kScenarioTimeout = Timeout(Duration(minutes: 5));

enum _Fault {
  transport('transport', QaServerMode.closed),
  timeout('timeout', QaServerMode.silent),
  malformed('malformed', QaServerMode.html),
  protocolNewer('protocol_newer', QaServerMode.protocolNewer),
  protocolOlder('protocol_older', QaServerMode.protocolOlder),
  unexpected('unexpected', QaServerMode.typeMismatch);

  const _Fault(this.label, this.mode);

  final String label;
  final QaServerMode mode;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 운영 앱처럼 프레임워크가 요청한 프레임을 모두 그린다.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final qa = QaRun.fromEnvironment(_Fault.values.map((fault) => fault.label));

  for (final fault in _Fault.values) {
    testWidgets(
      '${fault.label}: 동기화 오류 문구는 첫 부팅 오류 화면과 데이터 지연 배너에서 '
      '표시 언어의 문장으로 보이고 런타임 원문을 문장 안에만 싣는다',
      (tester) async {
        final run = qa;
        try {
          await _faultScenario(tester, run, fault);
        } finally {
          await run.closeServers();
          final exception = tester.takeException();
          run.note('end', <String, Object?>{'exception': '$exception'});
          expect(exception, isNull, reason: 'no uncaught framework error');
        }
      },
      skip: qa.scenario != fault.label,
      timeout: _kScenarioTimeout,
    );
  }
}

Future<void> _faultScenario(WidgetTester tester, QaRun qa, _Fault fault) async {
  expect(kSyncPath, _kContractSyncPath);
  expect(kDashboardProtocolVersion, _kContractProtocolVersion);
  expect(QaFakeServer.protocolFor(fault.mode), _serverVersionFor(fault));
  final logged = <String>[];
  final previousDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null && message.startsWith(_kUnexpectedLogPrefix)) {
      logged.add(message);
    }
    previousDebugPrint(message, wrapWidth: wrapWidth);
  };
  try {
    final server = await qa.server(
      'main',
      token: kQaClientToken,
      uiLang: qa.language,
      snapshotCursor: _kSnapshotCursor,
      sessions: const <QaSession>[_kSession],
    );
    await server.switchTo(fault.mode);
    qa.writeConfig(
      serverUrl: server.baseUrl,
      token: kQaClientToken,
      uiLang: qa.language,
    );

    await bootApp(tester, qa);
    final timeout = appContainer(
      tester,
    ).read(dashboardApiConfigProvider).timeout;
    final cause = await _observedCause(fault, server);
    final expected = _expectedLine(fault, qa.language, timeout, cause);
    qa.note('expected', <String, Object?>{
      'line': expected,
      'cause': cause,
      'timeout_ms': timeout.inMilliseconds,
    });

    final errorLine = _lineIn(find.byType(SessionsPage), expected);
    final failedAfter = await pumpUntil(
      tester,
      'first-boot error view',
      () => shows(errorLine),
      timeout: timeout + _kFailureSlack,
    );
    qa.note('first-boot-error', <String, Object?>{
      'after_ms': failedAfter.inMilliseconds,
    });
    await pumpFor(tester, kSettle);
    expect(find.text(_kErrorTitle[qa.language]!), findsOneWidget);
    await qa.capture(tester, 'first-boot-error');
    _expectLine(tester, qa, errorLine, expected, cause);
    expect(find.byType(StaleDataBanner), findsNothing);
    final failedRequestsBeforeRecovery = _faultRequests(server, fault).length;
    if (fault != _Fault.transport) {
      expect(failedRequestsBeforeRecovery, isPositive);
      expect(
        QaFakeServer.sinceOf(_faultRequests(server, fault).first),
        isNull,
        reason: 'the first failed sync is a snapshot request',
      );
    }

    await server.switchTo(QaServerMode.healthy);
    // 응답하지 않던 재시도가 방금 정상 응답을 받았으면 오류 화면은 이미
    // 사라졌다 — 그때는 누를 버튼이 없다.
    final retry = find.widgetWithText(FilledButton, _kRetry[qa.language]!);
    if (shows(retry)) await tester.tap(retry);
    final syncedAfter = await pumpUntil(
      tester,
      'first successful sync',
      () =>
          shows(find.text(_kSession.message)) &&
          !shows(find.byType(StaleDataBanner)) &&
          !shows(errorLine),
      timeout: timeout + _kFailureSlack,
    );
    qa.note('synced', <String, Object?>{
      'after_ms': syncedAfter.inMilliseconds,
    });
    await pumpFor(tester, kSettle);
    expectScreenLanguage(tester, qa);
    await qa.capture(tester, 'synced');
    expect(
      server.syncRequests.any(
        (request) =>
            request['mode'] == QaServerMode.healthy.name &&
            request['status'] == HttpStatus.ok,
      ),
      isTrue,
      reason: 'recovery must use a real successful loopback response',
    );

    await server.switchTo(fault.mode);
    final staleCause = await _observedCause(fault, server);
    expect(
      _comparableOrNull(staleCause),
      _comparableOrNull(cause),
      reason: 'the same failure gives the same runtime text',
    );
    final bannerLine = _lineIn(find.byType(StaleDataBanner), expected);
    final staleAfter = await pumpUntil(
      tester,
      'stale-data banner',
      () => shows(bannerLine),
      timeout: timeout + _kStaleSlack,
    );
    qa.note('stale-banner', <String, Object?>{
      'after_ms': staleAfter.inMilliseconds,
    });
    await pumpFor(tester, kSettle);
    expect(find.text(_kBannerTitle[qa.language]!), findsOneWidget);
    await qa.capture(tester, 'stale-banner');
    _expectLine(tester, qa, bannerLine, expected, cause);
    expect(find.text(_kSession.message), findsOneWidget);
    if (fault != _Fault.transport) {
      final failedRequestsAfterRecovery = _faultRequests(server, fault);
      expect(
        failedRequestsAfterRecovery.length,
        greaterThan(failedRequestsBeforeRecovery),
      );
      expect(
        QaFakeServer.sinceOf(failedRequestsAfterRecovery.last),
        isNotNull,
        reason: 'the stale failure follows a successful snapshot',
      );
    }

    qa.note('unexpected-log', <String, Object?>{'lines': logged});
    if (fault == _Fault.unexpected) {
      expect(logged, isNotEmpty, reason: 'the raw failure text is logged');
      expect(logged.first, contains(_kTypeErrorFragment));
    } else {
      expect(logged, isEmpty, reason: 'API failures are not "unexpected"');
    }
    expect(
      server.syncRequests.every(
        (request) =>
            request['authorization'] == QaFakeServer.bearer(kQaClientToken),
      ),
      isTrue,
    );
  } finally {
    debugPrint = previousDebugPrint;
  }
}

List<Map<String, Object?>> _faultRequests(QaFakeServer server, _Fault fault) =>
    <Map<String, Object?>>[
      for (final request in server.syncRequests)
        if (request['mode'] == fault.mode.name) request,
    ];

/// 상세 문구 한 줄을 본다: 기대 문장 그대로이고, 런타임 원문이 들어 있고,
/// 토큰은 없고, 화면 언어가 맞다. 실제 화면의 말줄임은 기록하고, 문구가
/// 화면 경계 밖으로 나간 경우는 실패시킨다.
void _expectLine(
  WidgetTester tester,
  QaRun qa,
  Finder line,
  String expected,
  String? cause,
) {
  expect(line, findsOneWidget);
  final widget = tester.widget<Text>(line);
  final text = widget.data!;
  expect(_comparable(text), _comparable(expected));
  if (cause != null) expect(_comparable(text), contains(_comparable(cause)));
  expect(text, isNot(contains(kQaClientToken)));
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: line, matching: find.byType(RichText)),
  );
  qa.note('line', <String, Object?>{
    'text': text,
    'max_lines': widget.maxLines,
    'truncated_on_screen': paragraph.didExceedMaxLines,
    'width': paragraph.size.width,
    'rect': '${tester.getRect(line)}',
    'viewport': '${Offset.zero & tester.binding.renderViews.first.size}',
  });
  final viewport = Offset.zero & tester.binding.renderViews.first.size;
  final lineRect = tester.getRect(line);
  expect(
    viewport.contains(lineRect.topLeft) &&
        viewport.contains(lineRect.bottomRight),
    isTrue,
    reason: 'the error line must fit inside the actual window',
  );
  if (qa.korean) expect(text, matches(kHangul));
  expectScreenLanguage(tester, qa, withCause: <String>{text.trim()});
}

String _expectedLine(
  _Fault fault,
  String language,
  Duration timeout,
  String? cause,
) {
  final request = '$_kSyncMethod $_kContractSyncPath';
  return _kSentences[fault]![language]!
      .replaceAll(_kRequestSlot, request)
      .replaceAll(_kCauseSlot, cause ?? '')
      .replaceAll(_kTimeoutSlot, '${timeout.inMilliseconds}')
      .replaceAll(_kServerSlot, '${_serverVersionFor(fault)}')
      .replaceAll(_kAppSlot, '$_kContractProtocolVersion');
}

int _serverVersionFor(_Fault fault) => switch (fault) {
  _Fault.protocolNewer => _kNewerServerProtocolVersion,
  _Fault.protocolOlder => _kOlderServerProtocolVersion,
  _ => _kContractProtocolVersion,
};

/// 앱과 같은 실패를 테스트가 직접 일으켜 런타임이 만드는 원문을 얻는다.
/// 문장에 원문을 싣지 않는 실패는 null.
Future<String?> _observedCause(_Fault fault, QaFakeServer server) async {
  switch (fault) {
    case _Fault.transport:
      final client = HttpClient();
      try {
        final request = await client.getUrl(server.syncUrl);
        final response = await request.close();
        await response.drain<void>();
      } on Exception catch (error) {
        return '$error';
      } finally {
        client.close(force: true);
      }
      fail('the closed port accepted ${server.syncUrl}');
    case _Fault.malformed:
      try {
        jsonDecode(QaFakeServer.htmlBody.trim());
      } on FormatException catch (error) {
        return '$error';
      }
      fail('the HTML body decoded as JSON');
    case _Fault.timeout:
    case _Fault.protocolNewer:
    case _Fault.protocolOlder:
    case _Fault.unexpected:
      return null;
  }
}

/// `SocketException`의 `port = N`은 실패한 연결의 로컬(임시) 포트라 시도마다
/// 다르다 — 서버 포트가 아니다. 문구를 비교할 때만 그 숫자를 지운다.
final RegExp _kEphemeralPort = RegExp(r'port = \d+');
const String _kAnyPort = 'port = #';

String _comparable(String text) => text.replaceAll(_kEphemeralPort, _kAnyPort);

String? _comparableOrNull(String? text) =>
    text == null ? null : _comparable(text);

/// [within] 아래에서 [expected]와 같은(임시 포트는 빼고) 문구를 그린 [Text].
Finder _lineIn(Finder within, String expected) => find.descendant(
  of: within,
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is Text &&
        widget.data != null &&
        _comparable(widget.data!) == _comparable(expected),
  ),
);
