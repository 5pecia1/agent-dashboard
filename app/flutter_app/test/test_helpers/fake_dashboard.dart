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
/// (두 테스트 파일(unit_tests/sync_reducer_test.dart와
/// unit_tests/sync_reducer_title_test.dart)이 함께 쓰게 되어 추출했다 - 이
/// 디렉터리의 README가 정한 "두 번 이상 반복되면 그때 추출한다" 규칙을 따른다.)
library;

import 'package:my_dashboard/src/data/dashboard_dto.dart';

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
    String? displayTitle,
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
            displayTitle: displayTitle,
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
            displayTitle: displayTitle,
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
        displayTitle: displayTitle,
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
