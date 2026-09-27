/// 리뷰 지적 high 수정: `SyncState.seenWatermark`(첫 도입 미확인 벽) 영속화만
/// 따로 닫는 파일.
///
/// `sync_controller_ack_test.dart` 상단 문서와 같은 이유로 조립 코드를 그대로
/// 옮겨 놓았다 — `sync_controller_test.dart`에 그대로 두면
/// `quality_check.py budget`의 1000줄 상한을 넘는다(house rule). 여기서 보는
/// 것은 `_persistSyncMeta`가 cursor와 같은 자리에서 seenWatermark를 같이
/// 저장·복원하는지, 그리고 트리거 조건이 `isFirstBoot`(cursor==null)가 아니라
/// `seenWatermark==null` 자신이어서 커서를 이미 갖고 있던 기존 설치에도 벽이
/// 세워지는지다 — `sync_reducer.dart`의 `reduceSync`/`restoreState` 문서 참고.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';

void main() {
  group('리뷰 지적 high: seenWatermark 영속화(cursor와 같은 자리)', () {
    late List<_Scheduled> scheduled;
    late int nowMs;
    late Future<ApiResponse> Function(ApiRequest request) httpHandler;
    late List<DashboardConfigValues> savedConfigs;
    late DashboardConfigValues storedConfig;
    late StreamController<bool> activity;
    late StreamController<void> wake;

    Timer fakeSchedule(Duration delay, void Function() callback) {
      scheduled.add(_Scheduled(delay, callback));
      return _FakeTimer();
    }

    // `sync_controller_test.dart`의 `buildContainer`와 같은 조립이다.
    ProviderContainer buildContainer({
      int? persistedCursor,
      int? persistedSeenWatermark,
    }) {
      storedConfig = DashboardConfigValues(
        cursor: persistedCursor,
        seenWatermark: persistedSeenWatermark,
        serverUrl: 'https://example.test',
      );
      return ProviderContainer(
        overrides: [
          syncScheduleFnProvider.overrideWithValue(fakeSchedule),
          syncNowMsFnProvider.overrideWithValue(() => nowMs),
          syncActivityWatchFnProvider.overrideWithValue(() => activity.stream),
          syncWakeWatchFnProvider.overrideWithValue(() => wake.stream),
          httpSendProvider.overrideWithValue(
            (ApiRequest request) => httpHandler(request),
          ),
          dashboardApiConfigProvider.overrideWithValue(
            DashboardApiConfig(baseUrl: Uri.parse('https://example.test')),
          ),
          dashboardConfigValuesProvider.overrideWithValue(storedConfig),
          configLoadFnProvider.overrideWithValue(() async => storedConfig),
          configSaveFnProvider.overrideWithValue((
            DashboardConfigValues values,
          ) async {
            storedConfig = values;
            savedConfigs.add(values);
          }),
        ],
      );
    }

    setUp(() {
      scheduled = <_Scheduled>[];
      nowMs = 1000;
      savedConfigs = <DashboardConfigValues>[];
      httpHandler = (ApiRequest request) async =>
          throw StateError('이 테스트는 httpHandler를 아직 설정하지 않았다.');
      activity = StreamController<bool>.broadcast(sync: true);
      wake = StreamController<void>.broadcast(sync: true);
    });

    tearDown(() {
      activity.close();
      wake.close();
    });

    Future<void> fireScheduled() async {
      final next = scheduled.removeAt(0);
      next.callback();
      await pumpMicrotasks();
    }

    Map<String, Object?> snapshotJson({int cursor = 1}) => <String, Object?>{
      'protocol_version': kDashboardProtocolVersion,
      'reset': true,
      'cursor': cursor,
      'has_more': false,
      'server_time': nowMs,
      'pruned_below_id': 0,
      'stall_ms': kDefaultStallMs,
      'mute_until': null,
      'sessions': const <Object?>[],
      'transitions': const <Object?>[],
      'sessions_touched': const <String>[],
    };

    Future<ApiResponse> Function(ApiRequest) okHandler({int cursor = 1}) =>
        (ApiRequest request) async =>
            ApiResponse(statusCode: 200, body: jsonEncode(snapshotJson(cursor: cursor)));

    test('첫 스냅샷의 seenWatermark를 configProvider(ConfigSaveFn)로 영속화한다', () async {
      httpHandler = okHandler(cursor: 42);
      final container = buildContainer(persistedCursor: null);
      addTearDown(container.dispose);
      container.read(syncControllerProvider);

      await fireScheduled();

      expect(savedConfigs, hasLength(1));
      expect(savedConfigs.single.seenWatermark, 42);
    });

    test('영속화된 seenWatermark로 build()가 SyncState를 복원한다', () {
      httpHandler = okHandler();
      final container = buildContainer(
        persistedCursor: 7,
        persistedSeenWatermark: 30,
      );
      addTearDown(container.dispose);

      final state = container.read(syncControllerProvider);
      expect(state.sync.seenWatermark, 30);
    });

    test(
      '이미 커서를 갖고 있던 기존 설치에 배포돼도 첫 스냅샷에서 seenWatermark 벽이 세워진다',
      () async {
        // 이 기능 도입 이전부터 커서만 저장돼 있던 기존 설치를 흉내낸다
        // (persistedSeenWatermark 없음 = null). isFirstBoot(cursor==null)를
        // 트리거로 쓰던 예전 로직이면 여기서 영영 벽이 안 세워진다.
        httpHandler = okHandler(cursor: 99);
        final container = buildContainer(
          persistedCursor: 50,
          persistedSeenWatermark: null,
        );
        addTearDown(container.dispose);
        container.read(syncControllerProvider);

        await fireScheduled();

        final state = container.read(syncControllerProvider);
        expect(state.sync.seenWatermark, 99);
        expect(savedConfigs.last.seenWatermark, 99);
      },
    );
  });
}

/// 대기 중인 스케줄 하나(`(delay, callback)`)의 기록.
class _Scheduled {
  _Scheduled(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
}

/// `Timer`의 계약(`cancel()`/`tick`/`isActive`)만 구현한 테스트용 대체물.
class _FakeTimer implements Timer {
  bool _active = true;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// `_runCycle`의 `await` 체인이 전부 끝날 만큼 마이크로태스크 턴을
/// 흘려보낸다. 실제 시간은 흐르지 않는다.
Future<void> pumpMicrotasks([int turns = 5]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
