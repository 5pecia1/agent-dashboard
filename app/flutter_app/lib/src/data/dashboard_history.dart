import 'package:flutter/foundation.dart' show immutable;

@immutable
class DashboardHistoryEvent {
  const DashboardHistoryEvent({
    required this.id,
    required this.sessionKey,
    required this.source,
    required this.event,
    required this.message,
    required this.receivedAt,
  });

  factory DashboardHistoryEvent.fromJson(Map<String, dynamic> json) =>
      DashboardHistoryEvent(
        id: json['id'] as int,
        sessionKey: json['session_key'] as String,
        source: json['source'] as String,
        event: json['event'] as String,
        message: json['message'] as String?,
        receivedAt: json['received_at'] as int,
      );

  final int id;
  final String sessionKey;
  final String source;
  final String event;
  final String? message;
  final int receivedAt;

  bool get isUserPrompt => event == 'UserPromptSubmit';
}

@immutable
class DashboardHistoryPage {
  DashboardHistoryPage({
    required List<DashboardHistoryEvent> events,
    required this.hasMore,
    required this.nextBeforeId,
  }) : events = List<DashboardHistoryEvent>.unmodifiable(events);

  factory DashboardHistoryPage.fromJson(Map<String, dynamic> json) {
    final eventsJson = json['events'] as List<dynamic>;
    final events = eventsJson
        .map(
          (event) =>
              DashboardHistoryEvent.fromJson(event as Map<String, dynamic>),
        )
        .toList();
    final hasMore = json['has_more'] as bool;
    if (!json.containsKey('next_before_id')) {
      throw const FormatException('Missing next_before_id');
    }
    final nextBeforeId = json['next_before_id'] as int?;
    if (!hasMore && nextBeforeId != null) {
      throw const FormatException('Unexpected next_before_id');
    }
    if (hasMore &&
        (events.isEmpty ||
            nextBeforeId == null ||
            nextBeforeId <= 0 ||
            nextBeforeId != events.last.id)) {
      throw const FormatException(
        'has_more=true인데 next_before_id가 유효한 커서가 아니다',
      );
    }
    return DashboardHistoryPage(
      events: events,
      hasMore: hasMore,
      nextBeforeId: nextBeforeId,
    );
  }

  final List<DashboardHistoryEvent> events;
  final bool hasMore;
  final int? nextBeforeId;
}
