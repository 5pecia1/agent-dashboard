/// T16(+ 후속): macOS 알림 프로브 선택("부팅 시 1회, 재프로브 가능") +
/// 클릭 딥링크.
///
/// 프로브 순서([probeNotificationSupport], 부팅 시퀀스에서 최소 한 번 —
/// 재호출 계약은 아래 "재프로브" 절 참고):
///   1. `flutter_local_notifications`로 권한을 요청한다 — `initialize()`가
///      돌려주는 `bool`이 곧 `UNUserNotificationCenter.requestAuthorization`
///      의 `granted` 콜백 값이다(패키지의 macOS 네이티브 구현,
///      `FlutterLocalNotificationsPlugin.swift`의 `requestPermissionsImpl`
///      참고). 승인되면 자기 테스트 알림을 `show()`한다. 둘 다 예외 없이
///      끝나면 1차 백엔드로 확정한다.
///   2. `initialize()`가 예외 없이 답했지만 승인이 아니면(`granted !=
///      true`), 그 답이 **진짜 거부**인지 **판정 불가**인지를
///      `MacOSFlutterLocalNotificationsPlugin.checkPermissions()`로 한 번
///      더 확인한다(macOS 지원 여부는 `flutter_local_notifications`
///      22.3.0의 `lib/src/platform_flutter_local_notifications.dart`
///      `MacOSFlutterLocalNotificationsPlugin.checkPermissions` 및 macOS
///      네이티브 `FlutterLocalNotificationsPlugin.swift`의
///      `checkPermissions(_:_:)`로 확인함 — `UNUserNotificationCenter
///      .getNotificationSettings`의 `authorizationStatus`를 그대로
///      옮긴다). `isEnabled == false`면 사용자/시스템이 명시적으로 거부한
///      것이다 — 이때는 **osascript로 접지 않는다**: [NotificationBackend
///      .none]으로 확정하고 [DesktopFeatureStatus.notifyPermissionDenied]를
///      true로 남긴다. 알림은 안 나간다(정직 — 클릭 안 되는 폴백 배너로
///      혼란을 주지 않는다).
///   3. `initialize()`/`show()`가 **예외로 실패**했거나(플러그인이 아직
///      네이티브에 등록되지 않은 등 고장) `checkPermissions()`가 판정을
///      내리지 못하면(예외/`null`) — 이 경우에만 `osascript display
///      notification`으로 같은 자기 테스트를 한 번 더 시도한다. 종료
///      코드 0이면 2차 백엔드로 확정한다.
///   4. 둘 다 실패하면 [NotificationBackend.none] — [DesktopFeatureStatus
///      .notifyLocal]은 계속 false로 남는다(capability_provider.dart가 이
///      값을 그대로 읽어 `notify.local`을 미구성으로 응답한다).
///
/// 위 2/3의 분기가 이번 후속 작업의 핵심이다: 이전에는 `granted != true`를
/// 전부 "실패"로 뭉뚱그려 osascript로 접었다 — 그 결과 시스템이 권한을
/// 거부한 상태에서도(권한 프롬프트 자체가 다시 뜨지 않으니 사용자는 그
/// 사실을 알 방법이 없는데) 클릭해도 아무 반응 없는 "Script Editor" 명의
/// 배너만 받는 혼란스러운 경험이 났다. 이제는 "권한이 거부됐다"와
/// "플러그인이 고장났다"를 구분해서, 전자는 [DesktopFeatureStatus
/// .notifyPermissionDenied]로 화면에 드러내고(설정 화면 배너, `setup_page
/// .dart`) 후자만 osascript로 접는다.
///
/// 클릭 딥링크는 1차 백엔드에서만 가능하다 — `osascript display
/// notification`을 쓰는 현재 폴백 구현에는 클릭 콜백이 연결되어 있지
/// 않다. 2차로
/// 접힌 경우 알림은 뜨지만 탭해도 아무 일도 일어나지 않는다 — 완료
/// 기준 (d)가 요구하는 대로 이 사실을 감추지 않고 [currentNotificationBackend]
/// 로 그대로 드러낸다(설정 화면도 이 값을 읽어 폴백 모드임을 한 줄로
/// 고지한다).
///
/// **재프로브 계약(갱신).** 예전 문서는 "부팅 시퀀스에서 정확히 한 번"만
/// 부른다고 못 박았다 — 이 스타터에 아직 "이미 프로브했음"을 디스크에
/// 남기는 인프라가 없고, OS 알림 권한은 사용자가 시스템 설정에서 언제든
/// 바꿀 수 있어 매 부팅 재확인이 `window_control`/`global_hotkey`와 같은
/// "실제로 확인된 상태만 반영한다" 원칙에 맞는다는 이유였다. 이제는 그
/// 이유가 부팅 시점을 넘어서까지 성립한다는 걸 인정한다: 권한이
/// denied였다가 사용자가 이 실행 중에(시스템 설정에서) granted로 바꿀 수도
/// 있으므로, [probeNotificationSupport]는 **부팅 시퀀스에서 최소 한 번,
/// 그리고 그 이후에도 몇 번이든 안전하게 재호출**할 수 있다 — 재호출은
/// 상태를 다시 계산해 덮어쓸 뿐 누적되는 부작용이 없다(`_plugin.initialize`
/// 재호출도 안전하다, 아래 참고). 설정 화면의 "테스트 알림" 버튼
/// (`setup_page.dart`)이 이 재호출 지점이다 — 사용자가 시스템 설정에서
/// 권한을 켠 뒤 앱을 재시작하지 않고도 복구되게 한다.
///
/// macOS는 이미 승인/거부된 앱에는 재프롬프트를 띄우지 않으므로
/// (`requestAuthorization` 재호출은 조용히 기존 답을 돌려준다) 부팅이든
/// 재프로브든 반복 호출이 사용자에게 반복 권한 팝업을 보여주지는 않는다.
library;

import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:my_dashboard/src/data/notification_tap.dart';
import 'package:my_dashboard/src/platform/feature_status.dart';
import 'package:my_dashboard/src/platform/resident_mode_native.dart'
    show showResidentWindow;

export 'package:my_dashboard/src/data/notification_tap.dart'
    show NotificationTap, NotificationTapHandler;

/// 실제로 알림을 띄우는 데 쓸 백엔드. 프로브가 부팅 시 정확히 한 번
/// 정한다 — 이후 [showNotification] 호출은 이 값을 그대로 따른다.
enum NotificationBackend {
  /// 1차: `UNUserNotificationCenter` 기반. 클릭 콜백을 지원한다(딥링크
  /// 가능).
  flutterLocalNotifications,

  /// 2차 폴백: `osascript display notification`. 클릭 콜백이 없다(딥링크
  /// 불가능 — 완료 기준 (d)).
  osascript,

  /// 둘 다 못 쓴다 — 알림 자체가 나가지 않는다.
  none,
}

/// 자기 테스트 알림에 쓰는 고정 id. 실제 알림(세션 전이)은
/// [TransitionDto.id](`notify_provider.dart`의 `NotifyPayload.id`를 거쳐
/// [showNotification]의 `id` 인자로 그대로 들어온다)를 알림 id로 쓴다 —
/// 서버 AUTOINCREMENT라 `0`과 절대 충돌하지 않는다(파일 하단
/// [_showViaFlutterLocalNotifications] 참고).
///
/// 예전에는 프로세스 메모리 카운터(`_nextNotificationId`)가 매번 새 id를
/// 뽑았는데, 그 카운터가 앱 재시작마다 리셋되면서 macOS 알림 센터에 남은
/// "전달된 알림"의 id와 충돌 -> `UNUserNotificationCenter`가 새 알림이
/// 아니라 **제자리 갱신**으로 처리 -> 배너도 소리도 안 나는 회귀가 실
/// A/B 로그로 확정됐다. 전이 id는 값 자체가 유일성을 보장하므로 그 카운터
/// 자체가 필요 없어져 제거했다.
const int _selfTestNotificationId = 0;

/// 대응하는 전이가 없는 일시 알림(트레이 음소거 확인 토스트 등,
/// `tray_native.dart`)에 쓰는 예약 id. `0x7fffffff`(32비트 부호 있는 정수
/// 최댓값)라 서버 전이 id(1부터 단조 증가하는 AUTOINCREMENT)가 실무적으로
/// 도달할 수 없다 — 이 id는 항상 `show` 직전에 `cancel`부터 하므로(파일
/// 하단 [showNotification] 참고) 값 자체는 무엇이든 상관없지만, 실제 전이
/// id 범위와 겹치지 않는 값을 골라 혼동을 피한다.
const int _transientNotificationId = _notificationIdMask;

/// 자기 테스트 알림의 제목/본문. 위젯 트리가 아직 없는 부팅 시퀀스에서
/// 도는 코드라 i18n 어댑터([t])를 쓸 수 없다(그 어댑터는 `WidgetRef`가
/// 있어야 한다) — 화면에 노출되는 문구가 아니라 내부 자기 진단용이라
/// 고정 문자열로 둔다.
const String _selfTestTitle = 'My Dashboard';
const String _selfTestBody = 'Notifications ready.';

/// 알림 id로 쓸 수 있는 32비트 부호 있는 정수의 최댓값 — 이 패키지가
/// 내부적으로 Android(int32) 제약을 함께 물려받는다.
const int _notificationIdMask = 0x7fffffff;

NotificationBackend _backend = NotificationBackend.none;
NotificationTapHandler? _tapHandler;
const int _receivedTapKeyLimit = 16;
NotificationTap? _pendingTap;
final LinkedHashSet<String> _receivedTapKeys = LinkedHashSet();
Future<void>? _coldLaunchCapture;

final FlutterLocalNotificationsPlugin _plugin =
    FlutterLocalNotificationsPlugin();

/// 지금 선택된 백엔드. 프로브 이전엔 항상 [NotificationBackend.none]이다.
NotificationBackend get currentNotificationBackend => _backend;

/// 플러그인과 같은 Flutter 대상 플랫폼을 사용한다. 테스트에서는 채널을
/// 대역으로 바꿔 어느 호스트 OS에서나 macOS 콜백을 검증할 수 있다.
bool get supportsLocalNotifications =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// 알림 탭 콜백을 등록한다(부팅 시퀀스에서 한 번, `feature_setup.dart`).
/// 등록 전에 도착한 냉시작·일반 클릭은 마지막 선택 하나만 전달한다.
void registerNotificationTapHandler(NotificationTapHandler handler) {
  _tapHandler = handler;
  final pending = _pendingTap;
  _pendingTap = null;
  if (pending != null) handler(pending);
}

/// 실제 OS 호출 없이 콜백 등록 전후의 부팅 순서를 검증하기 위한 초기화다.
@visibleForTesting
void resetNotificationTapStateForTest() {
  _tapHandler = null;
  _pendingTap = null;
  _receivedTapKeys.clear();
  _coldLaunchCapture = null;
  _backend = NotificationBackend.none;
}

/// 부팅 시퀀스가 최소 한 번 부른다. 설정 화면의 "테스트 알림" 버튼도 이
/// 함수를 다시 부른다(재프로브 계약, 파일 상단 문서 참고) — 몇 번을
/// 불러도 안전하다. 결과를 [DesktopFeatureStatus.notifyLocalChanged]와
/// [DesktopFeatureStatus.notifyPermissionDeniedChanged]에 거울로 남긴다.
Future<void> probeNotificationSupport() async {
  if (!supportsLocalNotifications) {
    // linux/windows에는 osascript도 없다 — 지금 이 두 OS에는 알림 백엔드가
    // 없다(향후 T16 후속 작업 대상). 웹은 이 파일 자체가 로드되지 않는다
    // (`local_notifications_web.dart`가 대신 쓰인다).
    _backend = NotificationBackend.none;
    desktopFeatureStatus.notifyPermissionDeniedChanged(false);
    desktopFeatureStatus.notifyLocalChanged(false);
    return;
  }

  final outcome = await _probePrimaryOutcome();
  final osascriptSucceeded = outcome == PrimaryProbeOutcome.unavailable
      ? await _probeOsascript()
      : false;
  final result = resolveProbeResult(
    outcome,
    osascriptSucceeded: osascriptSucceeded,
  );
  _backend = result.backend;
  desktopFeatureStatus.notifyPermissionDeniedChanged(result.permissionDenied);
  desktopFeatureStatus.notifyLocalChanged(_backend != NotificationBackend.none);
}

/// 1차 백엔드([FlutterLocalNotificationsPlugin])를 시도한 결과의 3분류.
/// [resolveProbeResult]가 이 값을 받아 실제 [NotificationBackend]와
/// [DesktopFeatureStatus.notifyPermissionDenied]로 옮긴다 — 분류와 결정을
/// 나눠서 [resolveProbeResult]를 플러그인/프로세스 없이 단위 테스트할 수
/// 있게 한다.
enum PrimaryProbeOutcome {
  /// 권한이 승인됐고 자기 테스트 알림까지 성공했다.
  granted,

  /// 권한이 명시적으로 거부됐다(`checkPermissions().isEnabled == false`) —
  /// 플러그인은 멀쩡히 응답했다.
  denied,

  /// 권한 승인 여부를 판정할 수 없다 — 예외로 실패했거나 `checkPermissions`
  /// 조차 판정을 못 냈다. osascript 폴백을 시도할 대상이다.
  unavailable,
}

/// [PrimaryProbeOutcome]과 osascript 시도 결과로부터 최종 백엔드/거부
/// 상태를 정하는 순수 함수. I/O가 전혀 없어 테스트가 플러그인이나
/// `Process.run` 없이 이 분기표만 검증할 수 있다.
@visibleForTesting
({NotificationBackend backend, bool permissionDenied}) resolveProbeResult(
  PrimaryProbeOutcome outcome, {
  required bool osascriptSucceeded,
}) {
  return switch (outcome) {
    PrimaryProbeOutcome.granted => (
      backend: NotificationBackend.flutterLocalNotifications,
      permissionDenied: false,
    ),
    PrimaryProbeOutcome.denied => (
      backend: NotificationBackend.none,
      permissionDenied: true,
    ),
    PrimaryProbeOutcome.unavailable => (
      backend: osascriptSucceeded
          ? NotificationBackend.osascript
          : NotificationBackend.none,
      permissionDenied: false,
    ),
  };
}

Future<PrimaryProbeOutcome> _probePrimaryOutcome() async {
  bool? granted;
  try {
    granted = await _plugin.initialize(
      settings: const InitializationSettings(
        macOS: DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );
  } on Exception {
    // 플러그인이 아직 네이티브 쪽에 등록되지 않았거나(드문 개발 환경 문제),
    // 채널 호출이 실패한 경우 전부 여기로 온다 — 예외를 위로 던지지 않고
    // 판정 불가로 접는다. 알림 백엔드 프로브 실패는 이 시임의 정상
    // 분기다.
    return PrimaryProbeOutcome.unavailable;
  }
  // 이미 전달된 알림의 클릭은 현재 발신 권한이나 자기 테스트의 성공과
  // 무관하다. 재프로브에서도 부팅 알림은 실행 중 정확히 한 번만 소비한다.
  await (_coldLaunchCapture ??= _captureColdLaunchTap());
  if (granted == true) {
    try {
      // 재프로브("테스트 알림" 버튼)가 반복 호출될 때마다 알림 센터에
      // id 0 항목이 남아 있으면 `UNUserNotificationCenter`가 제자리
      // 갱신으로 처리해 배너·소리가 나가지 않는다(실 A/B 로그로 확정된
      // 같은 버그) — `show` 직전에 항상 취소해 매번 새 전달로 만든다.
      await _plugin.cancel(id: _selfTestNotificationId);
      await _plugin.show(
        id: _selfTestNotificationId,
        title: _selfTestTitle,
        body: _selfTestBody,
        notificationDetails: const NotificationDetails(
          macOS: DarwinNotificationDetails(),
        ),
      );
      return PrimaryProbeOutcome.granted;
    } on Exception {
      // 권한은 됐는데 표시 자체가 고장났다 — 플러그인 문제로 보고 osascript
      // 폴백으로 넘긴다.
      return PrimaryProbeOutcome.unavailable;
    }
  }
  // `initialize()`가 예외 없이 답했지만 승인이 아니다 — "거부"와 "판정
  // 불가"를 `checkPermissions()`로 구분한다.
  return await _isPermissionDenied()
      ? PrimaryProbeOutcome.denied
      : PrimaryProbeOutcome.unavailable;
}

/// `initialize()`가 승인을 못 받았을 때, 그게 사용자/시스템의 명시적
/// 거부인지 확인한다. `checkPermissions()`가 지원되지 않거나(구버전
/// macOS/플러그인 버그) 예외를 던지면 판정 불가로 취급해 osascript
/// 폴백에 기회를 준다 — 거부를 오판해서 알림을 영영 못 뜨게 만드는 쪽보다
/// 안전하다.
Future<bool> _isPermissionDenied() async {
  try {
    final macOSPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >();
    final options = await macOSPlugin?.checkPermissions();
    if (options == null) return false;
    return !options.isEnabled;
  } on Exception {
    return false;
  }
}

/// macOS 시스템 설정의 알림 패널을 연다("시스템 설정 열기" 버튼,
/// `setup_page.dart`). 딥링크 URL이 이 macOS 버전에서 안 통하면(스킴이
/// OS 버전마다 바뀐 전례가 있다) 시스템 설정 앱 자체를 여는 것으로
/// 물러난다 — 둘 다 실패해도 조용히 넘어간다(설정 화면 자체가 배너로
/// 이미 상황을 설명했으니 여기서 또 에러를 띄우지 않는다).
Future<void> openNotificationSettings() async {
  try {
    final direct = await Process.run('open', <String>[
      'x-apple.systempreferences:com.apple.Notifications-Settings.extension',
    ]);
    if (direct.exitCode == 0) return;
  } on ProcessException {
    // fall through to the generic System Settings app.
  }
  try {
    await Process.run('open', <String>[
      '/System/Applications/System Settings.app',
    ]);
  } on ProcessException {
    // 최선을 다했다 — 둘 다 안 되면 조용히 넘어간다.
  }
}

/// 냉시작(앱이 완전히 종료된 상태에서 알림을 탭해 다시 켜진 경우) 딥링크.
/// 핸들러가 이미 등록됐으면 즉시, 아직 없으면 등록 시점에 전달한다.
Future<void> _captureColdLaunchTap() async {
  try {
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      final response = launchDetails?.notificationResponse;
      if (response != null) {
        _deliverNotificationResponse(response, coldLaunch: true);
      }
    }
  } on Exception {
    // 조회 실패는 냉시작 딥링크를 못 살리는 정도의 손해다 — 부팅을 막지
    // 않는다.
  }
}

Future<bool> _probeOsascript() async {
  try {
    final result = await Process.run('osascript', <String>[
      '-e',
      'display notification "$_selfTestBody" with title "$_selfTestTitle"',
    ]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void _onNotificationResponse(NotificationResponse response) {
  _deliverNotificationResponse(response);
}

void _deliverNotificationResponse(
  NotificationResponse response, {
  bool coldLaunch = false,
}) {
  final payload = response.payload;
  final tap = payload == null || payload.isEmpty
      ? const NotificationTap()
      : NotificationTap.decode(payload);
  if (tap == null) return;
  // id는 OS가 사용하는 잘린 값이다. 여기서는 중복 전달 확인에만 사용하고
  // 읽음 경계에는 payload의 원본 transitionId만 쓴다.
  final key = '${response.id}:${response.actionId}:${payload ?? ''}';
  if (coldLaunch && _receivedTapKeys.contains(key)) return;
  _receivedTapKeys.add(key);
  if (_receivedTapKeys.length > _receivedTapKeyLimit) {
    _receivedTapKeys.remove(_receivedTapKeys.first);
  }
  final handler = _tapHandler;
  if (handler != null) {
    handler(tap);
    return;
  }
  _pendingTap = tap;
}

/// 대시보드 창을 앞으로 가져온다. 트레이의 열기와 대상 없는 알림 클릭에
/// 쓰며, 작업 창으로 이동하는 알림 콜백에서는 무조건 호출하지 않는다.
///
/// 기존 `app/resident` MethodChannel(`resident_mode_native.dart`)의
/// `showWindow` 메서드를 부른다 — 네이티브 `AppDelegate`가 앱을
/// activate하고 `awakeFromNib`에서 등록해 둔 `MainFlutterWindow`를
/// `moveToActiveSpace`로 현재 macOS 데스크톱에 옮긴 뒤 `makeKey` +
/// `orderFrontRegardless`로 앞에 세운다. osascript `reopen`/`activate`
/// 경로는 실 QA에서 `applicationShouldHandleReopen`을 타지 않는 게
/// 확정돼 버렸다.
Future<void> bringWindowToFront() => showResidentWindow();

/// 실제 알림 하나를 선택된 백엔드로 띄운다. `notify_bridge_io.dart`의
/// `showLocalNotification`이 이 함수 하나로 위임한다 — 백엔드 선택/탭
/// 처리는 전부 이 파일 책임이고, `notify_provider.dart`의 중재 시임은
/// 무엇으로 뜨는지 몰라도 된다.
///
/// [id]는 이 알림을 대응하는 전이(`NotifyPayload.id` = `TransitionDto.id`)로
/// 구분한다 — [_selfTestNotificationId] 문서 참고.
/// - `id`가 있으면(세션 전이) 그 값을 그대로 쓴다. **취소하지 않는다** —
///   같은 전이를 다시 쏠 때 알림 센터가 제자리 갱신하는 건 올바른 동작
///   이다(재전송이 배너를 중복시키지 않는다).
/// - `id`가 없으면(대응하는 전이가 없는 일시 알림, `tray_native.dart`의
///   음소거 확인 토스트 등) [_transientNotificationId]를 쓰되, 매번 같은
///   id를 재사용하므로 `show` 직전에 반드시 `cancel`한다 — 취소하지 않으면
///   자기 테스트 알림과 같은 무음 버그에 걸린다.
Future<void> showNotification({
  required String title,
  required String body,
  String? sessionKey,
  int? id,
  String? project,
  String? host,
  String? serverUrl,
}) async {
  switch (_backend) {
    case NotificationBackend.flutterLocalNotifications:
      await _showViaFlutterLocalNotifications(
        title: title,
        body: body,
        sessionKey: sessionKey,
        id: id,
        project: project,
        host: host,
        serverUrl: serverUrl,
      );
    case NotificationBackend.osascript:
      await _showViaOsascript(title: title, body: body);
    case NotificationBackend.none:
      // 프로브가 실패한 상태다(완료 기준 (d)) — 조용히 접는다. 알림 실패는
      // 이 시임에서 예외가 아니라 정상 분기다(기존 osascript 브리지와 같은
      // 관용).
      break;
  }
}

Future<void> _showViaFlutterLocalNotifications({
  required String title,
  required String body,
  String? sessionKey,
  int? id,
  String? project,
  String? host,
  String? serverUrl,
}) async {
  try {
    int resolvedId;
    if (id != null) {
      resolvedId = id & _notificationIdMask;
    } else {
      // 일시 알림은 고정 id를 재사용한다 — 알림 센터에 이전 항목이 남아
      // 있으면 제자리 갱신(무음)되므로 매번 쏘기 전에 지운다.
      resolvedId = _transientNotificationId;
      await _plugin.cancel(id: resolvedId);
    }
    await _plugin.show(
      id: resolvedId,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        macOS: DarwinNotificationDetails(),
      ),
      payload: sessionKey == null
          ? null
          : NotificationTap(
              sessionKey: sessionKey,
              project: project,
              host: host,
              transitionId: id,
              serverUrl: serverUrl,
            ).encode(),
    );
  } on Exception {
    // 표시 실패도 예외를 던지지 않는다 — osascript 브리지의 기존 관용과
    // 같다.
  }
}

// AppleScript `display notification`은 `sound name`을 붙이지 않으면 무음으로
// 뜬다(문서화되지 않은 동작 — 배너는 보여도 소리가 안 난다). `/System/Library/
// Sounds`의 이름을 넣어야 하며, 실제로 터미널에서 실증했다: `sound name
// "default"`는 명령이 성공하고 배너도 뜨지만 macOS 통합 로그(`log show
// --predicate 'subsystem == "com.apple.unc"'`)에 `Playing sound *.aiff` 줄이
// 전혀 안 남는다(무효 이름을 줘도 같다) — 즉 `default`는 실제 재생을 보장하지
// 않는다. 반면 `sound name "Ping"`은 매번 `Playing sound Ping.aiff`가 로그에
// 남아 실제 재생이 확인됐다. 이 백엔드는 1차 백엔드(flutter_local_
// notifications)가 고장났을 때만 타는 폴백이라 자주 실행되진 않지만, 타는
// 순간 무음이면 방금 고친 알림 무음 버그와 같은 증상이 재발한다.
const String _osascriptFallbackSoundName = 'Ping';

Future<void> _showViaOsascript({
  required String title,
  required String body,
}) async {
  final escapedTitle = _escapeForAppleScript(title);
  final escapedBody = _escapeForAppleScript(body);
  // 사운드 이름은 코드 상수라 사용자 입력이 섞일 수 없으므로 escape가
  // 필요 없다 — escape는 title/body처럼 외부에서 온 문자열에만 필요하다.
  try {
    await Process.run('osascript', <String>[
      '-e',
      'display notification "$escapedBody" with title "$escapedTitle" '
          'sound name "$_osascriptFallbackSoundName"',
    ]);
  } on ProcessException {
    // osascript가 없거나 실행에 실패해도 예외를 던지지 않는다.
  }
}

/// AppleScript 문자열 리터럴 안에 그대로 넣을 수 있게 `\`와 `"`만
/// escape한다(`notify_bridge_io.dart`에 있던 것과 동일한 도우미 — 이
/// 파일이 이제 실제 발신을 맡으므로 함께 옮겨왔다).
String _escapeForAppleScript(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
