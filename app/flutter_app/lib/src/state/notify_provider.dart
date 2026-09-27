/// 실제 알림 발신 시임.
///
/// 규칙은 세 가지, 전부 이 파일 하나에 접혀 있다(화면·호출자는 이 규칙을
/// 몰라도 된다 — [notifyProvider] 하나만 부른다):
///
/// 1. **웹은 항상 no-op.** 알림은 push 서비스워커로만 흐른다
///    (완료 기준 (d)). [isWasmRuntimeProvider]가 true면 [localNotifyFnProvider]
///    쪽 실제 브리지가 이미 no-op(`notify_bridge_web.dart`)이지만, 이 파일이
///    한 번 더 확인한다 — 웹 no-op이 "그 파일 하나"가 아니라 "이 규칙"에
///    있다는 걸 테스트가 override 하나로 증명할 수 있게 한다.
/// 2. **APNs가 등록됐으면 로컬 알림은 끈다** (TASK D-app, A안 설계 ②).
///    [apnsRegisteredProvider]가 true라는 것은 이 기기가 서버에
///    `transport:'fcm-apns'`로 등록됐다는 뜻이고, 그 순간부터 배너는 전부
///    서버 -> FCM -> APNs 경로로 온다(앱이 꺼져 있어도 뜬다). 여기서 로컬
///    알림까지 띄우면 같은 전이로 배너가 **둘** 뜬다. 등록에 실패하면
///    (권한 거부, `aps-environment` entitlement 미활성 — 설계 ⑤) 이 값이
///    false로 남고 아래 3의 기존 경로가 그대로 살아 있다 = 폴백.
/// 3. **알림 전이 하나당 [notifyProvider] 호출 정확히 한 번.** 이 파일은
///    "몇 번 부를지"를 스스로 정하지 않는다 — [notifyForAlerts]가 호출자가
///    넘긴 전이 목록(`SyncState.pendingAlerts`) 길이만큼만 부른다.
///
/// macOS 네이티브에서 이 앱은 여전히 배너의 **단일 소유자**다 — 별도 상주
/// 데몬과의 중재는 없다. 달라진 것은 그 소유권 안에서 두 갈래가 생겼다는
/// 것뿐이다: APNs가 등록됐으면 OS(APNs)가, 아니면 이 파일이 띄운다. 어느
/// 쪽이든 창을 닫아도 앱 프로세스는 살아 있고(상주 토글이 켜져 있는 한 —
/// `AppDelegate.swift`와 `state/resident_provider.dart` 참고), Dock 아이콘
/// 클릭으로 창을 되살린다.
///
/// `capability_provider.dart`와 같은 3계층: 함수 타입 -> `Provider<Fn>` ->
/// 얇은 함수. 여기서는 그 얇은 함수([_notifyBridge])가 런타임 신호
/// (isWasm)까지 접어 반환한다 — `_capabilityBridge`가
/// windowReady/hotkeyReady를 접는 것과 같은 자리다.
library;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart' show dashboardApiConfigProvider;
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/i18n/t.dart' show i18nTranslateOverride, localeProvider;
import 'package:my_dashboard/src/state/capability_provider.dart' show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show sessionStateDtoFromCode, stateLabelKeyFnProvider;
import 'package:my_dashboard/src/state/push_provider.dart' show apnsRegisteredProvider;
import 'package:my_dashboard/src/state/notify_bridge_io.dart'
    if (dart.library.js_interop) 'package:my_dashboard/src/state/notify_bridge_web.dart'
    as bridge;
import 'package:my_dashboard/src/util/project_path.dart' show projectBasename;

// ─── 값 ──────────────────────────────────────────────────────────────────

/// 알림 하나를 실제로 띄우는 데 필요한 최소 정보.
@immutable
class NotifyPayload {
  const NotifyPayload({
    required this.id,
    required this.title,
    required this.body,
    this.sessionKey,
    this.project,
    this.host,
  });

  /// OS 알림 id로 그대로 쓰는 [TransitionDto.id]. 서버가 단조 증가시키고
  /// 재사용하지 않는 AUTOINCREMENT라 앱 재시작과 무관하다 — 프로세스 메모리
  /// 카운터(`_nextNotificationId`, 이제 제거됨)가 재시작마다 리셋되면서
  /// macOS 알림 센터에 남은 이전 배너의 id와 충돌해 제자리 갱신(무음)으로
  /// 처리되던 회귀를 막는다(`local_notifications_native.dart`
  /// `showNotification`의 `id` 인자로 그대로 흘러간다).
  final int id;

  final String title;
  final String body;

  /// 알림을 탭했을 때 열 세션(`<source>:<session_id>`). 알 수 없으면 null.
  final String? sessionKey;

  /// 알림 발신 시점의 프로젝트·호스트. 세션이 이후 바뀌거나 사라져도
  /// 클릭한 알림이 원래 가리키던 작업 창을 찾는다.
  final String? project;
  final String? host;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NotifyPayload &&
          other.id == id &&
          other.title == title &&
          other.body == body &&
          other.sessionKey == sessionKey &&
          other.project == project &&
          other.host == host;

  @override
  int get hashCode => Object.hash(id, title, body, sessionKey, project, host);

  @override
  String toString() => 'NotifyPayload($id, $title, sessionKey: $sessionKey)';
}

/// 전이 상태 코드(`TransitionDto.toState`, 정본 `states.enum`)를 지금 UI
/// 언어의 상태 라벨로 옮기는 함수 모양.
///
/// [payloadForAlert]가 **순수 함수로 남기 위한** 주입 지점이다. 제목·본문에
/// 사람이 읽는 상태 라벨이 필요하지만, i18n 조회는 활성
/// 로케일(`localeProvider`)에 의존하는 부작용 있는 읽기다 — 그걸 함수 안에서
/// 직접 하면 이 파일의 표시 문구 규칙을 `ProviderContainer` 없이 값만으로
/// 확인할 수 없게 된다. 그래서 이 파일의 다른 시임들과 **같은 3계층**
/// (`함수 타입 -> Provider<Fn> -> 얇은 함수`, 파일 상단 문서 참고)으로
/// 뽑았다: 여기 typedef, 아래 [alertStateLabelProvider], 그리고 실제 조회를
/// 담은 얇은 클로저.
typedef StateLabelResolver = String Function(String stateCode);

/// 카드의 상태 칩(`ui/widgets/state_chip.dart`)이 라벨을 얻는 것과 **같은
/// 두 단계**를 위젯 밖에서도 쓸 수 있게 연 시임:
///
///   상태 코드 -> [SessionStateDto]([sessionStateDtoFromCode])
///            -> i18n 키([stateLabelKeyFnProvider])
///            -> 활성 로케일의 문구([localeProvider] + [i18nTranslateOverride])
///
/// 새 i18n 키를 만들지 않는다 — 알림 제목의 상태 라벨은 화면의 상태 칩과
/// 글자 하나까지 같아야 한다("done" 배너를 받고 목록을 열었을 때 같은 단어를
/// 봐야 한다). `state.*` 6개 키가 이미 그 정본이다.
///
/// 세 소스를 전부 `watch`하므로 사용자가 UI 언어를 바꾸면 이 시임이 새로
/// 만들어진다 — [notifyProvider]가 [apnsRegisteredProvider]를 watch해 소유권
/// 전환을 즉시 반영하는 것과 같은 이유·같은 모양이다. 호출부
/// (`alert_notify_provider.dart`)는 그래서 이 Provider를 캡처해 두지 않고
/// 발신할 때마다 다시 읽는다.
///
/// 테스트는 이 Provider 하나만 override하면 i18n·FRB를 전혀 거치지 않는다.
final Provider<StateLabelResolver> alertStateLabelProvider = Provider<StateLabelResolver>((ref) {
  final labelKeyFor = ref.watch(stateLabelKeyFnProvider);
  final locale = ref.watch(localeProvider);
  final translate = ref.watch(i18nTranslateOverride);
  return (String stateCode) => translate(labelKeyFor(sessionStateDtoFromCode(stateCode)), locale);
});

/// 이 전이가 알림을 받을 자격이 있는지는 이미 `TransitionDto.isAlert`가
/// 정본(push_states)으로 판정했다 — 여기서는 표시 문구만 만든다.
///
/// **제목은 프로젝트 이름으로 시작한다**. 예전에는
/// `TransitionDto.sessionKey` 원문(`claude-code:0a1b2c…`)이 제목이었는데,
/// 그 문자열은 알림 센터에서 앞쪽이 먼저 잘리는 자리에 있으면서도 사람에게
/// 아무 뜻이 없다 — 어느 프로젝트에서 온 배너인지 알 수 없었다. 이제
/// 카드 제목과 같은 규칙([projectBasename] — 경로의 마지막 조각만)을 쓰고,
/// 그 뒤에 상태 라벨을 붙인다:
///
///   `{프로젝트 basename} · {상태 라벨}`
///
/// [TransitionDto.project]가 null이거나 빈 값일 때만 `sessionKey`로 접는다 —
/// 그때는 basename을 뽑을 대상 자체가 없다(`session_card.dart`의 카드 제목이
/// `sessionId`로 접는 것과 같은 폴백 자리).
///
/// **본문은 message가 있으면 message, 없으면 상태 라벨**이다(예전에는
/// 상태 **코드** 원문 `waiting_input`이 그대로 나갔다 — 사용자에게 보이는
/// 자리에 프로토콜 어휘를 노출하던 결함). [TransitionDto.host]가 있으면
/// 본문 앞에 `{host} · `를 붙여 "어느 기계의 세션인가"를 알린다 — 제목은
/// 프로젝트에 내주고, 기계 식별은 본문이 맡는다. 같은 프로젝트를 여러
/// 기계에서 실행해도 출처를 구분할 수 있다.
///
/// 서버 push 경로(`dashboard-server`의 `buildPushPayload`)도 같은 순서를 쓴다 —
/// 정본은 계약의 `i18n.ko.push.title`(`{project} · {host} · {label}`)이다.
/// 두 경로의 제목이 갈라지면 같은 전이가 기기마다 다른 제목으로 보인다.
NotifyPayload payloadForAlert(TransitionDto alert, {required StateLabelResolver stateLabel}) {
  final label = stateLabel(alert.toState);
  final project = alert.project;
  final projectText = (project != null && project.isNotEmpty)
      ? projectBasename(project)
      : alert.sessionKey;

  final message = alert.message;
  final bodyText = (message != null && message.isNotEmpty) ? message : label;
  // host는 `null`뿐 아니라 빈 문자열도 "없음"으로 본다 — 서버의 같은 조립
  // 지점(`dispatch.ts`의 `transition.host ? … : …`)이 빈 문자열을 falsy로
  // 떨어뜨리는 것과 같은 판정이라, 두 경로가 ` · `만 남은 접두를 만들지
  // 않는다.
  final host = alert.host;
  final hasHost = host != null && host.isNotEmpty;

  return NotifyPayload(
    id: alert.id,
    title: '$projectText · $label',
    body: hasHost ? '$host · $bodyText' : bodyText,
    sessionKey: alert.sessionKey,
    project: alert.project,
    host: alert.host,
  );
}

// ─── 1계층: OS 발신 시임 ────────────────────────────────────────────────

/// 실제로 알림 하나를 띄운다(macOS: `osascript`, 웹: no-op).
typedef LocalNotifyFn = Future<void> Function(NotifyPayload payload);

final Provider<LocalNotifyFn> localNotifyFnProvider = Provider<LocalNotifyFn>((ref) {
  return (payload) => bridge.showLocalNotification(
    payload,
    serverUrl: ref.read(dashboardApiConfigProvider).baseUrl.toString(),
  );
});

// ─── 2/3계층: 런타임 분기를 접은 발신 시임 ──────────────────────────────

/// 알림 하나를 내보낸다. 웹이면 조용히 완료된다 — 예외를 던지지 않는다.
typedef NotifyDispatchFn = Future<void> Function(NotifyPayload payload);

Future<void> _notifyBridge(
  NotifyPayload payload, {
  required LocalNotifyFn localNotify,
  required bool isWasm,
  required bool apnsOwnsBanners,
}) async {
  if (isWasm) return; // 규칙 1(완료 기준 (d)): 웹은 항상 no-op.
  if (apnsOwnsBanners) return; // 규칙 2(A안 설계 ②): 배너의 주인은 APNs다.
  await localNotify(payload);
}

/// 테스트는 이 Provider만 override한다 — [isWasmRuntimeProvider]/
/// [apnsRegisteredProvider]/[localNotifyFnProvider]를 각각 조합해 런타임·
/// 소유권 분기를 전부 override 없이도 실제로 태울 수 있고, 최종 호출
/// 자체를 가짜로 바꾸고 싶으면 이 Provider를 직접 override한다.
///
/// [apnsRegisteredProvider]를 `watch`하므로 등록이 성공/실패로 바뀌는
/// 순간 이 시임이 새로 만들어진다 — 소유권 전환이 다음 알림부터 즉시
/// 반영된다(설정 저장 후 재등록이 그 경로다).
final Provider<NotifyDispatchFn> notifyProvider = Provider<NotifyDispatchFn>((ref) {
  final localNotify = ref.watch(localNotifyFnProvider);
  final isWasm = ref.watch(isWasmRuntimeProvider);
  final apnsOwnsBanners = ref.watch(apnsRegisteredProvider);
  return (payload) => _notifyBridge(
    payload,
    localNotify: localNotify,
    isWasm: isWasm,
    apnsOwnsBanners: apnsOwnsBanners,
  );
});

/// TASK P-impl (4): 설정/진단 화면에 "지금 배너가 어느 경로로 오는가"를 한
/// 줄로 보여줄 i18n 키. [apnsRegisteredProvider]가 이미 그 정본이다(규칙
/// 2) — 이 Provider는 그 bool을 화면이 바로 [t]에 넘길 수 있는 문자열 키로
/// 뒤집을 뿐이다. `setup.notification_osascript_fallback_note`와 같은
/// 자리·수위로 쓰인다(`setup_page.dart`).
final Provider<String> notificationPathLabelKeyProvider = Provider<String>((ref) {
  final apnsOwnsBanners = ref.watch(apnsRegisteredProvider);
  return apnsOwnsBanners ? 'setup.notification_path_apns' : 'setup.notification_path_polling';
});

// ─── 오케스트레이션 ─────────────────────────────────────────────────────

/// [alerts](보통 `SyncState.pendingAlerts`) 각각에 대해 [dispatch]를 정확히
/// 한 번씩 부른다. 소유권·런타임 판정은 이미 [dispatch] 안에 접혀 있으므로
/// 이 함수는 순수하게 "몇 번, 어떤 순서로"만 책임진다(완료 기준 (b)).
///
/// [stateLabel]은 그대로 [payloadForAlert]에 넘겨 준다 — 이 함수도 i18n을
/// 스스로 조회하지 않아, 호출부가 시임 하나만 갈아끼우면 전체 경로가
/// 결정적이 된다(보통은 [alertStateLabelProvider]를 그대로 넘긴다).
Future<void> notifyForAlerts(
  List<TransitionDto> alerts, {
  required NotifyDispatchFn dispatch,
  required StateLabelResolver stateLabel,
}) async {
  for (final alert in alerts) {
    await dispatch(payloadForAlert(alert, stateLabel: stateLabel));
  }
}
