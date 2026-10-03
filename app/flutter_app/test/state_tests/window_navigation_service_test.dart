import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/window_connection.dart';
import 'package:my_dashboard/src/data/window_navigation_target.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/window_connections_provider.dart';
import 'package:my_dashboard/src/state/window_navigation_provider.dart';

const _session = SessionViewDto(
  key: 'codex:a',
  state: 'waiting_input',
  host: 'mac',
  project: '/work/demo',
  lastTransitionId: 10,
);
const _window = WindowCandidate(
  token: 'one',
  bundleId: 'editor',
  appName: 'Editor',
  title: 'file — demo',
);
const _other = WindowCandidate(
  token: 'two',
  bundleId: 'editor',
  appName: 'Editor',
  title: 'other — demo',
);

void main() {
  late List<String> focused;
  late List<String?> scopes;
  late List<(String, int)> seen;
  late List<WindowConnectionRule> rules;
  late WindowScan scan;
  late String focusResult;
  late int choices;
  late Future<WindowCandidate?> Function(WindowScan, WindowConnectionRule?)
  choose;

  ProviderContainer create() => ProviderContainer(
    overrides: [
      dashboardInitialApiConfigProvider.overrideWithValue(
        DashboardApiConfig(baseUrl: Uri.parse('https://a.example.test')),
      ),
      windowConnectionsLoadFnProvider.overrideWithValue(() async => rules),
      windowConnectionsSaveFnProvider.overrideWithValue((_) async {}),
      windowScanProvider.overrideWithValue(({String? bundleId}) async {
        scopes.add(bundleId);
        return scan;
      }),
      windowFocusProvider.overrideWithValue((token) async {
        focused.add(token);
        return focusResult;
      }),
      windowSeenProvider.overrideWithValue((key, cutoff) async {
        seen.add((key, cutoff));
      }),
    ],
  );

  setUp(() {
    focused = [];
    scopes = [];
    seen = [];
    choices = 0;
    focusResult = 'focused';
    rules = [
      WindowConnectionRule(
        key: WindowConnectionKey(host: 'mac', project: '/work/demo'),
        bundleId: 'editor',
        titlePattern: 'demo',
      ),
    ];
    scan = WindowScan(
      trusted: true,
      complete: true,
      localHost: 'mac',
      windows: [_window],
    );
    choose = (_, _) async {
      choices++;
      return _window;
    };
  });

  test('저장한 호스트와 경로 규칙을 새 세션과 다른 에이전트도 공유한다', () async {
    final container = create();
    addTearDown(container.dispose);
    final service = container.read(windowNavigationServiceProvider);
    expect(await service.open(_session, choose: choose), 'focused');
    final next = _session.copyWith(
      key: 'claude-code:b',
      source: 'claude-code',
      lastTransitionId: 15,
    );
    expect(await service.open(next, choose: choose), 'focused');
    expect(choices, 0);
    expect(focused, ['one', 'one']);
    expect(scopes, ['editor', 'editor']);
    expect(seen, [('codex:a', 10), ('claude-code:b', 15)]);
  });

  test('규칙이 없으면 유일한 제목 후보라도 사용자가 선택한다', () async {
    rules = [];
    final container = create();
    addTearDown(container.dispose);
    await container
        .read(windowNavigationServiceProvider)
        .open(_session, choose: choose);
    expect(choices, 1);
  });

  test('호스트 또는 전체 경로가 다르면 기존 규칙을 적용하지 않는다', () async {
    final container = create();
    addTearDown(container.dispose);
    final service = container.read(windowNavigationServiceProvider);
    await service.open(_session.copyWith(host: 'other'), choose: choose);
    await service.open(
      _session.copyWith(project: '/another/demo'),
      choose: choose,
    );
    expect(choices, 2);
  });

  test('여러 창 일치와 불완전 조회는 자동 이동하지 않는다', () async {
    scan = WindowScan(
      trusted: true,
      complete: true,
      localHost: 'mac',
      windows: [_window, _other],
    );
    final container = create();
    addTearDown(container.dispose);
    final service = container.read(windowNavigationServiceProvider);
    await service.open(_session, choose: choose);
    scan = WindowScan(
      trusted: true,
      complete: false,
      localHost: 'mac',
      windows: [_window],
    );
    await service.open(_session, choose: choose);
    expect(choices, 2);
  });

  test('저장한 규칙이 사라져도 다른 제목 후보로 조용히 넘어가지 않는다', () async {
    rules = [
      WindowConnectionRule(
        key: WindowConnectionKey.fromSession(_session)!,
        bundleId: 'missing',
        titlePattern: 'demo',
      ),
    ];
    final container = create();
    addTearDown(container.dispose);
    await container
        .read(windowNavigationServiceProvider)
        .open(_session, choose: choose);
    expect(choices, 1);
  });

  test('권한 없음과 사용자 취소는 포커스나 읽음을 바꾸지 않는다', () async {
    scan = WindowScan(
      trusted: false,
      complete: false,
      localHost: 'mac',
      windows: [],
    );
    final container = create();
    addTearDown(container.dispose);
    expect(
      await container
          .read(windowNavigationServiceProvider)
          .open(_session, choose: (_, _) async => null),
      'cancelled',
    );
    expect(focused, isEmpty);
    expect(seen, isEmpty);
  });

  test('네이티브가 전환을 확인하지 못하면 읽음 처리하지 않는다', () async {
    final container = create();
    addTearDown(container.dispose);
    for (final status in [
      'staleTarget',
      'notGranted',
      'timedOut',
      'unconfirmed',
    ]) {
      focusResult = status;
      expect(
        await container
            .read(windowNavigationServiceProvider)
            .open(_session, choose: choose),
        status,
      );
    }
    expect(seen, isEmpty);
  });

  test('창 선택을 기다리는 동안에도 원래 알림의 읽음 상한을 유지한다', () async {
    rules = [];
    final target = Completer<WindowCandidate?>();
    final container = create();
    addTearDown(container.dispose);
    final service = container.read(windowNavigationServiceProvider);
    final first = service.open(_session, choose: (_, _) => target.future);
    await Future<void>.delayed(Duration.zero);
    expect(
      await service.open(
        _session.copyWith(lastTransitionId: 30),
        choose: choose,
      ),
      'busy',
    );
    expect(seen, isEmpty);
    target.complete(_window);
    expect(await first, 'focused');
    expect(seen, [('codex:a', 10)]);
    expect(focused, ['one']);
  });

  test('창 선택 중 서버가 바뀌면 옛 세션의 창과 읽음을 새 연결에 적용하지 않는다', () async {
    rules = [];
    final choice = Completer<WindowCandidate?>();
    final container = create();
    addTearDown(container.dispose);
    final result = container
        .read(windowNavigationServiceProvider)
        .open(_session, choose: (_, _) => choice.future);
    await Future<void>.delayed(Duration.zero);
    container
        .read(dashboardApiConfigControllerProvider.notifier)
        .apply(serverUrl: 'https://b.example.test', clientToken: null);
    choice.complete(_window);
    expect(await result, kWindowNavigationStaleTarget);
    expect(focused, isEmpty);
    expect(seen, isEmpty);
  });

  test('옛 알림 대상을 전환 뒤 열어도 읽음 요청을 보내지 않는다', () async {
    final container = create();
    addTearDown(container.dispose);
    final connection = container.read(
      dashboardApiConfigControllerProvider.notifier,
    );
    final target = WindowNavigationTarget(
      sessionKey: _session.key,
      project: _session.project,
      host: _session.host,
      transitionId: _session.lastTransitionId,
      serverUrl: 'https://a.example.test',
      serverRevision: connection.serverRevision,
    );
    connection.apply(serverUrl: 'https://b.example.test', clientToken: null);
    expect(
      await container
          .read(windowNavigationServiceProvider)
          .openTarget(target, choose: choose),
      kWindowNavigationStaleTarget,
    );
    expect(focused, isEmpty);
    expect(seen, isEmpty);
  });

  test('전이 상한이 없는 항목과 명시적 연결 설정은 읽음 요청을 보내지 않는다', () async {
    final container = create();
    addTearDown(container.dispose);
    final service = container.read(windowNavigationServiceProvider);
    await service.open(
      _session.copyWith(lastTransitionId: null),
      choose: choose,
    );
    await service.open(
      _session,
      choose: choose,
      configure: true,
      markRead: false,
    );
    expect(choices, 1);
    expect(seen, isEmpty);
  });

  test('저장 규칙 읽기 실패는 이동하지 않고 다음 요청을 막지 않는다', () async {
    var fail = true;
    final container = create();
    addTearDown(container.dispose);
    container.updateOverrides([
      dashboardInitialApiConfigProvider.overrideWithValue(
        DashboardApiConfig(baseUrl: Uri.parse('https://a.example.test')),
      ),
      windowConnectionsLoadFnProvider.overrideWithValue(() async {
        if (fail) throw const FormatException('bad');
        return rules;
      }),
      windowConnectionsSaveFnProvider.overrideWithValue((_) async {}),
      windowScanProvider.overrideWithValue(({String? bundleId}) async {
        scopes.add(bundleId);
        return scan;
      }),
      windowFocusProvider.overrideWithValue((token) async {
        focused.add(token);
        return focusResult;
      }),
      windowSeenProvider.overrideWithValue((key, cutoff) async {
        seen.add((key, cutoff));
      }),
    ]);
    final service = container.read(windowNavigationServiceProvider);
    expect(await service.open(_session, choose: choose), 'failed');
    expect(focused, isEmpty);
    expect(seen, isEmpty);
    fail = false;
    container.invalidate(windowConnectionsProvider);
    expect(await service.open(_session, choose: choose), 'focused');
  });
  test('읽음 응답이 늦어도 창 전환 완료와 다음 요청을 막지 않는다', () async {
    final waiting = Completer<void>();
    final container = create();
    addTearDown(container.dispose);
    container.updateOverrides([
      dashboardInitialApiConfigProvider.overrideWithValue(
        DashboardApiConfig(baseUrl: Uri.parse('https://a.example.test')),
      ),
      windowConnectionsLoadFnProvider.overrideWithValue(() async => rules),
      windowConnectionsSaveFnProvider.overrideWithValue((_) async {}),
      windowScanProvider.overrideWithValue(({String? bundleId}) async => scan),
      windowFocusProvider.overrideWithValue((token) async {
        focused.add(token);
        return 'focused';
      }),
      windowSeenProvider.overrideWithValue((key, cutoff) => waiting.future),
    ]);
    final service = container.read(windowNavigationServiceProvider);
    expect(await service.open(_session, choose: choose), 'focused');
    expect(await service.open(_session, choose: choose), 'focused');
    expect(focused, ['one', 'one']);
    waiting.completeError(StateError('offline'));
    await Future<void>.delayed(Duration.zero);
  });
}
