import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/notification_tap.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/platform/resident_mode_native.dart';
import 'package:my_dashboard/src/routing/app_router.dart';
import 'package:my_dashboard/src/state/notification_target_provider.dart';
import 'package:my_dashboard/src/ui/window_navigation_actions.dart';

Future<void> openNotificationWindow(
  BuildContext context,
  WidgetRef ref,
  NotificationTap tap,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  String errorKey;
  try {
    final target = await ref.read(notificationTargetResolverProvider)(tap);
    if (!context.mounted || !ref.context.mounted) return;
    if (target == null) {
      await showResidentWindow();
    } else {
      await openWindowTarget(context, ref, target);
    }
    return;
  } on NotificationTargetUnavailable catch (error) {
    errorKey = error.messageKey;
  } catch (_) {
    errorKey = 'window.failed';
  }
  if (!context.mounted || !ref.context.mounted) return;
  final title = tRead(ref, 'notification.open_failed');
  final message = tRead(ref, errorKey);
  final cancel = tRead(ref, 'action.cancel');
  final detail = tRead(ref, 'window.show_session');
  await showResidentWindow();
  if (!context.mounted || !navigator.mounted) return;
  await showDialog<void>(
    context: navigator.context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(cancel)),
        // A changed server's old session key must not open an unrelated new one.
        if (tap.sessionKey != null && errorKey != 'notification.server_changed')
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              navigator.pushNamed(sessionDetailRouteName(tap.sessionKey!));
            },
            child: Text(detail),
          ),
      ],
    ),
  );
}
