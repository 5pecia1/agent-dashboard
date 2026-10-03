/// 루트 `MaterialApp` 골격 + 앱 셸 배선 (T-wire).
///
/// 이 템플릿의 세 기반 조각 — [AppTheme]/[AppTokens](테마 토큰), [t]/[tRead]
/// (i18n 어댑터), `capabilityCheckFnProvider`/`isWasmRuntimeProvider`(FFI
/// capability 시임) — 은 강등된 [TemplateDemoPage]가 여전히 예시로 갖고
/// 있다. 이 파일 자체는 그 세 조각을 더 이상 직접 쓰지 않는다 — T-wire가
/// 하는 일은 화면들을 엮는 배선이라, 실제 화면(`ui/sessions_page.dart` 등)
/// 이 이미 갖고 있는 지점을 다시 참조하지 않는다.
///
/// **T15/T-wire: 홈이 바뀌었다.** 템플릿 인사말/capability 데모 화면은
/// 더 이상 홈이 아니다 — `sessions_page.dart`(T15)가 홈이고, 데모 화면은
/// [TemplateDemoPage]로 이름을 바꿔 진단 화면 하위 경로로 강등됐다(삭제
/// 하지 않았다). [SolApp]은 [_AppHome]에게 "설정이 아직 없으면 설정 화면,
/// 있으면 세션 목록"의 분기를 맡긴다.
///
/// **T-wire: 세션 상세 라우트.** `routing/app_router.dart`가
/// `#/session/&lt;key&gt;` 모양의 라우트 이름 하나를 정의하고, [SolApp]의
/// `onGenerateRoute`가 그걸 해석한다. 이 라우트는 두 진입점이 공유한다:
/// (1) 세션 카드를 탭하는 인앱 내비게이션(`sessions_page.dart`)과 (2)
/// 아래 [handleNotificationTap](T16의 macOS 알림 클릭 딥링크)이 그것이다 —
/// 둘 다 `Navigator.pushNamed`로 같은 [MaterialApp.onGenerateRoute]를
/// 탄다. 웹 빌드에서는 이 라우트 이름이 그대로 URL 해시 프래그먼트가 된다
/// (`app_router.dart` 문서 참고) — 별도 라우터 패키지 없이 "웹 해시
/// 호환"을 만족한다.
///
/// **TASK ESC-nav: ESC 뒤로가기.** macOS 데스크톱 관례 — 어느 화면에서든
/// ESC를 누르면 뒤로 간다, 루트(세션 목록)에서는 no-op. [SolApp.build]가
/// `MaterialApp` 전체를 [CallbackShortcuts]로 한 겹 감싸 [rootNavigatorKey]
/// 기반 `Navigator.maybePop()`을 건다 — **`MaterialApp` 바깥**(`Navigator`의
/// 조상)에 두는 게 핵심이다: 키 이벤트는 지금 포커스된 위젯에서 포커스
/// 트리를 타고 위로 올라가며 가장 가까운 처리기부터 순서대로 기회를
/// 얻는데, 이 위치 덕분에 다음 둘이 자동으로 먼저 소비한다(새 예외 처리를
/// 여기서 만들지 않는다) —
///
/// 1. **다이얼로그가 떠 있을 때**: Flutter의 기본 `ModalRoute`가 이미
///    ESC(`DismissIntent`)를 바인딩해 두고, `showDialog`(`barrierDismissible`
///    기본값 true)의 다이얼로그 라우트가 이 앱의 어떤 화면 라우트보다
///    포커스에 더 가까워 그 다이얼로그만 닫는다(화면 자체의 `ModalRoute`는
///    `barrierDismissible`이 아니라서 같은 처리기가 비활성 상태로 남고,
///    그래서 이 앱 코드까지 올라오지 않는다) — `delete_session_dialog.dart`
///    확인 다이얼로그와 충돌하지 않는다.
/// 2. **텍스트 입력(예: `setup_page.dart`의 `TextField`)에 포커스가 있을
///    때**: `EditableText`의 기본 텍스트 편집 단축키가 ESC를 아무 것도
///    하지 않고 전파만 멈추는 의도로 먼저 잡아먹는다 — 그래서 설정 화면
///    타이핑 중 ESC로 원치 않게 화면이 튕겨 나가는 일이 없다.
///
/// 이 두 경우 다 아니면(다이얼로그도 텍스트 포커스도 없는 일반 화면) 키
/// 이벤트가 그 어떤 처리기에도 소비되지 않고 이 파일의 [CallbackShortcuts]
/// 까지 올라와 `maybePop()`을 부른다 — 세션 상세/설정/진단처럼 뒤로 갈
/// 라우트가 있으면 그리로, 루트(뒤로 갈 라우트가 없음)면 `canPop`이
/// false라 아무 일도 없다.
library;

import 'dart:async' show StreamSubscription, unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart' show TransitionDto;
import 'package:my_dashboard/src/data/notification_tap.dart';
import 'package:my_dashboard/src/i18n/t.dart' show localeProvider, platformLocaleProvider;
import 'package:my_dashboard/src/platform/push_signal.dart' show PushSignal, kPushSignalNotificationClick;
import 'package:my_dashboard/src/platform/resident_mode_native.dart'
    if (dart.library.js_interop) 'package:my_dashboard/src/platform/resident_mode_web.dart'
    as resident_bridge;
import 'package:my_dashboard/src/platform/tray.dart' show installTray;
import 'package:my_dashboard/src/routing/app_router.dart';
import 'package:my_dashboard/src/ui/window_navigation_actions.dart';
import 'package:my_dashboard/src/ui/notification_click_actions.dart';
import 'package:my_dashboard/src/state/notification_click_inbox.dart';
import 'package:my_dashboard/src/state/window_navigation_provider.dart';
import 'package:my_dashboard/src/state/alert_notify_provider.dart' show installAlertNotifier;
import 'package:my_dashboard/src/state/config_provider.dart' show dashboardConfigValuesProvider;
import 'package:my_dashboard/src/state/push_provider.dart'
    show pushRegistrarProvider, pushSignalWatchProvider;
import 'package:my_dashboard/src/state/background_activity_provider.dart'
    show backgroundActivityControllerProvider;
import 'package:my_dashboard/src/state/resident_provider.dart' show residentModeApplyProvider;
import 'package:my_dashboard/src/state/sync_controller.dart' show syncControllerProvider;
import 'package:my_dashboard/src/state/theme_mode_provider.dart'
    show parseThemeMode, themeModeControllerProvider;
import 'package:my_dashboard/src/state/ui_lang_provider.dart'
    show
        UiLangSyncSnapshot,
        installUiLangSync,
        parseUiLang,
        uiLangControllerProvider;
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';
import 'package:my_dashboard/src/ui/setup_page.dart';

/// 위젯 트리 밖(알림 탭 콜백)에서 현재 화면 위에 라우트를 얹기 위한 키.
/// `MaterialApp.navigatorKey`에 물린다 — 렌더링에는 영향이 없다.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// 웹 push와 세션 링크의 상세 진입점. macOS 배너는 창 이동 inbox를 쓴다.
void handleNotificationTap(String? sessionKey) {
  if (sessionKey == null) return;
  rootNavigatorKey.currentState?.pushNamed(sessionDetailRouteName(sessionKey));
}

class AppVimNavigationScope extends StatelessWidget {
  const AppVimNavigationScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const <ShortcutActivator, Intent>{
      _NonEditableSingleActivator(LogicalKeyboardKey.keyH):
          DirectionalFocusIntent(TraversalDirection.left),
      _NonEditableSingleActivator(LogicalKeyboardKey.keyJ):
          DirectionalFocusIntent(TraversalDirection.down),
      _NonEditableSingleActivator(LogicalKeyboardKey.keyK):
          DirectionalFocusIntent(TraversalDirection.up),
      _NonEditableSingleActivator(LogicalKeyboardKey.keyL):
          DirectionalFocusIntent(TraversalDirection.right),
    },
    child: child,
  );
}

class _NonEditableSingleActivator extends ShortcutActivator {
  const _NonEditableSingleActivator(this.trigger);

  final LogicalKeyboardKey trigger;

  @override
  Iterable<LogicalKeyboardKey> get triggers => <LogicalKeyboardKey>[trigger];

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext?.widget is EditableText ||
        focusContext?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }
    return SingleActivator(trigger).accepts(event, state);
  }

  @override
  String debugDescribeKeys() => trigger.keyLabel;
}

class SolApp extends ConsumerWidget {
  const SolApp({super.key, this.greeting = ''});

  /// T-wire 이전에는 홈 화면(지금의 [TemplateDemoPage])이 이 FFI `greet()`
  /// 결과를 그대로 보여줬다. 홈이 `sessions_page.dart`로 바뀌면서 이 값을
  /// 넘길 자리가 없어졌다 — [TemplateDemoPage]는 진단 화면에서 진입할 때
  /// 항상 자기 기본값(빈 문자열)으로 보여진다. 생성자 파라미터 자체는
  /// `main.dart`/기존 테스트와의 호환을 위해 남긴다 — 값을 다시 이어줄
  /// 자리(예: provider 하나 추가)를 만드는 건 이 배선 작업의 범위 밖이라
  /// 알려진 한계로 정직하게 남긴다(followup 대상).
  final String greeting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CallbackShortcuts(
      // TASK ESC-nav — 이 파일 머리말 문서 참고. `MaterialApp`(따라서
      // `Navigator`) **밖**에 둔다: 안에 두면 화면 위젯 안 어딘가에 초점이
      // 있을 때만 걸리고, 다이얼로그/텍스트 입력이 먼저 ESC를 잡아먹는
      // 순서(포커스 트리를 타고 위로)가 이 위치에서만 성립한다.
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(rootNavigatorKey.currentState?.maybePop()),
        if (resident_bridge.hasResidentToggleHost)
          const SingleActivator(LogicalKeyboardKey.keyW, meta: true): () =>
              unawaited(resident_bridge.hideResidentWindow()),
      },
      child: MaterialApp(
        title: 'Agent Dashboard',
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ref.watch(themeModeControllerProvider),
        debugShowCheckedModeBanner: false,
        navigatorKey: rootNavigatorKey,
        builder: (context, child) => AppVimNavigationScope(
          child: child ?? const SizedBox.shrink(),
        ),
        // `home:` 대신 `onGenerateRoute:`만 쓴다 — 그래야 `initialRoute`
        // (기본값은 `WidgetsBinding.instance.platformDispatcher.
        // defaultRouteName`, 웹에서는 URL 해시)가 `#/session/<key>`일 때도
        // 이 팩토리 하나로 초기 화면부터 세션 상세를 바로 그린다. 세션
        // 라우트가 아니면(대부분의 경우, 그리고 첫 진입) [_AppHome]으로
        // 접는다.
        onGenerateRoute: (settings) =>
            generateAppRoute(settings) ??
            MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => const _AppHome(),
            ),
      ),
    );
  }
}

/// T-wire 완료 기준 (2): "홈 = sessions_page, 단 서버 주소가 아직 설정
/// 안 됐으면 설정 화면으로 유도"의 분기 + `syncController` 부팅.
///
/// **시임 계약 준수.** [dashboardConfigValuesProvider]는 부팅 시점에
/// 한 번 읽어 override되는 스냅샷이다(`config_provider.dart` 문서 참고) —
/// [SetupPage]에서 저장해도 이 provider 자체는 갈아끼워지지 않는다. 그래서
/// "서버 주소가 있는가"는 이 위젯의 로컬 상태로만 판단하고, 저장이 끝나면
/// [SetupPage.onSaved] 콜백이 그 로컬 상태를 뒤집어 세션 목록으로 넘어간다.
/// 새로 저장한 서버 주소로 요청이 나가는 것도 재시작이 필요 없다 — 앱이 지금
/// 쓰는 API 설정은 부팅 스냅샷이 아니라 `DashboardApiConfigController`
/// (`config_provider.dart`)이고, 저장이 그 값을 먼저 바꾼 뒤 동기화를 연다.
///
/// `needsSetup`(401/403로 멈춘 상태, `sync_controller.dart`의
/// `SyncControllerState.needsSetup`)과는 다른 조건이다 — 그건
/// `sessions_page.dart`의 배너가 이미 다룬다. 이 위젯은 "서버 주소가
/// 아예 없다"는, 그보다 앞선 문 앞의 조건만 본다.
class _AppHome extends ConsumerStatefulWidget {
  const _AppHome();

  @override
  ConsumerState<_AppHome> createState() => _AppHomeState();
}

class _AppHomeState extends ConsumerState<_AppHome> with WidgetsBindingObserver {
  late bool _needsInitialSetup;
  void Function()? _detachNotificationClicks;

  /// TASK D-app 배선 (4): push 수신 신호 구독. 웹이면
  /// `BroadcastChannel('dashboard')`(서비스 워커), macOS면
  /// `onMessageOpenedApp`이 이 스트림으로 들어온다
  /// (`state/push_provider.dart`의 `pushSignalWatchProvider`).
  StreamSubscription<PushSignal>? _pushSignals;

  /// TASK A-impl (1): sync가 계산한 '미확인 alert 전이'를 실제 알림으로
  /// 바꾸는 구독(`state/alert_notify_provider.dart`). `listenManual`이
  /// 돌려주는 구독은 위젯 dispose 때 자동으로 닫히지만, [_pushSignals]와
  /// 같은 모양으로 명시적으로도 닫는다.
  ProviderSubscription<List<TransitionDto>>? _alertNotifications;

  /// UI 언어: sync 응답의 `ui_lang`(서버가 정본)을
  /// [uiLangControllerProvider]에 반영하는 구독(`state/ui_lang_provider.dart`
  /// 의 `installUiLangSync`). [_alertNotifications]와 같은 이유로 명시적으로도
  /// 닫는다.
  ProviderSubscription<UiLangSyncSnapshot>? _uiLangSync;

  @override
  void initState() {
    super.initState();
    // 앱-didChangeLocales: OS/브라우저 로케일이 실행 중에 바뀌는 것도
    // 감지한다 — `platformLocaleProvider`는 값 자체를 캐시하는 게 아니라
    // 호출될 때마다 그 순간의 `WidgetsBinding.platformDispatcher.locale`을
    // 읽는 함수 시임이라(`i18n/t.dart` 참고), provider 자신은 이 변화를
    // 스스로 알아채지 못한다 — `didChangeLocales` 콜백에서 invalidate해야
    // 다음 watch가 새 값을 읽는다.
    WidgetsBinding.instance.addObserver(this);
    _needsInitialSetup = ref.read(dashboardConfigValuesProvider).serverUrl == null;
    // T-wire 완료 기준 (2) 앱 시작 시 syncController 부팅. Riverpod의
    // `NotifierProvider`는 지연 평가라 아무도 read/watch하지 않으면
    // `SyncController.build()`(첫 동기화 예약이 걸리는 자리)가 절대
    // 돌지 않는다 — 설정 화면부터 보여주는 첫 실행 경로에서도 컨트롤러를
    // 미리 깨워 둔다(설정 화면에서 세션 목록으로 넘어가는 순간 이미 도는
    // 상태를 그대로 이어받는다).
    ref.read(syncControllerProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _detachNotificationClicks = ref.read(notificationClickInboxProvider).bind((tap) async {
        final context = rootNavigatorKey.currentState?.overlay?.context;
        if (!mounted || context == null) return;
        await openNotificationWindow(context, ref, tap);
      });
    });
    // TASK A-impl (1): **전이 -> 알림 실배선.** 위 한 줄이 깨운 컨트롤러가
    // `pendingAlerts`를 채우기만 하던 자리에, 그 큐를 실제 배너로 바꾸는
    // 구독을 여기서 붙인다 — 지금까지 프로덕션 부팅 경로에 없던 유일한
    // 조각이다(`sync_controller.dart` 상단이 "그걸 언제 어떻게 알림으로
    // 바꾸는지는 그 알림을 구독하는 쪽(향후 과제)의 몫"이라고 남겨 둔
    // 자리 — 이제 있다). 소유권(웹 no-op / APNs 등록 시 억제 / 권한 거부
    // 시 발신 없음)과 전이당 1회, 중복 억제는 전부
    // `alert_notify_provider.dart`와 그 아래 기존 시임이 갖고 있다 —
    // 여기서는 새 규칙을 만들지 않고 구독만 만든다.
    //
    // `syncControllerProvider`를 읽은 **뒤에** 붙인다: 먼저 컨트롤러를
    // 깨워 첫 사이클 예약이 걸린 다음 구독을 얹으면, 그 사이 큐에 무언가
    // 들어왔더라도 `fireImmediately: true`가 곧바로 따라잡는다.
    _alertNotifications = installAlertNotifier(ref);
    // T17f: 웹 푸시 등록도 같은 자리에서 한 번 깨운다. 기다리지 않는다 —
    // 푸시는 "있으면 좋은 깨우기 힌트"고 정합성은 폴링이 담보하므로
    // (정본 `push` 절) 첫 화면이 이것 때문에 늦어지면 안 된다.
    //
    // 데스크톱에서는 `notApplicable`로 즉시 끝나고 네트워크도 타지 않는다.
    // 웹에서는 서버 자격증명(`client_ready`)과 알림 권한을 확인만 하고,
    // **권한 프롬프트는 절대 띄우지 않는다** — 권한이 없으면
    // `permissionRequired`로 끝나고, 실제 프롬프트는 설정 화면의 명시적
    // 버튼(`webPushPermissionRequestProvider`)만 띄운다.
    // `_pushRegisterBridge`가 모든 실패를 값으로 접으므로 이 호출은 던지지
    // 않는다(`push_provider.dart`의 `DashboardApiException` catch 참고).
    //
    // T-wire 계약(U-fix): 서버 주소가 아직 없으면 이 호출 자체를 걸지
    // 않는다 — `pushRegistrarProvider`가 반환하는 함수는 내부에서
    // `ref.read(dashboardApiProvider)`(→ `dashboardApiConfigProvider`)를
    // try/catch 밖에서 읽는다(`push_provider.dart` 참고), 그래서 미설정
    // boot snapshot에서 부르면 던진다. "설정 안 됐으면 네트워크 0회"
    // 계약을 지키려면 애초에 부르지 않는 게 맞다 — 설정을 마치면
    // `setup_page.dart`의 저장 성공 분기가 같은 호출을 한다.
    if (ref.read(dashboardConfigValuesProvider).serverUrl != null) {
      unawaited(ref.read(pushRegistrarProvider)());
    }
    // TASK D-app 배선 (4): 지금까지 아무도 듣지 않던 수신 신호를 여기서
    // 받는다(`sync_controller.dart` 상단이 "그 사건을 알려줄 이벤트 소스가
    // 아예 없다"고 남겨 둔 자리 — 이제 있다). 등록 경로와 독립이라
    // 등록이 실패해도, 아직 끝나지 않았어도 구독은 살아 있다.
    _pushSignals = ref.read(pushSignalWatchProvider)().listen(_onPushSignal);
    // TASK D-app (A안 설계 ④): 저장된 상주 설정을 네이티브(AppDelegate)에
    // 밀어 넣는다.
    //
    // **`main.dart`가 아니라 여기서 하는 이유**: 이 값은 MethodChannel로
    // 가는데, `runApp` 이전(부팅 시퀀스)에는 채널 반대편
    // (`MainFlutterWindow.awakeFromNib`가 붙이는 핸들러)이 아직 없을 수
    // 있다 — 그러면 `MissingPluginException`으로 조용히 접히고 사용자가
    // 꺼 둔 설정이 반영되지 않는다. 위젯 트리가 뜬 시점이면 엔진과 창이
    // 확실히 살아 있다.
    //
    // 켜짐 방향은 이 호출이 실패해도 안전하다 — `AppDelegate`의 기본값이
    // 상주 켜짐이라 "창을 닫으면 알림이 끊긴다"는 상태로는 떨어지지 않는다.
    // 이 호출에 달려 있는 것은 반대 방향(끄기)뿐이다.
    unawaited(
      ref.read(residentModeApplyProvider)(
        ref.read(dashboardConfigValuesProvider).residentOrDefault,
      ),
    );
    // TASK P-impl (1): App Nap 방지 컨트롤러도 같은 자리에서 깨운다 —
    // `NotifierProvider`는 지연 평가라 아무도 읽지 않으면
    // `BackgroundActivityController.build()`(창 가시성 구독이 걸리는 자리)가
    // 절대 돌지 않는다(`syncControllerProvider` 배선과 같은 이유). 이
    // 컨트롤러는 `dashboardConfigValuesProvider`를 스스로 watch하지 않으므로
    // (그 provider가 override 없이 도는 화면 단위 테스트를 오염시키지 않기
    // 위해서 — `background_activity_provider.dart` 문서 참고) 저장된 상주
    // 값을 바로 위 `residentModeApplyProvider` 호출과 같은 값으로 직접
    // 밀어 넣는다.
    ref.read(backgroundActivityControllerProvider);
    ref
        .read(backgroundActivityControllerProvider.notifier)
        .setResident(ref.read(dashboardConfigValuesProvider).residentOrDefault);
    // 테마 모드: 저장된 값(없으면 시스템)으로 컨트롤러를 seed한다 — 같은
    // 이유로 `dashboardConfigValuesProvider`를 스스로 watch하지 않는
    // `ThemeModeController`(`state/theme_mode_provider.dart` 문서 참고)에게
    // 부팅 스냅샷을 직접 알려준다.
    //
    // `resident`/트레이와 달리 여기는 **`Future(() {...})`로 한 틱 미룬다**
    // — `SolApp`(위 조상)이 바로 이 provider를 `MaterialApp(themeMode:)`에
    // watch하고 있어서, initState 안에서 곧바로 state를 바꾸면 "아직 빌드
    // 중인 위젯 트리를 빌드 중에 수정한다"는 Riverpod 예외가 난다(첫 프레임
    // 안에서 같은 provider를 읽는 조상이 있을 때만 생기는 문제 — `resident`/
    // 트레이 설정은 자신을 watch하는 조상이 이 빌드 경로에 없어 문제가 없다).
    Future(() {
      if (!mounted) return;
      ref
          .read(themeModeControllerProvider.notifier)
          .setThemeMode(parseThemeMode(ref.read(dashboardConfigValuesProvider).themeMode));
    });
    // UI 언어: 테마 모드와 같은 이유로 같은 자리에서 같은 틱만큼 미룬다 —
    // `t()`(`i18n/t.dart`)가 read하는 `localeProvider`가
    // `uiLangControllerProvider`를 watch하는데, 이 프레임에 처음 빌드되는
    // 화면(`SetupPage`/`SessionsPage`)이 거의 모든 문구를 `t()`로 그려서
    // 곧바로 쓰면 위 테마 모드 문서가 설명하는 것과 같은 "빌드 중에 빌드
    // 중인 provider를 수정" 예외가 난다.
    //
    // 순서가 중요하다: 로컬 캐시로 먼저 seed한 다음 [installUiLangSync]를
    // 건다 — 그래야 부팅 직후(아직 첫 sync 응답 전) 그 리스너의
    // `fireImmediately` 즉시 호출이 `SyncState.uiLang`의 초기값(항상 null —
    // 이 필드는 영속화되지 않고 sync 응답으로만 채워진다)을 보고도 방금 seed한
    // 값을 `'system'`으로 도로 덮어쓰지 않는다(`ui_lang_provider.dart`의
    // `installUiLangSync` 문서가 설명하는 "서버 응답을 한 번도 못 받은
    // 동안은 아무것도 하지 않는다" 가드 참고 — 이 seed는 판정 근거가 아니라
    // 첫 응답까지 버티는 캐시일 뿐이라, 첫 응답이 도착하는 순간 그 값이
    // null이어도 그대로 덮인다).
    Future(() {
      if (!mounted) return;
      ref
          .read(uiLangControllerProvider.notifier)
          .setUiLang(parseUiLang(ref.read(dashboardConfigValuesProvider).uiLang));
      _uiLangSync = installUiLangSync(ref);
    });
    // TASK TRAY-impl: 트레이 아이콘도 같은 자리에서 배선한다 — 같은
    // 이유(위 상주 배선 문서 참고)로 `main.dart`가 아니라 여기다: 트레이
    // 아이콘 자체는 MethodChannel이 아니지만(플러그인 채널) 여기서 굽는
    // 메뉴 라벨이 [tRead]를 쓰고, [tRead]는 `WidgetRef`가 있어야 한다 —
    // 위젯 트리가 뜨기 전(`main.dart`)에는 그 자체가 없다. 웹/비macOS에서는
    // 즉시 no-op으로 돌아온다(`platform/tray_web.dart`, `traySupportedProvider`).
    unawaited(installTray(ref, onSessionSelected: (session) async {
      final context = rootNavigatorKey.currentState?.overlay?.context;
      if (context == null || !mounted) return;
      await openSessionWindow(context, ref, session);
    }));
  }

  /// 알림을 눌렀다는 신호 하나. 하는 일은 정확히 둘이고 순서가 있다:
  ///
  /// 1. **즉시 재조회.** push는 깨우기 힌트고 정합성은 언제나 sync가
  ///    담보한다(정본 `push` 절) — 알림이 말한 전이를 화면이 갖고 있다는
  ///    보장이 없으므로 딥링크보다 먼저 당긴다.
  /// 2. **딥링크.** 세션 키를 알면 세션 상세로 간다. 세션 카드를 탭했을
  ///    때와 정확히 같은 라우트([handleNotificationTap])다.
  void _onPushSignal(PushSignal signal) {
    if (signal.refresh) {
      ref.read(syncControllerProvider.notifier).triggerNow();
    }
    if (signal.type != kPushSignalNotificationClick) return;
    if (ref.read(windowNavigationSupportedProvider)) {
      ref.read(notificationClickInboxProvider).add(NotificationTap(
        sessionKey: signal.resolvedSessionKey,
        project: signal.project,
        host: signal.host,
        transitionId: signal.transitionId,
      ));
    } else {
      handleNotificationTap(signal.resolvedSessionKey);
    }
  }

  /// 앱-didChangeLocales: OS/브라우저 로케일이 실행 중에 바뀌면(설정 앱에서
  /// 시스템 언어를 바꾸는 등) 호출된다.
  ///
  /// **`platformLocaleProvider`뿐 아니라 `localeProvider`도 함께
  /// invalidate해야 한다 — 실측으로 확인한 Riverpod 전파 한계.**
  /// `platformLocaleProvider`는 값 자체가 아니라 "호출하면 그 순간의 로케일을
  /// 읽는 함수"(`PlatformLocaleFn`, `i18n/t.dart` 참고)를 돌려준다 — 그
  /// 함수 참조(`_platformLocale`)는 매번 다시 빌드돼도 항상 **똑같은
  /// 객체**다. Riverpod은 `invalidate`로 강제 재계산을 걸어도, 그 결과값이
  /// (참조 동일성으로) 이전과 같으면 "달라지지 않았다"고 보고 그 provider를
  /// watch하는 쪽(`localeProvider`)에는 재계산이 필요하다는 신호를 전파하지
  /// 않는다 — `localeProvider`의 캐시된 `LocaleDto`가 다음 읽기에서도 그대로
  /// 남는다(이 파일이 처음 `platformLocaleProvider`만 invalidate하도록
  /// 짰을 때 위젯 테스트로 실제로 재현·확인한 결함이다). 그래서
  /// `localeProvider` 자신도 직접 invalidate해 그 캐시를 비운다 —
  /// `platformLocaleProvider`도 함께 invalidate해 두는 건 (a) 문서적으로
  /// "플랫폼 로케일 시임이 낡았다"는 의도를 그대로 남기고 (b) 이 둘의
  /// 실제 전파 경로가 나중에 바뀌어도 안전한 이중 방어다.
  ///
  /// 실제로 화면이 다시 그려지는 건 `localeProvider`가
  /// `uiLangControllerProvider`가 `'system'`일 때만 `platformLocaleProvider`를
  /// watch하기 때문에 자동으로 따라온다(사용자가 직접 `'ko'`/`'en'`을
  /// 골랐으면 OS가 뭐라 하든 그 선택이 우선이다 — `i18n/t.dart`의
  /// `localeProvider` 문서 참고).
  @override
  void didChangeLocales(List<Locale>? locales) {
    ref.invalidate(platformLocaleProvider);
    ref.invalidate(localeProvider);
  }

  @override
  void dispose() {
    _detachNotificationClicks?.call();
    WidgetsBinding.instance.removeObserver(this);
    _pushSignals?.cancel();
    _alertNotifications?.close();
    _uiLangSync?.close();
    super.dispose();
  }

  void _onSetupSaved() {
    setState(() => _needsInitialSetup = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_needsInitialSetup) {
      return SetupPage(onSaved: _onSetupSaved);
    }
    return const SessionsPage();
  }
}
