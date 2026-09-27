/// 설정 화면 — 서버 주소/토큰, 알림 토글, 테스트 알림, 30/60분 음소거,
/// 상주 동작 토글.
///
/// **TASK D-app이 바꾼 것 둘.**
///
/// 1. **상주 동작이 안내 문구에서 토글이 됐다**(A안 설계 ④). 기존
///    `setup.resident_note` 문구는 사라지지 않고 그 토글의 설명(subtitle)
///    으로 흡수됐다. 값은 `DashboardConfigValues.resident`로 영속화되고,
///    바뀔 때마다 `residentModeApplyProvider`가 MethodChannel로
///    `AppDelegate`에 밀어 넣는다 — 그래서 "저장" 버튼을 누르지 않아도
///    즉시 반영된다(창을 닫는 순간의 동작이라 나중에 반영하면 늦다).
/// 2. **저장이 push 재등록을 트리거한다**(직전 게이트가 발견한 미배선
///    2건 중 하나). 서버 주소·토큰이 바뀌면 이전 서버에 등록해 둔 토큰은
///    아무 의미가 없다 — 저장 직후 [pushRegistrarProvider]를 한 번 부른다.
///    웹·macOS 공통이고, 대상이 아닌 호스트에서는 그 provider가
///    `notApplicable`로 즉시 끝난다.
///
/// **알려진 한계(공개 문서화, followup으로 보고):** `DashboardConfigValues`
/// (`state/config_provider.dart`)에는 "알림 사용"/"본문 내용 숨기기"/
/// "기기 이름" 필드가 여전히 없다 — 이번 작업은 상주 토글 하나만 그 파일에
/// 얹었다(설계 ④가 명시적으로 요구한 값이다). 나머지 세 값은 이 화면
/// 인스턴스가 살아있는 동안만 유지되는 휘발성 로컬 상태다.
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:my_dashboard/src/state/dashboard_extensions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/background_activity_provider.dart'
    show backgroundActivityControllerProvider;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/capability_provider.dart'
    show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/notification_probe_provider.dart';
import 'package:my_dashboard/src/state/notify_provider.dart'
    show notificationPathLabelKeyProvider;
import 'package:my_dashboard/src/state/push_provider.dart';
import 'package:my_dashboard/src/state/resident_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart'
    show muteStateListenable, syncControllerProvider;
import 'package:my_dashboard/src/state/theme_mode_provider.dart';
import 'package:my_dashboard/src/state/ui_lang_provider.dart';
import 'package:my_dashboard/src/state/window_navigation_provider.dart';
import 'package:my_dashboard/src/ui/window_connections_page.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/util/mute_time.dart' show formatMuteUntilClock;

class SetupPage extends ConsumerStatefulWidget {
  const SetupPage({super.key, this.onSaved});

  /// T-wire: 저장이 성공한 뒤(서버 주소가 비어 있지 않게 됐을 때만) 호출된다.
  /// `app.dart`의 `_AppHome`이 "첫 실행 -> 이 화면"에서 세션 목록으로
  /// 넘어가는 데 쓴다 — `dashboardConfigValuesProvider`는 부팅 시점
  /// 스냅샷이라(`config_provider.dart` 문서 참고) 저장 후에도 값이 갈아
  /// 끼워지지 않으므로, 화면 전환은 이 콜백이 만드는 로컬 위젯 상태로만
  /// 가능하다. 이 화면을 다른 진입점(설정 아이콘 등)에서 그냥 push했을
  /// 때는 null로 두면 된다 — 없어도 저장 자체는 그대로 동작한다.
  final VoidCallback? onSaved;

  @override
  ConsumerState<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends ConsumerState<SetupPage> {
  final _serverUrlController = TextEditingController();
  final _clientTokenController = TextEditingController();
  final _deviceLabelController = TextEditingController();

  bool _loadingConfig = true;
  bool _busy = false;
  bool _notificationsEnabled = true;
  bool _hideContent = false;

  /// A안 설계 ④. 저장된 값이 아직 없으면 [kResidentDefault](켜짐)로 시작한다.
  bool _resident = kResidentDefault;

  /// 저장된 값이 아직 없으면 [ThemeMode.system]으로 시작한다 —
  /// [parseThemeMode]의 기본 폴백과 같다.
  ThemeMode _themeMode = ThemeMode.system;

  /// 저장된 값이 아직 없으면 `'system'`으로 시작한다 — [parseUiLang]의
  /// 기본 폴백과 같다.
  String _uiLang = 'system';
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _clientTokenController.dispose();
    _deviceLabelController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    try {
      final stored = await ref.read(configLoadFnProvider)();
      // TASK I-local (1): 저장값이 없는 필드는 컴파일 기본값으로 미리
      // 채워 보여준다 — 사용자는 그 값을 그대로 두거나 언제든 덮어써
      // 저장할 수 있다(define 없는 빌드는 항상 stored와 같다).
      final values = ref.read(configDefaultsFnProvider)(stored);
      if (!mounted) return;
      setState(() {
        _serverUrlController.text = values.serverUrl ?? '';
        _clientTokenController.text = values.clientToken ?? '';
        _resident = values.residentOrDefault;
        _themeMode = parseThemeMode(values.themeMode);
        _uiLang = parseUiLang(values.uiLang);
        _loadingConfig = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingConfig = false);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final urlText = _serverUrlController.text.trim();
      final tokenText = _clientTokenController.text.trim();
      final serverUrl = urlText.isEmpty ? null : urlText;
      final clientToken = tokenText.isEmpty ? null : tokenText;
      // 이 화면에서 "저장" 버튼이 소유하는 필드는 serverUrl/clientToken
      // 뿐이다 — cursor/resident/themeMode/uiLang은 각자 다른 작성자
      // (sync_controller의 커서 저장, 상주·테마·언어 토글의 즉시 저장)가
      // 소유하므로 여기서는 손대지 않는다. [mutate]가 받는 `current`는
      // 이 패치 큐가 **방금 다시 읽은** 값이다(`_resident`/`_themeMode`/
      // `_uiLang` 같은 로컬 위젯 상태가 아니다) — 그래야 이 화면이 열려
      // 있는 동안 다른 작성자가 그 필드를 바꿨어도 이 저장이 그 값을
      // 되돌리지 않는다. `DashboardConfigValues.copyWith`는 `??` 기반이라
      // 필드를 명시적으로 비울 수 없다(null을 줘도 이전 값이 살아남는다,
      // `config_provider.dart`의 `copyWith` 문서 참고) — 그래서 여기서는
      // copyWith가 아니라 생성자를 직접 써서 빈 입력을 실제로 null로
      // 만든다. **주의**: 생성자를 직접 쓰면 명시적으로 안 넘긴 필드는
      // `??` 폴백 없이 곧바로 null이 된다 — 그래서 여기서 손대지 않는
      // 필드(cursor/resident/themeMode/uiLang)는 전부 `current`에서
      // 명시적으로 그대로 옮겨 적어야 한다(하나라도 빠뜨리면 "저장" 버튼을
      // 누를 때마다 그 필드가 조용히 초기화된다).
      await ref.read(configPatchFnProvider)(
        (DashboardConfigValues current) => DashboardConfigValues(
          serverUrl: serverUrl,
          clientToken: clientToken,
          cursor: current.cursor,
          resident: current.resident,
          themeMode: current.themeMode,
          seenWatermark: current.seenWatermark,
          uiLang: current.uiLang,
          extra: current.extra,
        ),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMessage = tRead(ref, 'setup.save_success');
      });
      // T-wire: 서버 주소가 (비어 있지 않은 값으로) 저장된 뒤에만 아래
      // 블록을 탄다 — 첫 실행 유도 화면에서 빈 값 그대로 저장을 눌러 봐야
      // 여전히 설정이 필요한 상태이므로 push 등록도, 폴링 시작도, 세션
      // 목록 전환도 할 이유가 없다(U-fix: 서버 주소가 없는 동안 네트워크
      // 0회 계약 — `pushRegistrarProvider`를 비어 있는 상태에서 부르면
      // 미설정 boot snapshot에서 예외를 던질 수 있다, `app.dart`의 같은
      // 가드 문서 참고).
      if (serverUrl != null) {
        // TASK D-app 배선 (4): 새 서버 주소·토큰으로 push를 다시 등록한다.
        // 기다리지 않는다 — 저장 자체는 이미 끝났고, 등록은 "있으면 좋은
        // 깨우기 힌트"라 화면을 붙잡을 이유가 없다(부팅 경로가 같은 이유로
        // `unawaited`하는 것과 같은 자리, `app.dart` 참고).
        // `pushRegistrarProvider`가 모든 실패를 값으로 접으므로 던지지
        // 않고, 대상이 아닌 호스트에서는 서버도 건드리지 않고 즉시 끝난다.
        unawaited(ref.read(pushRegistrarProvider)(label: _deviceLabelOrNull()));
        // U-fix: 기존 "저장 후 재등록 트리거"(바로 위 pushRegistrar 호출)와
        // 같은 자리에 얹는다 — 새 메커니즘을 만들지 않고, 부팅이 서버
        // 주소 없이 멈춰 둔 폴링을 여기서 정식으로 연다
        // (`sync_controller.dart`의 `SyncController.configureAndStart` 참고).
        ref.read(syncControllerProvider.notifier).configureAndStart();
        widget.onSaved?.call();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMessage = tRead(ref, 'setup.save_error');
      });
    }
  }

  /// 기기 이름 입력이 비었으면 null — 서버가 기존 이름을 유지한다
  /// (`DashboardApi.registerDevice` 문서: 보내지 않는 것과 빈 문자열은 다르다).
  String? _deviceLabelOrNull() {
    final text = _deviceLabelController.text.trim();
    return text.isEmpty ? null : text;
  }

  /// A안 설계 ④: 상주 토글. 저장 버튼을 기다리지 않고 곧바로 영속화 +
  /// 네이티브 반영을 한다 — "창을 닫는 순간"의 동작이라 나중에 반영하면
  /// 이미 늦기 때문이다.
  ///
  /// 영속화가 실패하면(디스크 권한 등) 토글을 되돌린다. 화면만 켜져
  /// 있고 실제 동작은 예전 값인 상태로 두지 않는다.
  Future<void> _setResident(bool enabled) async {
    final previous = _resident;
    setState(() {
      _resident = enabled;
      _busy = true;
    });
    try {
      // 이 토글이 소유하는 필드는 resident뿐이다 — [mutate]가 받는
      // `current`(방금 다시 읽은 값)에서 그 필드만 바꾼다(패치 시임 문서,
      // `config_provider.dart`의 [configPatchFnProvider] 참고).
      await ref.read(configPatchFnProvider)(
        (DashboardConfigValues current) => current.copyWith(resident: enabled),
      );
      await ref.read(residentModeApplyProvider)(enabled);
      // TASK P-impl (1): `dashboardConfigValuesProvider`는 부팅 시점 스냅샷이라
      // (그 파일 문서 참고) 저장만으로는 App Nap 컨트롤러가 새 값을 모른다 —
      // 상주 토글이 바뀌는 그 순간 직접 알려준다.
      ref
          .read(backgroundActivityControllerProvider.notifier)
          .setResident(enabled);
      if (!mounted) return;
      setState(() => _busy = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _resident = previous;
        _busy = false;
        _statusMessage = tRead(ref, 'setup.resident_error');
      });
    }
  }

  /// 테마 모드 선택. 저장 버튼을 기다리지 않고 곧바로 영속화 + 컨트롤러
  /// 반영을 한다 — `_setResident`와 같은 자리·같은 이유(즉시 반영해야
  /// 사용자가 고른 화면이 바로 바뀐다).
  ///
  /// 영속화가 실패하면 선택을 되돌린다 — `_setResident`와 같은 태도.
  Future<void> _setThemeMode(ThemeMode mode) async {
    final previous = _themeMode;
    setState(() {
      _themeMode = mode;
      _busy = true;
    });
    try {
      // 이 세그먼트가 소유하는 필드는 themeMode뿐이다 — `_setResident`와
      // 같은 자리·같은 이유.
      await ref.read(configPatchFnProvider)(
        (DashboardConfigValues current) =>
            current.copyWith(themeMode: themeModeConfigValue(mode)),
      );
      ref.read(themeModeControllerProvider.notifier).setThemeMode(mode);
      if (!mounted) return;
      setState(() => _busy = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _themeMode = previous;
        _busy = false;
        _statusMessage = tRead(ref, 'setup.theme_mode_error');
      });
    }
  }

  /// UI 표시 언어 선택. **낙관적 갱신을 하지 않는다** — `_setResident`/
  /// `_setThemeMode`와 다른 태도다(서버 동기화 계약:
  /// `dashboard_api.dart`의 `mute()` 전례를 그대로 따른다). 값은 항상
  /// **서버가 확인한 값**으로만 위젯 상태·`uiLangControllerProvider`·로컬
  /// 캐시를 갱신하고, 요청이 실패하면 값은 그대로 두고 에러만 보여준다
  /// (`_mute`/`_unmute`와 같은 태도 — 되돌릴 낙관 상태가 애초에 없다).
  ///
  /// **예외: 서버 미설정 단계.** 서버 주소 자체가 아직 없거나
  /// (`dashboardConfigValuesProvider.serverUrl == null` — `SyncPhase.
  /// unconfigured`, `dashboardApiProvider`를 읽으면 던진다) `needsSetup`
  /// (401/403으로 멈춘 `SyncPhase.stopped` — POST는 실패하지만 값이 그대로
  /// 남아 사용자를 가둔다)이면 서버에 쓸 방법이 없거나 써도 사용자를
  /// 구제하지 못하므로, 이 두 경우에만 로컬(위젯 상태·컨트롤러·로컬 캐시)에
  /// 곧바로 반영한다 — 언어를 잘못 골라 이 설정 화면 자체를 못 읽게 된
  /// 사용자가 영영 못 빠져나오는 것을 막기 위해서다(지시의 설계 근거 그대로).
  Future<void> _setUiLang(String value) async {
    final unconfigured =
        ref.read(dashboardConfigValuesProvider).serverUrl == null;
    final needsSetup = ref.read(syncControllerProvider).needsSetup;
    if (unconfigured || needsSetup) {
      setState(() {
        _uiLang = value;
        _busy = true;
      });
      try {
        await ref.read(configPatchFnProvider)(
          (DashboardConfigValues current) => current.copyWith(uiLang: value),
        );
        ref.read(uiLangControllerProvider.notifier).setUiLang(value);
        if (!mounted) return;
        setState(() => _busy = false);
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _statusMessage = tRead(ref, 'setup.ui_lang_error');
        });
      }
      return;
    }

    setState(() => _busy = true);
    try {
      final api = ref.read(dashboardApiProvider);
      // `'system'`은 로컬 기기 사실이라 서버로 보내지 않는다 — 서버 값을
      // 지우는 요청(null)으로 옮겨 적는다(`dashboard_api.dart`의
      // `setUiLang` 문서 참고).
      final confirmed = await api.setUiLang(value == 'system' ? null : value);
      final resolved = parseUiLang(confirmed);
      if (!mounted) return;
      // 확인값이 돌아온 **즉시** 화면(세그먼트 선택 + 컨트롤러)에 반영한다.
      // 낙관적 갱신이 아니다 — 서버가 이미 확정한 값이다. 로컬 캐시 쓰기는
      // 그 뒤다: 캐시는 다음 부팅의 깜빡임만 막는 보조 수단이라, 느린
      // 디스크가 이미 확정된 언어의 화면 반영을 늦출 이유가 없다(리뷰 지적
      // medium 수정).
      setState(() => _uiLang = resolved);
      ref.read(uiLangControllerProvider.notifier).setUiLang(resolved);
      await ref.read(configPatchFnProvider)(
        (DashboardConfigValues current) => current.copyWith(uiLang: resolved),
      );
      if (!mounted) return;
      setState(() => _busy = false);
    } on DashboardApiException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMessage = tRead(ref, 'setup.ui_lang_error');
      });
    } catch (_) {
      // 리뷰 지적 high 수정: `DashboardApiException`만 좁게 잡으면 위
      // `configPatchFn`(= `ConfigSaveFn` 계약상 "저장 실패는 예외")의 디스크
      // 예외가 어느 catch에도 안 걸려 새어 나가고, `_busy = false`에 도달하지
      // 못한 채 굳는다. `_busy`는 이 화면의 저장·상주·테마·테스트 알림·뮤트가
      // 전부 공유하는 잠금이라 한 번 굳으면 설정 화면 전체가 비활성이 된다.
      // `_setResident`/`_setThemeMode`/위 needsSetup 분기와 같은 태도로 전부
      // 잡는다. 값 자체는 서버가 이미 확정했으므로 되돌리지 않는다.
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMessage = tRead(ref, 'setup.ui_lang_error');
      });
    }
  }

  Future<void> _testNotification() async {
    setState(() => _busy = true);
    try {
      // 후속(T16 denied 구분): 버튼을 누를 때마다 macOS 알림 프로브를 다시
      // 돌린다 — 사용자가 방금 시스템 설정에서 권한을 켰을 수도 있기
      // 때문이다(재프로브 계약, `local_notifications_native.dart` 문서
      // 참고). 데스크톱이 아닌 호스트/웹에서는 no-op이라 항상 안전하다.
      await ref.read(notificationReprobeProvider)();
      final api = ref.read(dashboardApiProvider);
      final labelText = _deviceLabelController.text.trim();
      final result = await api.testPush(
        label: labelText.isEmpty ? null : labelText,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMessage = tRead(
          ref,
          result.sentCount > 0
              ? 'setup.test_notification_success'
              : 'setup.test_notification_error',
        );
      });
    } on DashboardApiException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMessage = tRead(ref, 'setup.test_notification_error');
      });
    }
  }

  /// 브라우저 알림 권한 프롬프트가 뜰 수 있는 **유일한 자리**.
  ///
  /// 부팅 경로(`app.dart`)도 [pushRegistrarProvider]를 부르지만, 권한이
  /// `granted`가 아니면 거기서는 프롬프트 없이
  /// [PushAvailability.permissionRequired]로 끝난다
  /// (`platform/web_push_web.dart`의 계약). 사용자가 이 버튼을 눌렀을 때만
  /// 먼저 권한을 요청하고, 받아 내면 곧바로 토큰 등록까지 이어 붙인다.
  ///
  /// 데스크톱에서는 이 버튼 자체가 그려지지 않는다(`_WebPushSection`).
  Future<void> _enableWebPush() async {
    setState(() => _busy = true);
    final granted = await ref.read(webPushPermissionRequestProvider)();
    if (!mounted) return;
    if (!granted) {
      setState(() {
        _busy = false;
        _statusMessage = tRead(ref, 'setup.web_push_permission_denied');
      });
      return;
    }
    final labelText = _deviceLabelController.text.trim();
    final result = await ref.read(pushRegistrarProvider)(
      label: labelText.isEmpty ? null : labelText,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _statusMessage = tRead(ref, switch (result.availability) {
        PushAvailability.registered => 'setup.web_push_registered',
        PushAvailability.permissionRequired =>
          'setup.web_push_permission_denied',
        // 자격증명이 없는 것은 이 브라우저의 잘못이 아니다 — 폴링은 계속
        // 돌고 있다는 사실을 그대로 알린다.
        PushAvailability.unavailable ||
        PushAvailability.notApplicable => 'setup.web_push_unavailable',
        PushAvailability.failed => 'setup.web_push_error',
      });
    });
  }

  Future<void> _mute(int minutes) async {
    setState(() => _busy = true);
    try {
      final api = ref.read(dashboardApiProvider);
      await api.mute(minutes: minutes);
      // 결함 수정(뮤트 무표시·해제 불가): 방금 바뀐 mute_until을 다음 폴링
      // 주기(최대 30초)까지 기다리지 않고 상시 상태 표시에 곧바로 반영한다
      // — `sessions_page.dart`의 `onRetry`와 같은 자리(`triggerNow(force:
      // true)`), 새 메커니즘을 만들지 않는다.
      if (mounted) {
        ref.read(syncControllerProvider.notifier).triggerNow(force: true);
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMessage = tRead(ref, 'setup.mute_success');
      });
    } on DashboardApiException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMessage = tRead(ref, 'setup.mute_error');
      });
    }
  }

  /// 결함 수정(뮤트 해제 불가): 상시 상태 표시 옆 "지금 해제" 버튼.
  /// `minutes: 0`은 서버 계약상 즉시 해제다(`dashboard_api.dart`의 `mute`
  /// 메서드 문서, `tray_native.dart`의 트레이 "해제" 항목과 같은 호출).
  Future<void> _unmute() async {
    setState(() => _busy = true);
    try {
      final api = ref.read(dashboardApiProvider);
      await api.mute(minutes: 0);
      if (mounted) {
        ref.read(syncControllerProvider.notifier).triggerNow(force: true);
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMessage = tRead(ref, 'setup.unmute_success');
      });
    } on DashboardApiException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMessage = tRead(ref, 'setup.unmute_error');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // 결함 수정(뮤트 무표시): `syncControllerProvider`(동기화가 매 폴링마다
    // 새로 읽어 오는 서버 설정)에서 파생한, 지금 이 순간(서버 시각 기준)
    // 뮤트 중인지 + 언제까지인지. `tray_native.dart`의 트레이 메뉴와 같은
    // provider를 구독한다(`state/sync_controller.dart`의
    // `muteStateListenable` 문서 참고) — 두 화면이 서로 다른 값을 보여줄
    // 이유가 없다.
    final muteState = ref.watch(muteStateListenable);
    // 이 화면이 열려 있는 동안 다른 작성자(`installUiLangSync` — sync가 실어
    // 온 서버 확정값, 예컨대 다른 기기·웹에서 바꾼 언어)가 언어를 바꾸면
    // 세그먼트 선택도 같이 따라간다. `_uiLang`은 위젯 지역 상태라 그냥 두면
    // "선택 표시는 English인데 화면은 한국어"처럼 실제 렌더 언어와 어긋난
    // 채로 남는다(리뷰 지적 medium 수정). `watch`가 아니라 `listen`인 이유:
    // 최초 표시는 `_loadConfig`가 저장값에서 읽어 채우고(부팅 seed는
    // `app.dart`가 컨트롤러에 하므로 이 화면만 단독으로 띄우는 경로에서는
    // 컨트롤러가 아직 기본값 `'system'`이다), 여기서는 "부팅 이후의 변화"만
    // 따라가면 된다.
    ref.listen<String>(uiLangControllerProvider, (previous, next) {
      if (!mounted || next == _uiLang) return;
      setState(() => _uiLang = next);
    });
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(title: Text(t(ref, 'setup.title'))),
      body: _loadingConfig
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _SectionHeader(
                  tokens: tokens,
                  text: t(ref, 'setup.section.server'),
                ),
                TextField(
                  controller: _serverUrlController,
                  decoration: InputDecoration(
                    labelText: t(ref, 'setup.server_url_label'),
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _clientTokenController,
                  decoration: InputDecoration(
                    labelText: t(ref, 'setup.client_token_label'),
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  child: Text(t(ref, 'action.save')),
                ),
                const SizedBox(height: 24),
                ...ref.watch(dashboardSetupSectionsProvider),
                if (ref.watch(windowNavigationSupportedProvider))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.window),
                    title: Text(t(ref, 'window.manage')),
                    subtitle: Text(t(ref, 'window.manage_note')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => const WindowConnectionsPage(),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                _SectionHeader(
                  tokens: tokens,
                  text: t(ref, 'setup.section.notifications'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _notificationsEnabled,
                  onChanged: _busy
                      ? null
                      : (value) =>
                            setState(() => _notificationsEnabled = value),
                  title: Text(t(ref, 'setup.notifications_enabled_label')),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _hideContent,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _hideContent = value),
                  title: Text(t(ref, 'setup.hide_content_label')),
                ),
                TextField(
                  controller: _deviceLabelController,
                  decoration: InputDecoration(
                    labelText: t(ref, 'setup.device_label_label'),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _busy ? null : _testNotification,
                  child: Text(t(ref, 'setup.test_notification_action')),
                ),
                // 후속(T16 denied 구분): macOS 권한이 명시적으로 거부된
                // 상태 — osascript로도 접지 않으므로 알림이 전혀 안 나간다는
                // 사실을 배너로 정직하게 드러낸다. 기본값이 false라 골든에는
                // 나타나지 않는다.
                if (ref.watch(notificationPermissionDeniedProvider))
                  const _PermissionDeniedBanner(),
                // 완료 기준 (d): osascript 폴백 중이면 탭해도 앱으로 돌아오지
                // 않는다는 사실을 한 줄로 고지한다. 기본값이 false라 골든에는
                // 나타나지 않는다.
                if (ref.watch(notificationUsesOsascriptFallbackProvider)) ...[
                  const SizedBox(height: 6),
                  Text(
                    t(ref, 'setup.notification_osascript_fallback_note'),
                    style: TextStyle(color: tokens.fg2, fontSize: 12),
                  ),
                ],
                // TASK P-impl (4): 지금 배너가 폴링(로컬 알림)인지 APNs인지
                // 한 줄로 고지한다 — 바로 위 osascript 폴백 고지와 같은
                // 자리·수위(fg2, 12px). 값이 바뀔 때마다(APNs 등록/해제)
                // [notificationPathLabelKeyProvider]가 새 키를 준다.
                const SizedBox(height: 6),
                Text(
                  t(ref, ref.watch(notificationPathLabelKeyProvider)),
                  style: TextStyle(color: tokens.fg2, fontSize: 12),
                ),
                // A안 설계 ④: 상주 토글. 판정은 `hasDesktopHost`가 아니라
                // provider로 한다 — 아래 웹 푸시 절이 [isWasmRuntimeProvider]
                // 를 쓰는 것과 정확히 같은 이유이고(위젯 테스트에서
                // `defaultTargetPlatform`이 android로 고정된다), 그 덕에 이
                // 토글의 영속화·네이티브 반영을 실제 macOS 없이 검증할 수
                // 있다. 기본값이 테스트에서 false이므로 골든은 그대로다.
                if (ref.watch(residentToggleSupportedProvider)) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _resident,
                    onChanged: _busy ? null : _setResident,
                    title: Text(t(ref, 'setup.resident_label')),
                    subtitle: Text(
                      t(ref, 'setup.resident_note'),
                      style: TextStyle(color: tokens.fg2, fontSize: 12),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                _SectionHeader(
                  tokens: tokens,
                  text: t(ref, 'setup.section.appearance'),
                ),
                SegmentedButton<ThemeMode>(
                  segments: [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text(t(ref, 'setup.theme_mode_system')),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text(t(ref, 'setup.theme_mode_light')),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text(t(ref, 'setup.theme_mode_dark')),
                    ),
                  ],
                  selected: {_themeMode},
                  onSelectionChanged: _busy
                      ? null
                      : (selection) => _setThemeMode(selection.first),
                ),
                const SizedBox(height: 24),
                _SectionHeader(
                  tokens: tokens,
                  text: t(ref, 'setup.section.language'),
                ),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'system',
                      label: Text(t(ref, 'setup.ui_lang_system')),
                    ),
                    ButtonSegment(
                      value: 'ko',
                      label: const Text(
                        // i18n-exempt: 언어 선택기는 각 언어를 그 언어로 표기한다
                        '한국어',
                      ),
                    ),
                    ButtonSegment(
                      value: 'en',
                      label: const Text(
                        // i18n-exempt: 언어 선택기는 각 언어를 그 언어로 표기한다
                        'English',
                      ),
                    ),
                  ],
                  selected: {_uiLang},
                  onSelectionChanged: _busy
                      ? null
                      : (selection) => _setUiLang(selection.first),
                ),
                const SizedBox(height: 24),
                // 웹 런타임에서만 그려진다 — 데스크톱 트리는 이 절 자체가
                // 없다. 판정은 `hasDesktopHost`가 아니라
                // [isWasmRuntimeProvider]로 한다: `hasDesktopHost`는
                // `defaultTargetPlatform`을 보는데 위젯 테스트에서는 그 값이
                // android로 고정되어(`flutter_test` 기본값) 데스크톱 트리가
                // 아닌 것으로 판정된다 — 위 상주 안내 문구도 같은 이유로
                // 위젯/골든 테스트에는 절대 나타나지 않는다. 이 절이 봐야
                // 하는 것은 대상 플랫폼이 아니라 "지금 브라우저에서
                // 도는가"이고, 그건 `push_provider.dart`가 쓰는 것과 같은
                // 시임이다.
                if (ref.watch(isWasmRuntimeProvider)) ...[
                  _SectionHeader(
                    tokens: tokens,
                    text: t(ref, 'setup.section.web_push'),
                  ),
                  _WebPushSection(onEnable: _busy ? null : _enableWebPush),
                  const SizedBox(height: 24),
                ],
                _SectionHeader(
                  tokens: tokens,
                  text: t(ref, 'setup.section.mute'),
                ),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy ? null : () => _mute(30),
                        child: Text(t(ref, 'setup.mute_30_action')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy ? null : () => _mute(60),
                        child: Text(t(ref, 'setup.mute_60_action')),
                      ),
                    ),
                  ],
                ),
                // 결함 수정(뮤트 무표시·해제 불가): 상시 상태 한 줄 +
                // 뮤트 중일 때만 나타나는 "지금 해제" 버튼. 트레이의 30분
                // 뮤트가 이 화면 밖에서 조용히 걸려도(완료 기준 (b): "상시
                // 표시") 다음 폴링 안에 여기 그대로 드러난다.
                const SizedBox(height: 8),
                Text(
                  muteState.muted
                      ? t(ref, 'setup.mute_status_muted', {
                          'time': formatMuteUntilClock(muteState.muteUntil!),
                        })
                      : t(ref, 'setup.mute_status_unmuted'),
                  style: TextStyle(color: tokens.fg2, fontSize: 12),
                ),
                if (muteState.muted) ...[
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _busy ? null : _unmute,
                    child: Text(t(ref, 'setup.unmute_action')),
                  ),
                ],
                if (_statusMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _statusMessage!,
                    style: TextStyle(color: tokens.fg2, fontSize: 12),
                  ),
                ],
              ],
            ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.tokens, required this.text});

  final AppTokens tokens;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: TextStyle(
        color: tokens.fg,
        fontWeight: FontWeight.w700,
        fontSize: 14,
      ),
    ),
  );
}

/// 후속(T16 denied 구분): macOS 알림 권한이 명시적으로 거부됐을 때의
/// 경고 배너. `widgets/alert_banner.dart`의 `_Banner`와 같은 스타일(색은
/// [AppTokens.warn]만 쓴다, `quality_check.py theme`)이지만 그 클래스가
/// 파일 비공개라 여기서 다시 그린다.
class _PermissionDeniedBanner extends ConsumerWidget {
  const _PermissionDeniedBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tokens.warn.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tokens.warn.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: tokens.warn, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t(ref, 'setup.notification_permission_denied_title'),
                  style: TextStyle(
                    color: tokens.warn,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t(ref, 'setup.notification_permission_denied_body'),
                  style: TextStyle(color: tokens.fg, fontSize: 12),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () =>
                          ref.read(openNotificationSettingsProvider)(),
                      child: Text(
                        t(ref, 'setup.notification_permission_denied_action'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// T17f: 브라우저 알림 권한 버튼. 호출 지점(`build`)이 `hasDesktopHost`로
/// 이미 걸러 웹에서만 트리에 들어간다 — 이 위젯 자신은 분기를 모른다.
class _WebPushSection extends ConsumerWidget {
  const _WebPushSection({required this.onEnable});

  final VoidCallback? onEnable;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Align(
    alignment: Alignment.centerLeft,
    child: OutlinedButton(
      onPressed: onEnable,
      child: Text(t(ref, 'setup.web_push_action')),
    ),
  );
}
