import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/notification_tap.dart';
import 'package:my_dashboard/src/data/window_navigation_target.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';

const kNotificationSessionWait = Duration(seconds: 8);

class NotificationTargetUnavailable implements Exception {
  const NotificationTargetUnavailable(this.messageKey);
  final String messageKey;
}

typedef NotificationSessionLookup =
    Future<SessionViewDto?> Function(String key);
final notificationSessionLookupProvider = Provider<NotificationSessionLookup>((
  ref,
) {
  return (key) async {
    final before = ref.read(syncControllerProvider);
    final cached = before.sync.sessions[key];
    if (cached != null) return cached;
    if (before.phase == SyncPhase.unconfigured || before.needsSetup) {
      return null;
    }
    final result = Completer<SessionViewDto?>();
    final subscription = ref.listen(syncControllerProvider, (_, next) {
      final session = next.sync.sessions[key];
      if (result.isCompleted) return;
      if (session != null) {
        result.complete(session);
      } else if (next.lastSuccessAtMs != before.lastSuccessAtMs ||
          next.lastError != before.lastError ||
          next.needsSetup) {
        result.complete(null);
      }
    });
    try {
      ref.read(syncControllerProvider.notifier).triggerNow();
      return await result.future.timeout(
        kNotificationSessionWait,
        onTimeout: () => null,
      );
    } finally {
      subscription.close();
    }
  };
});

typedef NotificationTargetResolver =
    Future<WindowNavigationTarget?> Function(NotificationTap tap);
final notificationTargetResolverProvider = Provider<NotificationTargetResolver>((
  ref,
) {
  return (tap) async {
    final key = tap.sessionKey;
    if (key == null || key.isEmpty) return null;
    final origin = _serverScope(tap.serverUrl);
    if (origin != null) {
      String? current;
      try {
        current = _serverScope(
          ref.read(dashboardApiConfigProvider).baseUrl.toString(),
        );
      } catch (_) {
        // A notification from an old configured server must not acknowledge a
        // similarly named session on an unconfigured or different connection.
      }
      if (current != origin) {
        throw const NotificationTargetUnavailable(
          'notification.server_changed',
        );
      }
    }
    var project = _known(tap.project);
    var host = _known(tap.host);
    if (project == null || host == null) {
      final session = await ref.read(notificationSessionLookupProvider)(key);
      if (!ref.mounted) return null;
      // Never splice an old project's path with a different live session host.
      // Complete the identity only if every field we already know agrees.
      if (session != null &&
          (project == null || project == session.project) &&
          (host == null || host.trim() == session.host?.trim())) {
        project ??= _known(session.project);
        host ??= _known(session.host);
      }
    }
    if (project == null) {
      throw const NotificationTargetUnavailable('notification.target_missing');
    }
    return WindowNavigationTarget(
      sessionKey: key,
      project: project,
      host: host,
      serverUrl: origin,
      serverRevision: origin == null
          ? null
          : ref
                .read(dashboardApiConfigControllerProvider.notifier)
                .serverRevision,
      // Old banners have no trustworthy original watermark. Never replace it
      // with the live session's newest transition or the masked OS id.
      transitionId: tap.legacy || origin == null ? null : tap.transitionId,
      requireSelection: tap.legacy || origin == null,
    );
  };
});

String? _known(String? value) =>
    value == null || value.trim().isEmpty ? null : value;
String? _serverScope(String? value) =>
    NotificationTap.safeServerUrl(value)?.replaceFirst(RegExp(r'/+$'), '');
