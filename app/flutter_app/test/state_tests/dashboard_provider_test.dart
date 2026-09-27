/// `dashboard_provider.dart`가 FRB 호출을 정확한 인자로 그대로 옮기는지,
/// 그리고 `isSessionStale`의 `PlatformInt64` 변환(io 빌드에서는 `int`와
/// 같다)이 값을 훼손하지 않는지를 가짜 [RustLibApi] 하나로 닫는다.
/// 실제 네이티브 dylib/wasm은 전혀 로드하지 않는다(`RustLib.initMock`).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/rust/frb_generated.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart';

class _DashboardApi extends RustLibApi {
  final List<String> calls = <String>[];

  @override
  SessionStateDto? crateApiDashboardStateForEvent({
    required EventSourceDto source,
    required String event,
  }) {
    calls.add('stateForEvent($source, $event)');
    if (source == EventSourceDto.claudeCode && event == 'question') {
      return SessionStateDto.waitingInput;
    }
    return null;
  }

  @override
  String crateApiDashboardStateLabelKey({required SessionStateDto state}) {
    calls.add('stateLabelKey($state)');
    return 'dashboard.state.${state.name}';
  }

  @override
  bool crateApiDashboardIsSessionStale({
    required PlatformInt64 now,
    required PlatformInt64 updatedAt,
    required PlatformInt64 staleMs,
  }) {
    calls.add('isSessionStale($now, $updatedAt, $staleMs)');
    return now - updatedAt > staleMs;
  }

  @override
  List<SessionOrderKeyDto> crateApiDashboardSortSessionOrder({
    required List<SessionOrderKeyDto> sessions,
  }) {
    calls.add('sortSessionOrder(${sessions.length})');
    // 순서를 뒤집어 돌려준다 — 어댑터가 응답을 그대로(가공 없이) 옮기는지
    // 확인하는 표식으로 쓴다.
    return sessions.reversed.toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _DashboardApi api;
  late ProviderContainer container;

  setUp(() {
    api = _DashboardApi();
    RustLib.initMock(api: api);
    container = ProviderContainer();
  });

  tearDown(() {
    container.dispose();
    RustLib.dispose();
  });

  test('stateForEventFnProvider는 인자를 그대로 옮기고 표에 없으면 null이다', () {
    final fn = container.read(stateForEventFnProvider);

    expect(
      fn(source: EventSourceDto.claudeCode, event: 'question'),
      SessionStateDto.waitingInput,
    );
    expect(fn(source: EventSourceDto.codex, event: 'unknown_event'), isNull);
    expect(api.calls, [
      'stateForEvent(EventSourceDto.claudeCode, question)',
      'stateForEvent(EventSourceDto.codex, unknown_event)',
    ]);
  });

  test('stateLabelKeyFnProvider는 상태별 i18n 키를 그대로 옮긴다', () {
    final fn = container.read(stateLabelKeyFnProvider);
    expect(fn(SessionStateDto.stalled), 'dashboard.state.stalled');
  });

  test('isSessionStaleFnProvider는 plain int를 PlatformInt64로 바꿔도 값이 훼손되지 않는다', () {
    final fn = container.read(isSessionStaleFnProvider);

    // io 테스트 호스트에서는 PlatformInt64 == int라 값이 그대로 보여야 한다.
    expect(
      fn(now: 1000000, updatedAt: 500000, staleMs: 300000),
      isTrue, // 500000 > 300000
    );
    expect(
      fn(now: 600000, updatedAt: 500000, staleMs: 300000),
      isFalse, // 100000 <= 300000
    );
    expect(api.calls, [
      'isSessionStale(1000000, 500000, 300000)',
      'isSessionStale(600000, 500000, 300000)',
    ]);
  });

  test('sortSessionOrderFnProvider는 요청/응답 목록을 가공 없이 옮긴다', () {
    final fn = container.read(sortSessionOrderFnProvider);
    final input = [
      const SessionOrderKeyDto(state: SessionStateDto.idle, updatedAt: 1),
      const SessionOrderKeyDto(state: SessionStateDto.working, updatedAt: 2),
    ];

    final result = fn(input);

    expect(result, input.reversed.toList());
    expect(api.calls, ['sortSessionOrder(2)']);
  });
}
