/// App Nap 방지 오케스트레이션 (TASK P-impl (1)).
///
/// **막는 조건.** 상주 모드가 켜져 있고(`resident_provider.dart`가 다루는
/// 같은 설정값) *그리고* 창이 완전히 숨겨져 있을 때만이다. 둘 중 하나라도
/// 아니면 막을 이유가 없다 — 상주가 꺼져 있으면 창을 닫는 순간 프로세스가
/// 끝나고(`AppDelegate.swift`), 창이 보이는 동안은 App Nap이 애초에 거의
/// 걸리지 않는다(macOS는 포그라운드/가시 앱을 스로틀하지 않는다).
///
/// **왜 [AppLifecycleState]를 그대로 쓰는가(bool로 접지 않는다).**
/// `sync_controller.dart`의 `SyncActivityWatchFn`은 "포그라운드냐"만 필요해
/// `resumed`만 남기고 나머지를 전부 false로 접는다. 여기는 다르다 — `hidden`
/// (창이 완전히 사라짐)과 `inactive`(포커스만 잃음, 여전히 보임)를 구분해야
/// 한다. `inactive`까지 "숨김"으로 접으면 사용자가 다른 창으로 잠깐 눈을
/// 돌릴 때마다 App Nap 방지가 켜졌다 꺼졌다 한다 — 의미가 없다. 그래서 이
/// 파일은 [SyncActivityWatchFn]을 재사용하지 않고 원시 상태 스트림을 따로
/// 가진다([BackgroundActivityLifecycleWatchFn]).
///
/// **실제 `ProcessInfo.beginActivity`/`endActivity`는 여기 없다.** Dart에는
/// 그 API가 없다 — 이 컨트롤러가 하는 일은 "언제 켜고 꺼야 하는가"를
/// 판정하는 것까지고, 그 판정을 [BackgroundActivityApplyFn] 시임(기본 구현:
/// `platform/background_activity_native.dart`)으로 넘기면 그 너머 Swift
/// (`AppDelegate.setBackgroundActivity`)가 실제 호출을 한다. 이 분리 덕에
/// 테스트는 실제 MethodChannel 없이 판정 로직만(가짜 시임으로) 검증한다.
///
/// `resident_provider.dart`/`capability_provider.dart`와 같은 3계층 관용:
/// 함수 타입 -> `Provider<Fn>` -> 얇은 함수(조건부 import로 데스크톱/웹 분기).
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/platform/background_activity_native.dart'
    if (dart.library.js_interop) 'package:my_dashboard/src/platform/background_activity_web.dart'
    as bridge;

// ─── 시임 (1계층: 함수 모양 + 2계층: Provider) ──────────────────────────

/// 네이티브에 App Nap 방지 on/off를 밀어 넣는다. `resident_provider.dart`의
/// `ResidentModeApplyFn`과 같은 모양 — 테스트는 이 Provider를 override해
/// 실제 MethodChannel 없이 호출 여부·인자만 본다.
typedef BackgroundActivityApplyFn = Future<void> Function(bool active);

final Provider<BackgroundActivityApplyFn> backgroundActivityApplyFnProvider =
    Provider<BackgroundActivityApplyFn>((ref) => bridge.applyBackgroundActivity);

/// 창 가시성을 포함한 원시 앱 생명주기 상태 스트림. 기본 구현은
/// `AppLifecycleListener`(Flutter 프레임워크 자체 — 플러그인이 아니다,
/// `sync_controller.dart`의 `SyncActivityWatchFn` 문서와 같은 근거).
typedef BackgroundActivityLifecycleWatchFn = Stream<AppLifecycleState> Function();

Stream<AppLifecycleState> _lifecycleWatchBridge() {
  AppLifecycleListener? listener;
  late final StreamController<AppLifecycleState> controller;
  controller = StreamController<AppLifecycleState>.broadcast(
    onListen: () {
      listener = AppLifecycleListener(
        onStateChange: (AppLifecycleState state) => controller.add(state),
      );
    },
    onCancel: () {
      listener?.dispose();
      listener = null;
    },
  );
  return controller.stream;
}

final Provider<BackgroundActivityLifecycleWatchFn> backgroundActivityLifecycleWatchFnProvider =
    Provider<BackgroundActivityLifecycleWatchFn>((ref) => _lifecycleWatchBridge);

// ─── 순수 정책 함수 ──────────────────────────────────────────────────────

/// 지금 App Nap 방지를 걸어야 하는가. 상주 && 창 숨김일 때만 true다.
///
/// 순수 함수라 가짜 상태 두 개만으로 이 파일이 요구하는 판정을 실제
/// `AppLifecycleListener`/`MethodChannel` 없이 재현할 수 있다.
bool shouldPreventAppNap({required bool residentEnabled, required AppLifecycleState lifecycle}) =>
    residentEnabled && lifecycle == AppLifecycleState.hidden;

// ─── 컨트롤러 (3계층: 조립) ──────────────────────────────────────────────

/// App Nap 방지 판정을 갖고 있는 [Notifier]. 노출하는 [state]는 "지금
/// App Nap 방지가 걸려 있다고 마지막으로 네이티브에 통보한 값"이다 — 화면이
/// 직접 구독할 일은 없지만(진단용 값이 아니다), 테스트가 begin/end 시임
/// 호출을 값 변화로 검증할 수 있게 한다.
class BackgroundActivityController extends Notifier<bool> {
  bool _residentEnabled = kResidentDefault;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  StreamSubscription<AppLifecycleState>? _subscription;

  @override
  bool build() {
    // **`dashboardConfigValuesProvider`를 여기서 watch하지 않는다.** 그
    // provider는 override 없이는 던진다(부팅 시퀀스가 채워야 하는 값,
    // `config_provider.dart` 문서 참고) — 이 컨트롤러를 부팅 시점 상주
    // 값과 엮으면 `setup_page.dart`처럼 상주 값만 필요한 화면의 테스트마다
    // 그 provider를 매번 override해야 한다. 대신 `resident_provider.dart`의
    // `residentModeApplyProvider`와 정확히 같은 관용을 쓴다 — 호출자(부팅
    // 경로는 `app.dart`, 토글 변경은 `setup_page.dart`)가 [setResident]로
    // 명시적으로 알려준다. 초기값 [kResidentDefault]는 그 알림이 오기 전
    // 창이 숨겨지는 극히 드문 경합에서도 "상주 꺼짐"으로 오판해 App Nap
    // 방지를 놓치지 않게 한다(`AppDelegate.swift`의 `isResident = true`
    // 기본값과 같은 이유).
    final watch = ref.watch(backgroundActivityLifecycleWatchFnProvider);
    _subscription = watch().listen(_onLifecycleChange);

    ref.onDispose(() => _subscription?.cancel());

    // `build()` 안에서는 `state`에 쓰지 않는다(riverpod 계약,
    // `sync_controller.dart`와 같은 이유) — 부팅 시점엔 창이 보이는 게
    // 보통이라 판정은 대개 false이고, 그 경우 네이티브를 부를 필요조차
    // 없으므로 초기값 false를 그대로 반환한다. 부팅 직후 이미 숨겨진 채로
    // 시작하는 드문 경로는 다음 lifecycle 이벤트가 곧 따라잡는다.
    return false;
  }

  /// 상주 값이 정해지거나 바뀔 때 호출자가 부른다 — 부팅 경로(`app.dart`)가
  /// 저장된 값으로 한 번, 이후 설정 화면(`setup_page.dart._setResident`)이
  /// 토글할 때마다 한 번씩. `resident_provider.dart`의
  /// `residentModeApplyProvider` 호출과 같은 자리에서 함께 부르면 된다.
  void setResident(bool enabled) {
    _residentEnabled = enabled;
    _apply();
  }

  void _onLifecycleChange(AppLifecycleState next) {
    _lifecycle = next;
    _apply();
  }

  void _apply() {
    final shouldBeActive = shouldPreventAppNap(
      residentEnabled: _residentEnabled,
      lifecycle: _lifecycle,
    );
    if (shouldBeActive == state) return;
    state = shouldBeActive;
    unawaited(ref.read(backgroundActivityApplyFnProvider)(shouldBeActive));
  }
}

/// 조립된 컨트롤러. `app.dart` 부팅 경로가 한 번 `ref.read`해 구독을
/// 시작해야 한다(`build()`가 리스너를 붙이는 자리라 읽지 않으면 아무 일도
/// 일어나지 않는다 — `syncControllerProvider`와 같은 관용).
final NotifierProvider<BackgroundActivityController, bool> backgroundActivityControllerProvider =
    NotifierProvider<BackgroundActivityController, bool>(BackgroundActivityController.new);
