import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/sync_reducer.dart';

import '../test_helpers/fake_dashboard.dart';

const int _base = 1757300000000;
const int _tick = 30000;

SyncState _applyAll(FakeDashboard server, {required int nowMs}) => reduceSync(
  const SyncState(cursor: 0),
  server.delta(since: 0, serverTime: nowMs, limit: 1000),
  nowMs: nowMs,
);

void main() {
  group('display_title — 작업 표시 제목의 리듀서 규칙', () {
    test('델타 전이가 싣고 온 제목이 세션 카드로 흐르고, 스냅샷도 같은 값을 준다', () {
      final server = FakeDashboard();
      server.ingest(
        source: 'claude-code',
        sessionId: 's1',
        event: 'SessionStart',
        state: 'idle',
        occurredAt: _base,
        receivedAt: _base,
      );
      server.ingest(
        source: 'claude-code',
        sessionId: 's1',
        event: 'UserPromptSubmit',
        state: 'working',
        occurredAt: _base + _tick,
        receivedAt: _base + _tick + 5,
        displayTitle: '작업 A',
      );

      final fromDelta = _applyAll(server, nowMs: _base + 2 * _tick);
      expect(fromDelta.sessions['claude-code:s1']?.displayTitle, '작업 A');
      expect(server.transitions.last.displayTitle, '작업 A');

      final fromSnapshot = reduceSync(
        const SyncState(),
        server.snapshot(serverTime: _base + 2 * _tick),
        nowMs: _base + 2 * _tick,
      );
      expect(fromSnapshot.sessions['claude-code:s1']?.displayTitle, '작업 A');
    });

    test('제목 없는 최신 전이는 기존 제목을 지운다(교체 의미론, COALESCE 아님)', () {
      final server = FakeDashboard();
      server.ingest(
        source: 'claude-code',
        sessionId: 's1',
        event: 'UserPromptSubmit',
        state: 'working',
        occurredAt: _base,
        receivedAt: _base + 5,
        displayTitle: '작업 A',
      );
      server.ingest(
        source: 'claude-code',
        sessionId: 's1',
        event: 'Notification',
        state: 'waiting_input',
        occurredAt: _base + _tick,
        receivedAt: _base + _tick + 5,
      );

      final state = _applyAll(server, nowMs: _base + 2 * _tick);
      expect(state.sessions['claude-code:s1']?.displayTitle, isNull);
      expect(server.transitions.first.displayTitle, '작업 A');
      expect(server.transitions.last.displayTitle, isNull);
    });

    test('같은 상태의 이름 전용 갱신은 전이가 아니다 — 델타는 다음 전이에서야 제목을 받는다', () {
      final server = FakeDashboard();
      server.ingest(
        source: 'claude-code',
        sessionId: 's1',
        event: 'UserPromptSubmit',
        state: 'working',
        occurredAt: _base,
        receivedAt: _base + 5,
        displayTitle: '작업 A',
      );
      server.ingest(
        source: 'claude-code',
        sessionId: 's1',
        event: 'UserPromptSubmit',
        state: 'working',
        occurredAt: _base + _tick,
        receivedAt: _base + _tick + 5,
        displayTitle: '작업 B',
      );
      expect(server.transitions, hasLength(1), reason: '이름 전용 갱신은 전이가 아니다');

      final fromDelta = _applyAll(server, nowMs: _base + 2 * _tick);
      expect(fromDelta.sessions['claude-code:s1']?.displayTitle, '작업 A');
      final fromSnapshot = reduceSync(
        const SyncState(),
        server.snapshot(serverTime: _base + 2 * _tick),
        nowMs: _base + 2 * _tick,
      );
      expect(fromSnapshot.sessions['claude-code:s1']?.displayTitle, '작업 B');

      server.ingest(
        source: 'claude-code',
        sessionId: 's1',
        event: 'Notification',
        state: 'waiting_input',
        occurredAt: _base + 2 * _tick,
        receivedAt: _base + 2 * _tick + 5,
        displayTitle: '작업 B',
      );
      final caughtUp = _applyAll(server, nowMs: _base + 3 * _tick);
      expect(caughtUp.sessions['claude-code:s1']?.displayTitle, '작업 B');
      expect(caughtUp.pendingAlerts.single.displayTitle, '작업 B');
    });

    test('역행 전이는 제목을 되돌리지 않는다(occurred_at 방어와 같은 규칙)', () {
      final server = FakeDashboard();
      server.ingest(
        source: 'claude-code',
        sessionId: 's1',
        event: 'Notification',
        state: 'waiting_input',
        occurredAt: _base + _tick,
        receivedAt: _base + _tick + 5,
        displayTitle: '최신 제목',
      );
      server.ingest(
        source: 'claude-code',
        sessionId: 's1',
        event: 'UserPromptSubmit',
        state: 'working',
        occurredAt: _base,
        receivedAt: _base + 2 * _tick,
        displayTitle: '옛 제목',
      );

      final state = _applyAll(server, nowMs: _base + 3 * _tick);
      expect(state.sessions['claude-code:s1']?.displayTitle, '최신 제목');
    });
  });
}
