/// 동기화 실물 실행 QA(`sync_error_locale_qa_test.dart`,
/// `sync_config_qa_test.dart`)가 함께 쓰는 조각: 임시 HOME 가드, 관찰 기록과
/// 엔진 화면 캡처, 루프백 가짜 대시보드 서버, 화면 언어 검사.
///
/// **임시 HOME에서만 실행한다.** [QaRun.fromEnvironment]는 `$HOME`에
/// [kQaHomeMarker] 파일이 있고 앱 상태 디렉터리가 아직 없을 때만 실행
/// 대상을 만든다(`config_read_failure_qa_test.dart`와 같은 표식·같은 조건).
/// QA 환경 변수가 없거나 안전 조건에 맞지 않으면 실행을 실패시킨다.
/// `flutter drive --profile -d macos`가 띄운
/// 앱은 도구의 환경 변수를 물려받으므로 도구를 임시 HOME으로 실행한다.
///
/// 가짜 서버([QaFakeServer])는 루프백에만 묶이는 `dart:io` `HttpServer`다.
/// 앱의 실제 전송(`HttpClient`)이 실제 소켓으로 요청하고, 서버는 받은 요청을
/// 경로·쿼리·`Authorization` 헤더 그대로 기록한다. 응답 본문은 앱의 DTO가 아니라
/// `contracts/dashboard-protocol.v1.json`의 `sync` 절 필드 이름으로 직접 만든다.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/main.dart' as app;
import 'package:my_dashboard/src/app.dart' show SolApp;
import 'package:my_dashboard/src/data/dashboard_api.dart' show kSyncPath;
import 'package:my_dashboard/src/data/dashboard_dto.dart'
    show kDashboardProtocolVersion;
import 'package:my_dashboard/src/i18n/t.dart' show localeProvider;
import 'package:my_dashboard/src/state/capability_ids.dart'
    show kSessionStateWorking;
import 'package:my_dashboard/src/state/config_provider.dart'
    show DashboardConfigValues;

/// 임시 HOME 표식(`config_read_failure_qa_test.dart`와 같은 이름).
const String kQaHomeMarker = '.my-dashboard-qa-home';

/// 실행할 시나리오 이름을 담는 환경 변수.
const String kQaScenarioVariable = 'MY_DASHBOARD_QA_SCENARIO';

/// 표시 언어(`en`/`ko`)를 담는 환경 변수.
const String kQaLanguageVariable = 'MY_DASHBOARD_QA_LANG';

/// 화면과 관찰 기록을 남길 디렉터리를 담는 환경 변수(선택).
const String kQaOutputVariable = 'MY_DASHBOARD_QA_OUT';

const String kEnglish = 'en';
const String kKorean = 'ko';
const List<String> kQaLanguages = <String>[kEnglish, kKorean];

/// 한글 음절·자모·호환 자모. 영어 화면의 문구에 있으면 안 된다.
final RegExp kHangul = RegExp('[ᄀ-ᇿ㄰-㆏가-힯]');

/// 설정 화면의 언어 선택기는 각 언어를 그 언어로 적는다(`setup_page.dart`의
/// `i18n-exempt`). 영어 화면 검사에서 이 표기만 뺀다.
const String kKoreanLanguageOptionLabel = '한국어';

/// 실패 원문이 화면에 새어 나왔음을 뜻하는 조각. 어느 화면에도 없어야 한다.
const List<String> kDumpFragments = <String>[
  'ProviderException',
  'StateError',
  'Bad state',
  'Exception:',
  'is not a subtype',
  '#0 ',
  'dart:async',
  'package:',
];

const String _kHomeVariable = 'HOME';
const String _kStateDirectory = '.local/state/my-dashboard';
const String _kConfigFileName = 'config.json';
const String _kObservationsFileName = 'observations.json';
const String _kRequestsFileName = 'requests.json';
const int _kShotNumberWidth = 2;

const Duration kPoll = Duration(milliseconds: 100);
const Duration kBootTimeout = Duration(seconds: 60);
const Duration kStepTimeout = Duration(seconds: 15);
const Duration kSettle = Duration(seconds: 1);

/// 아이콘 글리프가 쓰는 Private Use Area. 화면 문구 기록에서 뺀다.
const int _kPrivateUseStart = 0xE000;
const int _kPrivateUseEnd = 0xF8FF;
const int _kSupplementaryPrivateUseStart = 0xF0000;

/// 한 시나리오 실행(부팅은 프로세스마다 한 번이라 시나리오 하나가 실행
/// 한 번이다)의 위치와 기록.
class QaRun {
  QaRun._(this.scenario, this.language, this.home, this.output);

  /// [scenarios]에 있는 시나리오가 지정됐고, 언어가 [kQaLanguages] 중
  /// 하나이고, 임시 HOME 표식이 있고, 앱 상태 디렉터리가 아직 없을 때만
  /// 실행 대상을 만든다.
  static QaRun fromEnvironment(Iterable<String> scenarios) {
    final environment = Platform.environment;
    final home = environment[_kHomeVariable];
    final scenario = environment[kQaScenarioVariable];
    final language = environment[kQaLanguageVariable];
    if (scenario == null) {
      throw StateError('QA requires $kQaScenarioVariable');
    }
    if (home == null || !scenarios.contains(scenario)) {
      throw StateError('QA requires a known scenario and an isolated HOME');
    }
    if (!kQaLanguages.contains(language)) {
      throw StateError('$kQaLanguageVariable must be one of $kQaLanguages');
    }
    if (!File('$home/$kQaHomeMarker').existsSync()) {
      throw StateError('QA requires $kQaHomeMarker in its isolated HOME');
    }
    final state = '$home/$_kStateDirectory';
    if (FileSystemEntity.typeSync(state, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('QA requires a fresh state directory: $state');
    }
    final root = environment[kQaOutputVariable];
    final output = root == null
        ? null
        : (Directory('$root/$scenario-$language')..createSync(recursive: true));
    return QaRun._(scenario, language!, home, output);
  }

  final String scenario;
  final String language;
  final String home;
  final Directory? output;
  final Stopwatch _clock = Stopwatch()..start();
  final List<Map<String, Object?>> _entries = <Map<String, Object?>>[];
  final List<QaFakeServer> _servers = <QaFakeServer>[];
  int _shots = 0;

  bool get korean => language == kKorean;

  int get elapsedMs => _clock.elapsedMilliseconds;

  Directory get stateDir => Directory('$home/$_kStateDirectory');
  File get config => File('${stateDir.path}/$_kConfigFileName');

  /// 저장된 설정 파일을 JSON으로 읽는다. 없으면 null.
  Map<String, Object?>? storedConfig() {
    if (!config.existsSync()) return null;
    return jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
  }

  void note(String what, [Map<String, Object?> data = const {}]) {
    final entry = <String, Object?>{'t_ms': elapsedMs, 'what': what, ...data};
    _entries.add(entry);
    debugPrint('QA ${jsonEncode(entry)}');
    _write(_kObservationsFileName, _entries);
  }

  /// 루프백 가짜 서버 하나를 잡는다. 받은 요청은 [writeRequests]가 남긴다.
  Future<QaFakeServer> server(
    String name, {
    required String token,
    required String? uiLang,
    required int snapshotCursor,
    required List<QaSession> sessions,
  }) async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final server = QaFakeServer._(
      name,
      port,
      this,
      acceptedToken: token,
      uiLang: uiLang,
      snapshotCursor: snapshotCursor,
      sessions: sessions,
    );
    _servers.add(server);
    note('server-reserved', <String, Object?>{'server': name, 'port': port});
    return server;
  }

  /// 모든 가짜 서버를 닫고 받은 요청을 [_kRequestsFileName]에 남긴다.
  Future<void> closeServers() async {
    for (final server in _servers) {
      await server.close();
    }
    writeRequests();
  }

  void writeRequests() => _write(_kRequestsFileName, <Object?>[
    for (final server in _servers) ...server.requests,
  ]);

  void _write(String name, Object value) {
    final directory = output;
    if (directory == null) return;
    File(
      '${directory.path}/$name',
    ).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(value));
  }

  /// 설정 파일을 쓴다(첫 실행이 아닌 시나리오의 부팅 전 상태).
  void writeConfig({
    required Uri serverUrl,
    required String token,
    required String uiLang,
  }) {
    final values = DashboardConfigValues(
      serverUrl: '$serverUrl',
      clientToken: token,
      uiLang: uiLang,
    );
    stateDir.createSync(recursive: true);
    config.writeAsStringSync(jsonEncode(values.toJson()), flush: true);
    note('config-written', <String, Object?>{
      'server_url': '$serverUrl',
      'ui_lang': uiLang,
    });
  }

  /// 엔진이 그린 현재 화면을 PNG로 남긴다(OS 화면 녹화 권한이 필요 없다).
  Future<void> capture(WidgetTester tester, String label) async {
    _shots++;
    final name = '${'$_shots'.padLeft(_kShotNumberWidth, '0')}-$label';
    final texts = visibleTexts(tester);
    final directory = output;
    if (directory == null) {
      note('screen', <String, Object?>{'name': name, 'texts': texts});
      return;
    }
    // Profile 모드에서는 RenderView.debugLayer가 없다. 실제로 그려진
    // onstage RepaintBoundary를 캡처해 텍스트 목록뿐 아니라 화면도 보존한다.
    final boundaries =
        <RenderRepaintBoundary>[
            for (final element in find.byType(RepaintBoundary).evaluate())
              if (element.renderObject is RenderRepaintBoundary)
                element.renderObject! as RenderRepaintBoundary,
          ].where((boundary) => boundary.attached && boundary.hasSize).toList()
          ..sort(
            (a, b) => (b.size.width * b.size.height).compareTo(
              a.size.width * a.size.height,
            ),
          );
    if (boundaries.isEmpty) fail('No painted boundary for QA screenshot');
    final boundary = boundaries.first;
    final image = await boundary.toImage();
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
      'size': '${boundary.size}',
      'texts': texts,
    });
  }
}

/// 실제 `main()`을 부팅하고 루트 앱이 뜰 때까지 기다린다.
Future<void> bootApp(WidgetTester tester, QaRun qa) async {
  final dispatcher = WidgetsBinding.instance.platformDispatcher;
  qa.note('boot', <String, Object?>{
    'platform_locale': '${dispatcher.locale}',
    'brightness': dispatcher.platformBrightness.name,
  });
  await app.main();
  final elapsed = await pumpUntil(
    tester,
    'root app',
    () => shows(find.byType(SolApp)),
    timeout: kBootTimeout,
  );
  qa.note('booted', <String, Object?>{
    'after_ms': elapsed.inMilliseconds,
    'locale': appContainer(tester).read(localeProvider).name,
  });
}

ProviderContainer appContainer(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(SolApp)));

bool shows(Finder finder) => finder.evaluate().isNotEmpty;

Future<Duration> pumpUntil(
  WidgetTester tester,
  String what,
  bool Function() done, {
  Duration timeout = kStepTimeout,
}) async {
  final clock = Stopwatch()..start();
  while (!done()) {
    if (clock.elapsed > timeout) {
      fail('$what: not seen within $timeout; texts: ${visibleTexts(tester)}');
    }
    await tester.pump(kPoll);
  }
  return clock.elapsed;
}

Future<void> pumpFor(WidgetTester tester, Duration duration) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < duration) {
    await tester.pump(kPoll);
  }
}

bool _isIconGlyph(String text) => text.runes.every(
  (rune) =>
      (rune >= _kPrivateUseStart && rune <= _kPrivateUseEnd) ||
      rune >= _kSupplementaryPrivateUseStart,
);

/// 지금 무대 위에 그려진 문구 전부(아이콘 글리프 제외)와 입력칸 내용.
/// 가려진 입력칸은 길이만 남긴다.
List<String> visibleTexts(WidgetTester tester) {
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

/// 앱이 [QaRun.language]로 그리고 있는지 본다. 영어 화면은 보이는 어떤
/// 문구에도 한글이 없어야 한다(언어 선택기의 [kKoreanLanguageOptionLabel]만
/// 예외). 어느 화면에도 실패 원문 조각([kDumpFragments])이 없어야 한다 —
/// 설계상 런타임 원문을 문장 안에 싣는 오류 줄([withCause])만 그 검사에서
/// 뺀다(한글 검사는 그 줄에도 그대로다).
void expectScreenLanguage(
  WidgetTester tester,
  QaRun qa, {
  Set<String> withCause = const <String>{},
}) {
  expect(appContainer(tester).read(localeProvider).name, qa.language);
  final texts = visibleTexts(tester);
  final dumps = <String>[
    for (final text in texts)
      if (!withCause.contains(text) && kDumpFragments.any(text.contains)) text,
  ];
  expect(dumps, isEmpty, reason: 'a raw failure text is on the screen');
  if (qa.korean) return;
  final hangul = <String>[
    for (final text in texts)
      if (text != kKoreanLanguageOptionLabel && kHangul.hasMatch(text)) text,
  ];
  expect(hangul, isEmpty, reason: 'Hangul on the English screen');
}

/// 가짜 서버가 가진 세션 하나.
@immutable
class QaSession {
  const QaSession({required this.id, required this.message});

  static const String source = 'claude-code';
  static const String host = 'qa-host';
  static const String projectRoot = '/qa/project-';
  static const String lastEvent = 'PostToolUse';

  final String id;

  /// 카드가 그리는 마지막 메시지. 화면에서 이 세션을 찾는 표지다.
  final String message;

  String get key => '$source:$id';

  Map<String, Object?> toJson(int nowMs) => <String, Object?>{
    'key': key,
    'state': kSessionStateWorking,
    'source': source,
    'session_id': id,
    'project': '$projectRoot$id',
    'host': host,
    'last_event': lastEvent,
    'last_message': message,
    'last_occurred_at': nowMs,
    'created_at': nowMs,
    'updated_at': nowMs,
    'last_progress_at': nowMs,
    'stale': false,
  };
}

/// 가짜 서버가 지금 하는 일.
enum QaServerMode {
  /// 듣지 않는다 — 포트가 닫혀 연결이 거부된다.
  closed,

  /// 계약 모양의 정상 sync 응답.
  healthy,

  /// 연결을 받고 sync에 응답하지 않는다.
  silent,

  /// 200 + HTML(캡티브 포털·프록시 모양).
  html,

  /// 정상 모양이지만 더 새 `protocol_version`.
  protocolNewer,

  /// 정상 모양이지만 더 옛 `protocol_version`.
  protocolOlder,

  /// JSON 객체지만 `cursor`가 정수가 아니다(앱의 응답 해석이 타입 불일치로
  /// 던진다 — API 예외가 아닌 실패).
  typeMismatch,
}

/// 루프백 가짜 `GET /dashboard/sync`. `since`가 없으면 스냅샷(`reset: true`,
/// [sessions] 전부, 커서 [snapshotCursor]), 있으면 세션 없는 델타(커서
/// `since + 1`)다. [acceptedToken]이 아닌 `Authorization`에는 401, sync가
/// 아닌 경로에는 404를 준다(push 자격증명이 없는 서버와 같다). 응답마다
/// 연결을 닫아 앱이 닫힌 연결을 재사용하지 않게 한다.
class QaFakeServer {
  QaFakeServer._(
    this.name,
    this.port,
    this._run, {
    required this.acceptedToken,
    required this.uiLang,
    required this.snapshotCursor,
    required this.sessions,
  });

  static const String _scheme = 'http';
  static const String _sinceParameter = 'since';
  static const String _bearer = 'Bearer ';
  static const String _unauthorizedBody = '{"error":"unauthorized"}';
  static const String _notFoundBody = '{"error":"not found"}';
  static const String _invalidCursor = 'not-a-cursor';
  static const int _stallMs = 600000;
  static const String _htmlContentType = 'text/html; charset=utf-8';

  /// 캡티브 포털이나 프록시가 200으로 돌려주는 모양의 HTML.
  static const String htmlBody =
      '<!DOCTYPE html>\n'
      '<html><head><title>Sign in to the network</title></head>\n'
      '<body><p>Sign in to continue.</p></body></html>\n';

  /// [mode]가 돌려주는 `protocol_version`.
  static int protocolFor(QaServerMode mode) => switch (mode) {
    QaServerMode.protocolNewer => kDashboardProtocolVersion + 1,
    QaServerMode.protocolOlder => kDashboardProtocolVersion - 1,
    _ => kDashboardProtocolVersion,
  };

  final String name;
  final int port;
  final QaRun _run;

  /// 받아들이는 CLIENT_TOKEN. 테스트가 중간에 바꿔 토큰 교체를 흉내 낸다.
  String acceptedToken;
  final String? uiLang;
  final int snapshotCursor;
  final List<QaSession> sessions;

  /// 받은 요청 전부(오래된 순). 각 항목은 경로·쿼리·`Authorization` 헤더·
  /// 응답 상태다.
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
  final List<HttpRequest> _held = <HttpRequest>[];
  HttpServer? _server;
  QaServerMode _mode = QaServerMode.closed;

  Uri get baseUrl => Uri(
    scheme: _scheme,
    host: InternetAddress.loopbackIPv4.address,
    port: port,
  );

  Uri get syncUrl => baseUrl.replace(path: kSyncPath);

  /// sync 요청만.
  List<Map<String, Object?>> get syncRequests => <Map<String, Object?>>[
    for (final request in requests)
      if (request['path'] == kSyncPath) request,
  ];

  /// 요청에 실린 `since`(없으면 null).
  static String? sinceOf(Map<String, Object?> request) =>
      (request['query_parameters'] as Map<String, String>?)?[_sinceParameter];

  static String bearer(String token) => '$_bearer$token';

  Future<void> switchTo(QaServerMode mode) async {
    _mode = mode;
    _run.note('server-mode', <String, Object?>{
      'server': name,
      'mode': mode.name,
    });
    if (mode == QaServerMode.closed) {
      await close();
      return;
    }
    _server ??= await _bind();
    if (mode == QaServerMode.silent) return;
    // 응답하지 않던 요청은 새 모드로 답한다.
    final held = List<HttpRequest>.of(_held);
    _held.clear();
    for (final request in held) {
      await _answer(request);
    }
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    _held.clear();
    await server?.close(force: true);
  }

  Future<HttpServer> _bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    server.listen((request) => unawaited(_handle(request)));
    return server;
  }

  Future<void> _handle(HttpRequest request) async {
    final authorization = request.headers.value(
      HttpHeaders.authorizationHeader,
    );
    final entry = <String, Object?>{
      't_ms': _run.elapsedMs,
      'server': name,
      'port': port,
      'method': request.method,
      'path': request.uri.path,
      'query_parameters': request.uri.queryParameters,
      'authorization': authorization,
      'mode': _mode.name,
    };
    requests.add(entry);
    final response = request.response..persistentConnection = false;
    if (request.uri.path != kSyncPath) {
      await _reply(entry, response, HttpStatus.notFound, _notFoundBody);
      return;
    }
    if (authorization != bearer(acceptedToken)) {
      await _reply(entry, response, HttpStatus.unauthorized, _unauthorizedBody);
      return;
    }
    if (_mode == QaServerMode.silent) {
      entry['status'] = 'held';
      _held.add(request);
      _run.note('request', entry);
      return;
    }
    await _answer(request, entry);
  }

  Future<void> _reply(
    Map<String, Object?> entry,
    HttpResponse response,
    int status,
    String body,
  ) async {
    entry['status'] = status;
    _run.note('request', entry);
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(body);
    await response.close();
  }

  Future<void> _answer(
    HttpRequest request, [
    Map<String, Object?>? entry,
  ]) async {
    final response = request.response;
    if (_mode == QaServerMode.html) {
      entry?['status'] = HttpStatus.ok;
      if (entry != null) _run.note('request', entry);
      response.headers.set(HttpHeaders.contentTypeHeader, _htmlContentType);
      response.write(htmlBody);
      await response.close();
      return;
    }
    final since = int.tryParse(
      request.uri.queryParameters[_sinceParameter] ?? '',
    );
    final snapshot = since == null;
    final cursor = snapshot ? snapshotCursor : since + 1;
    final now = DateTime.now().millisecondsSinceEpoch;
    final body = <String, Object?>{
      'protocol_version': protocolFor(_mode),
      'reset': snapshot,
      'cursor': _mode == QaServerMode.typeMismatch ? _invalidCursor : cursor,
      'has_more': false,
      'server_time': now,
      'pruned_below_id': 0,
      'stall_ms': _stallMs,
      'mute_until': null,
      'ui_lang': uiLang,
      'seen': const <Object?>[],
      'hook_skew': const <Object?>[],
      'sessions': <Object?>[
        if (snapshot)
          for (final session in sessions) session.toJson(now),
      ],
      'transitions': const <Object?>[],
      'sessions_touched': const <Object?>[],
    };
    if (entry != null) {
      entry
        ..['status'] = HttpStatus.ok
        ..['cursor'] = body['cursor']
        ..['reset'] = snapshot;
      _run.note('request', entry);
    }
    response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await response.close();
  }
}
