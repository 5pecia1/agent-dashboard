import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_api.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_models.dart';

const Duration kTeamClaudePollInterval = Duration(seconds: 30);

final teamClaudeInitialConnectionProvider = Provider<TeamClaudeConnection?>(
  (ref) => null,
);
final teamClaudeApiProvider = Provider(
  (ref) => TeamClaudeApi(ref.watch(httpSendProvider)),
);

class TeamClaudeState {
  const TeamClaudeState({
    this.connection,
    this.snapshot,
    this.updatedAt,
    this.errorKey,
    this.loading = false,
  });
  final TeamClaudeConnection? connection;
  final TeamClaudeSnapshot? snapshot;
  final DateTime? updatedAt;
  final String? errorKey;
  final bool loading;
}

final teamClaudeControllerProvider =
    NotifierProvider<TeamClaudeController, TeamClaudeState>(
      TeamClaudeController.new,
    );

class TeamClaudeController extends Notifier<TeamClaudeState> {
  Timer? _timer;
  int _generation = 0;
  bool _active = true;
  bool _disposed = false;
  Future<void>? _pending;

  @override
  TeamClaudeState build() {
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      _timer?.cancel();
    });
    final connection = ref.read(teamClaudeInitialConnectionProvider);
    if (connection != null) _timer = Timer(Duration.zero, refresh);
    return TeamClaudeState(connection: connection);
  }

  void configure(TeamClaudeConnection? connection) {
    _generation++;
    _pending = null;
    _timer?.cancel();
    state = TeamClaudeState(connection: connection);
    if (connection != null) unawaited(refresh());
  }

  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    _timer?.cancel();
    if (active && state.errorKey != 'teamclaude.unauthorized') {
      unawaited(refresh());
    }
  }

  Future<void> refresh() {
    if (_disposed || state.connection == null) return Future.value();
    if (_pending != null) return _pending!;
    _timer?.cancel();
    final generation = _generation;
    final connection = state.connection!;
    final previous = state;
    state = TeamClaudeState(
      connection: connection,
      snapshot: previous.snapshot,
      updatedAt: previous.updatedAt,
      errorKey: previous.errorKey,
      loading: true,
    );
    return _pending = _fetch(connection, generation, previous);
  }

  Future<void> _fetch(
    TeamClaudeConnection connection,
    int generation,
    TeamClaudeState previous,
  ) async {
    try {
      final snapshot = await ref.read(teamClaudeApiProvider).status(connection);
      if (_disposed || generation != _generation) return;
      state = TeamClaudeState(
        connection: connection,
        snapshot: snapshot,
        updatedAt: DateTime.now(),
      );
    } catch (error) {
      if (_disposed || generation != _generation) return;
      state = TeamClaudeState(
        connection: connection,
        snapshot: previous.snapshot,
        updatedAt: previous.updatedAt,
        errorKey: error is TeamClaudeFailure
            ? error.labelKey
            : 'teamclaude.network_error',
      );
    } finally {
      if (!_disposed && generation == _generation) {
        _pending = null;
        if (_active && state.errorKey != 'teamclaude.unauthorized') {
          _timer = Timer(kTeamClaudePollInterval, refresh);
        }
      }
    }
  }
}
