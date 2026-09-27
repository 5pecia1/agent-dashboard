/// UI 표시 언어(system/ko/en) 선택 — `i18n/t.dart`의 `localeProvider`에
/// 직접 이어지는 값.
///
/// **테마 모드와 정확히 같은 모양, 단 저장 표현이 이미 최종형이다.**
/// `theme_mode_provider.dart`의 [ThemeModeController]는 `ThemeMode` enum과
/// 저장용 문자열 사이를 [parseThemeMode]/[themeModeConfigValue]로 오간다 —
/// 이 컨트롤러는 그 왕복이 필요 없다: `'system'`/`'ko'`/`'en'`이 이미
/// UI·저장소·컨트롤러 셋 다에서 쓰는 문자열이라, [Notifier]의 값 타입도
/// 그냥 `String`이다.
///
/// **`build()`가 [dashboardConfigValuesProvider]를 watch하지 않는 이유도
/// 같다**(`theme_mode_provider.dart` 문서 참고): 그 provider는 override
/// 없이는 던지는 부팅 스냅샷이고, 다수의 위젯 테스트가 그 provider를
/// override하지 않은 채 돈다. 대신 `app.dart`의 부팅 시퀀스가 저장된 값으로
/// 명시적으로 seed하고, sync 응답이 올 때마다(서버가 정본) 같은 세터를
/// 다시 부른다 — `i18n/t.dart`의 `localeProvider` 문서, `app.dart`의 boot/
/// sync 배선 참고.
///
/// **낙관적 갱신을 하지 않는다(서버 동기화 계약).**
/// `dashboard_api.dart`의 `mute()` 전례를 그대로 따른다 — 이 컨트롤러의
/// [setUiLang]은 스스로 서버에 쓰지 않는다. 실제 값 변경은 항상
/// `ui/setup_page.dart._setUiLang`이 몰아준다:
///   * 서버가 이미 연결된 상태 — POST가 성공해 돌아온 **확인된 값**으로만
///     [setUiLang]을 부른다(요청 도중에는 부르지 않는다). 실패하면
///     `mute`/`unmute`와 같은 태도로 에러만 보여주고 값은 그대로 둔다.
///   * 서버 미설정 단계(`needsSetup` — `sync_controller.dart`의
///     `SyncControllerState.needsSetup`, 또는 서버 주소 자체가 아직 없는
///     `SyncPhase.unconfigured`) — 이 예외적인 경우에만 로컬에서 바로
///     [setUiLang]을 부른다(서버에 쓸 방법이 아직 없다). 언어를 잘못
///     골라 설정 화면 자체를 못 읽게 되는 상황을 막기 위해서다.
library;

import 'dart:async' show unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/state/config_provider.dart'
    show DashboardConfigValues, configPatchFnProvider;
import 'package:my_dashboard/src/state/sync_controller.dart'
    show SyncControllerState, syncControllerProvider;

/// 저장된/서버로부터 받은 원값을 셋 중 하나로 접는 순수 함수. 알 수 없는
/// 값(손상된 저장소 등)과 null은 전부 `'system'`으로 접는다 — 테마 모드와
/// 같은 안전한 폴백.
String parseUiLang(String? raw) => switch (raw) {
  'ko' => 'ko',
  'en' => 'en',
  _ => 'system',
};

/// UI 언어 값을 들고 있는 [Notifier]. `i18n/t.dart`의 `localeProvider`가 이
/// 값을 watch해 `'ko'`/`'en'`이면 그대로 쓰고, `'system'`이면 플랫폼
/// 로케일로 내려간다.
class UiLangController extends Notifier<String> {
  @override
  String build() => 'system';

  /// 부팅 경로(`app.dart`)가 저장된 값으로, sync 응답이 올 때마다(서버가
  /// 정본) `app.dart`의 리스너가, 설정 화면(`setup_page.dart._setUiLang`)이
  /// POST 확인 응답을 받을 때마다 부른다. **이 메서드 자체는 서버에 쓰지
  /// 않는다** — 위 클래스 문서의 낙관적 갱신 금지 계약 참고.
  void setUiLang(String value) {
    state = parseUiLang(value);
  }
}

final NotifierProvider<UiLangController, String> uiLangControllerProvider =
    NotifierProvider<UiLangController, String>(UiLangController.new);

// ─── sync -> 컨트롤러 배선(서버가 정본) ────────────────────────────────────

/// [installUiLangSync]가 보는 한 조각 — "이번 세션에서 서버 응답을 한 번이라도
/// 받았는가"([everSynced])와 "그 응답이 실어 온 확정값"([uiLang])의 쌍이다.
typedef UiLangSyncSnapshot = ({bool everSynced, String? uiLang});

/// `SyncControllerState`에서 [UiLangSyncSnapshot]만 골라 보는 select 프로젝션 —
/// `alert_notify_provider.dart`의 `pendingAlertsListenable`과 같은 자리·같은
/// 이유의 top-level 선언이다(부팅 배선과 테스트가 같은 listenable을 쓰게).
/// `select`는 `==`로 비교하고 Dart record는 필드별 구조적 동등성이라, 두 필드
/// 중 하나라도 실제로 바뀔 때만 리스너가 깨어난다.
///
/// **`uiLang`만 보면 안 되는 이유(리뷰 지적 high 수정).** [SyncState.uiLang]은
/// 디스크에 영속화되지 않아 부팅 직후 항상 null이고, 서버가 아직 언어를 정하지
/// 않았으면(= 서버 확정값 null) 첫 sync 응답이 도착해도 null -> null이라 select가
/// 전이를 만들지 않는다. 그러면 리스너가 아예 깨어나지 않아 부팅 시 로컬 캐시로
/// seed한 값('ko' 등)이 **영원히** 서버의 null을 이기게 된다 — [모델] 지시가
/// 못 박은 "서버 null이면 각 기기가 자기 플랫폼 로케일, 로컬 config는 판정
/// 근거가 아니라 부팅 시드 캐시"가 정확히 뒤집힌다.
///
/// `String?` 하나로는 "아직 응답 없음"과 "서버가 null이라고 답함"을 구분할 수
/// 없으므로, 그 구분자를 함께 싣는다. sentinel은 새로 만들지 않고 이미 있는
/// [SyncControllerState.lastSuccessAtMs]를 쓴다 — `widgets/alert_banner.dart`가
/// 이미 "이번 세션에서 아직 한 번도 동기화 성공하지 않았다"의 뜻으로 읽는
/// 바로 그 필드이고, `sync_controller.dart`의 `_afterSuccess`가 `sync`와 **같은
/// 쓰기에서** 함께 갱신하므로 둘이 어긋난 중간 상태가 관측되지 않는다.
final syncUiLangListenable = syncControllerProvider.select(
  (SyncControllerState state) => (
    everSynced: state.lastSuccessAtMs != null,
    uiLang: state.sync.uiLang,
  ),
);

/// 부팅 이후(위젯 트리가 뜬 다음) 한 번 부른다 — `app.dart`의
/// `_AppHomeState.initState`, `installAlertNotifier`와 같은 자리·같은 모양
/// (`ref.listen`이 아니라 `ref.listenManual`인 이유도 같다: `build` 밖에서
/// 부르기 때문이다). 반환한 구독은 위젯이 dispose될 때 자동으로 닫히지만,
/// `app.dart`가 다른 구독들과 같은 모양으로 명시적으로도 닫는다.
///
/// **서버가 정본이다(서버 상태 계약).** `sync_reducer.dart`가
/// `mute_until`/`hookSkew`와 같은 절대값 관용으로 [SyncState.uiLang]을 매
/// 응답마다 무조건 채우는 것과 대칭으로, 이 리스너도 받은 값을 무조건
/// [UiLangController.setUiLang]에 반영한다(병합·조건 분기 없음). `null`
/// (서버가 아직 정하지 않음)은 [parseUiLang]이 `'system'`으로 접어, 각
/// 기기가 다시 자기 플랫폼 로케일을 쓰게 되돌린다.
///
/// **`fireImmediately: true`이지만 서버 응답을 아직 한 번도 못 받은 동안은
/// 아무것도 하지 않는다**([UiLangSyncSnapshot.everSynced]가 false인 구간).
/// [SyncState.uiLang]은 디스크에 영속화되지 않는 필드라(서버 응답으로만
/// 채워진다), 부팅 직후 `installUiLangSync`가 붙는 시점에는 첫 sync 응답이
/// 아직 도착하지 못한 게 보통이라 항상 null이다 — 그 상태에서 그대로
/// `fireImmediately`를 태우면 방금 로컬 캐시(`config_provider.dart`의
/// `DashboardConfigValues.uiLang`, `app.dart`의 부팅 seed)로 채운 값을 매
/// 부팅마다 `'system'`으로 곧바로 덮어써 [모델] 지시가 막으려던 "첫 sync 전
/// 깜빡임"을 오히려 만들어 낸다. **응답이 한 번이라도 도착한 뒤부터는 값이
/// null이든 아니든 무조건 반영한다** — "서버가 null이라고 답했다"는 서버의
/// 확정이지 무응답이 아니다.
///
/// **받은 값을 로컬 캐시에도 되쓴다(리뷰 지적 medium 수정).** 그러지 않으면
/// 캐시는 "이 기기에서 직접 언어를 고른 경우"에만 채워져, 웹에서 바꾸고 이
/// 기기가 sync로 받은 가장 흔한 크로스-기기 경로에서 매 부팅마다 플랫폼
/// 로케일로 그려졌다가 첫 sync 도착 시 튀는, 캐시가 막으라고 있는 바로 그
/// 깜빡임이 남는다(`config_provider.dart`의 `DashboardConfigValues.uiLang`
/// 문서가 이 되쓰기를 이미 계약으로 적어 두고 있었다).
///
/// 되쓰기는 `unawaited`이고 실패해도 삼킨다 — 정본은 서버이고 이 필드는
/// 다음 부팅의 깜빡임만 막는 보조 캐시라, 디스크 실패가 이미 화면에 반영된
/// 언어를 되돌리거나 배선을 멈출 이유가 없다. 매 폴링마다 같은 값을 다시
/// 저장하지도 않는다: select가 실제 전이에서만 깨우고, 그 위에
/// `_SerializedConfigPatcher`의 `next == current` 단락이 한 번 더 막는다.
ProviderSubscription<UiLangSyncSnapshot> installUiLangSync(WidgetRef ref) {
  return ref.listenManual<UiLangSyncSnapshot>(
    syncUiLangListenable,
    (UiLangSyncSnapshot? previous, UiLangSyncSnapshot next) {
      if (!next.everSynced) return;
      final resolved = parseUiLang(next.uiLang);
      ref.read(uiLangControllerProvider.notifier).setUiLang(resolved);
      unawaited(
        ref
            .read(configPatchFnProvider)(
              (DashboardConfigValues current) =>
                  current.copyWith(uiLang: resolved),
            )
            .catchError((Object _) {}),
      );
    },
    fireImmediately: true,
  );
}
