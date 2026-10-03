import 'dart:async' show unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart'
    show dashboardApiConfigProvider;
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/window_connection.dart';
import 'package:my_dashboard/src/data/window_navigation_target.dart';
import 'package:my_dashboard/src/platform/window_navigation.dart' as native;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/state/window_connections_provider.dart';

const kWindowNavigationFocused = 'focused';
const kWindowNavigationCancelled = 'cancelled';
const kWindowNavigationBusy = 'busy';
const kWindowNavigationFailed = 'failed';
const kWindowNavigationStaleTarget = 'staleTarget';

final windowNavigationSupportedProvider = Provider<bool>(
  (ref) => native.supportsWindowNavigation,
);
typedef WindowScanFn = Future<WindowScan> Function({String? bundleId});
final windowScanProvider = Provider<WindowScanFn>(
  (ref) =>
      ({String? bundleId}) async =>
          WindowScan.fromMap(await native.scanWindows(bundleId: bundleId)),
);
typedef WindowFocusFn = Future<String> Function(String token);
final windowFocusProvider = Provider<WindowFocusFn>(
  (ref) => native.focusWindow,
);
final windowAccessibilitySettingsProvider = Provider<Future<void> Function()>(
  (ref) => native.openWindowAccessibilitySettings,
);

typedef WindowSeenFn = Future<void> Function(String key, int transitionId);
final windowSeenProvider = Provider<WindowSeenFn>(
  (ref) =>
      (key, transitionId) => ref
          .read(syncControllerProvider.notifier)
          .markSeenThrough(key, transitionId),
);

typedef WindowChooser =
    Future<WindowCandidate?> Function(
      WindowScan scan,
      WindowConnectionRule? rule,
    );

/// One explicit user action at a time. This also prevents a late scan from
/// stealing focus after a second tray selection. Native calls have their own
/// bounded timeout; the chooser may stay open until the user decides.
class WindowNavigationService {
  WindowNavigationService(this._ref);
  final Ref _ref;
  bool _busy = false;

  Future<String> open(
    SessionViewDto session, {
    required WindowChooser choose,
    bool configure = false,
    bool markRead = true,
  }) => openTarget(
    WindowNavigationTarget.fromSession(session),
    choose: choose,
    configure: configure,
    markRead: markRead,
  );

  Future<String> openTarget(
    WindowNavigationTarget target, {
    required WindowChooser choose,
    bool configure = false,
    bool markRead = true,
  }) async {
    if (_busy) return kWindowNavigationBusy;
    final connection = _ref.read(dashboardApiConfigControllerProvider.notifier);
    final revision = connection.revision;
    final source = target.serverUrl;
    String? currentUrl;
    if (source != null) {
      try {
        currentUrl = _ref.read(dashboardApiConfigProvider).baseUrl.toString();
      } catch (_) {
        currentUrl = _ref
            .read(dashboardApiConfigControllerProvider)
            ?.baseUrl
            .toString();
      }
    }
    if ((target.serverRevision != null &&
            target.serverRevision != connection.serverRevision) ||
        (source != null &&
            source.replaceFirst(RegExp(r'/+$'), '') !=
                currentUrl?.replaceFirst(RegExp(r'/+$'), ''))) {
      return kWindowNavigationStaleTarget;
    }
    _busy = true;
    try {
      final rules = await _ref.read(windowConnectionsProvider.future);
      if (!_ref.mounted) return kWindowNavigationCancelled;
      if (connection.revision != revision) return kWindowNavigationStaleTarget;
      final key = target.connectionKey;
      final rule = rules.where((item) => item.key == key).firstOrNull;
      var scan = await _ref.read(windowScanProvider)(
        bundleId: configure ? null : rule?.bundleId,
      );
      if (!_ref.mounted) return kWindowNavigationCancelled;
      if (connection.revision != revision) return kWindowNavigationStaleTarget;
      final matches = rule == null
          ? <WindowCandidate>[]
          : scan.windows.where(rule.matches).toList();
      // A saved rule is an explicit mapping, including a local window showing
      // a remote project. Host is part of the rule key, not an inferred app ID.
      final canFocus =
          !configure &&
          !target.requireSelection &&
          scan.trusted &&
          scan.complete &&
          matches.length == 1;
      if (!canFocus && !configure && rule != null && scan.trusted) {
        scan = await _ref.read(windowScanProvider)();
        if (!_ref.mounted) return kWindowNavigationCancelled;
        if (connection.revision != revision) {
          return kWindowNavigationStaleTarget;
        }
      }
      final window = canFocus ? matches.single : await choose(scan, rule);
      if (window == null || !_ref.mounted) return kWindowNavigationCancelled;
      if (connection.revision != revision) return kWindowNavigationStaleTarget;
      final result = await _ref.read(windowFocusProvider)(window.token);
      if (!_ref.mounted) return kWindowNavigationCancelled;
      final cutoff = target.transitionId;
      if (result == kWindowNavigationFocused &&
          markRead &&
          cutoff != null &&
          connection.revision == revision) {
        // The immutable tray row owns the cutoff, never the newest sync state.
        unawaited(
          _ref
              .read(windowSeenProvider)(target.sessionKey, cutoff)
              .catchError((Object _) {}),
        );
      }
      return result;
    } catch (_) {
      // Window titles, paths and persisted rules must not reach error logs.
      return kWindowNavigationFailed;
    } finally {
      _busy = false;
    }
  }
}

final windowNavigationServiceProvider = Provider<WindowNavigationService>(
  WindowNavigationService.new,
);
