import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_history.dart';

const int kPromptHistoryBatchPages = 5;
const int kPromptHistoryBatchSize = kHistoryPageSize * kPromptHistoryBatchPages;

@immutable
class PromptHistoryState {
  PromptHistoryState({
    List<DashboardHistoryEvent> events = const <DashboardHistoryEvent>[],
    this.hasMore = false,
    this.nextBeforeId,
    this.loadingMore = false,
    this.refreshing = false,
    this.error,
    this.scannedCount = 0,
    this.lastRefreshedAt,
  }) : events = List<DashboardHistoryEvent>.unmodifiable(events);

  final List<DashboardHistoryEvent> events;
  final bool hasMore;
  final int? nextBeforeId;
  final bool loadingMore;
  final bool refreshing;
  final Object? error;
  final int scannedCount;
  final int? lastRefreshedAt;
}

final promptHistoryProvider =
    AsyncNotifierProvider<PromptHistoryController, PromptHistoryState>(
      PromptHistoryController.new,
    );

class PromptHistoryController extends AsyncNotifier<PromptHistoryState> {
  int _generation = 0;
  Future<void>? _pending;
  DashboardApi? _api;

  @override
  PromptHistoryState build() {
    // Synchronous empty state prevents AsyncNotifier's previous-value retention
    // from displaying history from a different server while its request runs.
    final generation = ++_generation;
    _pending = null;
    _api = null;
    ref.onDispose(() {
      _generation++;
      _pending = null;
      _api = null;
    });
    try {
      ref.watch(dashboardApiConfigProvider);
      _api = ref.watch(dashboardApiProvider);
    } catch (error) {
      return PromptHistoryState(error: error);
    }
    scheduleMicrotask(() {
      if (ref.mounted && generation == _generation) unawaited(refresh());
    });
    return PromptHistoryState(refreshing: true);
  }

  Future<void> refresh() {
    if (!ref.mounted) return Future<void>.value();
    if (_pending != null) return _pending!;
    final previous = state.value ?? PromptHistoryState();
    state = AsyncData(_copy(previous, refreshing: true));
    return _startLoad(previous, append: false);
  }

  Future<void> loadOlder() {
    if (!ref.mounted) return Future<void>.value();
    if (_pending != null) return _pending!;
    final previous = state.value;
    if (previous == null || !previous.hasMore) return Future<void>.value();
    state = AsyncData(_copy(previous, loadingMore: true));
    return _startLoad(previous, append: true);
  }

  Future<void> _startLoad(PromptHistoryState previous, {required bool append}) {
    final generation = _generation;
    late final Future<void> pending;
    pending = _load(previous, append: append, generation: generation)
        .whenComplete(() {
          if (ref.mounted &&
              generation == _generation &&
              identical(_pending, pending)) {
            _pending = null;
          }
        });
    _pending = pending;
    return pending;
  }

  Future<void> _load(
    PromptHistoryState previous, {
    required bool append,
    required int generation,
  }) async {
    try {
      ref.read(dashboardApiConfigProvider);
      final api = _api ?? ref.read<DashboardApi>(dashboardApiProvider);
      _api = api;
      final batch = await _fetchBatch(
        api,
        beforeId: append ? previous.nextBeforeId : null,
        generation: generation,
      );
      if (!ref.mounted || generation != _generation) return;
      final events = <int, DashboardHistoryEvent>{
        if (append)
          for (final event in previous.events) event.id: event,
        for (final event in batch.events) event.id: event,
      };
      state = AsyncData(
        PromptHistoryState(
          events: events.values.toList(),
          hasMore: batch.hasMore,
          nextBeforeId: batch.nextBeforeId,
          scannedCount:
              (append ? previous.scannedCount : 0) + batch.scannedCount,
          lastRefreshedAt: append
              ? previous.lastRefreshedAt
              : DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (error) {
      if (!ref.mounted || generation != _generation) return;
      state = AsyncData(_copy(previous, error: error));
    }
  }

  Future<PromptHistoryState> _fetchBatch(
    DashboardApi api, {
    int? beforeId,
    required int generation,
  }) async {
    final events = <DashboardHistoryEvent>[];
    var cursor = beforeId;
    var hasMore = false;
    var scannedCount = 0;
    for (var pageIndex = 0; pageIndex < kPromptHistoryBatchPages; pageIndex++) {
      final page = await api.history(promptsOnly: true, beforeId: cursor);
      if (!ref.mounted || generation != _generation) break;
      _validateCursor(page, cursor);
      scannedCount += page.events.length;
      // Older servers may ignore the kind filter; keep input-role filtering
      // here as well as in the pure analyzer instead of trusting the request.
      events.addAll(page.events.where((event) => event.isUserPrompt));
      hasMore = page.hasMore;
      cursor = page.nextBeforeId;
      if (!hasMore) break;
    }
    return PromptHistoryState(
      events: events,
      hasMore: hasMore,
      nextBeforeId: cursor,
      scannedCount: scannedCount,
    );
  }

  void _validateCursor(DashboardHistoryPage page, int? beforeId) {
    final next = page.nextBeforeId;
    if (page.hasMore &&
        (page.events.isEmpty ||
            next == null ||
            next <= 0 ||
            next != page.events.last.id ||
            (beforeId != null && next >= beforeId))) {
      throw const FormatException('Prompt history cursor did not advance');
    }
    var previousId = beforeId;
    for (final event in page.events) {
      if (event.id <= 0 || (previousId != null && event.id >= previousId)) {
        throw const FormatException('Prompt history page is not descending');
      }
      previousId = event.id;
    }
  }

  PromptHistoryState _copy(
    PromptHistoryState previous, {
    bool refreshing = false,
    bool loadingMore = false,
    Object? error,
  }) => PromptHistoryState(
    events: previous.events,
    hasMore: previous.hasMore,
    nextBeforeId: previous.nextBeforeId,
    scannedCount: previous.scannedCount,
    lastRefreshedAt: previous.lastRefreshedAt,
    refreshing: refreshing,
    loadingMore: loadingMore,
    error: error,
  );
}
