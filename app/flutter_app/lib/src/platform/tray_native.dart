/// macOS 메뉴 바 아이콘과 컨텍스트 메뉴.
/// 창 표시는 로컬 알림과 같은 [bringWindowToFront] 채널을 사용한다.
///
/// **가드.** 이 파일은 `dart.library.js_interop`가 없을 때만 로드된다
/// (`tray.dart`의 조건부 export — `package:tray_manager/tray_manager.dart`
/// 가 `dart:io`를 무조건 import해서 웹 컴파일 그래프에 들어가면 안 된다).
/// 웹 다음의 두 번째 가드는 macOS 자체다: 이번 작업 범위가 "macOS 메뉴
/// 바"로 명시돼 있어([traySupportedProvider]) linux/windows에서는
/// `tray_manager`가 기술적으로 지원해도 조용히 건너뛴다. 플러그인이 아직
/// 네이티브에 등록되지 않았거나(개발 환경 문제) 채널 호출이 실패해도
/// soft-fail(`debugPrint`만) — `local_notifications_native.dart`의 프로브와
/// 같은 관용이다.
///
/// **시임 3계층.** [trayOpenProvider]/[trayMuteProvider]/[trayQuitProvider]
/// 는 이 템플릿의 `typedef -> Provider<Fn> -> 얇은 함수` 계약을 그대로
/// 따른다 — 테스트는 실제 `tray_manager` 플러그인이나 `dashboard_api.dart`의
/// 네트워크 없이 이 세 Provider만 override해서 각 명령의 부작용을 확인한다
/// (`test/widget_tests/tray_test.dart`).
///
/// **i18n.** 메뉴 라벨은 위젯 트리 밖(부팅 이후, `app.dart`의
/// `_AppHomeState.initState`)에서 만들어지지만 그 시점엔 이미 위젯 트리가
/// 살아 있어 진짜 `WidgetRef`를 하나 갖고 있다 — `t.dart`가 [tRead]에 준
/// 계약("메뉴 라벨" 이 `tRead`의 예시 용례로 문서에 명시돼 있다)대로 그
/// `WidgetRef`로 [tRead]를 불러 라벨을 만든다. 메뉴를 다시 열 때는 현재
/// 로케일과 사용량 캐시를 다시 읽으며, 이미 열린 메뉴의 라벨은 유지한다.
library;

import 'dart:async' show unawaited;
import 'dart:io' show Platform, exit;

import 'package:flutter/foundation.dart'
    show debugPrint, listEquals, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart'
    show DashboardApiException, dashboardApiProvider;
import 'package:my_dashboard/src/data/dashboard_dto.dart'
    show SessionViewDto, sortedSessionsFor;
import 'package:my_dashboard/src/i18n/t.dart' show tRead;
import 'package:my_dashboard/src/platform/local_notifications_native.dart'
    show bringWindowToFront, showNotification;
import 'package:my_dashboard/src/platform/tray_command.dart';
import 'package:my_dashboard/src/state/dashboard_extensions.dart';
import 'package:my_dashboard/src/state/config_provider.dart'
    show dashboardApiConfigControllerProvider;
import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show sessionStateDtoFromCode, stateLabelKeyFnProvider;
import 'package:my_dashboard/src/state/sync_controller.dart'
    show SyncControllerState, syncControllerProvider;
import 'package:my_dashboard/src/util/mute_time.dart' show formatMuteUntilClock;
import 'package:my_dashboard/src/util/session_display.dart'
    show sessionDisplayName;

/// `assets/tray_icon.png`(pubspec에 등록, 16×16 **컬러** PNG — 종 모양의
/// 알파는 옛 template 원본 그대로, RGB만 보라 `#A56FD8`로 채웠다).
/// `setIcon`이 `rootBundle.load`로 그대로 읽는 리터럴 경로다(패키지 소스
/// 확인, `pubspec.yaml`의 assets 절 주석 참고) — device-pixel-ratio
/// 변형을 타지 않으므로 여기서 `@2x` 변형을 가리킬 필요가 없다.
///
/// **왜 컬러/non-template인가.** 흑백 template(RGB=0+알파만)이던 시절
/// "트레이 아이콘이 눈에 안 띈다"는 불만이 있었다(2026-09-20 확정,
/// `.okf/log.md`). template 이미지는 macOS가 메뉴 바 테마에 맞춰 단색으로
/// 다시 칠한다 — 어두운 메뉴 바에서는 흰색, 밝으면 검정이 되므로 아이콘
/// **색**으로 상태를 나타내는 것이 애초에 불가능하다. 아이콘 색으로 주의
/// 심각도를 구분하는 이 설계에서는 모든 아이콘이 `isTemplate: false`다
/// (상태별로 다를 이유가 없어 상수로 고정). 색의 근거는
/// `theme/app_tokens.dart`의 토큰 계열이다 — 보라는 `unseenDot` 계열
/// (청보라), 아래 호박·적갈은 `stateWaitingInput`/`stateStalled` 계열로,
/// 밝은 메뉴 바와 어두운 메뉴 바 양쪽에서 읽히는 중간 채도를 골랐다.
const String _kTrayIconAssetPath = 'assets/tray_icon.png';

/// 사람의 입력을 기다리는 세션(`waiting_input`)이 하나 이상일 때 쓰는 변형
/// (`assets/tray_icon_attention_waiting.png`) — 같은 종+점 모양을 호박
/// `#DE9E1F`로 채웠다. 알파 채널(종 본체 + 오른쪽 위 점, 점 주변 1px는
/// 알파 0으로 깎아 분리)은 폐기된 `tray_icon_attention.png`의 것을 그대로
/// 재사용하고 RGB만 바꿨다(16×16, `2.0x` 변형도 나란히 둔다).
const String _kTrayWaitingIconAssetPath =
    'assets/tray_icon_attention_waiting.png';

/// 멈춘 것으로 추정되는 세션(`stalled`)이 하나 이상일 때 쓰는 변형
/// (`assets/tray_icon_attention_stalled.png`) — 적갈 `#E0705B`
/// (`AppTokens.dark.stateStalled`와 같은 값). **stalled가 waiting보다
/// 우선**한다 — 둘이 동시에 있으면 더 심각한 쪽 색을 띄운다
/// ([trayBadgeIconAssetPath] 참고).
const String _kTrayStalledIconAssetPath =
    'assets/tray_icon_attention_stalled.png';

/// `POST /dashboard/mute`에 넘길 분(minute) — 이번 작업의 확정 설계값
/// ("알림 음소거 30분") 그대로다. 매직 넘버가 아니라 여기 한 곳에서만
/// 정의해 재사용한다.
const int _kTrayMuteMinutes = 30;

/// 이 호스트가 트레이 아이콘을 가질 수 있는가(macOS만).
///
/// **상수가 아니라 Provider인 이유는 `residentToggleSupportedProvider`와
/// 정확히 같다**(`state/resident_provider.dart` 문서 참고): 판정 바탕인
/// `Platform.isMacOS`를 테스트에서 갈아끼울 수 없으니, 그 판정을 감싸는
/// 이 Provider 쪽을 override해서 "웹/비macOS에서는 no-op"을 실제 플러그인
/// 없이 확인한다.
final Provider<bool> traySupportedProvider = Provider<bool>(
  (ref) => Platform.isMacOS,
);

/// "열기"(좌클릭과 동일) 명령의 함수 모양.
typedef TrayOpenFn = Future<void> Function();

/// "종료" 명령의 함수 모양. 상주 여부를 무시하고 진짜로 끝난다 — 되돌릴
/// 방법이 없으므로 반환값이 없다(정상적으로 다시 돌아오지 않는다).
typedef TrayQuitFn = void Function();

/// "알림 음소거 30분"/"알림 뮤트 해제" 명령의 함수 모양. `bool` 반환값은
/// 성공 여부다 — 호출부(`_DashboardTrayController._dispatch`)가 그 값으로
/// 성공/실패 알림 문구를 고른다(TASK MUTE-impl 완료 기준 (c): 뮤트/해제
/// 시 피드백).
typedef TrayMuteFn = Future<bool> Function();

/// 좌클릭/메뉴의 "열기" — 창을 앞으로 가져온다. `bringWindowToFront`를
/// 그대로 얹는다(새 메커니즘을 만들지 않는다).
final Provider<TrayOpenFn> trayOpenProvider = Provider<TrayOpenFn>(
  (ref) => bringWindowToFront,
);

/// 메뉴의 "종료". 테스트는 이 Provider를 override해 실제로 프로세스를
/// 끝내지 않고 호출 여부만 본다 — 실제 종료 경로(`_quitProcess`) 자체는
/// 단위 테스트 대상이 아니다(호출하면 테스트 러너가 죽는다).
final Provider<TrayQuitFn> trayQuitProvider = Provider<TrayQuitFn>(
  (ref) => _quitProcess,
);

/// 메뉴의 "알림 음소거 30분". [ref]는 Provider 그래프의 [Ref]를 그대로
/// 캡처한다(위젯 마운트 여부와 무관하게 컨테이너가 사는 동안 유효하다) —
/// 호출 시점에 [dashboardApiProvider]를 다시 읽어 그 시점의 서버 설정을
/// 쓴다.
final Provider<TrayMuteFn> trayMuteProvider = Provider<TrayMuteFn>(
  (ref) =>
      () => _setMute(ref, minutes: _kTrayMuteMinutes),
);

/// TASK MUTE-impl: 메뉴의 "알림 뮤트 해제". `POST /dashboard/mute`에
/// `minutes<=0`을 보내면 서버가 즉시 해제로 해석한다(`dashboard_api.dart`
/// 의 `mute` 메서드 문서) — 별도 엔드포인트가 아니라 같은 호출의 인자
/// 하나만 [trayMuteProvider]와 다르다.
final Provider<TrayMuteFn> trayUnmuteProvider = Provider<TrayMuteFn>(
  (ref) =>
      () => _setMute(ref, minutes: 0),
);

/// 표시 시점의 세션 스냅샷과 읽음 상한을 전달한다.
typedef TraySessionSelectFn = Future<void> Function(SessionViewDto session);

void _quitProcess() => exit(0);

/// 서버 미설정/오류는 크래시하지 않고 `debugPrint`만 한다(완료 기준 (4)).
/// 서버 오류는 [DashboardApiException] 하나로 모이지만, 서버 주소 없이 부팅한
/// 세션에서는 [dashboardApiProvider]를 읽는 순간 그 밖의 오류가 난다 — 둘 다
/// 실패로 돌려줘 호출부가 실패 알림을 띄우게 한다.
Future<bool> _setMute(Ref ref, {required int minutes}) async {
  try {
    await ref.read(dashboardApiProvider).mute(minutes: minutes);
    return true;
  } on Object catch (error) {
    debugPrint('tray mute($minutes): 서버 호출 실패 ($error) — 무시하고 계속한다.');
    return false;
  }
}

/// 트레이 컨텍스트 메뉴를 만든다. [ref]로 [tRead]를 딱 한 번 불러
/// 라벨을 굽는다 — 순수 데이터 구성이라(플랫폼 채널을 타지 않는다)
/// `tray_manager` 플러그인 없이도 단위 테스트할 수 있다.
///
/// TASK MUTE-impl: [muted]가 켜져 있으면 "30분 음소거" 자리를 "해제"
/// 항목이 대신한다(같은 자리를 배타적으로 갈아 낀다 — 동시에 둘 다 보일
/// 이유가 없다: 이미 음소거 중인데 또 30분을 얹는 UI는 혼란만 준다). 기본값
/// (`muted: false`)은 기존 호출부(`buildTrayMenuItems(ref)`)를 그대로 둔다.
///
/// TASK TRAY-unseen-menu: [unseen]에 미확인 세션(`SyncState.
/// unseenReportableSessions` — 트레이 숫자가 세는 것과 같은 필터)이 있으면
/// "열기" 아래에 구분선으로 감싼 세션 항목들이 서브메뉴 없이 바로 나열되고,
/// 항목을 누르면 표시 시점의 세션을 창 전환 콜백으로 전달한다. 항목 순서는 화면과 같은 정본
/// (`sortedSessionsFor`)이고 상한은 없다 — "리스트 다 보여주는 형식"
/// 항목을 접지 않는다.
List<MenuItem> buildTrayMenuItems(
  WidgetRef ref, {
  bool muted = false,
  int? muteUntil,
  List<SessionViewDto> unseen = const <SessionViewDto>[],
  List<String> usageLabels = const <String>[],
  TraySessionSelectFn? onSessionSelected,
}) => <MenuItem>[
  MenuItem(key: TrayCommand.open.menuItemKey, label: tRead(ref, 'tray.open')),
  if (usageLabels.isNotEmpty) ...[
    MenuItem.separator(),
    for (final label in usageLabels) MenuItem(label: label, disabled: true),
    if (unseen.isEmpty) MenuItem.separator(),
  ],
  ..._buildUnseenItems(ref, unseen, onSessionSelected),
  if (muted && muteUntil != null)
    MenuItem(
      key: TrayCommand.unmute.menuItemKey,
      label: tRead(ref, 'tray.mute_unmute', <String, String>{
        'time': formatMuteUntilClock(muteUntil),
      }),
    )
  else
    MenuItem(
      key: TrayCommand.mute30.menuItemKey,
      label: tRead(ref, 'tray.mute_30'),
    ),
  MenuItem.separator(),
  MenuItem(key: TrayCommand.quit.menuItemKey, label: tRead(ref, 'tray.quit')),
];

/// "안읽은 세션" 항목들 — 미확인 세션 하나당 항목 하나를 구분선 사이에 끼워
/// 최상위 메뉴에 바로 나열한다(한 단계 더 들어가는 서브메뉴는 쓰지 않는다 —
/// 항목을 숨기지 않는다). 항목 라벨은 카드 제목과 같은
/// 규칙(project의 basename, 없으면 sessionId — `session_card.dart`와 같은
/// 폴백)에 상태 라벨(`state.*` 키, `state_chip.dart`과 같은 정본 경로)을
/// 붙인 "{project} — {state}"다. [unseen]이 비면 아무것도 내지 않는다 —
/// 구분선만 덩그러니 남는 일이 없게 여기서 통째로 접는다.
List<MenuItem> _buildUnseenItems(
  WidgetRef ref,
  List<SessionViewDto> unseen,
  TraySessionSelectFn? onSessionSelected,
) {
  if (unseen.isEmpty) return const <MenuItem>[];
  // 열린 메뉴는 스냅샷으로 남는다. A 메뉴를 B 전환 뒤 클릭해도 A의
  // 세션과 읽음 id를 B에 전달하지 않도록 생성 시 서버 수명을 붙인다.
  final connection = ref.read(dashboardApiConfigControllerProvider.notifier);
  final serverRevision = connection.serverRevision;
  final labelKeyFor = ref.read(stateLabelKeyFnProvider);
  String labelFor(SessionViewDto session) {
    final project = sessionDisplayName(
      project: session.project,
      fallback: session.sessionId,
      displayTitle: session.displayTitle,
    );
    final stateLabel = tRead(
      ref,
      labelKeyFor(sessionStateDtoFromCode(session.state)),
    );
    return tRead(ref, 'tray.unseen_item', <String, String>{
      'project': project,
      'state': stateLabel,
    });
  }

  return <MenuItem>[
    MenuItem.separator(),
    for (final session in sortedSessionsFor(unseen))
      MenuItem(
        key: traySeenMenuKey(session.key),
        label: labelFor(session),
        onClick: (_) {
          if (onSessionSelected != null &&
              connection.serverRevision == serverRevision) {
            unawaited(onSessionSelected(session));
          }
        },
      ),
    MenuItem.separator(),
  ];
}

// ─── TASK A-impl (2): 주의 배지 ──────────────────────────────────────────

/// 배지 상태 하나를 네이티브에 밀어 넣는 시임(아이콘 -> 툴팁 -> 제목).
///
/// 세 플러그인 호출을 한 시임으로 묶은 이유는 순서가 계약이기 때문이다 —
/// `tray_manager`의 `setToolTip` 문서가 "아이콘을 세운 다음에 불러야
/// 한다"고 못 박는다. 호출부가 순서를 다시 정할 수 없게 여기 한 곳에
/// 접어 두고, 테스트는 이 Provider 하나만 override해 (제목, 아이콘, 툴팁)
/// 세 값을 그대로 관찰한다.
typedef TrayBadgeApplyFn =
    Future<void> Function({
      required String title,
      required String iconAssetPath,
      required String tooltip,
    });

Future<void> _trayBadgeApplyBridge({
  required String title,
  required String iconAssetPath,
  required String tooltip,
}) async {
  try {
    // `isTemplate: false` — 컬러 아이콘 설계의 핵심이다. template(true)이면
    // macOS가 색을 버리고 메뉴 바 테마 단색으로 다시 칠해, 아이콘 색으로
    // 주의 심각도(waiting=호박/stalled=적갈)를 나타내는 이 절의 계약이
    // 통째로 깨진다.
    await trayManager.setIcon(iconAssetPath, isTemplate: false);
    await trayManager.setToolTip(tooltip);
    await trayManager.setTitle(title);
  } on Exception catch (error) {
    // `installTray`와 같은 관용의 soft-fail — 배지가 안 붙는 것은 알림
    // 자체를 막지 않는다(배너는 `notify_provider.dart` 경로로 그대로
    // 뜬다).
    debugPrint('trayBadge: 배지를 갱신하지 못했다 ($error).');
  }
}

final Provider<TrayBadgeApplyFn> trayBadgeApplyFnProvider =
    Provider<TrayBadgeApplyFn>((ref) => _trayBadgeApplyBridge);

/// TASK TRAY-unseen: 트레이 숫자/아이콘이 각자 다른 축을 본다 — 이 둘을
/// 섞지 않는 게 이 절 전체의 설계 요지다.
///
/// - **숫자(제목/툴팁) = 미확인(unseen)**. "카드를 열어 읽었는가"만 본다
///   (`SyncState.unseenReportableSessionCount`, `SyncState.isSessionUnseen`과
///   같은 판정) — 다만 `working` 상태인 미확인 세션은 뺀다. 트레이는
///   사용자를 미는 신호면이라 "그냥 일하는 중"으로는 울리지 않는다(뷰의
///   카드 미확인 점은 working도 그대로 켠다 — `SyncState.
///   unseenReportableSessionCount` 문서 참고). 세션을 열면 카드의 미확인
///   점이 꺼지는 것과 정확히 같은 순간에 이 숫자도 준다.
/// - **아이콘 색 = 주의 심각도(attention, 상태별로 나뉜다)**. "행동이
///   필요한가"만 본다 — `stalled` 세션이 하나라도 있으면 적갈
///   ([_kTrayStalledIconAssetPath]), 없어도 `waiting_input`이 있으면 호박
///   ([_kTrayWaitingIconAssetPath]), 둘 다 없으면 기본 보라
///   ([_kTrayIconAssetPath]). 이미 읽은 세션이라도 여전히 사람의 입력을
///   기다리는 중이면 아이콘 색은 그대로 유지된다 — 읽음 여부로 꺼지지
///   않는다.
///
/// 두 축이 같은 순간에 다른 방향으로 움직일 수 있다(예: 대기 중인 세션을
/// 열어서 읽으면 숫자는 즉시 0으로 줄지만, 그 세션이 여전히 입력을
/// 기다리는 한 아이콘은 호박 그대로다) — 이건 버그가 아니라 각 신호가
/// 답하는 질문 자체가 다르기 때문이다.
///
/// 메뉴 바 아이콘 오른쪽에 붙는 글자. 0이면 빈 문자열이다 — 그게 곧
/// "배지를 지운다"다(`setTitle('')`).
String trayBadgeTitle(int unseenCount) => unseenCount > 0 ? '$unseenCount' : '';

/// stalled가 하나라도 있으면 적갈, 없어도 waiting이 있으면 호박, 둘 다
/// 없으면 기본 보라 아이콘. **stalled > waiting 우선** — 더 심각한 상태가
/// 이긴다(아이콘은 하나뿐이라 두 색을 동시에 띄울 수 없고, 멈춘 세션이
/// 입력 대기보다 더 급한 이상 신호다). **attention 기준** — [trayBadgeTitle]
/// 과 인자가 다른 축(unseen이 아니라 상태별 attention)임에 주의.
String trayBadgeIconAssetPath({required int waiting, required int stalled}) {
  if (stalled > 0) return _kTrayStalledIconAssetPath;
  if (waiting > 0) return _kTrayWaitingIconAssetPath;
  return _kTrayIconAssetPath;
}

/// 툴팁 요약의 i18n 키. **unseen 기준** — [trayBadgeTitle]과 같은 축이다.
/// 문구 자체는 카탈로그(`app-core/src/i18n.rs`)에 있고 `{count}`
/// 자리표시자만 이 파일이 채운다.
String trayBadgeTooltipKey(int unseenCount) =>
    unseenCount > 0 ? 'tray.tooltip_unseen' : 'tray.tooltip_idle';

/// 배지 하나. **(unseen, waiting, stalled) 튜플이 실제로 바뀔 때만** 시임을
/// 부른다 — 폴링은 3~30초마다 같은 세션 맵을 다시 들고 오므로, 값이 같은
/// 갱신까지 네이티브 채널로 흘리면 메뉴 바가 초당 몇 번씩 아이콘을 다시
/// 그린다.
///
/// [tRead]를 쓰므로(콜백에서 만들어지는 문자열의 정본 경로, `i18n/t.dart`)
/// 진짜 [WidgetRef]가 필요하다 — [installTray]가 받은 것을 그대로 물려
/// 받는다(메뉴 라벨을 굽는 것과 같은 자리·같은 이유).
class TrayBadge {
  TrayBadge(this._ref);

  final WidgetRef _ref;

  ({int unseen, int waiting, int stalled})? _applied;

  /// 마지막으로 네이티브에 밀어 넣은 (unseen, waiting, stalled) 튜플(아직
  /// 한 번도 없으면 null).
  @visibleForTesting
  ({int unseen, int waiting, int stalled})? get debugApplied => _applied;

  Future<void> apply({
    required int unseen,
    required int waiting,
    required int stalled,
  }) async {
    final next = (unseen: unseen, waiting: waiting, stalled: stalled);
    if (_applied == next) return;
    _applied = next;
    await _ref.read(trayBadgeApplyFnProvider)(
      title: trayBadgeTitle(unseen),
      iconAssetPath: trayBadgeIconAssetPath(waiting: waiting, stalled: stalled),
      tooltip: tRead(_ref, trayBadgeTooltipKey(unseen), <String, String>{
        'count': '$unseen',
      }),
    );
  }
}

/// 배지가 구독하는 대상 — 세션 상태 provider(`syncControllerProvider`)에서
/// 파생한 (미확인 수, 대기 수, 멈춤 수) 튜플이다. **새 메커니즘을 만들지
/// 않는다**: 화면(`sessions_page.dart`)이 watch하는 것과 같은 provider고,
/// 카운트 계산도 `sync_reducer.dart`의 `SyncState.unseenReportableSessionCount`/
/// `SyncState.waitingInputSessionCount`/`SyncState.stalledSessionCount`가
/// 이미 갖고 있다.
///
/// `select`가 레코드를 뽑으므로 `==` 비교(레코드는 필드별 구조적 동등)가
/// 정확히 "셋 중 하나라도 바뀌었다"와 같다 — 세션 맵이 갱신돼도 세 값이
/// 다 그대로면 리스너가 깨지 않는다([TrayBadge]의 중복 억제는 그 위에
/// 한 겹 더 있는 안전망이다).
///
/// 타입 이름을 적지 않는 이유는 `alert_notify_provider.dart`의
/// `pendingAlertsListenable`과 같다(`ProviderListenable`은
/// `flutter_riverpod` export 목록에 없다).
final trayBadgeCountsListenable = syncControllerProvider.select(
  (SyncControllerState state) => (
    unseen: state.sync.unseenReportableSessionCount,
    waiting: state.sync.waitingInputSessionCount,
    stalled: state.sync.stalledSessionCount,
  ),
);

// ─── TASK MUTE-impl / TRAY-unseen-menu: 트레이 메뉴 갱신 ───────────────

/// 컨텍스트 메뉴 전체를 네이티브에 다시 앉히는 시임 — [trayBadgeApplyFnProvider]
/// 와 같은 3계층(typedef -> `Provider<Fn>` -> 얇은 함수) 패턴이다. 테스트는
/// 이 Provider 하나만 override해 실제 `tray_manager` 플러그인 채널 없이
/// "어떤 항목 조합으로 다시 그렸는가"를 관찰한다.
typedef TrayMenuApplyFn = Future<void> Function(List<MenuItem> items);

Future<void> _trayMenuApplyBridge(List<MenuItem> items) =>
    trayManager.setContextMenu(Menu(items: items));

final Provider<TrayMenuApplyFn> trayMenuApplyFnProvider =
    Provider<TrayMenuApplyFn>((ref) => _trayMenuApplyBridge);

/// macOS 플러그인의 popup Future는 메뉴를 닫으면 완료된다.
typedef TrayMenuPopupFn = Future<void> Function();
final trayMenuPopupFnProvider = Provider<TrayMenuPopupFn>(
  (ref) =>
      () => trayManager.popUpContextMenu(),
);

/// 숨긴 창의 정기 조회를 재개하지 않고 사용량만 한 번 새로 읽는다.
/// 컨트롤러의 pending 요청 병합과 마지막 성공값 보존을 그대로 사용한다.
typedef TrayUsageRefreshFn = Future<void> Function();
final trayUsageRefreshFnProvider = Provider<TrayUsageRefreshFn>(
  (ref) => ref.watch(dashboardExtensionRefreshProvider),
);

/// 메뉴 입력. 사용량 계산과 연결 상태는 홈과 같은 컨트롤러가 소유한다.
typedef TrayMenuInputs = ({
  bool muted,
  int? muteUntil,
  List<SessionViewDto> unseen,
  DashboardTrayLabels labels,
  int serverRevision,
});

final trayMenuInputsListenable = Provider<TrayMenuInputs>((ref) {
  final state = ref.watch(syncControllerProvider);
  return (
    muted: state.sync.isMuted(state.sync.serverTime),
    muteUntil: state.sync.muteUntil,
    unseen: state.sync.unseenReportableSessions,
    labels: ref.watch(dashboardTrayLabelsProvider),
    serverRevision: ref
        .watch(dashboardApiConfigControllerProvider.notifier)
        .serverRevision,
  );
});

/// 표시 내용이 달라질 때만 메뉴를 교체한다. 열린 메뉴는 스냅샷으로 유지한다.
/// tray_manager는 교체할 때 클릭 ID 조회표도 바꾸므로 열린 메뉴를 바꾸면
/// 기존 항목의 클릭을 잃을 수 있다. 다음 우클릭은 항상 최신 상태를 읽는다.
class TrayMenu {
  TrayMenu(this._ref, {this.onSessionSelected});

  final TraySessionSelectFn? onSessionSelected;

  final WidgetRef _ref;

  TrayMenuInputs? _applied;
  List<String> _usageLabels = const [];
  Future<void> _pendingApply = Future.value();
  bool _showing = false;

  /// 테스트 전용 관측 지점 — 마지막으로 네이티브에 밀어 넣은 입력.
  @visibleForTesting
  TrayMenuInputs? get debugAppliedState => _applied;

  Future<void> apply({
    required bool muted,
    required int? muteUntil,
    required int serverRevision,
    List<SessionViewDto> unseen = const <SessionViewDto>[],
    DashboardTrayLabels labels = emptyDashboardTrayLabels,
  }) {
    if (_showing) return Future.value();
    final input = (
      muted: muted,
      muteUntil: muteUntil,
      unseen: unseen,
      labels: labels,
      serverRevision: serverRevision,
    );
    return _pendingApply = _pendingApply.then((_) async {
      if (!_showing) await _apply(input);
    });
  }

  Future<bool> _apply(TrayMenuInputs input, {bool force = false}) async {
    if (!_ref.context.mounted) return false;
    try {
      final labels = input.labels(_ref);
      final previous = _applied;
      if (!force &&
          previous != null &&
          previous.muted == input.muted &&
          previous.muteUntil == input.muteUntil &&
          previous.serverRevision == input.serverRevision &&
          listEquals(previous.unseen, input.unseen) &&
          listEquals(_usageLabels, labels)) {
        return true;
      }
      await _ref.read(trayMenuApplyFnProvider)(
        buildTrayMenuItems(
          _ref,
          muted: input.muted,
          muteUntil: input.muteUntil,
          unseen: input.unseen,
          usageLabels: labels,
          onSessionSelected: onSessionSelected == null
              ? null
              : (session) async {
                  if (_ref
                          .read(dashboardApiConfigControllerProvider.notifier)
                          .serverRevision !=
                      input.serverRevision) {
                    return;
                  }
                  await onSessionSelected!(session);
                },
        ),
      );
      _applied = input;
      _usageLabels = labels;
      return true;
    } catch (error) {
      // 번역/플러그인 실패가 직렬 큐를 거절 상태로 고정하지 않게 한다.
      debugPrint('tray menu: $error');
      return false;
    }
  }

  Future<void> show() async {
    if (_showing) return;
    _showing = true;
    try {
      await _pendingApply;
      if (!_ref.context.mounted) return;
      final applied = await _apply(
        _ref.read(trayMenuInputsListenable),
        force: true,
      );
      if (!applied || !_ref.context.mounted) return;
      // 네트워크 응답을 기다리지 않고 캐시가 든 메뉴를 바로 연다.
      unawaited(_refreshUsage());
      await _ref.read(trayMenuPopupFnProvider)();
    } on Exception catch (error) {
      debugPrint('tray popup: $error');
    } finally {
      _showing = false;
    }
  }

  Future<void> _refreshUsage() async {
    try {
      await _ref.read(trayUsageRefreshFnProvider)();
    } on Exception catch (error) {
      debugPrint('tray usage refresh: $error');
    }
  }
}

bool _installed = false;

/// 테스트 전용 관측 지점 — [installTray]가 가드(idempotent 체크 +
/// [traySupportedProvider])를 지나 실제로 [_DashboardTrayController.install]
/// (그리고 그 안의 [trayManager] 플러그인 채널 호출)까지 갔는지 본다.
/// 웹/비macOS에서 no-op이었다면 이 값은 절대 true가 되지 않는다 — 단위
/// 테스트가 실제 플러그인 채널을 타지 않고도 "가드에서 멈췄다"를 확인하는
/// 유일한 방법이다(`local_notifications_native_test.dart`가 순수 판정
/// 함수만 테스트하고 부작용이 있는 오케스트레이터 자체는 부르지 않는 것과
/// 같은 이유 — 다만 이 값은 부작용을 실행하지 않고도 "실행하려 했는가"만
/// 드러낸다).
@visibleForTesting
bool debugTrayInstallAttempted = false;

/// TASK A-impl (2): 배지 구독 하나. [installTray]가 idempotent인 것과 같은
/// 이유로 top-level에 둔다 — 트레이 아이콘이 하나뿐이라 그 배지도 하나뿐이다.
ProviderSubscription<({int unseen, int waiting, int stalled})>?
_badgeSubscription;

/// TASK MUTE-impl + TRAY-unseen-menu: 메뉴 구독 하나. [_badgeSubscription]
/// 과 같은 이유로 top-level이다.
ProviderSubscription<TrayMenuInputs>? _menuSubscription;

/// 테스트 간 위 전역 상태를 되돌린다. `installTray`가 idempotent이기 위해
/// top-level 변수를 쓰는 대가다 — 테스트 파일의 `setUp`에서 부른다.
@visibleForTesting
void debugResetTrayInstallStateForTest() {
  _installed = false;
  debugTrayInstallAttempted = false;
  _badgeSubscription?.close();
  _badgeSubscription = null;
  _menuSubscription?.close();
  _menuSubscription = null;
}

/// 부팅 이후(위젯 트리가 뜬 다음) 한 번 부른다(`app.dart`의
/// `_AppHomeState.initState`, `residentModeApplyProvider`를 미는 것과 같은
/// 자리 — 이유도 같다: `runApp` 이전에는 네이티브 쪽 엔진/플러그인 등록이
/// 아직 안 끝났을 수 있다). 여러 번 불러도 안전하다(idempotent) — 이미
/// 설치했으면 조용히 반환한다.
Future<void> installTray(
  WidgetRef ref, {
  TraySessionSelectFn? onSessionSelected,
}) async {
  if (_installed) return;
  if (!ref.read(traySupportedProvider)) return;
  try {
    debugTrayInstallAttempted = true;
    final menu = TrayMenu(ref, onSessionSelected: onSessionSelected);
    final controller = _DashboardTrayController(ref, menu);
    await controller.install();
    _installed = true;
    // TASK A-impl (2): 아이콘이 실제로 선 다음에만 배지를 구독한다 —
    // `setToolTip`/`setTitle`은 아이콘이 없으면 얹을 자리가 없다
    // (`tray_manager` 문서). `ref.listen`이 아니라 `listenManual`인 이유는
    // `alert_notify_provider.dart`와 같다(이 호출은 `build` 밖이다). 이
    // 구독은 [installTray]를 부른 위젯이 dispose될 때 자동으로 닫힌다 —
    // 그 위젯은 `app.dart`의 `_AppHome`이라 앱이 사는 동안 살아 있다.
    _badgeSubscription?.close();
    final badge = TrayBadge(ref);
    _badgeSubscription = ref
        .listenManual<({int unseen, int waiting, int stalled})>(
          trayBadgeCountsListenable,
          (
            ({int unseen, int waiting, int stalled})? previous,
            ({int unseen, int waiting, int stalled}) next,
          ) => unawaited(
            badge.apply(
              unseen: next.unseen,
              waiting: next.waiting,
              stalled: next.stalled,
            ),
          ),
          // 부팅 시점의 카운트(대개 0, 재시작 직후 이미 대기/미확인 세션이
          // 있으면 그 수)를 곧바로 한 번 밀어 넣는다.
          fireImmediately: true,
        );
    // 뮤트 상태, 미확인 세션 목록, 사용량도 배지와 같은 자리에서 구독한다.
    // `install()`이 이미
    // 기본 메뉴를 한 번 앉혀 뒀으므로, 부팅 시점에 이미 음소거 중이었거나
    // 미확인 세션이 있었다면(예: 앱을 껐다 켠 경우) 이 구독의
    // `fireImmediately`가 곧바로 "해제" 항목/"안읽은 세션" 항목들로
    // 갈아 끼운다.
    _menuSubscription?.close();
    _menuSubscription = ref.listenManual<TrayMenuInputs>(
      trayMenuInputsListenable,
      (TrayMenuInputs? previous, TrayMenuInputs next) => unawaited(
        menu.apply(
          muted: next.muted,
          muteUntil: next.muteUntil,
          serverRevision: next.serverRevision,
          unseen: next.unseen,
          labels: next.labels,
        ),
      ),
      fireImmediately: true,
    );
  } on Exception catch (error) {
    debugPrint('installTray: 트레이 아이콘을 설치하지 못했다 ($error).');
  }
}

/// [TrayListener] 구현 + 명령 배선. `UpegTray`(레퍼런스 `tray.dart`)와 같은
/// 자리 — 다만 그 클래스는 전용 `Ref`를 들고 있는 반면 여기서는 이미
/// [installTray]가 받은 [WidgetRef]를 그대로 들고 있다가 클릭 콜백에서
/// [ref.read]로 세 Provider(`trayOpenProvider`/`trayMuteProvider`/
/// `trayQuitProvider`)를 읊는다.
class _DashboardTrayController with TrayListener {
  _DashboardTrayController(this._ref, this._menu);

  final WidgetRef _ref;
  final TrayMenu _menu;

  Future<void> install() async {
    trayManager.addListener(this);
    // `isTemplate: false` — [_trayBadgeApplyBridge]와 같은 이유(컬러
    // 아이콘을 macOS가 단색으로 재색칠하지 않게 한다).
    await trayManager.setIcon(_kTrayIconAssetPath, isTemplate: false);
    await trayManager.setContextMenu(Menu(items: buildTrayMenuItems(_ref)));
  }

  /// 좌클릭 = 창 소환(완료 기준 (3): "왼클릭=창 소환").
  @override
  void onTrayIconMouseDown() {
    unawaited(_dispatch(TrayCommand.open));
  }

  /// 우클릭 = 컨텍스트 메뉴를 띄운다(항목 클릭은 [onTrayMenuItemClick]).
  @override
  void onTrayIconRightMouseDown() {
    unawaited(_menu.show());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final command = TrayCommand.fromKey(menuItem.key);
    if (command != null) {
      unawaited(_dispatch(command));
      return;
    }
    // 동적 항목은 표시 시점 값을 보관한 MenuItem.onClick에서 실행한다.
  }

  Future<void> _dispatch(TrayCommand command) async {
    switch (command) {
      case TrayCommand.open:
        await _ref.read(trayOpenProvider)();
      case TrayCommand.mute30:
        await _muteAndNotify(
          fn: _ref.read(trayMuteProvider),
          successKey: 'setup.mute_success',
          errorKey: 'setup.mute_error',
        );
      case TrayCommand.unmute:
        await _muteAndNotify(
          fn: _ref.read(trayUnmuteProvider),
          successKey: 'setup.unmute_success',
          errorKey: 'setup.unmute_error',
        );
      case TrayCommand.quit:
        _ref.read(trayQuitProvider)();
    }
  }

  /// TASK MUTE-impl 완료 기준 (c): 뮤트/해제 둘 다 결과를 시스템 알림
  /// 하나로 돌려준다 — 트레이 메뉴는 클릭한 뒤에도 화면이 뜨지 않으므로
  /// (좌클릭으로 따로 열지 않는 한) 이게 유일한 피드백 경로다. 성공/실패
  /// 문구는 설정 화면의 상태 문구(`setup.mute_success` 등)를 그대로
  /// 재사용한다 — "음소거했습니다"는 트레이에서 눌렀든 설정 화면에서
  /// 눌렀든 같은 사실이라 문구를 갈라 둘 이유가 없다. 성공했을 때는
  /// [syncControllerProvider]도 즉시 한 번 당겨(`triggerNow(force: true)`)
  /// 폴링 주기를 기다리지 않고 메뉴·배너가 새 상태를 반영하게 한다.
  Future<void> _muteAndNotify({
    required Future<bool> Function() fn,
    required String successKey,
    required String errorKey,
  }) async {
    final ok = await fn();
    if (ok) {
      _ref.read(syncControllerProvider.notifier).triggerNow(force: true);
    }
    await showNotification(
      title: tRead(_ref, 'app.title'),
      body: tRead(_ref, ok ? successKey : errorKey),
    );
  }
}
