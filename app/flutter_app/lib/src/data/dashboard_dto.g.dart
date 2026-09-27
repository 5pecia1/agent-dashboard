// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'dashboard_dto.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_SessionViewDto _$SessionViewDtoFromJson(Map<String, dynamic> json) =>
    _SessionViewDto(
      key: json['key'] as String,
      state: json['state'] as String,
      source: json['source'] as String? ?? '',
      sessionId: json['session_id'] as String? ?? '',
      project: json['project'] as String? ?? '',
      host: json['host'] as String?,
      lastEvent: json['last_event'] as String? ?? '',
      lastMessage: json['last_message'] as String?,
      lastOccurredAt: (json['last_occurred_at'] as num?)?.toInt(),
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      lastProgressAt: (json['last_progress_at'] as num?)?.toInt(),
      stale: json['stale'] as bool? ?? false,
      lastTransitionId: (json['last_transition_id'] as num?)?.toInt(),
    );

Map<String, dynamic> _$SessionViewDtoToJson(_SessionViewDto instance) =>
    <String, dynamic>{
      'key': instance.key,
      'state': instance.state,
      'source': instance.source,
      'session_id': instance.sessionId,
      'project': instance.project,
      'host': instance.host,
      'last_event': instance.lastEvent,
      'last_message': instance.lastMessage,
      'last_occurred_at': instance.lastOccurredAt,
      'created_at': instance.createdAt,
      'updated_at': instance.updatedAt,
      'last_progress_at': instance.lastProgressAt,
      'stale': instance.stale,
      'last_transition_id': instance.lastTransitionId,
    };

_TransitionDto _$TransitionDtoFromJson(Map<String, dynamic> json) =>
    _TransitionDto(
      id: (json['id'] as num).toInt(),
      sessionKey: json['session_key'] as String,
      toState: json['to_state'] as String,
      fromState: json['from_state'] as String?,
      source: json['source'] as String? ?? '',
      project: json['project'] as String?,
      host: json['host'] as String?,
      message: json['message'] as String?,
      occurredAt: (json['occurred_at'] as num?)?.toInt() ?? 0,
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$TransitionDtoToJson(_TransitionDto instance) =>
    <String, dynamic>{
      'id': instance.id,
      'session_key': instance.sessionKey,
      'to_state': instance.toState,
      'from_state': instance.fromState,
      'source': instance.source,
      'project': instance.project,
      'host': instance.host,
      'message': instance.message,
      'occurred_at': instance.occurredAt,
      'created_at': instance.createdAt,
    };

_SeenMarkerDto _$SeenMarkerDtoFromJson(Map<String, dynamic> json) =>
    _SeenMarkerDto(
      key: json['key'] as String,
      seenTransitionId: (json['seen_transition_id'] as num?)?.toInt(),
    );

Map<String, dynamic> _$SeenMarkerDtoToJson(_SeenMarkerDto instance) =>
    <String, dynamic>{
      'key': instance.key,
      'seen_transition_id': instance.seenTransitionId,
    };

_HookSkewDto _$HookSkewDtoFromJson(Map<String, dynamic> json) => _HookSkewDto(
  host: json['host'] as String,
  rev: json['rev'] as String?,
  project: json['project'] as String?,
);

Map<String, dynamic> _$HookSkewDtoToJson(_HookSkewDto instance) =>
    <String, dynamic>{
      'host': instance.host,
      'rev': instance.rev,
      'project': instance.project,
    };

_SyncResponseDto _$SyncResponseDtoFromJson(Map<String, dynamic> json) =>
    _SyncResponseDto(
      protocolVersion:
          (json['protocol_version'] as num?)?.toInt() ??
          kDashboardProtocolVersion,
      reset: json['reset'] as bool? ?? false,
      cursor: (json['cursor'] as num?)?.toInt() ?? 0,
      hasMore: json['has_more'] as bool? ?? false,
      serverTime: (json['server_time'] as num?)?.toInt() ?? 0,
      prunedBelowId: (json['pruned_below_id'] as num?)?.toInt() ?? 0,
      stallMs: (json['stall_ms'] as num?)?.toInt() ?? kDefaultStallMs,
      muteUntil: (json['mute_until'] as num?)?.toInt(),
      uiLang: json['ui_lang'] as String?,
      sessions:
          (json['sessions'] as List<dynamic>?)
              ?.map((e) => SessionViewDto.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const <SessionViewDto>[],
      transitions:
          (json['transitions'] as List<dynamic>?)
              ?.map((e) => TransitionDto.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const <TransitionDto>[],
      sessionsTouched:
          (json['sessions_touched'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const <String>[],
      seen:
          (json['seen'] as List<dynamic>?)
              ?.map((e) => SeenMarkerDto.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const <SeenMarkerDto>[],
      hookSkew:
          (json['hook_skew'] as List<dynamic>?)
              ?.map((e) => HookSkewDto.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const <HookSkewDto>[],
    );

Map<String, dynamic> _$SyncResponseDtoToJson(_SyncResponseDto instance) =>
    <String, dynamic>{
      'protocol_version': instance.protocolVersion,
      'reset': instance.reset,
      'cursor': instance.cursor,
      'has_more': instance.hasMore,
      'server_time': instance.serverTime,
      'pruned_below_id': instance.prunedBelowId,
      'stall_ms': instance.stallMs,
      'mute_until': instance.muteUntil,
      'ui_lang': instance.uiLang,
      'sessions': instance.sessions,
      'transitions': instance.transitions,
      'sessions_touched': instance.sessionsTouched,
      'seen': instance.seen,
      'hook_skew': instance.hookSkew,
    };

_PushConfigDto _$PushConfigDtoFromJson(Map<String, dynamic> json) =>
    _PushConfigDto(
      channels:
          (json['channels'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const <String>[],
      firebaseConfig:
          json['firebase_config'] as Map<String, dynamic>? ??
          const <String, Object?>{},
      vapidKey: json['vapid_key'] as String?,
      appleConfig:
          json['apple_config'] as Map<String, dynamic>? ??
          const <String, Object?>{},
      clientReady: json['client_ready'] as bool?,
      appleClientReady: json['apple_client_ready'] as bool?,
      options:
          json['options'] as Map<String, dynamic>? ?? const <String, Object?>{},
    );

Map<String, dynamic> _$PushConfigDtoToJson(_PushConfigDto instance) =>
    <String, dynamic>{
      'channels': instance.channels,
      'firebase_config': instance.firebaseConfig,
      'vapid_key': instance.vapidKey,
      'apple_config': instance.appleConfig,
      'client_ready': instance.clientReady,
      'apple_client_ready': instance.appleClientReady,
      'options': instance.options,
    };

_PushLogEntryDto _$PushLogEntryDtoFromJson(Map<String, dynamic> json) =>
    _PushLogEntryDto(
      transport: json['transport'] as String? ?? '',
      target: json['target'] as String? ?? '',
      result: json['result'] as String? ?? '',
      detail: json['detail'] as String?,
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$PushLogEntryDtoToJson(_PushLogEntryDto instance) =>
    <String, dynamic>{
      'transport': instance.transport,
      'target': instance.target,
      'result': instance.result,
      'detail': instance.detail,
      'created_at': instance.createdAt,
    };

_DiagnosticsDto _$DiagnosticsDtoFromJson(Map<String, dynamic> json) =>
    _DiagnosticsDto(
      lastEventAt: (json['last_event_at'] as num?)?.toInt(),
      maxTransitionId: (json['max_transition_id'] as num?)?.toInt() ?? 0,
      prunedBelowId: (json['pruned_below_id'] as num?)?.toInt() ?? 0,
      lastPush: json['last_push'] == null
          ? null
          : PushLogEntryDto.fromJson(json['last_push'] as Map<String, dynamic>),
      deviceFailureCount: (json['device_failure_count'] as num?)?.toInt() ?? 0,
      subscriptionFailureCount:
          (json['subscription_failure_count'] as num?)?.toInt() ?? 0,
      channels:
          (json['channels'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(k, e as bool),
          ) ??
          const <String, bool>{},
      tableCounts:
          (json['table_counts'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(k, (e as num).toInt()),
          ) ??
          const <String, int>{},
    );

Map<String, dynamic> _$DiagnosticsDtoToJson(_DiagnosticsDto instance) =>
    <String, dynamic>{
      'last_event_at': instance.lastEventAt,
      'max_transition_id': instance.maxTransitionId,
      'pruned_below_id': instance.prunedBelowId,
      'last_push': instance.lastPush,
      'device_failure_count': instance.deviceFailureCount,
      'subscription_failure_count': instance.subscriptionFailureCount,
      'channels': instance.channels,
      'table_counts': instance.tableCounts,
    };

_PushChannelResultDto _$PushChannelResultDtoFromJson(
  Map<String, dynamic> json,
) => _PushChannelResultDto(
  sent: (json['sent'] as num?)?.toInt() ?? 0,
  removed: (json['removed'] as num?)?.toInt() ?? 0,
  skipped: json['skipped'] as String?,
);

Map<String, dynamic> _$PushChannelResultDtoToJson(
  _PushChannelResultDto instance,
) => <String, dynamic>{
  'sent': instance.sent,
  'removed': instance.removed,
  'skipped': instance.skipped,
};

_TestPushResultDto _$TestPushResultDtoFromJson(Map<String, dynamic> json) =>
    _TestPushResultDto(
      ok: json['ok'] as bool? ?? false,
      transitionId: (json['transition_id'] as num?)?.toInt() ?? 0,
      channels:
          (json['channels'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(
              k,
              PushChannelResultDto.fromJson(e as Map<String, dynamic>),
            ),
          ) ??
          const <String, PushChannelResultDto>{},
    );

Map<String, dynamic> _$TestPushResultDtoToJson(_TestPushResultDto instance) =>
    <String, dynamic>{
      'ok': instance.ok,
      'transition_id': instance.transitionId,
      'channels': instance.channels,
    };

_AckResultDto _$AckResultDtoFromJson(Map<String, dynamic> json) =>
    _AckResultDto(
      ok: json['ok'] as bool? ?? false,
      state: json['state'] as String?,
      transitionId: (json['transition_id'] as num?)?.toInt(),
    );

Map<String, dynamic> _$AckResultDtoToJson(_AckResultDto instance) =>
    <String, dynamic>{
      'ok': instance.ok,
      'state': instance.state,
      'transition_id': instance.transitionId,
    };

_PushSubscriptionDto _$PushSubscriptionDtoFromJson(Map<String, dynamic> json) =>
    _PushSubscriptionDto(
      endpoint: json['endpoint'] as String,
      p256dh: json['p256dh'] as String,
      auth: json['auth'] as String,
    );

Map<String, dynamic> _$PushSubscriptionDtoToJson(
  _PushSubscriptionDto instance,
) => <String, dynamic>{
  'endpoint': instance.endpoint,
  'p256dh': instance.p256dh,
  'auth': instance.auth,
};
