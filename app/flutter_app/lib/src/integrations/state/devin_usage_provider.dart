import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_api.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_models.dart';

const Duration kDevinUsagePollInterval = Duration(seconds: 30);

final devinInitialConnectionProvider = Provider<DevinConnection?>(
  (ref) => null,
);
final devinUsageApiProvider = Provider(
  (ref) => DevinUsageApi(ref.watch(httpSendProvider)),
);

class DevinUsageState {
  const DevinUsageState({
    this.connection,
    this.quota,
    this.updatedAt,
    this.errorKey,
    this.loading = false,
  });
  final DevinConnection? connection;
  final DevinQuota? quota;
  final DateTime? updatedAt;
  final String? errorKey;
  final bool loading;
}

final devinUsageControllerProvider =
    NotifierProvider<DevinUsageController, DevinUsageState>(
      DevinUsageController.new,
    );

/// TeamClaudeController와 같은 생애주기다 — 화면 활성 동안 30초 폴링하고,
/// 인증 실패는 정기 재시도를 멈춰 설정 저장이나 수동 새로고침으로만 다시
/// 연다.
class DevinUsageController extends Notifier<DevinUsageState> {
  Timer? _timer;
  int _generation = 0;
  bool _active = true;
  bool _disposed = false;
  Future<void>? _pending;

  @override
  DevinUsageState build() {
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      _timer?.cancel();
    });
    final connection = ref.read(devinInitialConnectionProvider);
    if (connection != null) _timer = Timer(Duration.zero, refresh);
    return DevinUsageState(connection: connection);
  }

  void configure(DevinConnection? connection) {
    _generation++;
    _pending = null;
    _timer?.cancel();
    state = DevinUsageState(connection: connection);
    if (connection != null) unawaited(refresh());
  }

  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    _timer?.cancel();
    if (active && state.errorKey != 'devin.unauthorized') {
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
    state = DevinUsageState(
      connection: connection,
      quota: previous.quota,
      updatedAt: previous.updatedAt,
      errorKey: previous.errorKey,
      loading: true,
    );
    return _pending = _fetch(connection, generation, previous);
  }

  Future<void> _fetch(
    DevinConnection connection,
    int generation,
    DevinUsageState previous,
  ) async {
    try {
      final quota = await ref
          .read(devinUsageApiProvider)
          .userStatus(connection);
      if (_disposed || generation != _generation) return;
      state = DevinUsageState(
        connection: connection,
        quota: quota,
        updatedAt: DateTime.now(),
      );
    } catch (error) {
      if (_disposed || generation != _generation) return;
      state = DevinUsageState(
        connection: connection,
        quota: previous.quota,
        updatedAt: previous.updatedAt,
        errorKey: error is DevinUsageFailure
            ? error.labelKey
            : 'devin.network_error',
      );
    } finally {
      if (!_disposed && generation == _generation) {
        _pending = null;
        if (_active && state.errorKey != 'devin.unauthorized') {
          _timer = Timer(kDevinUsagePollInterval, refresh);
        }
      }
    }
  }
}
