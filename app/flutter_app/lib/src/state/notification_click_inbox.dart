import 'dart:async' show scheduleMicrotask, unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/data/notification_tap.dart';

const kNotificationClickLifetime = Duration(seconds: 30);
typedef NotificationClickConsumer = Future<void> Function(NotificationTap tap);

/// Buffer the latest explicit click until the UI is ready. Clicks received
/// while a chooser is active cannot later steal focus when it closes.
class NotificationClickInbox {
  NotificationClickInbox({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  NotificationTap? _pending;
  DateTime? _receivedAt;
  NotificationClickConsumer? _consumer;
  bool _processing = false;

  void add(NotificationTap tap) {
    if (_processing) return;
    _pending = tap;
    _receivedAt = _now();
    scheduleMicrotask(() => unawaited(_drain()));
  }

  void Function() bind(NotificationClickConsumer consumer) {
    _consumer = consumer;
    scheduleMicrotask(() => unawaited(_drain()));
    return () {
      if (identical(_consumer, consumer)) _consumer = null;
    };
  }

  Future<void> _drain() async {
    final consumer = _consumer;
    final tap = _pending;
    final receivedAt = _receivedAt;
    if (_processing || consumer == null || tap == null || receivedAt == null) return;
    _pending = null;
    _receivedAt = null;
    if (_now().difference(receivedAt) >= kNotificationClickLifetime) return;
    _processing = true;
    try {
      await consumer(tap);
    } catch (_) {
      // The consumer reports UI failures. Never log notification contents.
    } finally {
      _processing = false;
    }
  }
}

final notificationClickInbox = NotificationClickInbox();
final notificationClickInboxProvider = Provider<NotificationClickInbox>(
  (ref) => notificationClickInbox,
);
