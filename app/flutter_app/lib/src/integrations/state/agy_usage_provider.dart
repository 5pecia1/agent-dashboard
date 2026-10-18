import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/integrations/data/agy_usage_api.dart';
import 'package:my_dashboard/src/integrations/data/agy_usage_models.dart';
import 'package:my_dashboard/src/integrations/platform/agy_usage.dart';

const Duration kAgyUsagePollInterval = Duration(seconds: 60);
final agyUsageSupportedProvider = Provider<bool>(
  (ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS,
);
final agyInitialEnabledProvider = Provider<bool>((ref) => false);
final agyUsageFetchProvider = Provider<Future<AgyUsageReading> Function()>(
  (ref) => fetchInstalledAgyUsage,
);

class AgyUsageState {
  const AgyUsageState({
    this.enabled = false,
    this.reading,
    this.updatedAt,
    this.errorKey,
    this.loading = false,
  });
  final bool enabled;
  final AgyUsageReading? reading;
  final DateTime? updatedAt;
  final String? errorKey;
  final bool loading;
}

final agyUsageControllerProvider =
    NotifierProvider<AgyUsageController, AgyUsageState>(AgyUsageController.new);

class AgyUsageController extends Notifier<AgyUsageState> {
  Timer? _timer;
  int _generation = 0;
  int _pendingGeneration = 0;
  bool _active = true;
  bool _disposed = false;
  bool _blocked = false;
  Future<void>? _pending;

  @override
  AgyUsageState build() {
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      _timer?.cancel();
    });
    final enabled =
        ref.read(agyInitialEnabledProvider) &&
        ref.read(agyUsageSupportedProvider);
    if (enabled) _timer = Timer(Duration.zero, refresh);
    return AgyUsageState(enabled: enabled);
  }

  void configure(bool enabled) {
    _generation++;
    _blocked = false;
    _timer?.cancel();
    state = AgyUsageState(
      enabled: enabled && ref.read(agyUsageSupportedProvider),
    );
    if (state.enabled) unawaited(refresh(userInitiated: true));
  }

  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    _timer?.cancel();
    if (active && !_blocked) unawaited(refresh());
  }

  Future<void> refresh({bool userInitiated = false}) {
    if (_disposed || !state.enabled) return Future.value();
    if (userInitiated) _blocked = false;
    if (_pending != null) {
      // Toggling off/on discards the old result but still waits for its process.
      if (_pendingGeneration != _generation) {
        return _pending!.then((_) => refresh(userInitiated: userInitiated));
      }
      return _pending!;
    }
    _timer?.cancel();
    final previous = state;
    final generation = _generation;
    _pendingGeneration = generation;
    state = AgyUsageState(
      enabled: true,
      reading: previous.reading,
      updatedAt: previous.updatedAt,
      errorKey: previous.errorKey,
      loading: true,
    );
    return _pending = Future<void>.microtask(
      () => _fetch(generation, previous),
    );
  }

  Future<void> _fetch(int generation, AgyUsageState previous) async {
    try {
      final reading = await ref.read(agyUsageFetchProvider)();
      if (_disposed || generation != _generation) return;
      _blocked = false;
      state = AgyUsageState(
        enabled: true,
        reading: reading,
        updatedAt: DateTime.now(),
      );
    } catch (error) {
      if (_disposed || generation != _generation) return;
      final failure = error is AgyUsageFailure
          ? error
          : const AgyUsageFailure('agy.query_failed');
      _blocked = failure.blocksPolling;
      state = AgyUsageState(
        enabled: true,
        reading: previous.reading,
        updatedAt: previous.updatedAt,
        errorKey: failure.labelKey,
      );
    } finally {
      _pending = null;
      if (!_disposed && generation == _generation && _active && !_blocked) {
        _timer = Timer(kAgyUsagePollInterval, refresh);
      }
    }
  }
}
