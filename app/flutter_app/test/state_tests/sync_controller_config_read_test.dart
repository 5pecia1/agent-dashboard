/// 동기화 커서 저장 직전의 설정 읽기가 실패할 때(`ConfigReadException`)
/// 커서 저장은 아무것도 쓰지 않고, 동기화 자체는 성공으로 남는지 닫는다.
/// 저장된 설정으로 부팅한 뒤 설정 파일이 사라졌을 때 새 파일을 만들지
/// 않는 것도 여기서 닫는다(`config_provider.dart`의 `backgroundConfigPatch`).
///
/// `sync_controller_seen_watermark_test.dart`와 같은 조립을 옮겨 놓았다 —
/// `sync_controller_test.dart`에 넣으면 `quality_check.py budget`의
/// 1000줄 상한을 넘는다. 예전에는 읽기 실패가 빈 값으로 접혀, 3초마다 도는
/// 커서 저장이 서버 주소와 CLIENT_TOKEN을 지운 파일을 썼다.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';

const ConfigReadException _accessFailure = ConfigReadException(
  ConfigReadFailureKind.access,
  location: '/fixture/config.json',
  detail: 'Cannot open file: Permission denied (errno 13)',
);

void main() {
  late List<_Scheduled> scheduled;
  late int nowMs;
  late Future<ApiResponse> Function(ApiRequest request) httpHandler;
  late List<DashboardConfigValues> savedConfigs;
  late DashboardConfigValues storedConfig;
  late int failingLoads;
  late StreamController<bool> activity;
  late StreamController<void> wake;

  Timer fakeSchedule(Duration delay, void Function() callback) {
    scheduled.add(_Scheduled(delay, callback));
    return _FakeTimer();
  }

  /// [storedAtBoot]은 `main.dart`의 `buildDashboardRoot`가 채우는 "저장된
  /// 설정으로 부팅했다"는 사실이다. 이 파일의 기본 조립은 저장된 설정을
  /// 읽고 부팅한 세션이다.
  ProviderContainer buildContainer({bool storedAtBoot = true}) {
    storedConfig = const DashboardConfigValues(
      serverUrl: 'https://example.test',
      clientToken: 'stored-client-token',
      cursor: 7,
      themeMode: 'dark',
      extra: <String, Object?>{
        'teamclaude': <String, Object?>{
          'url': 'https://tc.example.test',
          'api_key': 'tc-key',
        },
      },
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
        storedConfigAtBootProvider.overrideWithValue(storedAtBoot),
        configLoadFnProvider.overrideWithValue(() async {
          if (failingLoads > 0) {
            failingLoads -= 1;
            throw _accessFailure;
          }
          return storedConfig;
        }),
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
    failingLoads = 0;
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

  Future<ApiResponse> Function(ApiRequest) okHandler({required int cursor}) =>
      (ApiRequest request) async => ApiResponse(
        statusCode: 200,
        body: jsonEncode(<String, Object?>{
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
        }),
      );

  test('커서 저장 직전 읽기가 실패하면 아무것도 쓰지 않고 동기화는 실패로 치지 않는다', () async {
    httpHandler = okHandler(cursor: 42);
    failingLoads = 1;
    final container = buildContainer();
    addTearDown(container.dispose);
    container.read(syncControllerProvider);

    await fireScheduled();

    expect(savedConfigs, isEmpty, reason: '읽지 못한 값 위에 커서만 담긴 파일을 쓰면 안 된다');
    final state = container.read(syncControllerProvider);
    expect(state.phase, SyncPhase.idle);
    expect(state.consecutiveFailures, 0);
    expect(state.lastError, isNull);
    expect(state.sync.cursor, 42, reason: '메모리 상태는 응답대로 앞으로 간다');
    expect(scheduled, hasLength(1));
    expect(
      scheduled.single.delay,
      kSyncForegroundInterval,
      reason: '백오프가 아니라 평소 간격',
    );
  });

  test('다음 사이클은 새 커서를 저장하면서 서버 주소, 토큰, 연동 설정을 보존한다', () async {
    httpHandler = okHandler(cursor: 42);
    failingLoads = 1;
    final container = buildContainer();
    addTearDown(container.dispose);
    container.read(syncControllerProvider);
    await fireScheduled();
    expect(savedConfigs, isEmpty);

    httpHandler = okHandler(cursor: 43);
    await fireScheduled();

    expect(savedConfigs, hasLength(1));
    final saved = savedConfigs.single;
    expect(saved.cursor, 43);
    expect(saved.serverUrl, 'https://example.test');
    expect(saved.clientToken, 'stored-client-token');
    expect(saved.themeMode, 'dark');
    expect(saved.extra.keys, contains('teamclaude'));
  });

  test('저장된 설정으로 부팅한 뒤 설정 파일이 사라지면 커서만 담긴 새 파일을 만들지 않는다', () async {
    // 사용자가 손상된 설정을 고치려고 실행 중에 파일을 옆으로 옮긴 순간이다.
    // 새 파일이 생기면 원본을 되돌릴 때 이름이 부딪히고, 다음 부팅은 저장된
    // 설정 없이 뜬다.
    httpHandler = okHandler(cursor: 42);
    final container = buildContainer();
    addTearDown(container.dispose);
    container.read(syncControllerProvider);
    storedConfig = DashboardConfigValues.empty;

    await fireScheduled();

    expect(savedConfigs, isEmpty);
    final state = container.read(syncControllerProvider);
    expect(state.phase, SyncPhase.idle);
    expect(state.sync.cursor, 42);
  });

  test('저장된 설정 없이 부팅한 세션(빌드 기본값으로 도는 첫 실행)은 첫 커서를 새 파일에 남긴다', () async {
    httpHandler = okHandler(cursor: 42);
    final container = buildContainer(storedAtBoot: false);
    addTearDown(container.dispose);
    container.read(syncControllerProvider);
    storedConfig = DashboardConfigValues.empty;

    await fireScheduled();

    expect(savedConfigs, hasLength(1));
    expect(savedConfigs.single.cursor, 42);
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
