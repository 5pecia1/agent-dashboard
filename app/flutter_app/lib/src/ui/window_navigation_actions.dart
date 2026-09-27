import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/window_connection.dart';
import 'package:my_dashboard/src/data/window_navigation_target.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/platform/resident_mode_native.dart';
import 'package:my_dashboard/src/routing/app_router.dart';
import 'package:my_dashboard/src/state/window_navigation_provider.dart';
import 'package:my_dashboard/src/ui/widgets/window_connection_dialog.dart';

Future<void> openSessionWindow(
  BuildContext context,
  WidgetRef ref,
  SessionViewDto session, {
  bool configure = false,
  bool markRead = true,
}) => openWindowTarget(
  context,
  ref,
  WindowNavigationTarget.fromSession(session),
  configure: configure,
  markRead: markRead,
);

Future<void> openWindowTarget(
  BuildContext context,
  WidgetRef ref,
  WindowNavigationTarget target, {
  bool configure = false,
  bool markRead = true,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final result = await ref
      .read(windowNavigationServiceProvider)
      .openTarget(
        target,
        configure: configure,
        markRead: markRead,
        choose: (scan, rule) async {
          await showResidentWindow();
          if (!navigator.mounted) return null;
          final selectedWindow = await showDialog<WindowCandidate>(
            context: navigator.context,
            // Finish closing our UI before the native layer activates another app.
            animationStyle: AnimationStyle.noAnimation,
            builder: (dialogContext) => WindowConnectionDialog(
              connectionKey: target.connectionKey,
              project: target.project,
              host: target.host,
              scan: scan,
              rule: rule,
              onShowSession: () {
                Navigator.of(dialogContext).pop();
                navigator.pushNamed(sessionDetailRouteName(target.sessionKey));
              },
            ),
          );
          // Navigator.pop completes before the overlay removal frame. Let our
          // modal finish restoring focus before activating the external app.
          await WidgetsBinding.instance.endOfFrame;
          return selectedWindow;
        },
      );
  if (!navigator.mounted || !context.mounted || !ref.context.mounted) return;
  if (result == kWindowNavigationFocused ||
      result == kWindowNavigationCancelled ||
      result == kWindowNavigationBusy) {
    return;
  }
  final title = tRead(ref, 'window.focus_failed');
  final message = tRead(
    ref,
    result == kWindowNavigationStaleTarget ? 'window.stale' : 'window.failed',
  );
  final cancel = tRead(ref, 'action.cancel');
  final detail = tRead(ref, 'window.show_session');
  await showResidentWindow();
  if (!navigator.mounted || !context.mounted) return;
  await showDialog<void>(
    context: navigator.context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(cancel)),
        TextButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            navigator.pushNamed(sessionDetailRouteName(target.sessionKey));
          },
          child: Text(detail),
        ),
      ],
    ),
  );
}
