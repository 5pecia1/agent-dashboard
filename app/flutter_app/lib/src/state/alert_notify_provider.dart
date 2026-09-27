/// TASK A-impl (1): "미확인 alert 전이 -> 실제 알림"의 **호출부**.
///
/// 지금까지 이 코드베이스에는 이 조각만 없었다. `sync_reducer.dart`는 어떤
/// 전이가 알림 대상인지 이미 계산해 [SyncState.pendingAlerts]에 쌓고
/// (`waiting_input`/`stalled` = 정본 `push_states.enum`, `done`은 2026-09-14
/// Sol 확정으로 제외됨, 중복
/// `transition_id` 제거, 첫 기동 10분 창까지 포함), `notify_provider.dart`는
/// "전이 하나당 한 번, 소유권·런타임을 존중해서" 배너를 띄우는 법을 이미
/// 안다. 둘을 잇는 구독이 없어서 프로덕션 부팅 경로에서는 배너가 실제로
/// 뜨지 않았다(`sync_controller.dart` 상단이 "향후 과제"로 남겨 둔 자리,
/// RUNBOOK의 알려진 결함 표에 있던 항목).
///
/// **새 규칙을 만들지 않는다.** 이 파일은 "누구에게 알릴지"도 "웹이냐"도
/// "APNs가 배너의 주인이냐"도 "권한이 거부됐냐"도 판정하지 않는다 —
/// 전부 이미 있는 자리에 그대로 맡긴다:
///   * 어떤 전이가 알림인가 -> `sync_reducer.dart`(리듀서) + `TransitionDto.isAlert`
///   * 웹 no-op / APNs 등록 시 억제 -> `notify_provider.dart`의 [notifyProvider]
///   * 권한 거부 시 발신 없음 -> `local_notifications_native.dart`의
///     `NotificationBackend.none`(프로브가 정한다)
///   * 알림 클릭 -> 세션 상세 딥링크 -> 기존 T16 경로(`app.dart`의
///     `handleNotificationTap`, 페이로드의 `sessionKey`는
///     `payloadForAlert`가 이미 싣는다)
///
/// 이 파일이 새로 책임지는 것은 **정확히 하나**다: "같은 전이로 두 번
/// 알리지 않는다". [SyncState.pendingAlerts]는 사용자가 확인할 때까지
/// 남아 있는 **누적 큐**다(화면의 "그동안 있었던 일" 패널이 그 큐를
/// 그린다 — `catchup_panel.dart`). 그래서 sync가 한 번 더 돌 때마다 같은
/// 큐가 다시 도착한다 — 큐를 그대로 발신에 넘기면 폴링 주기마다 같은
/// 배너가 다시 뜬다. [AlertNotifier]는 리듀서가 쓰는 것과 같은 모양의
/// 워터마크(이미 발신한 최대 전이 id)를 들고 그 위쪽만 내보낸다. 전이
/// id는 서버에서 단조 증가하고 재사용되지 않으므로(`TransitionDto.id`
/// 문서) 이 한 정수가 "이미 알린 것"을 전부 표현한다.
library;

import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart' show TransitionDto;
import 'package:my_dashboard/src/state/notify_provider.dart'
    show alertStateLabelProvider, notifyForAlerts, notifyProvider;
import 'package:my_dashboard/src/state/sync_controller.dart'
    show SyncControllerState, syncControllerProvider;

// ─── 순수 정책 함수 ──────────────────────────────────────────────────────

/// [pendingAlerts] 중 아직 발신하지 않은 것만 고른다(id > [watermark]).
///
/// 순수 함수라 리스너·타이머·Provider 없이 "중복 재전송 0회"를 값만으로
/// 확인할 수 있다(`sync_reducer.dart`의 순수 리듀서와 같은 관용).
List<TransitionDto> unnotifiedAlerts(
  List<TransitionDto> pendingAlerts, {
  required int watermark,
}) => pendingAlerts
    .where((TransitionDto alert) => alert.id > watermark)
    .toList(growable: false);

// ─── 워터마크 게이트 ─────────────────────────────────────────────────────

/// 도착한 미확인 알림 큐를 받아 **아직 알리지 않은 전이당 정확히 한 번**
/// [notifyProvider]를 부른다.
///
/// [notifyProvider]를 생성 시점에 캡처하지 않고 발신할 때마다 다시 읽는다 —
/// 그 Provider는 [apnsRegisteredProvider]를 watch하므로 APNs 등록이
/// 성공/실패로 바뀌는 순간 새로 만들어진다(`notify_provider.dart` 규칙 2).
/// 캡처해 두면 소유권이 넘어간 뒤에도 옛 시임으로 계속 띄워 배너가 둘
/// 뜬다.
///
/// [alertStateLabelProvider]도 **같은 이유로** 매번 다시 읽는다 — 그쪽은
/// 활성 로케일(`localeProvider`)을 watch하므로 사용자가 UI 언어를 바꾸는
/// 순간 새로 만들어진다. 캡처해 두면 언어를 바꾼 뒤에도 알림 제목만 옛
/// 언어로 남는다. 여기가 이 앱에서 `WidgetRef`가 아닌 `Ref`를 든 채 i18n
/// 문구가 필요해지는 유일한 자리라, `i18n/t.dart`의 `t`/`tRead`(둘 다
/// `WidgetRef` 전용) 대신 Provider 시임을 쓴다.
class AlertNotifier {
  AlertNotifier(this._ref);

  final Ref _ref;

  int _watermark = 0;

  /// 마지막으로 발신한 전이 id. 테스트가 "중복 재전송 0회"의 이유를
  /// 값으로 확인할 수 있게 노출한다.
  @visibleForTesting
  int get debugWatermark => _watermark;

  /// [pendingAlerts]에서 워터마크 위쪽만 발신한다. 큐 전체가 다시 와도
  /// (폴링 주기마다 그렇다) 이미 알린 전이는 다시 나가지 않는다.
  ///
  /// 워터마크를 `await` **전에** 올린다 — 발신 중에 다음 sync 결과가
  /// 도착해도(폴링은 발신을 기다려 주지 않는다) 같은 전이를 두 번 집지
  /// 않는다.
  Future<void> dispatchNew(List<TransitionDto> pendingAlerts) async {
    final fresh = unnotifiedAlerts(pendingAlerts, watermark: _watermark);
    if (fresh.isEmpty) return;
    for (final alert in fresh) {
      _watermark = math.max(_watermark, alert.id);
    }
    await notifyForAlerts(
      fresh,
      dispatch: _ref.read(notifyProvider),
      stateLabel: _ref.read(alertStateLabelProvider),
    );
  }
}

/// 앱 하나에 하나. 위젯이 아니라 Provider 그래프가 들고 있어서, 화면이
/// 다시 마운트되더라도(설정 화면 -> 세션 목록 전환 등) 워터마크가 초기화되지
/// 않는다 — 그게 곧 "이미 알린 전이를 다시 알리지 않는다"의 수명이다.
final Provider<AlertNotifier> alertNotifierProvider = Provider<AlertNotifier>(
  (ref) => AlertNotifier(ref),
);

// ─── 부팅 배선 ───────────────────────────────────────────────────────────

/// 리스너가 구독하는 대상. 부팅 배선([installAlertNotifier])과 테스트가
/// **같은** listenable을 쓰게 top-level에 둔다.
///
/// 타입 이름을 소스에 적지 않는 이유는 `app_wiring_test.dart`의
/// `_commonOverrides`와 같다 — `ProviderListenable`은 `flutter_riverpod`의
/// export 목록에 없다(정본은 `package:riverpod`). 초기화식에서 타입이
/// 그대로 추론되므로 `strict-inference`도 만족한다.
///
/// `select`는 `==`로 비교한다 — `pendingAlerts`는 매 사이클마다 새
/// `List`(`List.unmodifiable`)라 알림이 늘지 않은 사이클에도 리스너가
/// 깨어난다. 중복 억제는 그래서 리스너가 아니라 [AlertNotifier]의
/// 워터마크가 담보한다.
final pendingAlertsListenable = syncControllerProvider.select(
  (SyncControllerState state) => state.sync.pendingAlerts,
);

/// 부팅 이후(위젯 트리가 뜬 다음) 한 번 부른다 — `app.dart`의
/// `_AppHomeState.initState`, `syncControllerProvider`를 깨우고
/// `installTray`를 부르는 것과 **같은 자리**다.
///
/// `ref.listen`이 아니라 `ref.listenManual`인 이유: 이 호출은 `build`
/// 밖(initState)이다(riverpod이 그 구분을 계약으로 못 박았다 —
/// `widget_ref.dart` 문서). 반환한 구독은 위젯이 dispose될 때 자동으로
/// 닫히지만(같은 문서), `app.dart`가 `_pushSignals`와 같은 모양으로
/// 명시적으로도 닫는다.
///
/// `fireImmediately: true`는 부팅 직전에 이미 큐에 들어와 있던 전이(예:
/// 첫 사이클이 컨트롤러 `build()` 직후 곧바로 끝난 경합)를 놓치지 않기
/// 위한 것이다 — 워터마크가 있으니 중복 위험은 없다.
ProviderSubscription<List<TransitionDto>> installAlertNotifier(WidgetRef ref) {
  final notifier = ref.read(alertNotifierProvider);
  return ref.listenManual<List<TransitionDto>>(
    pendingAlertsListenable,
    (List<TransitionDto>? previous, List<TransitionDto> next) =>
        unawaited(notifier.dispatchNew(next)),
    fireImmediately: true,
  );
}
