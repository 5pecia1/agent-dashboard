/// TASK A-impl 완료 기준 (4)(a)(b): "전이 -> 알림" 리스너를 실제 OS 알림·
/// 실제 서버·실제 타이머 없이 닫는다.
///
/// 가짜 sync 스트림은 `SyncController`를 갈아끼워 만든다 — 컨트롤러가
/// 폴링·백오프·wake 구독을 전혀 하지 않는 대신 테스트가 `emit()`으로 sync
/// 결과를 원하는 순서대로 밀어 넣는다. 그 결과 자체는 **진짜 리듀서**
/// (`reduceSync`)가 만든다: 알림 대상 판정(`push_states`)·중복
/// `transition_id` 제거가 테스트 안에 복사되지 않고 정본 그대로 돈다.
///
/// 구독하는 대상([pendingAlertsListenable])도 프로덕션 부팅 경로
/// (`app.dart` -> `installAlertNotifier`)와 같은 것을 쓴다 — 그 배선 자체가
/// 앱 트리에 붙어 있는지는 `widget_tests/app_wiring_test.dart`(완료 기준
/// (4)(d))가 따로 본다.
library;

import 'dart:async' show unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart'
    show DashboardApiConfig;
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/platform/apns_push.dart'
    show kPushTransportFcmApns;
import 'package:my_dashboard/src/state/alert_notify_provider.dart';
import 'package:my_dashboard/src/state/capability_provider.dart'
    show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/config_provider.dart'
    show
        dashboardApiConfigControllerProvider,
        dashboardInitialApiConfigProvider;
import 'package:my_dashboard/src/state/notify_provider.dart'
    show NotifyPayload, alertStateLabelProvider, localNotifyFnProvider;
import 'package:my_dashboard/src/state/push_provider.dart'
    show
        ApnsOwnership,
        PushAvailability,
        PushRegistrationResult,
        apnsRegisteredProvider;
import 'package:my_dashboard/src/state/sync_controller.dart';

/// `notify_provider_test.dart`와 같은 가짜 소유권 — 실제 등록 경로(서버·
/// Firebase)를 태우지 않고 "배너의 주인이 누구인가"만 고정한다.
class _FixedOwnership extends ApnsOwnership {
  _FixedOwnership(this._owned);

  final bool _owned;

  @override
  bool build() => _owned;
}

/// 폴링·백오프·생명주기·wake 구독이 전혀 없는 컨트롤러. `build()`를 통째로
/// 갈아끼우므로 실제 `Timer`도, `dashboardApiProvider`(override 없이는
/// 던지는 시임)도 필요 없다 — 테스트가 [emit]으로 "sync 한 사이클이
/// 끝났다"만 흉내낸다.
///
/// `cursor: 0`으로 시작한다: `SyncState.isFirstBoot`를 false로 만들어
/// 리듀서의 첫 기동 10분 창(그건 `sync_reducer_test.dart`가 이미 닫는다)이
/// 이 테스트의 전이를 잘라내지 않게 한다.
class _FakeSyncController extends SyncController {
  static _FakeSyncController? last;

  @override
  SyncControllerState build() {
    last = this;
    return const SyncControllerState(sync: SyncState(cursor: 0));
  }

  /// 서버 응답 한 통을 **진짜 리듀서**로 접어 상태로 밀어 넣는다.
  void emitResponse(SyncResponseDto response, {required int nowMs}) {
    state = state.copyWith(
      sync: reduceSync(state.sync, response, nowMs: nowMs),
    );
  }
}

const int _kNowMs = 1_700_000_000_000;

TransitionDto _alert({
  required int id,
  required String sessionKey,
  String? message,
}) => TransitionDto(
  id: id,
  sessionKey: sessionKey,
  toState: 'waiting_input',
  source: sessionKey.split(':').first,
  message: message,
  occurredAt: _kNowMs,
  createdAt: _kNowMs,
);

SyncResponseDto _delta(List<TransitionDto> transitions) => SyncResponseDto(
  cursor: transitions.isEmpty ? 0 : transitions.last.id,
  serverTime: _kNowMs,
  transitions: transitions,
);

/// 리스너 -> `dispatchNew` -> `notifyForAlerts`는 전부 `async`다. 이벤트
/// 루프를 한 바퀴 돌려 그 체인이 끝나게 한다(실제 지연은 없다).
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late List<NotifyPayload> sent;

  /// 프로덕션 부팅 경로가 하는 것과 같은 구독을 컨테이너에 붙인다.
  /// `installAlertNotifier`는 `WidgetRef`(위젯 트리)를 요구하므로 여기서는
  /// 같은 listenable + 같은 [AlertNotifier]를 컨테이너 수준으로 잇는다.
  ({ProviderContainer container, _FakeSyncController controller}) boot({
    bool apnsRegistered = false,
    bool isWasm = false,
    DashboardApiConfig? initial,
  }) {
    sent = <NotifyPayload>[];
    _FakeSyncController.last = null;
    final container = ProviderContainer(
      overrides: [
        syncControllerProvider.overrideWith(_FakeSyncController.new),
        dashboardInitialApiConfigProvider.overrideWithValue(initial),
        isWasmRuntimeProvider.overrideWithValue(isWasm),
        apnsRegisteredProvider.overrideWith(
          () => _FixedOwnership(apnsRegistered),
        ),
        localNotifyFnProvider.overrideWithValue((NotifyPayload payload) async {
          sent.add(payload);
        }),
        // 알림 제목·본문에 들어가는 상태 라벨 시임. 기본 구현은 활성
        // 로케일(`platformLocaleProvider` -> `WidgetsBinding.instance`)과
        // FRB i18n 카탈로그까지 내려간다 — 이 파일은 `ProviderContainer`만
        // 쓰는 순수 `test`라 둘 다 없는 환경이다. 시임 하나를 고정값으로
        // 갈아끼워 이 테스트가 보려는 것(발신 **횟수**와 워터마크)만 남긴다.
        // 문구 조립 자체는 `notify_provider_test.dart`가 닫는다.
        alertStateLabelProvider.overrideWithValue(
          (String stateCode) => stateCode,
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(alertNotifierProvider);
    container.listen<List<TransitionDto>>(
      pendingAlertsListenable,
      (List<TransitionDto>? previous, List<TransitionDto> next) =>
          unawaited(notifier.dispatchNew(next)),
      fireImmediately: true,
    );
    return (container: container, controller: _FakeSyncController.last!);
  }

  group('unnotifiedAlerts (워터마크 순수 판정)', () {
    test('워터마크 이하의 전이는 이미 알린 것이다', () {
      final alerts = <TransitionDto>[
        _alert(id: 1, sessionKey: 'claude_code:s1'),
        _alert(id: 2, sessionKey: 'codex:s2'),
        _alert(id: 3, sessionKey: 'claude_code:s3'),
      ];

      expect(unnotifiedAlerts(alerts, watermark: 0).map((t) => t.id), <int>[
        1,
        2,
        3,
      ]);
      expect(unnotifiedAlerts(alerts, watermark: 2).map((t) => t.id), <int>[3]);
      expect(unnotifiedAlerts(alerts, watermark: 3), isEmpty);
      expect(unnotifiedAlerts(const <TransitionDto>[], watermark: 0), isEmpty);
    });
  });

  group('완료 기준 (4)(a): alert 전이 2건 -> notify 정확히 2회', () {
    test('한 사이클에 알림 전이 2건이 오면 전이당 1회씩, 총 2회 발신한다', () async {
      final booted = boot();

      booted.controller.emitResponse(
        _delta(<TransitionDto>[
          _alert(id: 1, sessionKey: 'claude_code:s1', message: '입력을 기다립니다'),
          _alert(id: 2, sessionKey: 'codex:s2', message: '리뷰를 기다립니다'),
        ]),
        nowMs: _kNowMs,
      );
      await _settle();

      expect(sent.length, 2);
      expect(sent.map((NotifyPayload p) => p.sessionKey), <String>[
        'claude_code:s1',
        'codex:s2',
      ]);
      expect(sent.map((NotifyPayload p) => p.body), <String>[
        '입력을 기다립니다',
        '리뷰를 기다립니다',
      ]);
      // 딥링크(T16 경로)가 탈 세션 키가 페이로드에 실려 있다.
      expect(sent.every((NotifyPayload p) => p.sessionKey != null), isTrue);
    });

    test('알림 대상이 아닌 전이(working/idle)는 발신하지 않는다', () async {
      final booted = boot();

      booted.controller.emitResponse(
        _delta(<TransitionDto>[
          TransitionDto(
            id: 1,
            sessionKey: 'claude_code:s1',
            toState: 'working',
            occurredAt: _kNowMs,
            createdAt: _kNowMs,
          ),
        ]),
        nowMs: _kNowMs,
      );
      await _settle();

      expect(sent, isEmpty, reason: '정본 push_states에 없는 상태다');
    });
  });

  group('완료 기준 (4)(a): 중복 재전송 0회', () {
    test('서버 A의 큰 전이 뒤 서버 B의 작은 전이도 발신하고 B 안에서는 중복하지 않는다', () async {
      final booted = boot(
        initial: DashboardApiConfig(
          baseUrl: Uri.parse('https://a.example.test'),
        ),
      );
      booted.controller.emitResponse(
        _delta(<TransitionDto>[_alert(id: 901, sessionKey: 'codex:a')]),
        nowMs: _kNowMs,
      );
      await _settle();
      expect(sent.map((payload) => payload.id), <int>[901]);
      expect(sent.single.serverUrl, 'https://a.example.test');

      final connection = booted.container.read(
        dashboardApiConfigControllerProvider.notifier,
      );
      connection.apply(serverUrl: 'https://b.example.test');
      booted.controller.state = booted.controller.state.copyWith(
        sync: const SyncState(cursor: 0),
      );
      booted.controller.emitResponse(
        _delta(<TransitionDto>[_alert(id: 6, sessionKey: 'codex:b')]),
        nowMs: _kNowMs,
      );
      await _settle();
      expect(sent.map((payload) => payload.id), <int>[901, 6]);
      expect(sent.last.serverUrl, 'https://b.example.test');

      booted.controller.emitResponse(
        _delta(<TransitionDto>[_alert(id: 6, sessionKey: 'codex:b')]),
        nowMs: _kNowMs,
      );
      await _settle();
      expect(sent.map((payload) => payload.id), <int>[901, 6]);

      booted.controller.emitResponse(
        _delta(<TransitionDto>[_alert(id: 7, sessionKey: 'codex:b2')]),
        nowMs: _kNowMs,
      );
      await _settle();
      expect(sent.map((payload) => payload.id), <int>[901, 6, 7]);
      expect(booted.container.read(alertNotifierProvider).debugWatermark, 7);
    });

    test('같은 서버의 토큰만 바꾸면 알림 워터마크를 유지한다', () async {
      final booted = boot(
        initial: DashboardApiConfig(
          baseUrl: Uri.parse('https://a.example.test'),
        ),
      );
      booted.controller.emitResponse(
        _delta(<TransitionDto>[_alert(id: 901, sessionKey: 'codex:a')]),
        nowMs: _kNowMs,
      );
      await _settle();

      booted.container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: 'https://a.example.test', clientToken: 'rotated');
      booted.controller.emitResponse(
        _delta(<TransitionDto>[_alert(id: 6, sessionKey: 'codex:old')]),
        nowMs: _kNowMs,
      );
      await _settle();
      expect(sent.map((payload) => payload.id), <int>[901]);
    });

    test('같은 큐가 폴링마다 다시 도착해도 다시 발신하지 않는다', () async {
      final booted = boot();
      final first = <TransitionDto>[
        _alert(id: 1, sessionKey: 'claude_code:s1'),
        _alert(id: 2, sessionKey: 'codex:s2'),
      ];

      booted.controller.emitResponse(_delta(first), nowMs: _kNowMs);
      await _settle();
      expect(sent.length, 2);

      // `pendingAlerts`는 사용자가 확인할 때까지 남는 누적 큐다 — 다음
      // 사이클(전이 없는 빈 델타)에서도 같은 두 건이 그대로 다시 온다.
      booted.controller.emitResponse(
        SyncResponseDto(cursor: 2, serverTime: _kNowMs + 1000),
        nowMs: _kNowMs + 1000,
      );
      await _settle();
      expect(sent.length, 2, reason: '이미 알린 전이는 다시 나가지 않는다');

      // 서버가 같은 전이를 다시 배달해도(중복 transition_id) 리듀서가 먼저
      // 걸러내고, 설령 통과했더라도 워터마크가 막는다.
      booted.controller.emitResponse(_delta(first), nowMs: _kNowMs + 2000);
      await _settle();
      expect(sent.length, 2);

      // 새 전이 하나는 그 뒤에도 정확히 한 번 나간다.
      booted.controller.emitResponse(
        _delta(<TransitionDto>[_alert(id: 3, sessionKey: 'claude_code:s3')]),
        nowMs: _kNowMs + 3000,
      );
      await _settle();
      expect(sent.length, 3);
      expect(sent.last.sessionKey, 'claude_code:s3');

      expect(booted.container.read(alertNotifierProvider).debugWatermark, 3);
    });

    test('화면이 큐를 확인 처리해 비워도 다시 발신하지 않는다', () async {
      final booted = boot();
      booted.controller.emitResponse(
        _delta(<TransitionDto>[_alert(id: 1, sessionKey: 'claude_code:s1')]),
        nowMs: _kNowMs,
      );
      await _settle();
      expect(sent.length, 1);

      // 큐가 비고(확인 처리) 나서 같은 전이가 다시 배달되는 경로.
      booted.controller.state = booted.controller.state.copyWith(
        sync: acknowledgeAllAlerts(booted.controller.state.sync),
      );
      await _settle();
      booted.controller.emitResponse(
        _delta(<TransitionDto>[_alert(id: 1, sessionKey: 'claude_code:s1')]),
        nowMs: _kNowMs + 1000,
      );
      await _settle();

      expect(sent.length, 1);
    });
  });

  group('완료 기준 (4)(b): 소유권 준수', () {
    test('APNs가 등록돼 있으면 로컬 발신은 0회다(배너는 서버->APNs가 띄운다)', () async {
      final booted = boot(apnsRegistered: true);

      booted.controller.emitResponse(
        _delta(<TransitionDto>[
          _alert(id: 1, sessionKey: 'claude_code:s1'),
          _alert(id: 2, sessionKey: 'codex:s2'),
        ]),
        nowMs: _kNowMs,
      );
      await _settle();

      expect(sent, isEmpty);
    });

    test('웹 런타임에서도 0회다', () async {
      final booted = boot(isWasm: true);

      booted.controller.emitResponse(
        _delta(<TransitionDto>[_alert(id: 1, sessionKey: 'claude_code:s1')]),
        nowMs: _kNowMs,
      );
      await _settle();

      expect(sent, isEmpty);
    });

    test('등록이 도중에 성공하면 그 다음 전이부터 억제된다', () async {
      final booted = boot();

      booted.controller.emitResponse(
        _delta(<TransitionDto>[_alert(id: 1, sessionKey: 'claude_code:s1')]),
        nowMs: _kNowMs,
      );
      await _settle();
      expect(sent.length, 1, reason: '아직 이 앱이 배너의 주인이다');

      booted.container
          .read(apnsRegisteredProvider.notifier)
          .applyResult(
            const PushRegistrationResult(
              availability: PushAvailability.registered,
              token: 't',
              transport: kPushTransportFcmApns,
            ),
          );

      booted.controller.emitResponse(
        _delta(<TransitionDto>[_alert(id: 2, sessionKey: 'codex:s2')]),
        nowMs: _kNowMs + 1000,
      );
      await _settle();

      expect(sent.length, 1, reason: '소유권이 APNs로 넘어갔으므로 늘지 않는다');
    });
  });
}
