/// 대시보드 서버 API 클라이언트.
///
/// 이 파일이 지키는 계약은 두 가지다.
///
/// **1. 네트워크는 [httpSendProvider] 시임 하나로만 나간다.** `dart:io`도,
/// `package:http`도 여기 없다. `capability_provider.dart`/`t.dart`와 똑같은
/// "typedef -> `Provider<Fn>` -> 얇은 함수" 3계층이라, 테스트는 서버도
/// 네트워크도 없이 가짜 핸들러 하나만 끼워 401/403/5xx/타임아웃 분기를 전부
/// 태울 수 있다. 실제 전송 구현(데스크톱 `HttpClient`, 웹 `fetch`)은 이
/// 계층 밖에서 [httpSendProvider]를 override해 꽂는다.
///
/// **2. 경로와 응답 모양의 정본은 `contracts/dashboard-protocol.v1.json`이다.**
/// 다만 정본에 아직 없는 두 라우트(`/dashboard/push-config`,
/// `/dashboard/subscriptions`)는 서버 트랙이 곧 구현할 대상이라 경로를 이
/// 파일 상단 상수로 뽑아 두었다 — 서버와 이름이 어긋나면 상수 한 줄만 고친다.
/// (정본 `auth.tokens.CLIENT_TOKEN.endpoints`에는 구독 경로가
/// `POST /dashboard/push-subscriptions`로 적혀 있다. 두 이름이 갈라져 있으므로
/// 서버 트랙과 맞출 때 [kSubscriptionsPath]를 확인해야 한다.)
///
/// 응답 해석(세션 맵·알림 큐 만들기)은 이 파일이 하지 않는다 —
/// `sync_reducer.dart`의 순수 함수가 맡는다.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/dashboard_history.dart';

// ─── 경로 (정본 sync.endpoint / event_history.endpoint / push.mute.endpoint / push.test_push.endpoint) ──

const String kSyncPath = '/dashboard/sync';
const String kEventsPath = '/dashboard/events';
const String kSessionsPath = '/dashboard/sessions';
const String kDevicesPath = '/dashboard/devices';
const String kSubscriptionsPath = '/dashboard/subscriptions';
const String kPushConfigPath = '/dashboard/push-config';
const String kDiagnosticsPath = '/dashboard/diagnostics';
const String kTestPushPath = '/dashboard/test-push';
const String kMutePath = '/dashboard/mute';
const String kUiLangPath = '/dashboard/ui-lang';

const int kHistoryPageSize = 200;

// ─── 전송 시임 (1계층: 함수 모양) ─────────────────────────────────────────

/// 시임이 주고받는 요청. `dart:io`/`package:http`의 타입을 쓰지 않는 이유는
/// 이 계층이 데스크톱·웹 어느 쪽 구현에도 묶이지 않게 하기 위해서다.
@immutable
class ApiRequest {
  const ApiRequest({
    required this.method,
    required this.url,
    this.headers = const <String, String>{},
    this.body,
    this.followRedirects = true,
  });

  /// 대문자 HTTP 메서드(`GET`/`POST`/`DELETE`).
  final String method;
  final Uri url;
  final Map<String, String> headers;

  /// 직렬화가 끝난 JSON 본문. 본문이 없으면 null.
  final String? body;
  final bool followRedirects;

  @override
  String toString() => 'ApiRequest($method $url)';
}

/// 시임이 돌려주는 응답.
@immutable
class ApiResponse {
  const ApiResponse({
    required this.statusCode,
    this.body = '',
    this.headers = const <String, String>{},
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  @override
  String toString() => 'ApiResponse($statusCode)';
}

/// 실제 전송 함수의 모양.
typedef HttpSendFn = Future<ApiResponse> Function(ApiRequest request);

/// 전송 구현이 안 꽂힌 상태의 기본값. 조용히 성공한 척하지 않는다.
Future<ApiResponse> _transportNotConfigured(ApiRequest request) =>
    Future<ApiResponse>.error(
      const DashboardNetworkFailure(
        'httpSendProvider가 override되지 않았다. 앱 부팅(또는 테스트)에서 '
        '실제 전송 구현을 꽂아야 한다.',
      ),
      StackTrace.current,
    );

/// 전송 시임 (2계층: Provider). 테스트는 이것만 갈아끼운다.
///
/// ```dart
/// final container = ProviderContainer(
///   overrides: [
///     httpSendProvider.overrideWithValue(
///       (request) async => const ApiResponse(statusCode: 401),
///     ),
///   ],
/// );
/// ```
final Provider<HttpSendFn> httpSendProvider = Provider<HttpSendFn>(
  (ref) => _transportNotConfigured,
);

// ─── 설정 ────────────────────────────────────────────────────────────────

/// 서버 주소와 CLIENT_TOKEN. 정본 `auth.scheme`은 `Authorization: Bearer`다.
@immutable
class DashboardApiConfig {
  const DashboardApiConfig({
    required this.baseUrl,
    this.clientToken,
    this.timeout = const Duration(seconds: 10),
  });

  /// 예: `https://api.example.workers.dev` 또는 경로 접두사가 있는 주소.
  final Uri baseUrl;

  /// 정본 `auth.tokens.CLIENT_TOKEN`. 없으면 Authorization 헤더를 붙이지 않는다.
  final String? clientToken;

  /// 한 요청의 상한. 넘기면 [DashboardTimeout].
  final Duration timeout;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DashboardApiConfig &&
          other.baseUrl == baseUrl &&
          other.clientToken == clientToken &&
          other.timeout == timeout;

  @override
  int get hashCode => Object.hash(baseUrl, clientToken, timeout);
}

/// 앱 부팅이 override해야 하는 설정 provider.
final Provider<DashboardApiConfig> dashboardApiConfigProvider =
    Provider<DashboardApiConfig>(
      (ref) => throw StateError(
        'dashboardApiConfigProvider를 override해야 한다 '
        '(서버 주소와 CLIENT_TOKEN은 빌드에 굽지 않는다).',
      ),
    );

// ─── 오류 ────────────────────────────────────────────────────────────────

/// 이 계층이 던지는 모든 실패의 뿌리. `sealed`라 화면 쪽 `switch`가
/// 빠진 분기를 컴파일 타임에 잡는다.
sealed class DashboardApiException implements Exception {
  const DashboardApiException(this.message, {this.statusCode});

  /// 실패의 원문. 번역하지 않는다 — [fault]가 있으면 그 사실 나열과 같다.
  final String message;

  /// HTTP 상태 코드. 전송 자체가 실패했으면 null.
  final int? statusCode;

  /// 화면이 표시 언어의 문장을 만들 사실. 없으면 null이고, 화면은 [message]
  /// 원문을 그대로 보여준다(`sessions_page.dart`의 `syncErrorDetailText`).
  DashboardFault? get fault => null;

  @override
  String toString() => '$runtimeType($statusCode): $message';
}

/// 401 — CLIENT_TOKEN 불일치. 사용자가 토큰을 다시 넣어야 한다.
final class DashboardUnauthorized extends DashboardApiException {
  const DashboardUnauthorized(super.message) : super(statusCode: 401);
}

/// 403 — 인증은 됐지만 이 토큰에 권한이 없다(예: INGEST_TOKEN으로 조회).
final class DashboardForbidden extends DashboardApiException {
  const DashboardForbidden(super.message) : super(statusCode: 403);
}

/// 그 밖의 4xx — 요청이 잘못됐다. 재시도해도 같은 결과다.
final class DashboardClientError extends DashboardApiException {
  const DashboardClientError(super.message, {required int super.statusCode});
}

/// 5xx — 서버 쪽 문제. 재시도가 의미 있는 유일한 HTTP 실패다.
final class DashboardServerError extends DashboardApiException {
  const DashboardServerError(super.message, {required int super.statusCode});
}

/// 시간 안에 응답이 오지 않았다.
final class DashboardTimeout extends DashboardApiException {
  const DashboardTimeout(super.message, {required this.fault});

  @override
  final TimeoutFault fault;
}

/// 실패 한 건의 사실. 이 계층은 사람이 읽을 문장을 만들지 않는다 — 화면이
/// 이 사실로 표시 언어에 맞는 문장을 만든다(`sessions_page.dart`의
/// `syncErrorDetailText`). 예전에는 여기서 한국어 문장을 만들어 영어
/// 화면에도 그 조각이 보였다. `sealed`라 화면의 `switch`가 새 사실을
/// 빠뜨리면 컴파일 타임에 잡힌다.
///
/// 하위 클래스의 `toString`은 `DashboardApi._statusFailure`의
/// `'$method $path: $detail'`과 같은 모양의 사실 나열이다(문장이 아니다).
/// 예외의 [DashboardApiException.message]가 이 값을 쓴다.
@immutable
sealed class DashboardFault {
  const DashboardFault();
}

/// 시임([HttpSendFn])이 던져 응답을 끝까지 받지 못했다: 어느 요청([method]
/// [path])이 무슨 원인([cause])으로. 연결 거부뿐 아니라 응답을 받는 도중의
/// 실패(본문 디코딩, 연결 끊김, TLS)도 여기로 온다.
final class TransportFault extends DashboardFault {
  const TransportFault({
    required this.method,
    required this.path,
    required this.cause,
  });

  /// 대문자 HTTP 메서드(`GET`/`POST`/`DELETE`).
  final String method;

  /// 요청한 경로 상수(예: [kSyncPath]). 서버 주소·쿼리·토큰은 담지 않는다.
  final String path;

  /// 시임이 던진 원래 예외의 문자열(예: `SocketException: ...`). 런타임이
  /// 만든 원문이라 번역하지 않는다.
  final String cause;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransportFault &&
          other.method == method &&
          other.path == path &&
          other.cause == cause;

  @override
  int get hashCode => Object.hash(method, path, cause);

  @override
  String toString() => '$method $path: $cause';
}

/// 요청([method] [path])이 [timeoutMs] 안에 응답을 받지 못했다
/// ([DashboardApiConfig.timeout]).
final class TimeoutFault extends DashboardFault {
  const TimeoutFault({
    required this.method,
    required this.path,
    required this.timeoutMs,
  });

  /// 대문자 HTTP 메서드(`GET`/`POST`/`DELETE`).
  final String method;

  /// 요청한 경로 상수(예: [kSyncPath]). 서버 주소·쿼리·토큰은 담지 않는다.
  final String path;

  /// 기다린 상한(ms).
  final int timeoutMs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TimeoutFault &&
          other.method == method &&
          other.path == path &&
          other.timeoutMs == timeoutMs;

  @override
  int get hashCode => Object.hash(method, path, timeoutMs);

  @override
  String toString() => '$method $path: timeout ${timeoutMs}ms';
}

/// 2xx 응답([method] [path])의 본문을 기대한 모양으로 읽지 못했다 — JSON이
/// 아니거나(프록시나 캡티브 포털이 HTML을 200으로 돌려줄 때가 대표적이다)
/// JSON 객체가 아니거나, 이벤트 기록 응답의 필드가 어긋났다.
final class MalformedResponseFault extends DashboardFault {
  const MalformedResponseFault({
    required this.method,
    required this.path,
    required this.detail,
  });

  /// 대문자 HTTP 메서드(`GET`/`POST`/`DELETE`).
  final String method;

  /// 요청한 경로 상수(예: [kSyncPath]). 서버 주소·쿼리·토큰은 담지 않는다.
  final String path;

  /// 해석 실패의 원문 — 디코더나 파서가 던진 예외의 문자열(예:
  /// `FormatException: ...`)이나, JSON이지만 객체가 아니면 그 값의 런타임
  /// 타입. 번역하지 않는다.
  final String detail;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MalformedResponseFault &&
          other.method == method &&
          other.path == path &&
          other.detail == detail;

  @override
  int get hashCode => Object.hash(method, path, detail);

  @override
  String toString() => '$method $path: $detail';
}

/// 서버가 말한 프로토콜 major([serverVersion])가 이 앱이 아는 값
/// ([supportedVersion], [kDashboardProtocolVersion])과 다르다.
final class ProtocolMismatchFault extends DashboardFault {
  const ProtocolMismatchFault({
    required this.serverVersion,
    required this.supportedVersion,
  });

  final int serverVersion;
  final int supportedVersion;

  /// 서버가 더 새 major를 말한다 — 앱을 갱신해야 맞는다. 아니면 서버가
  /// 뒤처졌다(이 앱은 같은 major만 받는다,
  /// `SyncResponseDto.isSupportedProtocol`).
  bool get serverIsNewer => serverVersion > supportedVersion;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProtocolMismatchFault &&
          other.serverVersion == serverVersion &&
          other.supportedVersion == supportedVersion;

  @override
  int get hashCode => Object.hash(serverVersion, supportedVersion);

  @override
  String toString() =>
      'protocol_version $serverVersion (supported: $supportedVersion)';
}

/// 전송 자체가 실패했다(연결 불가, 시임 미설정 등).
final class DashboardNetworkFailure extends DashboardApiException {
  const DashboardNetworkFailure(super.message, {this.fault});

  /// 시임이 던진 예외를 접은 실패라면 그 요청과 원인. 시임 미설정처럼 특정
  /// 요청과 무관한 실패면 null이다.
  @override
  final TransportFault? fault;
}

/// 2xx인데 본문이 JSON 객체가 아니다.
final class DashboardMalformedResponse extends DashboardApiException {
  const DashboardMalformedResponse(super.message, {required this.fault});

  @override
  final MalformedResponseFault fault;
}

/// 서버가 모르는 프로토콜 major를 말한다. 정본 `sync.response.fields`의
/// "클라이언트가 모르는 값이면 갱신을 안내한다".
final class DashboardProtocolMismatch extends DashboardApiException {
  const DashboardProtocolMismatch(super.message, {required this.fault});

  @override
  final ProtocolMismatchFault fault;
}

/// push 자격증명이 서버에 없다(또는 라우트가 아직 없다).
final class DashboardPushUnavailable extends DashboardApiException {
  const DashboardPushUnavailable(super.message, {super.statusCode});
}

// ─── 클라이언트 ──────────────────────────────────────────────────────────

/// 대시보드 서버의 클라이언트 엔드포인트 묶음.
///
/// 모든 메서드는 실패를 [DashboardApiException]으로만 던진다. 시임이 던진
/// 다른 예외도 여기서 [DashboardNetworkFailure]로 접힌다.
class DashboardApi {
  const DashboardApi({required this.send, required this.config});

  final HttpSendFn send;
  final DashboardApiConfig config;

  /// `GET /dashboard/sync?since=` — 클라이언트가 쓰는 유일한 조회 경로.
  ///
  /// [since]가 null이면 서버가 스냅샷(`reset:true`)을 준다. 손상된 커서를
  /// 들고 있을 때도 null로 부르는 것이 안전한 복구 경로다
  /// (`sync_reducer.dart`의 `cursorForRequest` 참고).
  Future<SyncResponseDto> sync({
    int? since,
    int? limit,
    bool includeEnded = false,
  }) async {
    final query = <String, String>{
      if (since != null) 'since': '$since',
      if (limit != null) 'limit': '$limit',
      if (includeEnded) 'include_ended': '1',
    };
    final json = await _request('GET', kSyncPath, query: query);
    final response = SyncResponseDto.fromJson(json);
    if (!response.isSupportedProtocol) {
      final fault = ProtocolMismatchFault(
        serverVersion: response.protocolVersion,
        supportedVersion: kDashboardProtocolVersion,
      );
      throw DashboardProtocolMismatch('$fault', fault: fault);
    }
    return response;
  }

  Future<DashboardHistoryPage> history({
    required String sessionKey,
    bool promptsOnly = false,
    int? beforeId,
  }) async {
    final json = await _request(
      'GET',
      kEventsPath,
      query: <String, String>{
        'session_key': sessionKey,
        'limit': '$kHistoryPageSize',
        'kind': promptsOnly ? 'prompts' : 'all',
        if (beforeId != null) 'before_id': '$beforeId',
      },
    );
    try {
      return DashboardHistoryPage.fromJson(json);
    } on Object catch (error) {
      throw _malformed('GET', kEventsPath, '$error');
    }
  }

  /// `POST /dashboard/devices` — FCM 기기 토큰 등록(같은 토큰은 갱신).
  ///
  /// [transport]는 서버의 채널 id(`fcm`)다. 서버는 안 보내면 `fcm`으로
  /// 기본값을 채우므로 데스크톱 호출자는 생략해도 된다 — 웹 클라이언트는
  /// 자기가 어떤 채널로 등록하는지 명시한다(`web_push_web.dart`).
  /// [label]은 사람이 읽는 기기 이름이고, 서버는 null이면 기존 값을
  /// 유지한다(`COALESCE(excluded.label, ...)`). 그래서 **보내지 않는 것과
  /// 빈 문자열을 보내는 것은 다르다** — 모를 때는 아예 넣지 않는다.
  Future<void> registerDevice({
    required String token,
    required String platform,
    String? transport,
    String? label,
  }) async {
    await _request(
      'POST',
      kDevicesPath,
      body: <String, Object?>{
        'token': token,
        'platform': platform,
        // null-aware element: null이면 키 자체가 빠진다.
        'transport': ?transport,
        if (label != null && label.isNotEmpty) 'label': label,
      },
    );
  }

  /// `POST /dashboard/subscriptions` — 웹 푸시 구독 등록.
  Future<void> registerSubscription(PushSubscriptionDto subscription) async {
    await _request('POST', kSubscriptionsPath, body: subscription.toJson());
  }

  /// `DELETE /dashboard/subscriptions?endpoint=` — 구독 해지.
  ///
  /// 지운 게 없어서 404가 와도 성공으로 접는다(해지의 결과는 "없음"이고,
  /// 그 상태에 이미 도달해 있기 때문이다).
  Future<void> removeSubscription({required String endpoint}) async {
    try {
      await _request(
        'DELETE',
        kSubscriptionsPath,
        query: <String, String>{'endpoint': endpoint},
      );
    } on DashboardClientError catch (error) {
      if (error.statusCode != 404) rethrow;
    }
  }

  /// `GET /dashboard/push-config` — 웹 클라이언트의 FCM 구독 설정.
  ///
  /// 자격증명이 없으면(빈 채널 목록, 404/501/503) [DashboardPushUnavailable].
  Future<PushConfigDto> pushConfig() async {
    final Map<String, dynamic> json;
    try {
      json = await _request('GET', kPushConfigPath);
    } on DashboardClientError catch (error) {
      if (error.statusCode == 404) {
        throw DashboardPushUnavailable(
          'push-config 라우트가 없다: ${error.message}',
          statusCode: error.statusCode,
        );
      }
      rethrow;
    } on DashboardServerError catch (error) {
      if (error.statusCode == 501 || error.statusCode == 503) {
        throw DashboardPushUnavailable(
          'push 채널이 아직 준비되지 않았다: ${error.message}',
          statusCode: error.statusCode,
        );
      }
      rethrow;
    }
    final config = PushConfigDto.fromServer(json);
    if (config.isUnavailable) {
      throw const DashboardPushUnavailable('서버에 push 자격증명이 없다.');
    }
    return config;
  }

  /// `GET /dashboard/diagnostics` — 운영 스냅샷.
  Future<DiagnosticsDto> diagnostics() async =>
      DiagnosticsDto.fromJson(await _request('GET', kDiagnosticsPath));

  /// `POST /dashboard/test-push` — 기기 등록이 살아 있는지 확인하는 발송.
  /// 음소거를 무시한다(서버가 그렇게 정의한다).
  Future<TestPushResultDto> testPush({String? label}) async =>
      TestPushResultDto.fromJson(
        await _request(
          'POST',
          kTestPushPath,
          body: <String, Object?>{'label': ?label},
        ),
      );

  /// `POST /dashboard/mute` — 지금부터 [minutes]분 음소거. 0 이하면 즉시 해제.
  /// 반환값은 음소거 종료 시각(epoch ms), 해제 상태면 null.
  Future<int?> mute({required int minutes}) async {
    final json = await _request(
      'POST',
      kMutePath,
      body: <String, Object?>{'minutes': minutes},
    );
    final Object? until = json['mute_until'];
    return until is int ? until : null;
  }

  /// `GET /dashboard/ui-lang` — 서버에 저장된 UI 표시 언어(정본
  /// `dashboard_settings.ui_lang`). `'ko'`/`'en'` 또는 null(서버가 아직
  /// 정하지 않음 — 그때는 각 기기가 자기 플랫폼 로케일을 쓴다, `state/
  /// ui_lang_provider.dart`/`i18n/t.dart` 문서 참고). `sync` 응답이 매번
  /// 실어 오는 같은 값의 단독 조회 버전이다 — 화면이 동기화 주기를 기다리지
  /// 않고 지금 값을 바로 확인하고 싶을 때 쓴다.
  Future<String?> uiLang() async {
    final json = await _request('GET', kUiLangPath);
    final Object? value = json['ui_lang'];
    return value is String ? value : null;
  }

  /// `POST /dashboard/ui-lang` — UI 표시 언어를 [value]로 정한다.
  /// `'ko'`/`'en'` 중 하나를 보낸다 — `'system'`은 로컬 기기 사실이라 서버로
  /// 보내지 않는다(호출자가 그 매핑을 한다, [경합] 지시 참고: `'system'`을
  /// 고르는 것은 서버 값을 지우는 것과 같은 뜻이라 [value]에 null을 보낸다).
  ///
  /// **요청 키와 응답 키가 다르다 — 계약이 그렇게 정해 놨다(정본
  /// `contracts/dashboard-protocol.v1.json`의 `settings.ui_lang.endpoint.post`).**
  /// 요청 본문은 `{"lang": ...}`이고 응답 본문은 `{"ok":true,"ui_lang":...}`다.
  /// 서버(`dashboard-server/src/features/dashboard-ops/routes.ts`)는 `"lang" in body`로
  /// **키의 존재 자체**를 먼저 본다 — 명시적 null("선택 해제")이 유효값이라
  /// 키 부재와 구분해야 하기 때문이다. 그래서 여기서 `ui_lang`을 보내면
  /// 값이 아무리 맞아도 "키 부재" 400으로 떨어진다(리뷰 지적 high 수정:
  /// 실제로 그렇게 보내고 있었고, 양쪽 테스트가 각자 자기 모양만 단언해
  /// 게이트가 전부 초록인 채로 통과했다 — 지금은 `scripts/contract_check.py`의
  /// check 10)이 계약·서버·이 파일 세 곳의 키를 함께 대조한다).
  ///
  /// **낙관적 갱신 금지, `mute()`와 같은 전례.** 반환값은 서버가 실제로
  /// 확인한 값이다 — 호출자(`ui/setup_page.dart._setUiLang`)는 요청을 보내는
  /// 시점이 아니라 **이 반환값**으로만 `uiLangControllerProvider`와 로컬
  /// 캐시(`DashboardConfigValues.uiLang`)를 갱신해야 한다.
  Future<String?> setUiLang(String? value) async {
    final json = await _request(
      'POST',
      kUiLangPath,
      body: <String, Object?>{'lang': value},
    );
    final Object? confirmed = json['ui_lang'];
    return confirmed is String ? confirmed : null;
  }

  /// `POST /dashboard/sessions/{key}/ack` — 정본 `client_actions.UserAck`.
  ///
  /// [sessionKey]는 `<source>:<session_id>` 꼴이라 이론적으로 `/`를 담을 수
  /// 있다 — 문자열로 이어붙여 `path`에 넣으면 그 `/`가 추가 경로 구간으로
  /// 잘못 쪼개진다. 그래서 [_url]의 `extraSegments`(리스트 원소 그대로,
  /// `Uri.replace(pathSegments:)`가 구간마다 퍼센트 인코딩한다)로 넘긴다 —
  /// `removeSubscription`이 `/`를 담을 수 있는 `endpoint`를 쿼리 파라미터로
  /// 돌려 같은 위험을 피한 것과 같은 이유의 다른 해법이다(여기는 경로
  /// 모양 자체가 `/ack` 접미사를 요구해 쿼리로 뺄 수 없다).
  ///
  /// 세션이 `waiting_input`이 아니면(이미 처리됐거나 없음) 서버는 실패가
  /// 아니라 200 no-op으로 응답한다(정본 `guard`) — 그 경우도 여기서는 그냥
  /// 성공으로 돌려주고, 되돌리기 판단은 호출자(`sync_controller.dart`의
  /// `ackSession`)가 응답의 [AckResultDto.state]를 보고 한다.
  Future<AckResultDto> ack(String sessionKey) async => AckResultDto.fromJson(
    await _request(
      'POST',
      kSessionsPath,
      extraSegments: <String>[sessionKey, 'ack'],
    ),
  );

  /// `POST /dashboard/sessions/{key}/seen` — 읽음/안읽음 마커(상태 전이 아님,
  /// 이벤트 로그에 적재되지 않는다 — 정본 `client_actions.MarkSeen`,
  /// `effect:"marker"`).
  ///
  /// [lastTransitionId]는 클라이언트가 지금 보고 있는 `SessionViewDto.
  /// lastTransitionId`를 그대로 실어 보낸다 — 서버가 그 값으로 단조 갱신한다
  /// (뒤처진 기기가 과거 값을 보내 앞선 기기의 갱신을 역행시키지 않도록
  /// `MAX(...)`로 받는다, 0004 마이그레이션). 생략하면 서버는 현재
  /// `last_transition_id`로 채운다. 응답 `{ok:true, seen_transition_id}`에서
  /// 갱신된 값만 뽑아 돌려준다 — 실패는 [DashboardApiException]으로만
  /// 던진다(호출자 `sync_controller.dart`의 `markSeen`이 무해하게 삼킨다).
  Future<int?> markSeen(String sessionKey, {int? lastTransitionId}) async {
    final json = await _request(
      'POST',
      kSessionsPath,
      extraSegments: <String>[sessionKey, 'seen'],
      body: lastTransitionId == null
          ? null
          : <String, Object?>{'last_transition_id': lastTransitionId},
    );
    final Object? seen = json['seen_transition_id'];
    return seen is int ? seen : null;
  }

  /// `DELETE /dashboard/sessions/{key}` — 세션 기록 삭제(살아있는 세션은
  /// 다음 이벤트에서 다시 나타난다 — 삭제 UI 사양 확인 다이얼로그 문구와
  /// 같은 사실). 서버는 같은 자리에서 `dashboard_seen` 행도 함께 지운다
  /// (내 담당 아님). 지울 게 없어서 404가 와도 성공으로 접는다 —
  /// [removeSubscription]과 같은 관용이다.
  Future<void> deleteSession(String sessionKey) async {
    try {
      await _request(
        'DELETE',
        kSessionsPath,
        extraSegments: <String>[sessionKey],
      );
    } on DashboardClientError catch (error) {
      if (error.statusCode != 404) rethrow;
    }
  }

  // ─── 내부 ──────────────────────────────────────────────────────────────

  Uri _url(
    String path,
    Map<String, String> query, {
    List<String> extraSegments = const <String>[],
  }) {
    final base = config.baseUrl;
    final segments = <String>[
      ...base.pathSegments.where((String segment) => segment.isNotEmpty),
      ...path.split('/').where((String segment) => segment.isNotEmpty),
      ...extraSegments,
    ];
    return base.replace(
      pathSegments: segments,
      queryParameters: query.isEmpty ? null : query,
    );
  }

  Map<String, String> _headers({required bool hasBody}) => <String, String>{
    'Accept': 'application/json',
    if (hasBody) 'Content-Type': 'application/json',
    if (config.clientToken != null && config.clientToken!.isNotEmpty)
      'Authorization': 'Bearer ${config.clientToken}',
  };

  /// 요청 한 번 = 전송 + 상태 코드 분기 + JSON 객체 파싱.
  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, String> query = const <String, String>{},
    Map<String, Object?>? body,
    List<String> extraSegments = const <String>[],
  }) async {
    final request = ApiRequest(
      method: method,
      url: _url(path, query, extraSegments: extraSegments),
      headers: _headers(hasBody: body != null),
      body: body == null ? null : jsonEncode(body),
    );

    final ApiResponse response;
    try {
      response = await send(request).timeout(config.timeout);
    } on TimeoutException {
      final fault = TimeoutFault(
        method: method,
        path: path,
        timeoutMs: config.timeout.inMilliseconds,
      );
      throw DashboardTimeout('$fault', fault: fault);
    } on DashboardApiException {
      rethrow;
    } catch (error) {
      final fault = TransportFault(method: method, path: path, cause: '$error');
      throw DashboardNetworkFailure('$fault', fault: fault);
    }

    if (!response.isSuccess) throw _statusFailure(response, method, path);
    return _decodeObject(response, method, path);
  }

  /// 실패 응답을 종류별 예외로 나눈다. 본문의 `error` 문구가 있으면 살린다.
  DashboardApiException _statusFailure(
    ApiResponse response,
    String method,
    String path,
  ) {
    final detail = _errorDetail(response);
    final where = '$method $path';
    return switch (response.statusCode) {
      401 => DashboardUnauthorized('$where: $detail'),
      403 => DashboardForbidden('$where: $detail'),
      >= 500 => DashboardServerError(
        '$where: $detail',
        statusCode: response.statusCode,
      ),
      _ => DashboardClientError(
        '$where: $detail',
        statusCode: response.statusCode,
      ),
    };
  }

  /// 실패 본문에서 사람이 읽을 문구를 꺼낸다. JSON이 아니면 앞부분만 자른다.
  String _errorDetail(ApiResponse response) {
    final body = response.body.trim();
    if (body.isEmpty) return 'HTTP ${response.statusCode}';
    try {
      final Object? decoded = jsonDecode(body) as Object?;
      if (decoded is Map<String, dynamic>) {
        final Object? message = decoded['error'] ?? decoded['message'];
        if (message is String && message.isNotEmpty) return message;
      }
    } on FormatException {
      // JSON이 아닌 오류 본문(프록시 HTML 등)은 그대로 잘라 보여준다.
    }
    return body.length > 200 ? '${body.substring(0, 200)}...' : body;
  }

  Map<String, dynamic> _decodeObject(
    ApiResponse response,
    String method,
    String path,
  ) {
    final body = response.body.trim();
    // 204나 빈 본문은 "성공했고 돌려줄 게 없다"로 읽는다.
    if (body.isEmpty) return <String, dynamic>{};
    final Object? decoded;
    try {
      decoded = jsonDecode(body) as Object?;
    } on FormatException catch (error) {
      throw _malformed(method, path, '$error');
    }
    if (decoded is! Map<String, dynamic>) {
      throw _malformed(method, path, '${decoded.runtimeType}');
    }
    return decoded;
  }

  DashboardMalformedResponse _malformed(
    String method,
    String path,
    String detail,
  ) {
    final fault = MalformedResponseFault(
      method: method,
      path: path,
      detail: detail,
    );
    return DashboardMalformedResponse('$fault', fault: fault);
  }
}

/// 조립된 클라이언트 (3계층: 시임 두 개를 엮는 얇은 지점).
final Provider<DashboardApi> dashboardApiProvider = Provider<DashboardApi>(
  (ref) => DashboardApi(
    send: ref.watch(httpSendProvider),
    config: ref.watch(dashboardApiConfigProvider),
  ),
);
