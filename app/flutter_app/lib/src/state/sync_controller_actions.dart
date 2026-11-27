part of 'sync_controller.dart';

@immutable
class SessionDeletionResult {
  const SessionDeletionResult({
    required this.deletedCount,
    required this.failedCount,
    this.connectionChanged = false,
  });

  final int deletedCount;
  final int failedCount;
  final bool connectionChanged;
}

/// 서버 세션에 대한 사용자 액션과 낙관적 상태 변경.
mixin SyncControllerActions on Notifier<SyncControllerState> {
  int get _connectionRevision =>
      ref.read(dashboardApiConfigControllerProvider.notifier).revision;

  /// UserAck-impl: `StateChip`이 `waiting_input` 카드에서 탭됐을 때 부른다
  /// (정본 `client_actions.UserAck`, `POST /dashboard/sessions/{key}/ack`).
  ///
  /// **낙관 갱신 정합.** 요청을 기다리지 않고 즉시 [kDashboardStateWorking]로
  /// 보여준다 — 사람이 방금 응답을 마쳤다는 확신이 있어야 누른 것이므로,
  /// 왕복 지연 동안 칩이 그대로 `waiting_input`이면 "눌렀는데 안 먹었나"로
  /// 보인다. 응답이 오면 [AckResultDto.state]로 그대로 덮어써 정합을
  /// 맞춘다 — 서버가 실제로 전이했으면 그 값도 `working`이라 눈에 띄는
  /// 변화가 없고, guard에 걸려 no-op이었으면(이미 다른 기기가 먼저
  /// 응답했거나 세션 상태가 바뀜) 그 응답의 [AckResultDto.state]가 곧
  /// 되돌리기 전 실제 현재 상태라 이 한 줄이 "되돌리기"까지 함께 구현한다 —
  /// 별도 분기가 필요 없다. 요청 자체가 실패하면(네트워크·서버 오류) 그
  /// 응답이 아예 없으니 [previous]로 직접 되돌리고, `_afterFailure`와 같은
  /// [SyncErrorInfo.fromError]로 [SyncControllerState.lastError]를 채운다 —
  /// 이 파일 밖에 SnackBar 같은 별도 오류 표시 관례가 없고
  /// (`sessions_page.dart`의 `StaleDataBanner`가 이 필드를 그린다), 그게 곧
  /// "기존 오류 표시 관례"다.
  ///
  /// [AckResultDto.state]가 null이거나(세션이 아예 없어졌다 — 카드는 낙관
  /// 갱신이 남긴 `working`인 채로 아직 화면에 있을 수 있다) [kDashboardStates]
  /// 밖의 값이면(검증 리뷰 지적 medium 수정) 그 값으로 덮어쓰지 않고
  /// [previous]로 되돌린다 — 예전에는 `AckResultDto.state`가
  /// `@Default('')`라 null이 빈 문자열로 접혔고, 빈 문자열은
  /// `sessionStateDtoFromCode`(dashboard_provider.dart)의 미인식 코드 폴백을 타 화면에
  /// 가짜 `idle` 배지로 영구히 남았다(롤백도 오류 표시도 없이) — 이 분기가
  /// 그 회귀를 없앤다.
  ///
  /// 두 지점 다 `sync`가 아직 그 [key]를 들고 있을 때만 손댄다 — 낙관 갱신을
  /// 시작한 사이 진짜 폴링이 세션을 맵에서 지웠다면(예: 세션 종료) 되살릴
  /// 이유가 없다.
  Future<void> ackSession(String key) async {
    final previous = state.sync.sessions[key];
    if (previous == null) return;
    final revision = _connectionRevision;
    _patchSessionState(key, kDashboardStateWorking);
    final nowMsFn = ref.read(syncNowMsFnProvider);
    try {
      final api = ref.read(dashboardApiProvider);
      final result = await api.ack(key);
      if (_connectionRevision != revision) return;
      final resolvedState = result.state;
      final isRecognizedState =
          resolvedState != null && kDashboardStates.contains(resolvedState);
      _patchSessionState(
        key,
        isRecognizedState ? resolvedState : previous.state,
      );
      // seen 연동(0004, 읽음 계약): ack가 실제로 전이를 만들었으면
      // (transitionId != null) 그 전이 자체가 방금 사람이 처리했다는
      // 사실이다 — 서버(ack 라우트)도 같은 자리에서 그 세션의
      // seen_transition_id를 그 전이 id로 단조 갱신한다. 여기서 미리
      // 반영해 두지 않으면, 이 응답과 다음 정상 폴링 사이 짧은 틈에 카드가
      // "자기 자신의 ack 전이" 때문에 다시 미확인으로 반짝인다. 세션
      // 객체가 아니라 `SyncState.seenTransitionIds` 맵을 MAX로 올린다
      // ([_bumpSeen] 참고).
      if (result.transitionId != null) {
        _bumpSeen(key, result.transitionId!);
      }
    } catch (error) {
      if (_connectionRevision != revision) return;
      _patchSessionState(key, previous.state);
      state = state.copyWith(
        lastError: SyncErrorInfo.fromError(error, atMs: nowMsFn()),
      );
    }
  }

  /// 읽음 처리(0004 seen 기능) — `session_detail_page.dart`가 화면 진입
  /// (`initState`) 시 정확히 한 번 부른다.
  ///
  /// **실패 무해.** ack와 달리 이 액션은 "상태가 변했는가"와 무관한 순수
  /// UI 편의 표시(미확인 점)라, 오케스트레이터 사양이 명시적으로 실패를
  /// 화면에 드러내지 말라고 한다 — [SyncControllerState.lastError]를 절대
  /// 건드리지 않고 조용히 삼킨다. 세션이 이미 맵에 없으면(예: 그 사이 삭제)
  /// 아무것도 하지 않는다.
  ///
  /// 낙관 갱신: 요청을 기다리지 않고 이 세션의 `SyncState.
  /// seenTransitionIds`를 이미 알고 있는 [SessionViewDto.lastTransitionId]로
  /// 즉시 올려([_bumpSeen]) 화면의 미확인 점을 바로 끈다. 서버 응답이 오면
  /// 그 값(뒤늦게 도착한 더 최신 전이가 있었을 수 있어 서버가 최종
  /// 권위자다)으로 다시 한 번 정합을 맞춘다 — 둘 다 MAX 적용이라 서버 값이
  /// 더 작아도(있을 수 없지만) 로컬을 낮추지 않는다.
  Future<void> markSeen(String key) async {
    final session = state.sync.sessions[key];
    if (session == null) return;
    final lastTransitionId = session.lastTransitionId;
    if (lastTransitionId != null) {
      await markSeenThrough(key, lastTransitionId);
      return;
    }
    final revision = _connectionRevision;
    try {
      final seen = await ref.read(dashboardApiProvider).markSeen(key);
      if (_connectionRevision != revision) return;
      if (seen != null) _bumpSeen(key, seen);
    } catch (_) {
      // Read markers never block navigation.
    }
  }

  /// A tray row captures its watermark when the menu opens. Do not acknowledge
  /// newer transitions that arrive while the user chooses an external window.
  Future<void> markSeenThrough(String key, int transitionId) async {
    // A delivered banner may be opened before the first session sync. Its
    // explicit watermark is safe to submit without guessing the current state.
    if (transitionId <= 0) return;
    final revision = _connectionRevision;
    _bumpSeen(key, transitionId);
    try {
      final seen = await ref
          .read(dashboardApiProvider)
          .markSeen(key, lastTransitionId: transitionId);
      if (_connectionRevision != revision) return;
      if (seen != null) _bumpSeen(key, seen);
    } catch (_) {
      // Preserve the existing optimistic, nonblocking marker semantics.
    }
  }

  Future<bool> deleteSession(String key) async {
    if (!state.sync.sessions.containsKey(key)) return false;
    final result = await _deleteSessions(
      {key},
      _connectionRevision,
      (api) => api.deleteSession(key),
    );
    return result.deletedCount == 1;
  }

  /// 확인창을 열 때 고정한 키를 한 번의 요청으로 삭제한다.
  Future<SessionDeletionResult> deleteSessions(
    Iterable<String> keys, {
    required int expectedConnectionRevision,
  }) {
    final targets = keys.toSet();
    return _deleteSessions(
      targets,
      expectedConnectionRevision,
      (api) => api.deleteSessions(targets),
    );
  }

  Future<SessionDeletionResult> _deleteSessions(
    Set<String> targets,
    int revision,
    Future<void> Function(DashboardApi) send,
  ) async {
    const connectionChanged = SessionDeletionResult(
      deletedCount: 0,
      failedCount: 0,
      connectionChanged: true,
    );
    if (_connectionRevision != revision) return connectionChanged;
    if (targets.isEmpty) {
      return const SessionDeletionResult(deletedCount: 0, failedCount: 0);
    }
    final previous = {
      for (final key in targets) key: ?state.sync.sessions[key],
    };
    final alertIds = {
      for (final alert in state.sync.pendingAlerts)
        if (targets.contains(alert.sessionKey)) alert.id,
    };
    final nowMsFn = ref.read(syncNowMsFnProvider);
    state = state.copyWith(
      sync: state.sync.copyWith(
        sessions: Map.unmodifiable({
          for (final entry in state.sync.sessions.entries)
            if (!targets.contains(entry.key)) entry.key: entry.value,
        }),
      ),
    );
    try {
      if (_connectionRevision != revision) return connectionChanged;
      await send(ref.read(dashboardApiProvider));
    } catch (error) {
      if (_connectionRevision != revision) return connectionChanged;
      // 요청 중 같은 키에 새 활동이 도착했다면 최신 세션을 유지한다.
      state = state.copyWith(
        sync: state.sync.copyWith(
          sessions: Map.unmodifiable({...previous, ...state.sync.sessions}),
        ),
        lastError: SyncErrorInfo.fromError(error, atMs: nowMsFn()),
      );
      return SessionDeletionResult(
        deletedCount: 0,
        failedCount: targets.length,
      );
    }
    if (_connectionRevision != revision) return connectionChanged;
    ref.invalidate(promptHistoryProvider);
    state = state.copyWith(
      sync: state.sync.copyWith(
        pendingAlerts: state.sync.pendingAlerts
            .where((alert) => !alertIds.contains(alert.id))
            .toList(growable: false),
      ),
    );
    return SessionDeletionResult(deletedCount: targets.length, failedCount: 0);
  }

  /// [ackSession]이 낙관 갱신·성공 반영·실패 되돌리기 세 자리에서 공유하는
  /// 세션 맵 patch. 리듀서를 다시 돌리지 않고 그 세션 한 칸의 [SessionViewDto.
  /// state]만 바꾼다 — 그 밖의 필드(예: `lastProgressAt`)는 다음 정상 폴링이
  /// 채우므로 여기서 추정해 채우지 않는다.
  void _patchSessionState(String key, String newState) {
    _updateSession(key, (current) => current.copyWith(state: newState));
  }

  /// [_patchSessionState]/[markSeen]/[ackSession]이 공유하는 더 일반적인
  /// patch — 세션 맵의 한 칸을 [update]로 바꿔 넣는다. 그 키가 이미 맵에
  /// 없으면(예: 그 사이 폴링이나 삭제로 사라짐) 아무것도 하지 않는다.
  void _updateSession(
    String key,
    SessionViewDto Function(SessionViewDto current) update,
  ) {
    final current = state.sync.sessions[key];
    if (current == null) return;
    final patched = Map<String, SessionViewDto>.of(state.sync.sessions)
      ..[key] = update(current);
    state = state.copyWith(
      sync: state.sync.copyWith(
        sessions: Map<String, SessionViewDto>.unmodifiable(patched),
      ),
    );
  }

  /// [ackSession]/[markSeen]이 공유하는 seen 맵 patch(읽음 계약).
  ///
  /// `SyncState.seenTransitionIds[key]`를 [candidate]와 **MAX**로 올린다 —
  /// `sync_reducer.dart`의 `reduceSync`가 `response.seen`을 병합할 때 쓰는
  /// 규칙과 정확히 같다. 낙관 갱신이 이미 세운 값을, 그 갱신을 아직 반영
  /// 하지 못한 채 뒤늦게 도착한 서버 값이 되돌리는 일이 없다(깜빡임 방지).
  /// [candidate]가 기존 값 이하면 아무것도 하지 않는다(불필요한 리빌드
  /// 방지).
  void _bumpSeen(String key, int candidate) {
    final current = state.sync.seenTransitionIds[key] ?? 0;
    if (candidate <= current) return;
    final patched = Map<String, int>.of(state.sync.seenTransitionIds)
      ..[key] = candidate;
    state = state.copyWith(
      sync: state.sync.copyWith(
        seenTransitionIds: Map<String, int>.unmodifiable(patched),
      ),
    );
  }
}
