/// `sync_reducer.dart`의 여섯 불변식을 서버·네트워크·FFI 없이 닫는다.
///
/// 비교 대상 스냅샷은 `test_helpers/fake_dashboard.dart`가 서버와 같은
/// 프로젝션 규칙으로 만든다 — 그래야 "델타를 다 적용하면 스냅샷과 같다"가
/// 자기 자신을 증명하는 동어반복이 되지 않는다.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';

/// 서버 없이 `GET /dashboard/sync`의 두 응답(스냅샷/델타)을 만드는 가짜 서버.
///
/// `dashboard-server/src/features/dashboard/routes.ts`의 프로젝션 규칙과 `sync.ts`의
/// 응답 조립을 그대로 옮긴 것이다 - "델타를 다 적용하면 스냅샷과 같아지는가"를
/// 물으려면 비교 대상 스냅샷을 서버와 같은 규칙으로 만들어야 하기 때문이다.
/// 옮긴 규칙은 넷이다:
///
///  * 순서 역행 방어: `occurred_at < last_occurred_at`이면 상태를 안 바꾼다.
///  * ended 불변식: 끝난 세션은 `SessionStart`로만 되살아난다.
///  * COALESCE: 이벤트가 모르는 값(host·message가 null)은 기존 값을 안 지운다.
///  * 같은 상태 재진입은 전이가 아니다(커서도 알림도 늘지 않는다).
///
/// (아직 이 파일 하나만 쓰므로 test_helpers/로 빼지 않았다 - 그 디렉터리의
/// README가 정한 "두 번 이상 반복되면 그때 추출한다" 규칙을 따른다.)
/// 프로젝션과 전이 로그를 함께 들고 있는 가짜 서버.
class FakeDashboard {
  final Map<String, SessionViewDto> _sessions = <String, SessionViewDto>{};
  final List<TransitionDto> _transitions = <TransitionDto>[];
  int _nextTransitionId = 1;

  /// 보존 정리로 사라진 전이 경계(`pruned_below_id`).
  int prunedBelowId = 0;

  List<TransitionDto> get transitions =>
      List<TransitionDto>.unmodifiable(_transitions);

  Map<String, SessionViewDto> get sessions =>
      Map<String, SessionViewDto>.unmodifiable(_sessions);

  int get cursor => _transitions.isEmpty ? 0 : _transitions.last.id;

  /// hook 이벤트 하나를 먹인다(`POST /dashboard/events`와 같은 순서로 처리).
  void ingest({
    required String source,
    required String sessionId,
    required String event,
    required String state,
    required int occurredAt,
    required int receivedAt,
    String project = '/w/demo',
    String? host,
    String? message,
  }) {
    final key = '$source:$sessionId';
    final current = _sessions[key];

    final lastOccurred = current?.lastOccurredAt;
    if (lastOccurred != null && occurredAt < lastOccurred) return;
    if (current?.state == 'ended' && event != 'SessionStart') return;

    _sessions[key] = current == null
        ? SessionViewDto(
            key: key,
            state: state,
            source: source,
            sessionId: sessionId,
            project: project,
            host: host,
            lastEvent: event,
            lastMessage: message,
            lastOccurredAt: occurredAt,
            createdAt: receivedAt,
            updatedAt: receivedAt,
          )
        : current.copyWith(
            state: state,
            project: project,
            host: host ?? current.host,
            lastEvent: event,
            lastMessage: message ?? current.lastMessage,
            lastOccurredAt: occurredAt,
            updatedAt: receivedAt,
          );

    if (current?.state == state) return;

    _transitions.add(
      TransitionDto(
        id: _nextTransitionId++,
        sessionKey: key,
        fromState: current?.state,
        toState: state,
        source: source,
        project: project,
        host: host,
        message: message,
        occurredAt: occurredAt,
        createdAt: receivedAt,
      ),
    );
  }

  /// `reset:true` 응답(전체 스냅샷).
  SyncResponseDto snapshot({
    required int serverTime,
    bool includeEnded = true,
  }) {
    final rows = _sessions.values
        .where((SessionViewDto s) => includeEnded || !s.isEnded)
        .toList(growable: false);
    return SyncResponseDto(
      reset: true,
      cursor: cursor,
      serverTime: serverTime,
      prunedBelowId: prunedBelowId,
      sessions: rows,
    );
  }

  /// `reset:false` 응답(`since` 이후 전이 델타).
  SyncResponseDto delta({
    required int since,
    required int serverTime,
    int limit = 200,
  }) {
    final rows = _transitions
        .where((TransitionDto t) => t.id > since)
        .toList(growable: false);
    final page = rows.length > limit ? rows.sublist(0, limit) : rows;
    return SyncResponseDto(
      reset: false,
      cursor: page.isEmpty ? since : page.last.id,
      hasMore: rows.length > limit,
      serverTime: serverTime,
      prunedBelowId: prunedBelowId,
      transitions: page,
      sessionsTouched: <String>{
        for (final TransitionDto t in page) t.sessionKey,
      }.toList(growable: false),
    );
  }
}

/// 정본 예시의 시각. 여기서부터 30초 간격으로 이벤트를 흘린다.
const int _base = 1757300000000;
const int _tick = 30000;

/// 상태가 매번 바뀌는 이벤트만 낸다.
///
/// 같은 상태 재진입은 정본상 전이가 아니라 로그에 안 남는다 — 즉 전이만으로는
/// 복원할 수 없는 정보다. 그 경우를 섞으면 "델타 재구성 == 스냅샷"이 성립할 수
/// 없으므로(프로토콜의 성질이지 리듀서의 결함이 아니다) 시나리오에서 뺀다.
FakeDashboard _scenario() {
  final server = FakeDashboard();
  const sources = <String>['claude-code', 'codex', 'claude-code', 'generic'];
  const ids = <String>['a1', 'b2', 'c3', 'd4'];
  const cycle = <List<String>>[
    <String>['SessionStart', 'idle'],
    <String>['UserPromptSubmit', 'working'],
    <String>['Notification', 'waiting_input'],
    <String>['UserPromptSubmit', 'working'],
    <String>['Stop', 'done'],
  ];

  var clock = _base;
  for (var round = 0; round < 5; round++) {
    for (var session = 0; session < ids.length; session++) {
      final step = cycle[(round + session) % cycle.length];
      clock += _tick;
      server.ingest(
        source: sources[session],
        sessionId: ids[session],
        event: step[0],
        state: step[1],
        // 세션마다 project·host는 고정이고(현실도 그렇다), host는 한 세션만
        // 비워 COALESCE 경로를 태운다.
        project: '/w/${ids[session]}',
        host: session == 2 ? null : 'mac-$session',
        message: round.isEven ? 'round $round' : null,
        occurredAt: clock,
        receivedAt: clock + 5,
      );
    }
  }

  // 늦게 도착한 스풀: 과거 시각의 이벤트는 상태를 되돌리지 못한다.
  server.ingest(
    source: sources[0],
    sessionId: ids[0],
    event: 'Notification',
    state: 'waiting_input',
    project: '/w/${ids[0]}',
    host: 'mac-0',
    occurredAt: _base - 10 * _tick,
    receivedAt: clock + 10,
  );

  // 한 세션은 끝난다. 그 뒤 이벤트는 SessionStart가 아니면 무시된다.
  clock += _tick;
  server.ingest(
    source: sources[1],
    sessionId: ids[1],
    event: 'SessionEnd',
    state: 'ended',
    project: '/w/${ids[1]}',
    host: 'mac-1',
    occurredAt: clock,
    receivedAt: clock + 5,
  );
  server.ingest(
    source: sources[1],
    sessionId: ids[1],
    event: 'Stop',
    state: 'done',
    project: '/w/${ids[1]}',
    host: 'mac-1',
    occurredAt: clock + 1000,
    receivedAt: clock + 1005,
  );

  // 서버 cron이 만드는 파생 상태.
  clock += _tick;
  server.ingest(
    source: sources[3],
    sessionId: ids[3],
    event: 'stall-sweep',
    state: 'stalled',
    project: '/w/${ids[3]}',
    host: 'mac-3',
    occurredAt: clock,
    receivedAt: clock + 5,
  );

  return server;
}

/// 델타 전체를 한 통으로 적용한 기준 상태(전이는 id 오름차순 그대로).
SyncState _applyAll(FakeDashboard server, {required int nowMs}) => reduceSync(
  // cursor를 0으로 주면 "이미 한 번 동기화했고 아직 아무 전이도 못 봤다"가
  // 되어 첫 기동 10분 규칙이 끼어들지 않는다(그 규칙은 (d)에서 따로 본다).
  const SyncState(cursor: 0),
  server.delta(since: 0, serverTime: nowMs, limit: 1000),
  nowMs: nowMs,
);

void main() {
  group('(a) 델타는 도착 순서에 의존하지 않는다', () {
    test('한 응답 안의 전이를 무작위로 섞어도 세션 맵과 알림 큐가 같다', () {
      final server = _scenario();
      final now = server.transitions.last.createdAt + _tick;
      final expected = _applyAll(server, nowMs: now);
      expect(expected.sessions, isNotEmpty);

      for (var seed = 0; seed < 25; seed++) {
        final shuffled = List<TransitionDto>.of(server.transitions)
          ..shuffle(Random(seed));
        final actual = reduceSync(
          const SyncState(cursor: 0),
          SyncResponseDto(
            cursor: server.cursor,
            serverTime: now,
            transitions: shuffled,
          ),
          nowMs: now,
        );
        expect(actual.sessions, expected.sessions, reason: 'seed=$seed');
        expect(
          actual.pendingAlerts.map((TransitionDto t) => t.id).toList(),
          expected.pendingAlerts.map((TransitionDto t) => t.id).toList(),
          reason: 'seed=$seed',
        );
        expect(actual.cursor, expected.cursor, reason: 'seed=$seed');
      }
    });

    test('무작위 크기의 여러 응답으로 나눠 받아도 최종 상태가 같다', () {
      final server = _scenario();
      final now = server.transitions.last.createdAt + _tick;
      final expected = _applyAll(server, nowMs: now);

      for (var seed = 0; seed < 25; seed++) {
        final random = Random(seed);
        var state = const SyncState(cursor: 0);
        var offset = 0;
        final all = server.transitions;
        while (offset < all.length) {
          final size = 1 + random.nextInt(4);
          final end = min(offset + size, all.length);
          // 서버는 항상 오름차순 구간으로 잘라 주지만, 그 구간 **안의** 순서는
          // 전송 계층이 흔들 수 있다고 보고 섞는다.
          final chunk = all.sublist(offset, end)..shuffle(random);
          state = reduceSync(
            state,
            SyncResponseDto(
              cursor: all[end - 1].id,
              hasMore: end < all.length,
              serverTime: now,
              transitions: chunk,
            ),
            nowMs: now,
          );
          offset = end;
        }
        expect(state.sessions, expected.sessions, reason: 'seed=$seed');
        expect(
          state.pendingAlerts.map((TransitionDto t) => t.id).toList(),
          expected.pendingAlerts.map((TransitionDto t) => t.id).toList(),
          reason: 'seed=$seed',
        );
        expect(state.cursor, server.cursor, reason: 'seed=$seed');
      }
    });
  });

  group('(b) 델타 재구성은 reset 스냅샷과 수렴한다', () {
    test('전이만으로 만든 세션 맵이 스냅샷과 같은 투영을 갖는다', () {
      final server = _scenario();
      final now = server.transitions.last.createdAt + _tick;

      final fromDelta = _applyAll(server, nowMs: now);
      final fromSnapshot = reduceSync(
        const SyncState(),
        server.snapshot(serverTime: now),
        nowMs: now,
      );

      expect(
        sessionCores(fromDelta.sessions),
        sessionCores(fromSnapshot.sessions),
      );
      // 스냅샷 경로는 서버 프로젝션을 그대로 받으므로 원본과도 같아야 한다.
      expect(fromSnapshot.sessions, server.sessions);
      expect(fromDelta.cursor, fromSnapshot.cursor);
    });

    test('스냅샷 뒤에 이어진 델타도 같은 곳으로 수렴한다', () {
      final server = _scenario();
      final firstNow = server.transitions.last.createdAt + _tick;
      var state = reduceSync(
        const SyncState(),
        server.snapshot(serverTime: firstNow),
        nowMs: firstNow,
      );

      final clock = firstNow + _tick;
      // 시나리오 끝에서 a1은 done이다. 같은 상태 재진입은 전이를 남기지
      // 않으므로(정본), 상태가 실제로 바뀌는 이벤트를 하나 더 먹인다.
      server.ingest(
        source: 'claude-code',
        sessionId: 'a1',
        event: 'Notification',
        state: 'waiting_input',
        project: '/w/a1',
        host: 'mac-0',
        message: '승인 대기',
        occurredAt: clock,
        receivedAt: clock + 5,
      );

      final since = cursorForRequest(state);
      expect(since, isNotNull);
      state = reduceSync(
        state,
        server.delta(since: since!, serverTime: clock + 10),
        nowMs: clock + 10,
      );

      expect(sessionCores(state.sessions), sessionCores(server.sessions));
      expect(state.cursor, server.cursor);
      // 새 waiting_input 전이 하나가 알림 큐에 들어온다.
      expect(state.pendingAlerts.map((TransitionDto t) => t.toState), <String>[
        'waiting_input',
      ]);
    });

    test('reset은 로컬 상태를 통째로 갈아치우고 알림 큐를 비운다', () {
      final server = _scenario();
      final now = server.transitions.last.createdAt + _tick;
      final dirty = _applyAll(server, nowMs: now);
      expect(dirty.pendingAlerts, isNotEmpty);

      final replaced = reduceSync(
        dirty.copyWith(
          sessions: <String, SessionViewDto>{
            ...dirty.sessions,
            'ghost:zz': const SessionViewDto(key: 'ghost:zz', state: 'working'),
          },
        ),
        server.snapshot(serverTime: now),
        nowMs: now,
      );

      expect(replaced.sessions.containsKey('ghost:zz'), isFalse);
      expect(replaced.sessions, server.sessions);
      expect(replaced.pendingAlerts, isEmpty);
    });
  });

  group('(c) 중복 transition_id', () {
    final duplicate = TransitionDto(
      id: 7,
      sessionKey: 'claude-code:a1',
      fromState: 'working',
      toState: 'waiting_input',
      source: 'claude-code',
      project: '/w/a1',
      host: 'mac-0',
      message: '승인 대기',
      occurredAt: _base,
      createdAt: _base,
    );

    test('한 응답 안에 같은 id가 두 번 있어도 알림은 하나다', () {
      final state = reduceSync(
        const SyncState(cursor: 0),
        SyncResponseDto(
          cursor: 7,
          serverTime: _base,
          transitions: <TransitionDto>[duplicate, duplicate],
        ),
        nowMs: _base,
      );
      expect(state.pendingAlerts.length, 1);
      expect(state.sessions['claude-code:a1']?.state, 'waiting_input');
    });

    test('겹치는 since로 다시 받아도 알림이 늘지 않는다', () {
      const start = SyncState(cursor: 0);
      final first = reduceSync(
        start,
        SyncResponseDto(
          cursor: 7,
          serverTime: _base,
          transitions: <TransitionDto>[duplicate],
        ),
        nowMs: _base,
      );
      final again = reduceSync(
        first,
        SyncResponseDto(
          cursor: 7,
          serverTime: _base,
          transitions: <TransitionDto>[duplicate],
        ),
        nowMs: _base,
      );
      expect(again.pendingAlerts.length, 1);
      expect(again.alertWatermark, 7);
    });

    test('확인 처리한 알림은 재배달돼도 다시 쌓이지 않는다', () {
      final state = acknowledgeAlerts(
        reduceSync(
          const SyncState(cursor: 0),
          SyncResponseDto(
            cursor: 7,
            serverTime: _base,
            transitions: <TransitionDto>[duplicate],
          ),
          nowMs: _base,
        ),
        <int>[7],
      );
      expect(state.pendingAlerts, isEmpty);

      final redelivered = reduceSync(
        state,
        SyncResponseDto(
          cursor: 7,
          serverTime: _base,
          transitions: <TransitionDto>[duplicate],
        ),
        nowMs: _base,
      );
      expect(redelivered.pendingAlerts, isEmpty);
    });

    test('알림이 아닌 상태(working·idle)는 큐에 들어가지 않는다', () {
      final state = reduceSync(
        const SyncState(cursor: 0),
        SyncResponseDto(
          cursor: 2,
          serverTime: _base,
          transitions: <TransitionDto>[
            TransitionDto(
              id: 1,
              sessionKey: 'codex:b2',
              toState: 'idle',
              occurredAt: _base,
            ),
            TransitionDto(
              id: 2,
              sessionKey: 'codex:b2',
              toState: 'working',
              occurredAt: _base + 1,
            ),
          ],
        ),
        nowMs: _base,
      );
      expect(state.pendingAlerts, isEmpty);
      expect(state.sessions['codex:b2']?.state, 'working');
    });
  });

  group('(d) 첫 기동 10분 규칙', () {
    TransitionDto alertAt(int id, int occurredAt) => TransitionDto(
      id: id,
      sessionKey: 'claude-code:s$id',
      toState: 'waiting_input',
      source: 'claude-code',
      project: '/w/s$id',
      occurredAt: occurredAt,
      createdAt: occurredAt,
    );

    test('커서가 없으면 10분보다 오래된 전이는 알림 대상이 아니다', () {
      const now = _base;
      final state = reduceSync(
        const SyncState(),
        SyncResponseDto(
          cursor: 3,
          serverTime: now,
          transitions: <TransitionDto>[
            alertAt(1, now - const Duration(minutes: 15).inMilliseconds),
            alertAt(2, now - kFirstBootAlertWindow.inMilliseconds),
            alertAt(3, now - const Duration(minutes: 1).inMilliseconds),
          ],
        ),
        nowMs: now,
      );

      // 경계값(정확히 10분 전)은 포함한다.
      expect(state.pendingAlerts.map((TransitionDto t) => t.id), <int>[2, 3]);
      // 알림에서 잘린 전이도 상태 반영은 전부 한다.
      expect(state.sessions.length, 3);
      expect(state.sessions['claude-code:s1']?.state, 'waiting_input');
    });

    test('커서가 있으면 오래된 전이도 알림 대상이다', () {
      const now = _base;
      final state = reduceSync(
        const SyncState(cursor: 0),
        SyncResponseDto(
          cursor: 1,
          serverTime: now,
          transitions: <TransitionDto>[
            alertAt(1, now - const Duration(hours: 3).inMilliseconds),
          ],
        ),
        nowMs: now,
      );
      expect(state.pendingAlerts.length, 1);
    });

    test('스냅샷을 먼저 받으면 그 뒤 델타는 창 제한을 받지 않는다', () {
      const now = _base;
      final booted = reduceSync(
        const SyncState(),
        const SyncResponseDto(reset: true, cursor: 0, serverTime: now),
        nowMs: now,
      );
      expect(booted.isFirstBoot, isFalse);

      final state = reduceSync(
        booted,
        SyncResponseDto(
          cursor: 1,
          serverTime: now,
          transitions: <TransitionDto>[
            alertAt(1, now - const Duration(days: 1).inMilliseconds),
          ],
        ),
        nowMs: now,
      );
      expect(state.pendingAlerts.length, 1);
    });
  });

  group('(e) 손상 커서 복구', () {
    test('parseCursor는 쓸 수 있는 값만 통과시킨다', () {
      expect(parseCursor(42), 42);
      expect(parseCursor('42'), 42);
      expect(parseCursor(' 42 '), 42);
      expect(parseCursor(42.0), 42);
      expect(parseCursor(0), 0);
      expect(parseCursor(kMaxSafeCursor), kMaxSafeCursor);

      expect(parseCursor(null), isNull);
      expect(parseCursor(''), isNull);
      expect(parseCursor('abc'), isNull);
      expect(parseCursor('12abc'), isNull);
      expect(parseCursor(-1), isNull);
      expect(parseCursor(4.2), isNull);
      expect(parseCursor(double.nan), isNull);
      expect(parseCursor(double.infinity), isNull);
      expect(parseCursor(kMaxSafeCursor + 1), isNull);
      expect(parseCursor(true), isNull);
      expect(parseCursor(<String>['42']), isNull);
    });

    test('손상된 저장 커서는 스냅샷 요청으로 복구된다', () {
      final server = _scenario();
      final now = server.transitions.last.createdAt + _tick;

      final broken = restoreState(persistedCursor: '커서가 아니라 낙서');
      expect(broken.cursor, isNull);
      expect(cursorForRequest(broken), isNull);

      final recovered = reduceSync(
        broken,
        server.snapshot(serverTime: now),
        nowMs: now,
      );
      expect(recovered.sessions, server.sessions);
      expect(recovered.cursor, server.cursor);
      expect(cursorForRequest(recovered), server.cursor);
    });

    test('정리된 구간을 가리키는 커서는 스냅샷을 청한다', () {
      const state = SyncState(cursor: 5, prunedBelowId: 40);
      expect(cursorForRequest(state), isNull);

      const healthy = SyncState(cursor: 41, prunedBelowId: 40);
      expect(cursorForRequest(healthy), 41);
    });

    test('음수·초과 커서를 들고 있어도 스냅샷을 청한다', () {
      expect(cursorForRequest(const SyncState(cursor: -3)), isNull);
      expect(
        cursorForRequest(const SyncState(cursor: kMaxSafeCursor + 1)),
        isNull,
      );
    });
  });

  group('커서 단조성', () {
    test('델타 응답의 커서가 뒤로 가도 로컬 커서는 유지된다', () {
      final state = reduceSync(
        const SyncState(cursor: 100),
        const SyncResponseDto(cursor: 7, serverTime: _base),
        nowMs: _base,
      );
      expect(state.cursor, 100);
    });

    test('reset만이 커서를 낮출 수 있다(유일한 복구 경로)', () {
      final state = reduceSync(
        const SyncState(cursor: 100),
        const SyncResponseDto(reset: true, cursor: 7, serverTime: _base),
        nowMs: _base,
      );
      expect(state.cursor, 7);
    });

    test('reset 이하의 전이가 뒤늦게 배달돼도 알림이 되지 않는다', () {
      final booted = reduceSync(
        const SyncState(),
        const SyncResponseDto(reset: true, cursor: 50, serverTime: _base),
        nowMs: _base,
      );
      final late = reduceSync(
        booted,
        SyncResponseDto(
          cursor: 50,
          serverTime: _base,
          transitions: <TransitionDto>[
            TransitionDto(
              id: 30,
              sessionKey: 'codex:b2',
              toState: 'done',
              occurredAt: _base - 1000,
            ),
          ],
        ),
        nowMs: _base,
      );
      expect(late.pendingAlerts, isEmpty);
      expect(late.cursor, 50);
    });

    test('보존 경계(pruned_below_id)는 뒤로 가지 않는다', () {
      final state = reduceSync(
        const SyncState(cursor: 0, prunedBelowId: 90),
        const SyncResponseDto(cursor: 0, serverTime: _base),
        nowMs: _base,
      );
      expect(state.prunedBelowId, 90);
    });
  });

  group('occurred_at 역행 방어', () {
    test('과거 전이는 세션 상태를 되돌리지 못한다', () {
      final state = reduceSync(
        const SyncState(cursor: 0),
        SyncResponseDto(
          cursor: 2,
          serverTime: _base,
          transitions: <TransitionDto>[
            TransitionDto(
              id: 1,
              sessionKey: 'claude-code:a1',
              toState: 'done',
              occurredAt: _base + 5000,
            ),
            TransitionDto(
              id: 2,
              sessionKey: 'claude-code:a1',
              toState: 'working',
              occurredAt: _base,
            ),
          ],
        ),
        nowMs: _base,
      );
      expect(state.sessions['claude-code:a1']?.state, 'done');
      expect(state.sessions['claude-code:a1']?.lastOccurredAt, _base + 5000);
    });

    test('occurred_at이 같으면 전이 id가 큰 쪽이 이긴다', () {
      final state = reduceSync(
        const SyncState(cursor: 0),
        SyncResponseDto(
          cursor: 9,
          serverTime: _base,
          transitions: <TransitionDto>[
            TransitionDto(
              id: 9,
              sessionKey: 'claude-code:a1',
              toState: 'working',
              occurredAt: _base,
            ),
            TransitionDto(
              id: 8,
              sessionKey: 'claude-code:a1',
              toState: 'done',
              occurredAt: _base,
            ),
          ],
        ),
        nowMs: _base,
      );
      expect(state.sessions['claude-code:a1']?.state, 'working');
    });

    test('전이가 모르는 값(null)은 기존 세션 값을 지우지 않는다', () {
      const seeded = SyncState(
        cursor: 0,
        sessions: <String, SessionViewDto>{
          'codex:b2': SessionViewDto(
            key: 'codex:b2',
            state: 'working',
            source: 'codex',
            sessionId: 'b2',
            project: '/w/b2',
            host: 'mac-1',
            lastEvent: 'UserPromptSubmit',
            lastMessage: '앞선 문구',
            lastOccurredAt: _base,
          ),
        },
      );
      final state = reduceSync(
        seeded,
        SyncResponseDto(
          cursor: 1,
          serverTime: _base,
          transitions: <TransitionDto>[
            TransitionDto(
              id: 1,
              sessionKey: 'codex:b2',
              toState: 'done',
              source: 'codex',
              occurredAt: _base + 1,
            ),
          ],
        ),
        nowMs: _base,
      );
      final session = state.sessions['codex:b2']!;
      expect(session.state, 'done');
      expect(session.host, 'mac-1');
      expect(session.lastMessage, '앞선 문구');
      expect(session.project, '/w/b2');
      // 이벤트 이름은 전이 로그에 없다 - 스냅샷이 채운 값을 유지한다.
      expect(session.lastEvent, 'UserPromptSubmit');
    });
  });

  group('Opus escalation 판정 E 리뷰 지적(high) 수정: lastProgressAt은 전이마다 서버 시계로 밀린다', () {
    // 배경: session_card.dart의 stale 배지·last_signal 라벨은 lastProgressAt과
    // serverTime(둘 다 서버 시계)만 비교한다(교차 시계 오염 방지). 그런데 리듀서가
    // lastProgressAt을 갱신하지 않으면, 델타로만 세션을 받는 흔한 경로(sync.ts는 델타
    // 응답에 sessions를 담지 않는다 - reset일 때만 세션 객체가 내려온다)에서 그 값이
    // 스냅샷 당시 시각에 영원히 얼어붙는다. 전이는 정의상 상태를 바꾼 이벤트 = 진척이고
    // `transition.createdAt`은 서버 수신 시각이라, 계약의 last_progress_at 정의와 그대로
    // 맞는다.
    test('전이만으로 새로 만든 세션은 전이의 createdAt(서버 수신 시각)을 lastProgressAt으로 갖는다', () {
      final state = reduceSync(
        const SyncState(cursor: 0),
        SyncResponseDto(
          cursor: 1,
          serverTime: _base,
          transitions: <TransitionDto>[
            TransitionDto(
              id: 1,
              sessionKey: 'claude-code:new1',
              toState: 'working',
              occurredAt: _base,
              createdAt: _base + 500,
            ),
          ],
        ),
        nowMs: _base,
      );
      expect(state.sessions['claude-code:new1']?.lastProgressAt, _base + 500);
    });

    test('기존 세션에 전이가 이어지면 lastProgressAt이 그 전이의 createdAt으로 밀린다', () {
      const seeded = SyncState(
        cursor: 0,
        sessions: <String, SessionViewDto>{
          'claude-code:c1': SessionViewDto(
            key: 'claude-code:c1',
            state: 'working',
            source: 'claude-code',
            sessionId: 'c1',
            lastOccurredAt: _base,
            lastProgressAt: _base,
          ),
        },
      );
      final state = reduceSync(
        seeded,
        SyncResponseDto(
          cursor: 1,
          serverTime: _base + 9000,
          transitions: <TransitionDto>[
            TransitionDto(
              id: 1,
              sessionKey: 'claude-code:c1',
              toState: 'done',
              occurredAt: _base + 8000,
              createdAt: _base + 9000,
            ),
          ],
        ),
        nowMs: _base + 9000,
      );
      // 델타 경로는 sync.ts가 sessions를 내려주지 않는 정상 경로다 - 리듀서가 전이만으로
      // lastProgressAt을 밀지 않으면 이 값이 스냅샷 당시(_base)에 영원히 얼어붙는다(회귀).
      expect(state.sessions['claude-code:c1']?.lastProgressAt, _base + 9000);
    });

    test('lastProgressAt은 뒤로 가지 않는다(도착 순서와 무관하게 max)', () {
      const seeded = SyncState(
        cursor: 0,
        sessions: <String, SessionViewDto>{
          'claude-code:c2': SessionViewDto(
            key: 'claude-code:c2',
            state: 'working',
            source: 'claude-code',
            sessionId: 'c2',
            lastOccurredAt: _base,
            lastProgressAt: _base + 5000,
          ),
        },
      );
      // 같은 응답 안에서 id 오름차순으로 정렬돼 적용되지만(파일 상단 불변식), createdAt
      // 자체는 그 전이보다 작을 수 있다 - 그래도 기존 lastProgressAt보다 뒤로는 가지 않는다.
      final state = reduceSync(
        seeded,
        SyncResponseDto(
          cursor: 2,
          serverTime: _base + 5000,
          transitions: <TransitionDto>[
            TransitionDto(
              id: 2,
              sessionKey: 'claude-code:c2',
              toState: 'done',
              occurredAt: _base + 6000,
              createdAt: _base + 1000, // 기존 lastProgressAt(_base+5000)보다 과거
            ),
          ],
        ),
        nowMs: _base + 5000,
      );
      expect(state.sessions['claude-code:c2']?.lastProgressAt, _base + 5000);
    });
  });

  group('상태 편의 API', () {
    test('activeSessions는 종료된 세션을 뺀다', () {
      final server = _scenario();
      final now = server.transitions.last.createdAt + _tick;
      final state = _applyAll(server, nowMs: now);
      expect(
        state.sessions.values.where((SessionViewDto s) => s.isEnded),
        isNotEmpty,
      );
      expect(
        state.activeSessions.where((SessionViewDto s) => s.isEnded),
        isEmpty,
      );
    });

    test('acknowledgeAllAlerts는 큐만 비운다', () {
      final server = _scenario();
      final now = server.transitions.last.createdAt + _tick;
      final state = _applyAll(server, nowMs: now);
      final cleared = acknowledgeAllAlerts(state);
      expect(cleared.pendingAlerts, isEmpty);
      expect(cleared.sessions, state.sessions);
      expect(cleared.cursor, state.cursor);
    });

    test('has_more는 즉시 재요청 신호로 남는다', () {
      final server = _scenario();
      final now = server.transitions.last.createdAt + _tick;
      final page = server.delta(since: 0, serverTime: now, limit: 3);
      final state = reduceSync(const SyncState(cursor: 0), page, nowMs: now);
      expect(state.shouldFetchAgain, isTrue);
      expect(state.cursor, 3);
    });

    test('음소거 구간 판정은 서버 시각 기준이다', () {
      final state = reduceSync(
        const SyncState(cursor: 0),
        const SyncResponseDto(
          cursor: 0,
          serverTime: _base,
          muteUntil: _base + 60000,
        ),
        nowMs: _base,
      );
      expect(state.isMuted(_base), isTrue);
      expect(state.isMuted(_base + 60001), isFalse);
    });

    test('서버가 음소거를 풀면(null) 로컬 값도 지워진다', () {
      final muted = reduceSync(
        const SyncState(cursor: 0),
        const SyncResponseDto(
          cursor: 0,
          serverTime: _base,
          muteUntil: _base + 60000,
        ),
        nowMs: _base,
      );
      final cleared = reduceSync(
        muted,
        const SyncResponseDto(cursor: 0, serverTime: _base),
        nowMs: _base,
      );
      expect(cleared.muteUntil, isNull);
      expect(cleared.isMuted(_base), isFalse);
    });

    test('알림 큐는 상한을 넘지 않는다(가장 오래된 것부터 버린다)', () {
      final flood = <TransitionDto>[
        // 이 테스트의 본질은 "상한·오래된 것부터 버리기"이지 어떤 상태가
        // 알림인지가 아니다 - 여전히 알림 대상인 상태(waiting_input)를 쓴다.
        // `done`은 2026-09-14(Sol 확정)부터 push_states가 아니라 pendingAlerts가
        // 비어 이 테스트가 성립하지 않는다.
        for (var i = 1; i <= kMaxPendingAlerts + 25; i++)
          TransitionDto(
            id: i,
            sessionKey: 'generic:s$i',
            toState: 'waiting_input',
            occurredAt: _base + i,
          ),
      ];
      final state = reduceSync(
        const SyncState(cursor: 0),
        SyncResponseDto(
          cursor: flood.last.id,
          serverTime: _base,
          transitions: flood,
        ),
        nowMs: _base,
      );
      expect(state.pendingAlerts.length, kMaxPendingAlerts);
      expect(state.pendingAlerts.first.id, 26);
      expect(state.pendingAlerts.last.id, flood.last.id);
    });
  });
}
