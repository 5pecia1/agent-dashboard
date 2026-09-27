import 'package:flutter/foundation.dart' show immutable;

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/window_connection.dart';

/// A click owns its project identity and read watermark even after the live
/// session changes or disappears. It is not a synthetic session state.
@immutable
class WindowNavigationTarget {
  const WindowNavigationTarget({
    required this.sessionKey,
    this.project,
    this.host,
    this.transitionId,
    this.requireSelection = false,
  });

  factory WindowNavigationTarget.fromSession(SessionViewDto session) => WindowNavigationTarget(
    sessionKey: session.key,
    project: session.project,
    host: session.host,
    transitionId: session.lastTransitionId,
  );

  final String sessionKey;
  final String? project;
  final String? host;
  final int? transitionId;
  final bool requireSelection;

  WindowConnectionKey? get connectionKey {
    final project = this.project;
    final host = this.host;
    if (project == null || project.trim().isEmpty || host == null || host.trim().isEmpty) {
      return null;
    }
    return WindowConnectionKey(host: host, project: project);
  }
}
