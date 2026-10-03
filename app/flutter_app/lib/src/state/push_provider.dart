/// push 등록·수신 시임 — 웹(FCM 웹 토큰)과 macOS(APNs 경유 FCM 토큰) 둘.
///
/// **TASK D-app 이전에는 웹 전용이었다.** 지금은 같은 [pushRegistrarProvider]
/// 하나가 호스트를 보고 두 경로 중 하나를 고른다(A안 설계 ②③):
///
/// | 호스트 | 토큰 취득 | `transport` | `platform` |
/// |---|---|---|---|
/// | 웹 | `web_push_web.dart`(벤더링한 Firebase JS SDK) | `fcm` | `web` |
/// | macOS | `apns_push_native.dart`(`firebase_messaging`) | `fcm-apns` | `macos` |
/// | 그 밖 | — | — | [PushAvailability.notApplicable] |
///
/// **채널은 여전히 FCM 하나다** — `fcm-apns`는 별도 채널이 아니라 같은 FCM
/// 트랜스포트가 맡는 두 번째 대상 모양이다(정본 `push.channels.fcm-apns`).
///
/// 두 호스트 모두 표준 Web Push 구독(`POST /dashboard/subscriptions`)이
/// 아니라 **FCM 등록 토큰을 기기로** 등록한다 — 서버의 `dashboard_devices`
/// 한 테이블이 macOS 앱과 웹 PWA를 함께 담는다.
/// (`registerSubscription`/`PushSubscriptionDto`는 정본이 `vapid-web` 채널을
/// "나중에 붙일 수 있게" 열어 둔 자리라 API 계층에 그대로 남아 있지만, 지금
/// 이 경로는 쓰지 않는다.)
///
/// 서버가 자격증명을 안 줬을 때(`DashboardPushUnavailable`, 빈 채널,
/// `client_ready:false`/`apple_client_ready:false`)는 예외를 다시 던지지
/// 않는다 — [PushAvailability.unavailable]로 접어 호출자가 폴링만으로 계속
/// 동작하게 한다. push는 "있으면 좋은 깨우기 힌트"고 없어도 동기화 폴링이
/// 정합성을 담보한다는 정본 `push` 절의 원칙 그대로다. macOS에서는 그
/// 저하가 곧 "로컬 알림 폴백 유지"이기도 하다(설계 ②).
///
/// `capability_provider.dart`와 같은 3계층. [webPushTokenFnProvider]/
/// [apnsTokenFnProvider]가 1계층(실제 OS·브라우저 API 호출, io/web 분기)
/// 이고, [pushRegistrarProvider]가 그 위에 자격증명 조회·호스트 분기·서버
/// 등록·소유권 갱신까지 접은 2/3계층이다.
///
/// 이 파일은 등록(나가는 방향)뿐 아니라 **수신 신호(들어오는 방향)**
/// [pushSignalWatchProvider]와 **소유권** [apnsRegisteredProvider]도 함께
/// 갖는다 — 셋이 같은 "push 배선"이라는 하나의 관심사이고, 서로 다른
/// 파일에 흩어지면 "지금 배너의 주인이 누구인가"를 한눈에 읽을 수 없다.
library;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/platform/apns_push.dart';
import 'package:my_dashboard/src/platform/apns_push_native.dart'
    if (dart.library.js_interop) 'package:my_dashboard/src/platform/apns_push_web.dart'
    as apns;
import 'package:my_dashboard/src/platform/push_signal.dart';
import 'package:my_dashboard/src/platform/push_signal_native.dart'
    if (dart.library.js_interop) 'package:my_dashboard/src/platform/push_signal_web.dart'
    as signals;
import 'package:my_dashboard/src/platform/web_push.dart';
import 'package:my_dashboard/src/platform/web_push_native.dart'
    if (dart.library.js_interop) 'package:my_dashboard/src/platform/web_push_web.dart'
    as bridge;
import 'package:my_dashboard/src/state/capability_provider.dart'
    show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/config_provider.dart'
    show dashboardApiConfigControllerProvider;

// ─── 값 ──────────────────────────────────────────────────────────────────

/// 이번 등록 시도의 결과.
enum PushAvailability {
  /// 이 호스트는 push 등록 대상이 아니다(웹도, macOS도 아닌 데스크톱).
  /// 아무것도 하지 않았다 — 서버도 브라우저도 건드리지 않는다.
  notApplicable,

  /// 서버에 push 자격증명이 없거나(빈 채널, `client_ready:false`) 이
  /// 브라우저가 웹 푸시를 지원하지 않는다 — 폴링만으로 계속 동작한다.
  unavailable,

  /// 알림 권한이 아직 없다. 설정 화면 버튼이
  /// [webPushPermissionRequestProvider]를 부른 뒤 다시 시도해야 한다.
  /// **부팅 경로가 스스로 프롬프트를 띄우지 않는다는 뜻**이기도 하다.
  permissionRequired,

  /// 지원·권한은 있는데 이번 시도가 실패했다(등록 거절, getToken 오류,
  /// 서버 등록 실패).
  failed,

  /// 토큰을 받아 서버에 기기로 등록했다.
  registered,
}

/// [pushRegistrarProvider]가 돌려주는 값 하나.
@immutable
class PushRegistrationResult {
  const PushRegistrationResult({
    required this.availability,
    this.token,
    this.detail = '',
    this.transport = '',
  });

  final PushAvailability availability;

  /// [PushAvailability.registered]일 때만 채워진다. FCM 등록 토큰이다 —
  /// 화면에 그대로 노출하지 않는다(자격증명에 준하는 값이다).
  final String? token;

  /// 진단용 사유. 사용자에게 그대로 보여주지 않는다(i18n 대상이 아니다).
  final String detail;

  /// 이번 시도가 탄 경로의 `dashboard_devices.transport`
  /// ([kPushTransportFcm] 또는 [kPushTransportFcmApns]). 아무 경로도 타지
  /// 않았으면(notApplicable) 빈 문자열이다 — 소유권 규칙(설계 ②)이
  /// "APNs로 등록됐는가"를 이 값으로 판정한다.
  final String transport;

  bool get isRegistered => availability == PushAvailability.registered;

  /// 설계 ②의 소유권 판정: 이 결과가 곧 "이제부터 배너는 APNs가 띄운다".
  bool get isApnsRegistered =>
      isRegistered && transport == kPushTransportFcmApns;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PushRegistrationResult &&
          other.availability == availability &&
          other.token == token &&
          other.detail == detail &&
          other.transport == transport;

  @override
  int get hashCode => Object.hash(availability, token, detail, transport);

  @override
  String toString() =>
      'PushRegistrationResult($availability'
      '${transport.isEmpty ? '' : ', $transport'}'
      '${detail.isEmpty ? '' : ', $detail'})';
}

// ─── 1계층: 브라우저 API 시임 ───────────────────────────────────────────

/// 실제로 브라우저에서 FCM 등록 토큰을 받아 온다(서비스 워커 등록 ->
/// 권한 확인 -> Firebase `getToken`). 데스크톱 브리지는 언제나
/// [WebPushTokenStatus.unsupported]를 돌린다.
typedef WebPushTokenFn =
    Future<WebPushTokenResult> Function(PushConfigDto config);

final Provider<WebPushTokenFn> webPushTokenFnProvider =
    Provider<WebPushTokenFn>((ref) => bridge.acquireWebPushToken);

/// 알림 권한 프롬프트. **설정 화면의 명시적 버튼만 부른다** — 부팅 경로에서
/// 부르면 앱이 뜨자마자 권한 팝업을 던지는 앱이 된다.
typedef WebPushPermissionFn = Future<bool> Function();

final Provider<WebPushPermissionFn> webPushPermissionRequestProvider =
    Provider<WebPushPermissionFn>((ref) => bridge.requestWebPushPermission);

/// 지금의 알림 권한 문자열(`default` | `granted` | `denied` | `unsupported`).
/// 화면이 "권한 필요" 안내를 띄울지 정하는 데 쓴다.
final Provider<String> webPushPermissionProvider = Provider<String>(
  (ref) => bridge.currentWebPushPermission(),
);

// ─── 1계층: APNs(macOS) 시임 ────────────────────────────────────────────

/// 이 호스트가 APNs 경로 대상인가(macOS 데스크톱만 true).
///
/// [isWasmRuntimeProvider]와 짝을 이루는 **두 번째** 호스트 판정이다.
/// 둘 다 false인 호스트(linux/windows)에서 [pushRegistrarProvider]는
/// [PushAvailability.notApplicable]로 즉시 끝나고 서버도 건드리지 않는다.
final Provider<bool> isApplePushHostProvider = Provider<bool>(
  (ref) => apns.hasApplePushHost,
);

/// 실제로 macOS에서 APNs 경유 FCM 등록 토큰을 받아 온다
/// (Firebase 초기화 -> 권한 -> 포그라운드 배너 억제 -> APNs/FCM 토큰).
/// 웹 브리지는 언제나 [ApnsTokenStatus.unsupported]를 돌린다.
typedef ApnsTokenFn = Future<ApnsTokenResult> Function(PushConfigDto config);

final Provider<ApnsTokenFn> apnsTokenFnProvider = Provider<ApnsTokenFn>(
  (ref) => apns.acquireApnsToken,
);

// ─── push 수신 신호 (배선 (4)) ──────────────────────────────────────────

/// 서비스 워커(웹)나 `onMessageOpenedApp`(macOS)이 "알림을 눌렀다"를
/// 알려 오는 통로. `app.dart`의 `_AppHome`이 이 스트림 하나만 듣는다.
typedef PushSignalWatchFn = Stream<PushSignal> Function();

final Provider<PushSignalWatchFn> pushSignalWatchProvider =
    Provider<PushSignalWatchFn>((ref) => signals.watchPushSignals);

// ─── 소유권 (설계 ②) ────────────────────────────────────────────────────

/// APNs 등록에 성공했는가 = **배너의 주인이 누구인가**.
///
/// true면 모든 배너가 서버 -> FCM -> APNs 경로로 온다. 그 상태에서
/// `notify_provider.dart`가 로컬 알림까지 띄우면 같은 전이로 배너가 둘
/// 뜬다 — 그래서 그 파일이 이 값을 보고 발신을 억제한다(설계 ②).
///
/// 등록에 실패하거나(권한 거부, entitlement 미활성) 애초에 macOS가
/// 아니면 false로 남고, 기존 로컬 알림 경로가 그대로 살아 있다.
class ApnsOwnership extends Notifier<bool> {
  @override
  bool build() {
    // 새 주소/토큰을 적용하면 옛 서버의 등록 성공은 새 연결의 소유권이 아니다.
    // 새 등록이 끝나기 전까지 로컬 배너가 맡는다.
    ref.watch(dashboardApiConfigControllerProvider);
    return false;
  }

  /// [pushRegistrarProvider]의 결과 하나를 그대로 반영한다. 등록이 실패로
  /// 바뀌면(자격증명 회수, 권한 철회) 소유권도 곧바로 되돌아간다 —
  /// "한 번 켜지면 영원히"는 알림이 조용히 사라지는 길이다.
  void applyResult(PushRegistrationResult result) {
    state = result.isApnsRegistered;
  }
}

final NotifierProvider<ApnsOwnership, bool> apnsRegisteredProvider =
    NotifierProvider<ApnsOwnership, bool>(ApnsOwnership.new);

// ─── 2/3계층: 자격증명 조회 + 호스트 분기 + 서버 등록 ───────────────────

/// 토큰을 (필요하면) 받아 서버에 기기로 등록한다. [label]은 사람이 읽는 기기
/// 이름이고, 모르면 생략한다 — 서버가 기존 이름을 유지한다.
typedef PushRegisterFn =
    Future<PushRegistrationResult> Function({String? label});

/// 두 경로가 공유하는 앞단: `GET /dashboard/push-config`.
///
/// `DashboardPushUnavailable`뿐 아니라 **모든** API 실패를 값으로 접는다.
/// 이 함수는 부팅 경로(`app.dart`의 `_AppHome`)가 기다리지 않고 부르는
/// 자리라, 던지면 잡히지 않는 비동기 예외가 된다 — 서버 주소를 아직
/// 설정하지 않은 첫 실행이 바로 그 경우다(연결 실패).
Future<({PushConfigDto? config, String failure})> _loadPushConfig(
  DashboardApi api,
) async {
  try {
    return (config: await api.pushConfig(), failure: '');
  } on DashboardApiException catch (error) {
    return (config: null, failure: error.message);
  }
}

/// 등록 성공 이후 공통 뒷단: `POST /dashboard/devices`.
Future<PushRegistrationResult> _registerDevice({
  required DashboardApi api,
  required String token,
  required String platform,
  required String transport,
  String? label,
}) async {
  try {
    await api.registerDevice(
      token: token,
      platform: platform,
      transport: transport,
      label: label,
    );
  } on DashboardApiException catch (error) {
    // 서버 등록 실패도 앱을 멈추게 두지 않는다 — 폴링은 그대로 돈다.
    return PushRegistrationResult(
      availability: PushAvailability.failed,
      detail: '기기 등록 실패: ${error.message}',
      transport: transport,
    );
  }
  return PushRegistrationResult(
    availability: PushAvailability.registered,
    token: token,
    transport: transport,
  );
}

/// 웹 경로 — 벤더링한 Firebase JS SDK로 받은 FCM 웹 토큰을
/// `transport:'fcm'` / `platform:'web'`으로 등록한다(T17f 그대로).
Future<PushRegistrationResult> _webRegisterBridge({
  required DashboardApi api,
  required WebPushTokenFn acquireToken,
  String? label,
}) async {
  final loaded = await _loadPushConfig(api);
  final config = loaded.config;
  if (config == null) {
    return PushRegistrationResult(
      availability: PushAvailability.unavailable,
      detail: loaded.failure,
    );
  }
  if (!config.canSubscribeOnWeb) {
    // `client_ready:false`(서버가 자격증명을 반만 설정)도 여기로 온다.
    return const PushRegistrationResult(
      availability: PushAvailability.unavailable,
      detail: '서버가 웹 클라이언트용 자격증명을 주지 않았다',
    );
  }

  final result = await acquireToken(config);
  switch (result.status) {
    case WebPushTokenStatus.permissionRequired:
      return PushRegistrationResult(
        availability: PushAvailability.permissionRequired,
        detail: result.detail,
      );
    case WebPushTokenStatus.unsupported:
      return PushRegistrationResult(
        availability: PushAvailability.unavailable,
        detail: result.detail,
      );
    case WebPushTokenStatus.failed:
      return PushRegistrationResult(
        availability: PushAvailability.failed,
        detail: result.detail,
      );
    case WebPushTokenStatus.acquired:
      break;
  }

  final token = result.token;
  if (token == null || token.isEmpty) {
    return const PushRegistrationResult(
      availability: PushAvailability.failed,
      detail: 'acquired인데 토큰이 비어 있다',
    );
  }

  return _registerDevice(
    api: api,
    token: token,
    platform: kPushPlatformWeb,
    transport: kPushTransportFcm,
    label: label,
  );
}

/// macOS 경로 (A안 설계 ②③) — `apple_config`로 Firebase를 코드 초기화하고
/// APNs 경유로 받은 FCM 등록 토큰을 `transport:'fcm-apns'` /
/// `platform:'macos'`로 등록한다.
///
/// 웹과 같은 모양이지만 판정하는 자격증명이 다르다
/// ([PushConfigDto.canSubscribeOnApple]) — VAPID 키는 브라우저 구독 전용
/// 값이라 여기서는 보지 않는다.
Future<PushRegistrationResult> _appleRegisterBridge({
  required DashboardApi api,
  required ApnsTokenFn acquireToken,
  String? label,
}) async {
  final loaded = await _loadPushConfig(api);
  final config = loaded.config;
  if (config == null) {
    return PushRegistrationResult(
      availability: PushAvailability.unavailable,
      detail: loaded.failure,
    );
  }
  if (!config.canSubscribeOnApple) {
    // `apple_client_ready:false`(FIREBASE_APPLE_CONFIG 미설정)도 여기로 온다.
    // 실패가 아니다 — 로컬 알림 폴백이 그대로 배너를 맡는다(설계 ②).
    return const PushRegistrationResult(
      availability: PushAvailability.unavailable,
      detail: '서버가 Apple 클라이언트용 자격증명(apple_config)을 주지 않았다',
    );
  }

  final result = await acquireToken(config);
  switch (result.status) {
    case ApnsTokenStatus.permissionRequired:
      return PushRegistrationResult(
        availability: PushAvailability.permissionRequired,
        detail: result.detail,
        transport: kPushTransportFcmApns,
      );
    case ApnsTokenStatus.unsupported:
      // entitlement 미활성(설계 ⑤)이 여기로 온다 — 실패가 아니다.
      return PushRegistrationResult(
        availability: PushAvailability.unavailable,
        detail: result.detail,
        transport: kPushTransportFcmApns,
      );
    case ApnsTokenStatus.failed:
      return PushRegistrationResult(
        availability: PushAvailability.failed,
        detail: result.detail,
        transport: kPushTransportFcmApns,
      );
    case ApnsTokenStatus.acquired:
      break;
  }

  final token = result.token;
  if (token == null || token.isEmpty) {
    return const PushRegistrationResult(
      availability: PushAvailability.failed,
      detail: 'acquired인데 토큰이 비어 있다',
      transport: kPushTransportFcmApns,
    );
  }

  return _registerDevice(
    api: api,
    token: token,
    platform: kPushPlatformMacos,
    transport: kPushTransportFcmApns,
    label: label,
  );
}

/// 테스트는 이 Provider를 override하거나, [dashboardApiProvider]/
/// [webPushTokenFnProvider]/[apnsTokenFnProvider]를 각각 override해 세부
/// 분기를 태운다.
///
/// **의존을 `watch`가 아니라 호출 시점의 `read`로 잡는 이유**: 호스트 분기
/// ([isWasmRuntimeProvider]/[isApplePushHostProvider])를 가장 먼저 보고,
/// 어느 쪽도 아니면 그 뒤의 [dashboardApiProvider]를 **아예 읽지 않는다**.
/// 그 provider는 서버 주소·토큰 override가 없으면 던지는 계약이라
/// (`dashboard_api.dart`), 눈으로만 읽어도 위젯 테스트가 푸시와 무관하게
/// 깨진다. "이 호스트가 아니면 아무것도 건드리지 않는다"는 이 파일의
/// 약속을 provider 배선 수준에서도 지킨다.
///
/// **소유권 갱신도 여기서 정확히 한 번.** 결과가 나오면 곧바로
/// [apnsRegisteredProvider]에 반영한다 — 호출자(부팅 경로, 설정 저장)는
/// 소유권 규칙을 몰라도 되고, `notify_provider.dart`는 그 값만 본다.
final Provider<PushRegisterFn> pushRegistrarProvider = Provider<PushRegisterFn>(
  (ref) {
    return ({String? label}) async {
      final connection = ref.read(
        dashboardApiConfigControllerProvider.notifier,
      );
      final revision = connection.revision;
      final PushRegistrationResult result;
      if (ref.read(isWasmRuntimeProvider)) {
        result = await _webRegisterBridge(
          api: ref.read(dashboardApiProvider),
          acquireToken: ref.read(webPushTokenFnProvider),
          label: label,
        );
      } else if (ref.read(isApplePushHostProvider)) {
        result = await _appleRegisterBridge(
          api: ref.read(dashboardApiProvider),
          acquireToken: ref.read(apnsTokenFnProvider),
          label: label,
        );
      } else {
        result = const PushRegistrationResult(
          availability: PushAvailability.notApplicable,
        );
      }
      // **소유권 갱신은 반드시 비동기 경계 뒤에서 한다.** 부팅 경로
      // (`app.dart`의 `_AppHome.initState`)가 이 함수를 위젯 트리 빌드 중에
      // 부르는데, 그 구간에서 provider를 수정하면 riverpod이 "Tried to modify
      // a provider while the widget tree was building" 어서션으로 죽는다.
      // 위 두 등록 경로는 네트워크를 타므로 이미 한 번 이상 suspend하지만,
      // `notApplicable` 분기는 await가 하나도 없어 여기까지 동기로 도달한다 —
      // 그래서 분기와 무관하게 여기서 한 번 양보한다(riverpod 문서가 안내하는
      // "Delay your modification"과 같은 해법이다).
      await Future<void>.value();
      if (connection.revision != revision) {
        return const PushRegistrationResult(
          availability: PushAvailability.failed,
          detail: '연결이 바뀌어 이전 push 등록 결과를 버렸다',
        );
      }
      ref.read(apnsRegisteredProvider.notifier).applyResult(result);
      return result;
    };
  },
);
