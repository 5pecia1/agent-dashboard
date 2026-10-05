// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'dashboard_dto.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$SessionViewDto {

/// `<source>:<session_id>`. 프로젝션·전이·push가 공유하는 식별자다.
 String get key;/// 현재 상태. [kDashboardStates] 중 하나.
 String get state; String get source;@JsonKey(name: 'session_id') String get sessionId; String get project; String? get host;@JsonKey(name: 'last_event') String get lastEvent;@JsonKey(name: 'last_message') String? get lastMessage;@JsonKey(name: 'display_title') String? get displayTitle;/// 마지막 이벤트의 발생 시각(epoch ms, **이벤트를 낸 기계의 시계**).
@JsonKey(name: 'last_occurred_at') int? get lastOccurredAt;/// 세션 첫 이벤트 수신 시각(epoch ms, 서버 시계).
@JsonKey(name: 'created_at') int get createdAt;/// 프로젝션 마지막 갱신 시각(epoch ms, 서버 시계).
@JsonKey(name: 'updated_at') int get updatedAt;/// 마지막 **진척** 신호를 서버가 **수신한** 시각(epoch ms, 서버 시계).
/// 정본 `sync.session_object.fields.last_progress_at` — 상태를 바꾼
/// 이벤트와 heartbeat_events만 이 값을 밀고, 기록-전용 이벤트는 밀지
/// 않는다. stalled 판정과 이 화면의 stale 배지가 둘 다 이 값을 서버
/// 시각([SyncState.serverTime])과 비교한다 — [lastOccurredAt](클라이언트
/// 기계 시계)이나 기기의 `DateTime.now()`와는 절대 비교하지 않는다
/// (교차 시계 오염 방지). additive라 구형 응답에는 없을 수 있어
/// nullable — 그 경우 [updatedAt](역시 서버 시계)으로 접는다.
@JsonKey(name: 'last_progress_at') int? get lastProgressAt;/// 0001 시절의 legacy 플래그. 새 화면은 [state]의 `stalled`를 쓴다.
 bool get stale;/// 이 세션에 마지막으로 적재된 전이의 id(0004 seen 기능의 기준값,
/// `dashboard_sessions.last_transition_id`). 전이가 한 번도 없던 세션은
/// null. additive라 구형 응답에는 없을 수 있어 nullable이다 —
/// `sync_reducer.dart`가 델타 경로에서도 `transition.id`로 직접
/// 채운다(sync.ts는 델타 응답에 `sessions`를 담지 않는다).
@JsonKey(name: 'last_transition_id') int? get lastTransitionId;
/// Create a copy of SessionViewDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SessionViewDtoCopyWith<SessionViewDto> get copyWith => _$SessionViewDtoCopyWithImpl<SessionViewDto>(this as SessionViewDto, _$identity);

  /// Serializes this SessionViewDto to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SessionViewDto&&(identical(other.key, key) || other.key == key)&&(identical(other.state, state) || other.state == state)&&(identical(other.source, source) || other.source == source)&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.project, project) || other.project == project)&&(identical(other.host, host) || other.host == host)&&(identical(other.lastEvent, lastEvent) || other.lastEvent == lastEvent)&&(identical(other.lastMessage, lastMessage) || other.lastMessage == lastMessage)&&(identical(other.displayTitle, displayTitle) || other.displayTitle == displayTitle)&&(identical(other.lastOccurredAt, lastOccurredAt) || other.lastOccurredAt == lastOccurredAt)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.lastProgressAt, lastProgressAt) || other.lastProgressAt == lastProgressAt)&&(identical(other.stale, stale) || other.stale == stale)&&(identical(other.lastTransitionId, lastTransitionId) || other.lastTransitionId == lastTransitionId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,key,state,source,sessionId,project,host,lastEvent,lastMessage,displayTitle,lastOccurredAt,createdAt,updatedAt,lastProgressAt,stale,lastTransitionId);

@override
String toString() {
  return 'SessionViewDto(key: $key, state: $state, source: $source, sessionId: $sessionId, project: $project, host: $host, lastEvent: $lastEvent, lastMessage: $lastMessage, displayTitle: $displayTitle, lastOccurredAt: $lastOccurredAt, createdAt: $createdAt, updatedAt: $updatedAt, lastProgressAt: $lastProgressAt, stale: $stale, lastTransitionId: $lastTransitionId)';
}


}

/// @nodoc
abstract mixin class $SessionViewDtoCopyWith<$Res>  {
  factory $SessionViewDtoCopyWith(SessionViewDto value, $Res Function(SessionViewDto) _then) = _$SessionViewDtoCopyWithImpl;
@useResult
$Res call({
 String key, String state, String source,@JsonKey(name: 'session_id') String sessionId, String project, String? host,@JsonKey(name: 'last_event') String lastEvent,@JsonKey(name: 'last_message') String? lastMessage,@JsonKey(name: 'display_title') String? displayTitle,@JsonKey(name: 'last_occurred_at') int? lastOccurredAt,@JsonKey(name: 'created_at') int createdAt,@JsonKey(name: 'updated_at') int updatedAt,@JsonKey(name: 'last_progress_at') int? lastProgressAt, bool stale,@JsonKey(name: 'last_transition_id') int? lastTransitionId
});




}
/// @nodoc
class _$SessionViewDtoCopyWithImpl<$Res>
    implements $SessionViewDtoCopyWith<$Res> {
  _$SessionViewDtoCopyWithImpl(this._self, this._then);

  final SessionViewDto _self;
  final $Res Function(SessionViewDto) _then;

/// Create a copy of SessionViewDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? key = null,Object? state = null,Object? source = null,Object? sessionId = null,Object? project = null,Object? host = freezed,Object? lastEvent = null,Object? lastMessage = freezed,Object? displayTitle = freezed,Object? lastOccurredAt = freezed,Object? createdAt = null,Object? updatedAt = null,Object? lastProgressAt = freezed,Object? stale = null,Object? lastTransitionId = freezed,}) {
  return _then(_self.copyWith(
key: null == key ? _self.key : key // ignore: cast_nullable_to_non_nullable
as String,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as String,source: null == source ? _self.source : source // ignore: cast_nullable_to_non_nullable
as String,sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,project: null == project ? _self.project : project // ignore: cast_nullable_to_non_nullable
as String,host: freezed == host ? _self.host : host // ignore: cast_nullable_to_non_nullable
as String?,lastEvent: null == lastEvent ? _self.lastEvent : lastEvent // ignore: cast_nullable_to_non_nullable
as String,lastMessage: freezed == lastMessage ? _self.lastMessage : lastMessage // ignore: cast_nullable_to_non_nullable
as String?,displayTitle: freezed == displayTitle ? _self.displayTitle : displayTitle // ignore: cast_nullable_to_non_nullable
as String?,lastOccurredAt: freezed == lastOccurredAt ? _self.lastOccurredAt : lastOccurredAt // ignore: cast_nullable_to_non_nullable
as int?,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as int,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as int,lastProgressAt: freezed == lastProgressAt ? _self.lastProgressAt : lastProgressAt // ignore: cast_nullable_to_non_nullable
as int?,stale: null == stale ? _self.stale : stale // ignore: cast_nullable_to_non_nullable
as bool,lastTransitionId: freezed == lastTransitionId ? _self.lastTransitionId : lastTransitionId // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}

}


/// Adds pattern-matching-related methods to [SessionViewDto].
extension SessionViewDtoPatterns on SessionViewDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SessionViewDto value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SessionViewDto() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SessionViewDto value)  $default,){
final _that = this;
switch (_that) {
case _SessionViewDto():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SessionViewDto value)?  $default,){
final _that = this;
switch (_that) {
case _SessionViewDto() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String key,  String state,  String source, @JsonKey(name: 'session_id')  String sessionId,  String project,  String? host, @JsonKey(name: 'last_event')  String lastEvent, @JsonKey(name: 'last_message')  String? lastMessage, @JsonKey(name: 'display_title')  String? displayTitle, @JsonKey(name: 'last_occurred_at')  int? lastOccurredAt, @JsonKey(name: 'created_at')  int createdAt, @JsonKey(name: 'updated_at')  int updatedAt, @JsonKey(name: 'last_progress_at')  int? lastProgressAt,  bool stale, @JsonKey(name: 'last_transition_id')  int? lastTransitionId)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SessionViewDto() when $default != null:
return $default(_that.key,_that.state,_that.source,_that.sessionId,_that.project,_that.host,_that.lastEvent,_that.lastMessage,_that.displayTitle,_that.lastOccurredAt,_that.createdAt,_that.updatedAt,_that.lastProgressAt,_that.stale,_that.lastTransitionId);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String key,  String state,  String source, @JsonKey(name: 'session_id')  String sessionId,  String project,  String? host, @JsonKey(name: 'last_event')  String lastEvent, @JsonKey(name: 'last_message')  String? lastMessage, @JsonKey(name: 'display_title')  String? displayTitle, @JsonKey(name: 'last_occurred_at')  int? lastOccurredAt, @JsonKey(name: 'created_at')  int createdAt, @JsonKey(name: 'updated_at')  int updatedAt, @JsonKey(name: 'last_progress_at')  int? lastProgressAt,  bool stale, @JsonKey(name: 'last_transition_id')  int? lastTransitionId)  $default,) {final _that = this;
switch (_that) {
case _SessionViewDto():
return $default(_that.key,_that.state,_that.source,_that.sessionId,_that.project,_that.host,_that.lastEvent,_that.lastMessage,_that.displayTitle,_that.lastOccurredAt,_that.createdAt,_that.updatedAt,_that.lastProgressAt,_that.stale,_that.lastTransitionId);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String key,  String state,  String source, @JsonKey(name: 'session_id')  String sessionId,  String project,  String? host, @JsonKey(name: 'last_event')  String lastEvent, @JsonKey(name: 'last_message')  String? lastMessage, @JsonKey(name: 'display_title')  String? displayTitle, @JsonKey(name: 'last_occurred_at')  int? lastOccurredAt, @JsonKey(name: 'created_at')  int createdAt, @JsonKey(name: 'updated_at')  int updatedAt, @JsonKey(name: 'last_progress_at')  int? lastProgressAt,  bool stale, @JsonKey(name: 'last_transition_id')  int? lastTransitionId)?  $default,) {final _that = this;
switch (_that) {
case _SessionViewDto() when $default != null:
return $default(_that.key,_that.state,_that.source,_that.sessionId,_that.project,_that.host,_that.lastEvent,_that.lastMessage,_that.displayTitle,_that.lastOccurredAt,_that.createdAt,_that.updatedAt,_that.lastProgressAt,_that.stale,_that.lastTransitionId);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _SessionViewDto extends SessionViewDto {
  const _SessionViewDto({required this.key, required this.state, this.source = '', @JsonKey(name: 'session_id') this.sessionId = '', this.project = '', this.host, @JsonKey(name: 'last_event') this.lastEvent = '', @JsonKey(name: 'last_message') this.lastMessage, @JsonKey(name: 'display_title') this.displayTitle, @JsonKey(name: 'last_occurred_at') this.lastOccurredAt, @JsonKey(name: 'created_at') this.createdAt = 0, @JsonKey(name: 'updated_at') this.updatedAt = 0, @JsonKey(name: 'last_progress_at') this.lastProgressAt, this.stale = false, @JsonKey(name: 'last_transition_id') this.lastTransitionId}): super._();
  factory _SessionViewDto.fromJson(Map<String, dynamic> json) => _$SessionViewDtoFromJson(json);

/// `<source>:<session_id>`. 프로젝션·전이·push가 공유하는 식별자다.
@override final  String key;
/// 현재 상태. [kDashboardStates] 중 하나.
@override final  String state;
@override@JsonKey() final  String source;
@override@JsonKey(name: 'session_id') final  String sessionId;
@override@JsonKey() final  String project;
@override final  String? host;
@override@JsonKey(name: 'last_event') final  String lastEvent;
@override@JsonKey(name: 'last_message') final  String? lastMessage;
@override@JsonKey(name: 'display_title') final  String? displayTitle;
/// 마지막 이벤트의 발생 시각(epoch ms, **이벤트를 낸 기계의 시계**).
@override@JsonKey(name: 'last_occurred_at') final  int? lastOccurredAt;
/// 세션 첫 이벤트 수신 시각(epoch ms, 서버 시계).
@override@JsonKey(name: 'created_at') final  int createdAt;
/// 프로젝션 마지막 갱신 시각(epoch ms, 서버 시계).
@override@JsonKey(name: 'updated_at') final  int updatedAt;
/// 마지막 **진척** 신호를 서버가 **수신한** 시각(epoch ms, 서버 시계).
/// 정본 `sync.session_object.fields.last_progress_at` — 상태를 바꾼
/// 이벤트와 heartbeat_events만 이 값을 밀고, 기록-전용 이벤트는 밀지
/// 않는다. stalled 판정과 이 화면의 stale 배지가 둘 다 이 값을 서버
/// 시각([SyncState.serverTime])과 비교한다 — [lastOccurredAt](클라이언트
/// 기계 시계)이나 기기의 `DateTime.now()`와는 절대 비교하지 않는다
/// (교차 시계 오염 방지). additive라 구형 응답에는 없을 수 있어
/// nullable — 그 경우 [updatedAt](역시 서버 시계)으로 접는다.
@override@JsonKey(name: 'last_progress_at') final  int? lastProgressAt;
/// 0001 시절의 legacy 플래그. 새 화면은 [state]의 `stalled`를 쓴다.
@override@JsonKey() final  bool stale;
/// 이 세션에 마지막으로 적재된 전이의 id(0004 seen 기능의 기준값,
/// `dashboard_sessions.last_transition_id`). 전이가 한 번도 없던 세션은
/// null. additive라 구형 응답에는 없을 수 있어 nullable이다 —
/// `sync_reducer.dart`가 델타 경로에서도 `transition.id`로 직접
/// 채운다(sync.ts는 델타 응답에 `sessions`를 담지 않는다).
@override@JsonKey(name: 'last_transition_id') final  int? lastTransitionId;

/// Create a copy of SessionViewDto
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SessionViewDtoCopyWith<_SessionViewDto> get copyWith => __$SessionViewDtoCopyWithImpl<_SessionViewDto>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SessionViewDtoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SessionViewDto&&(identical(other.key, key) || other.key == key)&&(identical(other.state, state) || other.state == state)&&(identical(other.source, source) || other.source == source)&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.project, project) || other.project == project)&&(identical(other.host, host) || other.host == host)&&(identical(other.lastEvent, lastEvent) || other.lastEvent == lastEvent)&&(identical(other.lastMessage, lastMessage) || other.lastMessage == lastMessage)&&(identical(other.displayTitle, displayTitle) || other.displayTitle == displayTitle)&&(identical(other.lastOccurredAt, lastOccurredAt) || other.lastOccurredAt == lastOccurredAt)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.lastProgressAt, lastProgressAt) || other.lastProgressAt == lastProgressAt)&&(identical(other.stale, stale) || other.stale == stale)&&(identical(other.lastTransitionId, lastTransitionId) || other.lastTransitionId == lastTransitionId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,key,state,source,sessionId,project,host,lastEvent,lastMessage,displayTitle,lastOccurredAt,createdAt,updatedAt,lastProgressAt,stale,lastTransitionId);

@override
String toString() {
  return 'SessionViewDto(key: $key, state: $state, source: $source, sessionId: $sessionId, project: $project, host: $host, lastEvent: $lastEvent, lastMessage: $lastMessage, displayTitle: $displayTitle, lastOccurredAt: $lastOccurredAt, createdAt: $createdAt, updatedAt: $updatedAt, lastProgressAt: $lastProgressAt, stale: $stale, lastTransitionId: $lastTransitionId)';
}


}

/// @nodoc
abstract mixin class _$SessionViewDtoCopyWith<$Res> implements $SessionViewDtoCopyWith<$Res> {
  factory _$SessionViewDtoCopyWith(_SessionViewDto value, $Res Function(_SessionViewDto) _then) = __$SessionViewDtoCopyWithImpl;
@override @useResult
$Res call({
 String key, String state, String source,@JsonKey(name: 'session_id') String sessionId, String project, String? host,@JsonKey(name: 'last_event') String lastEvent,@JsonKey(name: 'last_message') String? lastMessage,@JsonKey(name: 'display_title') String? displayTitle,@JsonKey(name: 'last_occurred_at') int? lastOccurredAt,@JsonKey(name: 'created_at') int createdAt,@JsonKey(name: 'updated_at') int updatedAt,@JsonKey(name: 'last_progress_at') int? lastProgressAt, bool stale,@JsonKey(name: 'last_transition_id') int? lastTransitionId
});




}
/// @nodoc
class __$SessionViewDtoCopyWithImpl<$Res>
    implements _$SessionViewDtoCopyWith<$Res> {
  __$SessionViewDtoCopyWithImpl(this._self, this._then);

  final _SessionViewDto _self;
  final $Res Function(_SessionViewDto) _then;

/// Create a copy of SessionViewDto
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? key = null,Object? state = null,Object? source = null,Object? sessionId = null,Object? project = null,Object? host = freezed,Object? lastEvent = null,Object? lastMessage = freezed,Object? displayTitle = freezed,Object? lastOccurredAt = freezed,Object? createdAt = null,Object? updatedAt = null,Object? lastProgressAt = freezed,Object? stale = null,Object? lastTransitionId = freezed,}) {
  return _then(_SessionViewDto(
key: null == key ? _self.key : key // ignore: cast_nullable_to_non_nullable
as String,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as String,source: null == source ? _self.source : source // ignore: cast_nullable_to_non_nullable
as String,sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,project: null == project ? _self.project : project // ignore: cast_nullable_to_non_nullable
as String,host: freezed == host ? _self.host : host // ignore: cast_nullable_to_non_nullable
as String?,lastEvent: null == lastEvent ? _self.lastEvent : lastEvent // ignore: cast_nullable_to_non_nullable
as String,lastMessage: freezed == lastMessage ? _self.lastMessage : lastMessage // ignore: cast_nullable_to_non_nullable
as String?,displayTitle: freezed == displayTitle ? _self.displayTitle : displayTitle // ignore: cast_nullable_to_non_nullable
as String?,lastOccurredAt: freezed == lastOccurredAt ? _self.lastOccurredAt : lastOccurredAt // ignore: cast_nullable_to_non_nullable
as int?,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as int,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as int,lastProgressAt: freezed == lastProgressAt ? _self.lastProgressAt : lastProgressAt // ignore: cast_nullable_to_non_nullable
as int?,stale: null == stale ? _self.stale : stale // ignore: cast_nullable_to_non_nullable
as bool,lastTransitionId: freezed == lastTransitionId ? _self.lastTransitionId : lastTransitionId // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}


}


/// @nodoc
mixin _$TransitionDto {

/// AUTOINCREMENT 커서. 서버에서 단조 증가하고 재사용되지 않는다.
 int get id;@JsonKey(name: 'session_key') String get sessionKey;@JsonKey(name: 'to_state') String get toState;@JsonKey(name: 'from_state') String? get fromState; String get source; String? get project; String? get host; String? get message;@JsonKey(name: 'display_title') String? get displayTitle;/// 이벤트 발생 시각(epoch ms, 이벤트를 낸 기계의 시계).
@JsonKey(name: 'occurred_at') int get occurredAt;/// 전이 기록 시각(epoch ms, 서버 시계).
@JsonKey(name: 'created_at') int get createdAt;
/// Create a copy of TransitionDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TransitionDtoCopyWith<TransitionDto> get copyWith => _$TransitionDtoCopyWithImpl<TransitionDto>(this as TransitionDto, _$identity);

  /// Serializes this TransitionDto to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TransitionDto&&(identical(other.id, id) || other.id == id)&&(identical(other.sessionKey, sessionKey) || other.sessionKey == sessionKey)&&(identical(other.toState, toState) || other.toState == toState)&&(identical(other.fromState, fromState) || other.fromState == fromState)&&(identical(other.source, source) || other.source == source)&&(identical(other.project, project) || other.project == project)&&(identical(other.host, host) || other.host == host)&&(identical(other.message, message) || other.message == message)&&(identical(other.displayTitle, displayTitle) || other.displayTitle == displayTitle)&&(identical(other.occurredAt, occurredAt) || other.occurredAt == occurredAt)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,sessionKey,toState,fromState,source,project,host,message,displayTitle,occurredAt,createdAt);

@override
String toString() {
  return 'TransitionDto(id: $id, sessionKey: $sessionKey, toState: $toState, fromState: $fromState, source: $source, project: $project, host: $host, message: $message, displayTitle: $displayTitle, occurredAt: $occurredAt, createdAt: $createdAt)';
}


}

/// @nodoc
abstract mixin class $TransitionDtoCopyWith<$Res>  {
  factory $TransitionDtoCopyWith(TransitionDto value, $Res Function(TransitionDto) _then) = _$TransitionDtoCopyWithImpl;
@useResult
$Res call({
 int id,@JsonKey(name: 'session_key') String sessionKey,@JsonKey(name: 'to_state') String toState,@JsonKey(name: 'from_state') String? fromState, String source, String? project, String? host, String? message,@JsonKey(name: 'display_title') String? displayTitle,@JsonKey(name: 'occurred_at') int occurredAt,@JsonKey(name: 'created_at') int createdAt
});




}
/// @nodoc
class _$TransitionDtoCopyWithImpl<$Res>
    implements $TransitionDtoCopyWith<$Res> {
  _$TransitionDtoCopyWithImpl(this._self, this._then);

  final TransitionDto _self;
  final $Res Function(TransitionDto) _then;

/// Create a copy of TransitionDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? sessionKey = null,Object? toState = null,Object? fromState = freezed,Object? source = null,Object? project = freezed,Object? host = freezed,Object? message = freezed,Object? displayTitle = freezed,Object? occurredAt = null,Object? createdAt = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as int,sessionKey: null == sessionKey ? _self.sessionKey : sessionKey // ignore: cast_nullable_to_non_nullable
as String,toState: null == toState ? _self.toState : toState // ignore: cast_nullable_to_non_nullable
as String,fromState: freezed == fromState ? _self.fromState : fromState // ignore: cast_nullable_to_non_nullable
as String?,source: null == source ? _self.source : source // ignore: cast_nullable_to_non_nullable
as String,project: freezed == project ? _self.project : project // ignore: cast_nullable_to_non_nullable
as String?,host: freezed == host ? _self.host : host // ignore: cast_nullable_to_non_nullable
as String?,message: freezed == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String?,displayTitle: freezed == displayTitle ? _self.displayTitle : displayTitle // ignore: cast_nullable_to_non_nullable
as String?,occurredAt: null == occurredAt ? _self.occurredAt : occurredAt // ignore: cast_nullable_to_non_nullable
as int,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [TransitionDto].
extension TransitionDtoPatterns on TransitionDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TransitionDto value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TransitionDto() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TransitionDto value)  $default,){
final _that = this;
switch (_that) {
case _TransitionDto():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TransitionDto value)?  $default,){
final _that = this;
switch (_that) {
case _TransitionDto() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int id, @JsonKey(name: 'session_key')  String sessionKey, @JsonKey(name: 'to_state')  String toState, @JsonKey(name: 'from_state')  String? fromState,  String source,  String? project,  String? host,  String? message, @JsonKey(name: 'display_title')  String? displayTitle, @JsonKey(name: 'occurred_at')  int occurredAt, @JsonKey(name: 'created_at')  int createdAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TransitionDto() when $default != null:
return $default(_that.id,_that.sessionKey,_that.toState,_that.fromState,_that.source,_that.project,_that.host,_that.message,_that.displayTitle,_that.occurredAt,_that.createdAt);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int id, @JsonKey(name: 'session_key')  String sessionKey, @JsonKey(name: 'to_state')  String toState, @JsonKey(name: 'from_state')  String? fromState,  String source,  String? project,  String? host,  String? message, @JsonKey(name: 'display_title')  String? displayTitle, @JsonKey(name: 'occurred_at')  int occurredAt, @JsonKey(name: 'created_at')  int createdAt)  $default,) {final _that = this;
switch (_that) {
case _TransitionDto():
return $default(_that.id,_that.sessionKey,_that.toState,_that.fromState,_that.source,_that.project,_that.host,_that.message,_that.displayTitle,_that.occurredAt,_that.createdAt);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int id, @JsonKey(name: 'session_key')  String sessionKey, @JsonKey(name: 'to_state')  String toState, @JsonKey(name: 'from_state')  String? fromState,  String source,  String? project,  String? host,  String? message, @JsonKey(name: 'display_title')  String? displayTitle, @JsonKey(name: 'occurred_at')  int occurredAt, @JsonKey(name: 'created_at')  int createdAt)?  $default,) {final _that = this;
switch (_that) {
case _TransitionDto() when $default != null:
return $default(_that.id,_that.sessionKey,_that.toState,_that.fromState,_that.source,_that.project,_that.host,_that.message,_that.displayTitle,_that.occurredAt,_that.createdAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _TransitionDto extends TransitionDto {
  const _TransitionDto({required this.id, @JsonKey(name: 'session_key') required this.sessionKey, @JsonKey(name: 'to_state') required this.toState, @JsonKey(name: 'from_state') this.fromState, this.source = '', this.project, this.host, this.message, @JsonKey(name: 'display_title') this.displayTitle, @JsonKey(name: 'occurred_at') this.occurredAt = 0, @JsonKey(name: 'created_at') this.createdAt = 0}): super._();
  factory _TransitionDto.fromJson(Map<String, dynamic> json) => _$TransitionDtoFromJson(json);

/// AUTOINCREMENT 커서. 서버에서 단조 증가하고 재사용되지 않는다.
@override final  int id;
@override@JsonKey(name: 'session_key') final  String sessionKey;
@override@JsonKey(name: 'to_state') final  String toState;
@override@JsonKey(name: 'from_state') final  String? fromState;
@override@JsonKey() final  String source;
@override final  String? project;
@override final  String? host;
@override final  String? message;
@override@JsonKey(name: 'display_title') final  String? displayTitle;
/// 이벤트 발생 시각(epoch ms, 이벤트를 낸 기계의 시계).
@override@JsonKey(name: 'occurred_at') final  int occurredAt;
/// 전이 기록 시각(epoch ms, 서버 시계).
@override@JsonKey(name: 'created_at') final  int createdAt;

/// Create a copy of TransitionDto
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TransitionDtoCopyWith<_TransitionDto> get copyWith => __$TransitionDtoCopyWithImpl<_TransitionDto>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$TransitionDtoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _TransitionDto&&(identical(other.id, id) || other.id == id)&&(identical(other.sessionKey, sessionKey) || other.sessionKey == sessionKey)&&(identical(other.toState, toState) || other.toState == toState)&&(identical(other.fromState, fromState) || other.fromState == fromState)&&(identical(other.source, source) || other.source == source)&&(identical(other.project, project) || other.project == project)&&(identical(other.host, host) || other.host == host)&&(identical(other.message, message) || other.message == message)&&(identical(other.displayTitle, displayTitle) || other.displayTitle == displayTitle)&&(identical(other.occurredAt, occurredAt) || other.occurredAt == occurredAt)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,sessionKey,toState,fromState,source,project,host,message,displayTitle,occurredAt,createdAt);

@override
String toString() {
  return 'TransitionDto(id: $id, sessionKey: $sessionKey, toState: $toState, fromState: $fromState, source: $source, project: $project, host: $host, message: $message, displayTitle: $displayTitle, occurredAt: $occurredAt, createdAt: $createdAt)';
}


}

/// @nodoc
abstract mixin class _$TransitionDtoCopyWith<$Res> implements $TransitionDtoCopyWith<$Res> {
  factory _$TransitionDtoCopyWith(_TransitionDto value, $Res Function(_TransitionDto) _then) = __$TransitionDtoCopyWithImpl;
@override @useResult
$Res call({
 int id,@JsonKey(name: 'session_key') String sessionKey,@JsonKey(name: 'to_state') String toState,@JsonKey(name: 'from_state') String? fromState, String source, String? project, String? host, String? message,@JsonKey(name: 'display_title') String? displayTitle,@JsonKey(name: 'occurred_at') int occurredAt,@JsonKey(name: 'created_at') int createdAt
});




}
/// @nodoc
class __$TransitionDtoCopyWithImpl<$Res>
    implements _$TransitionDtoCopyWith<$Res> {
  __$TransitionDtoCopyWithImpl(this._self, this._then);

  final _TransitionDto _self;
  final $Res Function(_TransitionDto) _then;

/// Create a copy of TransitionDto
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? sessionKey = null,Object? toState = null,Object? fromState = freezed,Object? source = null,Object? project = freezed,Object? host = freezed,Object? message = freezed,Object? displayTitle = freezed,Object? occurredAt = null,Object? createdAt = null,}) {
  return _then(_TransitionDto(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as int,sessionKey: null == sessionKey ? _self.sessionKey : sessionKey // ignore: cast_nullable_to_non_nullable
as String,toState: null == toState ? _self.toState : toState // ignore: cast_nullable_to_non_nullable
as String,fromState: freezed == fromState ? _self.fromState : fromState // ignore: cast_nullable_to_non_nullable
as String?,source: null == source ? _self.source : source // ignore: cast_nullable_to_non_nullable
as String,project: freezed == project ? _self.project : project // ignore: cast_nullable_to_non_nullable
as String?,host: freezed == host ? _self.host : host // ignore: cast_nullable_to_non_nullable
as String?,message: freezed == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String?,displayTitle: freezed == displayTitle ? _self.displayTitle : displayTitle // ignore: cast_nullable_to_non_nullable
as String?,occurredAt: null == occurredAt ? _self.occurredAt : occurredAt // ignore: cast_nullable_to_non_nullable
as int,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}


/// @nodoc
mixin _$SeenMarkerDto {

/// `session_key`. [SessionViewDto.key]/[TransitionDto.sessionKey]와
/// 같은 값 공간이다.
 String get key;/// 사용자가 마지막으로 확인 처리(seen)한 전이 id. 한 번도 MarkSeen을
/// 호출한 적 없으면 null.
@JsonKey(name: 'seen_transition_id') int? get seenTransitionId;
/// Create a copy of SeenMarkerDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SeenMarkerDtoCopyWith<SeenMarkerDto> get copyWith => _$SeenMarkerDtoCopyWithImpl<SeenMarkerDto>(this as SeenMarkerDto, _$identity);

  /// Serializes this SeenMarkerDto to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SeenMarkerDto&&(identical(other.key, key) || other.key == key)&&(identical(other.seenTransitionId, seenTransitionId) || other.seenTransitionId == seenTransitionId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,key,seenTransitionId);

@override
String toString() {
  return 'SeenMarkerDto(key: $key, seenTransitionId: $seenTransitionId)';
}


}

/// @nodoc
abstract mixin class $SeenMarkerDtoCopyWith<$Res>  {
  factory $SeenMarkerDtoCopyWith(SeenMarkerDto value, $Res Function(SeenMarkerDto) _then) = _$SeenMarkerDtoCopyWithImpl;
@useResult
$Res call({
 String key,@JsonKey(name: 'seen_transition_id') int? seenTransitionId
});




}
/// @nodoc
class _$SeenMarkerDtoCopyWithImpl<$Res>
    implements $SeenMarkerDtoCopyWith<$Res> {
  _$SeenMarkerDtoCopyWithImpl(this._self, this._then);

  final SeenMarkerDto _self;
  final $Res Function(SeenMarkerDto) _then;

/// Create a copy of SeenMarkerDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? key = null,Object? seenTransitionId = freezed,}) {
  return _then(_self.copyWith(
key: null == key ? _self.key : key // ignore: cast_nullable_to_non_nullable
as String,seenTransitionId: freezed == seenTransitionId ? _self.seenTransitionId : seenTransitionId // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}

}


/// Adds pattern-matching-related methods to [SeenMarkerDto].
extension SeenMarkerDtoPatterns on SeenMarkerDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SeenMarkerDto value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SeenMarkerDto() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SeenMarkerDto value)  $default,){
final _that = this;
switch (_that) {
case _SeenMarkerDto():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SeenMarkerDto value)?  $default,){
final _that = this;
switch (_that) {
case _SeenMarkerDto() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String key, @JsonKey(name: 'seen_transition_id')  int? seenTransitionId)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SeenMarkerDto() when $default != null:
return $default(_that.key,_that.seenTransitionId);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String key, @JsonKey(name: 'seen_transition_id')  int? seenTransitionId)  $default,) {final _that = this;
switch (_that) {
case _SeenMarkerDto():
return $default(_that.key,_that.seenTransitionId);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String key, @JsonKey(name: 'seen_transition_id')  int? seenTransitionId)?  $default,) {final _that = this;
switch (_that) {
case _SeenMarkerDto() when $default != null:
return $default(_that.key,_that.seenTransitionId);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _SeenMarkerDto implements SeenMarkerDto {
  const _SeenMarkerDto({required this.key, @JsonKey(name: 'seen_transition_id') this.seenTransitionId});
  factory _SeenMarkerDto.fromJson(Map<String, dynamic> json) => _$SeenMarkerDtoFromJson(json);

/// `session_key`. [SessionViewDto.key]/[TransitionDto.sessionKey]와
/// 같은 값 공간이다.
@override final  String key;
/// 사용자가 마지막으로 확인 처리(seen)한 전이 id. 한 번도 MarkSeen을
/// 호출한 적 없으면 null.
@override@JsonKey(name: 'seen_transition_id') final  int? seenTransitionId;

/// Create a copy of SeenMarkerDto
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SeenMarkerDtoCopyWith<_SeenMarkerDto> get copyWith => __$SeenMarkerDtoCopyWithImpl<_SeenMarkerDto>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SeenMarkerDtoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SeenMarkerDto&&(identical(other.key, key) || other.key == key)&&(identical(other.seenTransitionId, seenTransitionId) || other.seenTransitionId == seenTransitionId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,key,seenTransitionId);

@override
String toString() {
  return 'SeenMarkerDto(key: $key, seenTransitionId: $seenTransitionId)';
}


}

/// @nodoc
abstract mixin class _$SeenMarkerDtoCopyWith<$Res> implements $SeenMarkerDtoCopyWith<$Res> {
  factory _$SeenMarkerDtoCopyWith(_SeenMarkerDto value, $Res Function(_SeenMarkerDto) _then) = __$SeenMarkerDtoCopyWithImpl;
@override @useResult
$Res call({
 String key,@JsonKey(name: 'seen_transition_id') int? seenTransitionId
});




}
/// @nodoc
class __$SeenMarkerDtoCopyWithImpl<$Res>
    implements _$SeenMarkerDtoCopyWith<$Res> {
  __$SeenMarkerDtoCopyWithImpl(this._self, this._then);

  final _SeenMarkerDto _self;
  final $Res Function(_SeenMarkerDto) _then;

/// Create a copy of SeenMarkerDto
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? key = null,Object? seenTransitionId = freezed,}) {
  return _then(_SeenMarkerDto(
key: null == key ? _self.key : key // ignore: cast_nullable_to_non_nullable
as String,seenTransitionId: freezed == seenTransitionId ? _self.seenTransitionId : seenTransitionId // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}


}


/// @nodoc
mixin _$HookSkewDto {

/// 구버전 훅을 돌리는 기계명. `SessionViewDto.host`와 같은 값 공간이다.
 String get host;/// 그 기계 훅이 신고한 리비전(8자리 hex). 훅이 아직 버전을 신고하지
/// 않는 더 구버전이면 null이다 — "모름"이 아니라 "더 오래됨"의 신호다.
 String? get rev;/// 그 기계에서 이 훅이 마지막으로 관측된 프로젝트 경로. `SessionViewDto.
/// project`와 같은 값 공간(보통 절대경로)이다. devcontainer 등 host명이
/// 무작위 hex라 식별 불가한 경우를 위한 additive 필드라 서버 구버전
/// 응답에는 없을 수 있어 nullable이다 — null이면 host만으로 표시한다.
@JsonKey(name: 'project') String? get project;
/// Create a copy of HookSkewDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$HookSkewDtoCopyWith<HookSkewDto> get copyWith => _$HookSkewDtoCopyWithImpl<HookSkewDto>(this as HookSkewDto, _$identity);

  /// Serializes this HookSkewDto to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is HookSkewDto&&(identical(other.host, host) || other.host == host)&&(identical(other.rev, rev) || other.rev == rev)&&(identical(other.project, project) || other.project == project));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,host,rev,project);

@override
String toString() {
  return 'HookSkewDto(host: $host, rev: $rev, project: $project)';
}


}

/// @nodoc
abstract mixin class $HookSkewDtoCopyWith<$Res>  {
  factory $HookSkewDtoCopyWith(HookSkewDto value, $Res Function(HookSkewDto) _then) = _$HookSkewDtoCopyWithImpl;
@useResult
$Res call({
 String host, String? rev,@JsonKey(name: 'project') String? project
});




}
/// @nodoc
class _$HookSkewDtoCopyWithImpl<$Res>
    implements $HookSkewDtoCopyWith<$Res> {
  _$HookSkewDtoCopyWithImpl(this._self, this._then);

  final HookSkewDto _self;
  final $Res Function(HookSkewDto) _then;

/// Create a copy of HookSkewDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? host = null,Object? rev = freezed,Object? project = freezed,}) {
  return _then(_self.copyWith(
host: null == host ? _self.host : host // ignore: cast_nullable_to_non_nullable
as String,rev: freezed == rev ? _self.rev : rev // ignore: cast_nullable_to_non_nullable
as String?,project: freezed == project ? _self.project : project // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [HookSkewDto].
extension HookSkewDtoPatterns on HookSkewDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _HookSkewDto value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _HookSkewDto() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _HookSkewDto value)  $default,){
final _that = this;
switch (_that) {
case _HookSkewDto():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _HookSkewDto value)?  $default,){
final _that = this;
switch (_that) {
case _HookSkewDto() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String host,  String? rev, @JsonKey(name: 'project')  String? project)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _HookSkewDto() when $default != null:
return $default(_that.host,_that.rev,_that.project);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String host,  String? rev, @JsonKey(name: 'project')  String? project)  $default,) {final _that = this;
switch (_that) {
case _HookSkewDto():
return $default(_that.host,_that.rev,_that.project);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String host,  String? rev, @JsonKey(name: 'project')  String? project)?  $default,) {final _that = this;
switch (_that) {
case _HookSkewDto() when $default != null:
return $default(_that.host,_that.rev,_that.project);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _HookSkewDto implements HookSkewDto {
  const _HookSkewDto({required this.host, this.rev, @JsonKey(name: 'project') this.project});
  factory _HookSkewDto.fromJson(Map<String, dynamic> json) => _$HookSkewDtoFromJson(json);

/// 구버전 훅을 돌리는 기계명. `SessionViewDto.host`와 같은 값 공간이다.
@override final  String host;
/// 그 기계 훅이 신고한 리비전(8자리 hex). 훅이 아직 버전을 신고하지
/// 않는 더 구버전이면 null이다 — "모름"이 아니라 "더 오래됨"의 신호다.
@override final  String? rev;
/// 그 기계에서 이 훅이 마지막으로 관측된 프로젝트 경로. `SessionViewDto.
/// project`와 같은 값 공간(보통 절대경로)이다. devcontainer 등 host명이
/// 무작위 hex라 식별 불가한 경우를 위한 additive 필드라 서버 구버전
/// 응답에는 없을 수 있어 nullable이다 — null이면 host만으로 표시한다.
@override@JsonKey(name: 'project') final  String? project;

/// Create a copy of HookSkewDto
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$HookSkewDtoCopyWith<_HookSkewDto> get copyWith => __$HookSkewDtoCopyWithImpl<_HookSkewDto>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$HookSkewDtoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _HookSkewDto&&(identical(other.host, host) || other.host == host)&&(identical(other.rev, rev) || other.rev == rev)&&(identical(other.project, project) || other.project == project));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,host,rev,project);

@override
String toString() {
  return 'HookSkewDto(host: $host, rev: $rev, project: $project)';
}


}

/// @nodoc
abstract mixin class _$HookSkewDtoCopyWith<$Res> implements $HookSkewDtoCopyWith<$Res> {
  factory _$HookSkewDtoCopyWith(_HookSkewDto value, $Res Function(_HookSkewDto) _then) = __$HookSkewDtoCopyWithImpl;
@override @useResult
$Res call({
 String host, String? rev,@JsonKey(name: 'project') String? project
});




}
/// @nodoc
class __$HookSkewDtoCopyWithImpl<$Res>
    implements _$HookSkewDtoCopyWith<$Res> {
  __$HookSkewDtoCopyWithImpl(this._self, this._then);

  final _HookSkewDto _self;
  final $Res Function(_HookSkewDto) _then;

/// Create a copy of HookSkewDto
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? host = null,Object? rev = freezed,Object? project = freezed,}) {
  return _then(_HookSkewDto(
host: null == host ? _self.host : host // ignore: cast_nullable_to_non_nullable
as String,rev: freezed == rev ? _self.rev : rev // ignore: cast_nullable_to_non_nullable
as String?,project: freezed == project ? _self.project : project // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$SyncResponseDto {

@JsonKey(name: 'protocol_version') int get protocolVersion;/// true면 로컬 상태를 버리고 [sessions]로 갈아탄다.
 bool get reset;/// 이 응답까지 반영한 최대 전이 id. 다음 요청의 `since`에 그대로 넣는다.
 int get cursor;/// limit에 걸려 잘렸다. [cursor]로 즉시 한 번 더 요청한다.
@JsonKey(name: 'has_more') bool get hasMore;/// 서버 시각(epoch ms). 리듀서의 `nowMs`로 쓰는 것이 기본이다 —
/// 기기 시계가 틀어져도 알림 판정이 흔들리지 않는다.
@JsonKey(name: 'server_time') int get serverTime;/// 이 값보다 작은 전이 id는 보존 정리로 사라졌다.
@JsonKey(name: 'pruned_below_id') int get prunedBelowId;/// 서버가 쓰는 `DASHBOARD_STALL_MS`.
@JsonKey(name: 'stall_ms') int get stallMs;/// 음소거 종료 시각(epoch ms). null이면 음소거 아님.
@JsonKey(name: 'mute_until') int? get muteUntil;/// UI 표시 언어(서버 `dashboard_settings.ui_lang`, 정본은 서버 —
/// 서버 상태 계약). `'ko'`/`'en'` 또는 null — null이면
/// 서버가 아직 정하지 않아 각 기기가 자기 플랫폼 로케일을 쓴다는 뜻이다
/// (`'system'`은 로컬 기기 사실이라 서버에는 없는 값이다). [muteUntil]/
/// [hookSkew]와 같은 절대값 서버 상태 관용 — 매 응답(스냅샷·델타 공통)에
/// 무조건 대입된다(`sync_reducer.dart`의 `reduceSync` 참고).
@JsonKey(name: 'ui_lang') String? get uiLang; List<SessionViewDto> get sessions; List<TransitionDto> get transitions;/// 이번 델타가 건드린 `session_key` 목록(서버 편의 필드).
@JsonKey(name: 'sessions_touched') List<String> get sessionsTouched;/// 읽음/안읽음(seen) 마커 전체(읽음 계약) — 범위는 [sessions]의 스냅샷과
/// 같다(비-ended 세션), 매 응답(스냅샷·델타 공통)에 절대값으로 동봉된다.
/// `sync_reducer.dart`의 `reduceSync`가 이 배열을 `SyncState.
/// seenTransitionIds`에 MAX(로컬, 수신)로 멱등 병합한다 — 낙관 갱신
/// 직후 비행 중이던 옛 응답이 점을 되살리는 깜빡임을 막는다.
 List<SeenMarkerDto> get seen;/// 서버가 지금 서빙 중인 훅과 다른(구버전) 훅을 돌리는 기계 목록.
/// additive라 구형 응답에는 없을 수 있어 빈 리스트로 접힌다 — 빈
/// 배열은 "전부 최신"이지 "모름"이 아니다. `sync_reducer.dart`의
/// `reduceSync`가 이 값을 `SyncState.hookSkew`에 매 응답(스냅샷·델타
/// 공통) **무조건 대입**한다([muteUntil]과 같은 절대값 관용 —
/// [seen]의 MAX 병합과 다르다: 훅이 갱신되면 그 기계가 목록에서
/// 사라져야 하므로 "낮아지지 않는다"가 아니라 "매번 그대로"가 맞다).
@JsonKey(name: 'hook_skew') List<HookSkewDto> get hookSkew;
/// Create a copy of SyncResponseDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncResponseDtoCopyWith<SyncResponseDto> get copyWith => _$SyncResponseDtoCopyWithImpl<SyncResponseDto>(this as SyncResponseDto, _$identity);

  /// Serializes this SyncResponseDto to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncResponseDto&&(identical(other.protocolVersion, protocolVersion) || other.protocolVersion == protocolVersion)&&(identical(other.reset, reset) || other.reset == reset)&&(identical(other.cursor, cursor) || other.cursor == cursor)&&(identical(other.hasMore, hasMore) || other.hasMore == hasMore)&&(identical(other.serverTime, serverTime) || other.serverTime == serverTime)&&(identical(other.prunedBelowId, prunedBelowId) || other.prunedBelowId == prunedBelowId)&&(identical(other.stallMs, stallMs) || other.stallMs == stallMs)&&(identical(other.muteUntil, muteUntil) || other.muteUntil == muteUntil)&&(identical(other.uiLang, uiLang) || other.uiLang == uiLang)&&const DeepCollectionEquality().equals(other.sessions, sessions)&&const DeepCollectionEquality().equals(other.transitions, transitions)&&const DeepCollectionEquality().equals(other.sessionsTouched, sessionsTouched)&&const DeepCollectionEquality().equals(other.seen, seen)&&const DeepCollectionEquality().equals(other.hookSkew, hookSkew));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,protocolVersion,reset,cursor,hasMore,serverTime,prunedBelowId,stallMs,muteUntil,uiLang,const DeepCollectionEquality().hash(sessions),const DeepCollectionEquality().hash(transitions),const DeepCollectionEquality().hash(sessionsTouched),const DeepCollectionEquality().hash(seen),const DeepCollectionEquality().hash(hookSkew));

@override
String toString() {
  return 'SyncResponseDto(protocolVersion: $protocolVersion, reset: $reset, cursor: $cursor, hasMore: $hasMore, serverTime: $serverTime, prunedBelowId: $prunedBelowId, stallMs: $stallMs, muteUntil: $muteUntil, uiLang: $uiLang, sessions: $sessions, transitions: $transitions, sessionsTouched: $sessionsTouched, seen: $seen, hookSkew: $hookSkew)';
}


}

/// @nodoc
abstract mixin class $SyncResponseDtoCopyWith<$Res>  {
  factory $SyncResponseDtoCopyWith(SyncResponseDto value, $Res Function(SyncResponseDto) _then) = _$SyncResponseDtoCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'protocol_version') int protocolVersion, bool reset, int cursor,@JsonKey(name: 'has_more') bool hasMore,@JsonKey(name: 'server_time') int serverTime,@JsonKey(name: 'pruned_below_id') int prunedBelowId,@JsonKey(name: 'stall_ms') int stallMs,@JsonKey(name: 'mute_until') int? muteUntil,@JsonKey(name: 'ui_lang') String? uiLang, List<SessionViewDto> sessions, List<TransitionDto> transitions,@JsonKey(name: 'sessions_touched') List<String> sessionsTouched, List<SeenMarkerDto> seen,@JsonKey(name: 'hook_skew') List<HookSkewDto> hookSkew
});




}
/// @nodoc
class _$SyncResponseDtoCopyWithImpl<$Res>
    implements $SyncResponseDtoCopyWith<$Res> {
  _$SyncResponseDtoCopyWithImpl(this._self, this._then);

  final SyncResponseDto _self;
  final $Res Function(SyncResponseDto) _then;

/// Create a copy of SyncResponseDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? protocolVersion = null,Object? reset = null,Object? cursor = null,Object? hasMore = null,Object? serverTime = null,Object? prunedBelowId = null,Object? stallMs = null,Object? muteUntil = freezed,Object? uiLang = freezed,Object? sessions = null,Object? transitions = null,Object? sessionsTouched = null,Object? seen = null,Object? hookSkew = null,}) {
  return _then(_self.copyWith(
protocolVersion: null == protocolVersion ? _self.protocolVersion : protocolVersion // ignore: cast_nullable_to_non_nullable
as int,reset: null == reset ? _self.reset : reset // ignore: cast_nullable_to_non_nullable
as bool,cursor: null == cursor ? _self.cursor : cursor // ignore: cast_nullable_to_non_nullable
as int,hasMore: null == hasMore ? _self.hasMore : hasMore // ignore: cast_nullable_to_non_nullable
as bool,serverTime: null == serverTime ? _self.serverTime : serverTime // ignore: cast_nullable_to_non_nullable
as int,prunedBelowId: null == prunedBelowId ? _self.prunedBelowId : prunedBelowId // ignore: cast_nullable_to_non_nullable
as int,stallMs: null == stallMs ? _self.stallMs : stallMs // ignore: cast_nullable_to_non_nullable
as int,muteUntil: freezed == muteUntil ? _self.muteUntil : muteUntil // ignore: cast_nullable_to_non_nullable
as int?,uiLang: freezed == uiLang ? _self.uiLang : uiLang // ignore: cast_nullable_to_non_nullable
as String?,sessions: null == sessions ? _self.sessions : sessions // ignore: cast_nullable_to_non_nullable
as List<SessionViewDto>,transitions: null == transitions ? _self.transitions : transitions // ignore: cast_nullable_to_non_nullable
as List<TransitionDto>,sessionsTouched: null == sessionsTouched ? _self.sessionsTouched : sessionsTouched // ignore: cast_nullable_to_non_nullable
as List<String>,seen: null == seen ? _self.seen : seen // ignore: cast_nullable_to_non_nullable
as List<SeenMarkerDto>,hookSkew: null == hookSkew ? _self.hookSkew : hookSkew // ignore: cast_nullable_to_non_nullable
as List<HookSkewDto>,
  ));
}

}


/// Adds pattern-matching-related methods to [SyncResponseDto].
extension SyncResponseDtoPatterns on SyncResponseDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SyncResponseDto value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SyncResponseDto() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SyncResponseDto value)  $default,){
final _that = this;
switch (_that) {
case _SyncResponseDto():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SyncResponseDto value)?  $default,){
final _that = this;
switch (_that) {
case _SyncResponseDto() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(name: 'protocol_version')  int protocolVersion,  bool reset,  int cursor, @JsonKey(name: 'has_more')  bool hasMore, @JsonKey(name: 'server_time')  int serverTime, @JsonKey(name: 'pruned_below_id')  int prunedBelowId, @JsonKey(name: 'stall_ms')  int stallMs, @JsonKey(name: 'mute_until')  int? muteUntil, @JsonKey(name: 'ui_lang')  String? uiLang,  List<SessionViewDto> sessions,  List<TransitionDto> transitions, @JsonKey(name: 'sessions_touched')  List<String> sessionsTouched,  List<SeenMarkerDto> seen, @JsonKey(name: 'hook_skew')  List<HookSkewDto> hookSkew)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SyncResponseDto() when $default != null:
return $default(_that.protocolVersion,_that.reset,_that.cursor,_that.hasMore,_that.serverTime,_that.prunedBelowId,_that.stallMs,_that.muteUntil,_that.uiLang,_that.sessions,_that.transitions,_that.sessionsTouched,_that.seen,_that.hookSkew);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(name: 'protocol_version')  int protocolVersion,  bool reset,  int cursor, @JsonKey(name: 'has_more')  bool hasMore, @JsonKey(name: 'server_time')  int serverTime, @JsonKey(name: 'pruned_below_id')  int prunedBelowId, @JsonKey(name: 'stall_ms')  int stallMs, @JsonKey(name: 'mute_until')  int? muteUntil, @JsonKey(name: 'ui_lang')  String? uiLang,  List<SessionViewDto> sessions,  List<TransitionDto> transitions, @JsonKey(name: 'sessions_touched')  List<String> sessionsTouched,  List<SeenMarkerDto> seen, @JsonKey(name: 'hook_skew')  List<HookSkewDto> hookSkew)  $default,) {final _that = this;
switch (_that) {
case _SyncResponseDto():
return $default(_that.protocolVersion,_that.reset,_that.cursor,_that.hasMore,_that.serverTime,_that.prunedBelowId,_that.stallMs,_that.muteUntil,_that.uiLang,_that.sessions,_that.transitions,_that.sessionsTouched,_that.seen,_that.hookSkew);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(name: 'protocol_version')  int protocolVersion,  bool reset,  int cursor, @JsonKey(name: 'has_more')  bool hasMore, @JsonKey(name: 'server_time')  int serverTime, @JsonKey(name: 'pruned_below_id')  int prunedBelowId, @JsonKey(name: 'stall_ms')  int stallMs, @JsonKey(name: 'mute_until')  int? muteUntil, @JsonKey(name: 'ui_lang')  String? uiLang,  List<SessionViewDto> sessions,  List<TransitionDto> transitions, @JsonKey(name: 'sessions_touched')  List<String> sessionsTouched,  List<SeenMarkerDto> seen, @JsonKey(name: 'hook_skew')  List<HookSkewDto> hookSkew)?  $default,) {final _that = this;
switch (_that) {
case _SyncResponseDto() when $default != null:
return $default(_that.protocolVersion,_that.reset,_that.cursor,_that.hasMore,_that.serverTime,_that.prunedBelowId,_that.stallMs,_that.muteUntil,_that.uiLang,_that.sessions,_that.transitions,_that.sessionsTouched,_that.seen,_that.hookSkew);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _SyncResponseDto extends SyncResponseDto {
  const _SyncResponseDto({@JsonKey(name: 'protocol_version') this.protocolVersion = kDashboardProtocolVersion, this.reset = false, this.cursor = 0, @JsonKey(name: 'has_more') this.hasMore = false, @JsonKey(name: 'server_time') this.serverTime = 0, @JsonKey(name: 'pruned_below_id') this.prunedBelowId = 0, @JsonKey(name: 'stall_ms') this.stallMs = kDefaultStallMs, @JsonKey(name: 'mute_until') this.muteUntil, @JsonKey(name: 'ui_lang') this.uiLang, final  List<SessionViewDto> sessions = const <SessionViewDto>[], final  List<TransitionDto> transitions = const <TransitionDto>[], @JsonKey(name: 'sessions_touched') final  List<String> sessionsTouched = const <String>[], final  List<SeenMarkerDto> seen = const <SeenMarkerDto>[], @JsonKey(name: 'hook_skew') final  List<HookSkewDto> hookSkew = const <HookSkewDto>[]}): _sessions = sessions,_transitions = transitions,_sessionsTouched = sessionsTouched,_seen = seen,_hookSkew = hookSkew,super._();
  factory _SyncResponseDto.fromJson(Map<String, dynamic> json) => _$SyncResponseDtoFromJson(json);

@override@JsonKey(name: 'protocol_version') final  int protocolVersion;
/// true면 로컬 상태를 버리고 [sessions]로 갈아탄다.
@override@JsonKey() final  bool reset;
/// 이 응답까지 반영한 최대 전이 id. 다음 요청의 `since`에 그대로 넣는다.
@override@JsonKey() final  int cursor;
/// limit에 걸려 잘렸다. [cursor]로 즉시 한 번 더 요청한다.
@override@JsonKey(name: 'has_more') final  bool hasMore;
/// 서버 시각(epoch ms). 리듀서의 `nowMs`로 쓰는 것이 기본이다 —
/// 기기 시계가 틀어져도 알림 판정이 흔들리지 않는다.
@override@JsonKey(name: 'server_time') final  int serverTime;
/// 이 값보다 작은 전이 id는 보존 정리로 사라졌다.
@override@JsonKey(name: 'pruned_below_id') final  int prunedBelowId;
/// 서버가 쓰는 `DASHBOARD_STALL_MS`.
@override@JsonKey(name: 'stall_ms') final  int stallMs;
/// 음소거 종료 시각(epoch ms). null이면 음소거 아님.
@override@JsonKey(name: 'mute_until') final  int? muteUntil;
/// UI 표시 언어(서버 `dashboard_settings.ui_lang`, 정본은 서버 —
/// 서버 상태 계약). `'ko'`/`'en'` 또는 null — null이면
/// 서버가 아직 정하지 않아 각 기기가 자기 플랫폼 로케일을 쓴다는 뜻이다
/// (`'system'`은 로컬 기기 사실이라 서버에는 없는 값이다). [muteUntil]/
/// [hookSkew]와 같은 절대값 서버 상태 관용 — 매 응답(스냅샷·델타 공통)에
/// 무조건 대입된다(`sync_reducer.dart`의 `reduceSync` 참고).
@override@JsonKey(name: 'ui_lang') final  String? uiLang;
 final  List<SessionViewDto> _sessions;
@override@JsonKey() List<SessionViewDto> get sessions {
  if (_sessions is EqualUnmodifiableListView) return _sessions;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_sessions);
}

 final  List<TransitionDto> _transitions;
@override@JsonKey() List<TransitionDto> get transitions {
  if (_transitions is EqualUnmodifiableListView) return _transitions;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_transitions);
}

/// 이번 델타가 건드린 `session_key` 목록(서버 편의 필드).
 final  List<String> _sessionsTouched;
/// 이번 델타가 건드린 `session_key` 목록(서버 편의 필드).
@override@JsonKey(name: 'sessions_touched') List<String> get sessionsTouched {
  if (_sessionsTouched is EqualUnmodifiableListView) return _sessionsTouched;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_sessionsTouched);
}

/// 읽음/안읽음(seen) 마커 전체(읽음 계약) — 범위는 [sessions]의 스냅샷과
/// 같다(비-ended 세션), 매 응답(스냅샷·델타 공통)에 절대값으로 동봉된다.
/// `sync_reducer.dart`의 `reduceSync`가 이 배열을 `SyncState.
/// seenTransitionIds`에 MAX(로컬, 수신)로 멱등 병합한다 — 낙관 갱신
/// 직후 비행 중이던 옛 응답이 점을 되살리는 깜빡임을 막는다.
 final  List<SeenMarkerDto> _seen;
/// 읽음/안읽음(seen) 마커 전체(읽음 계약) — 범위는 [sessions]의 스냅샷과
/// 같다(비-ended 세션), 매 응답(스냅샷·델타 공통)에 절대값으로 동봉된다.
/// `sync_reducer.dart`의 `reduceSync`가 이 배열을 `SyncState.
/// seenTransitionIds`에 MAX(로컬, 수신)로 멱등 병합한다 — 낙관 갱신
/// 직후 비행 중이던 옛 응답이 점을 되살리는 깜빡임을 막는다.
@override@JsonKey() List<SeenMarkerDto> get seen {
  if (_seen is EqualUnmodifiableListView) return _seen;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_seen);
}

/// 서버가 지금 서빙 중인 훅과 다른(구버전) 훅을 돌리는 기계 목록.
/// additive라 구형 응답에는 없을 수 있어 빈 리스트로 접힌다 — 빈
/// 배열은 "전부 최신"이지 "모름"이 아니다. `sync_reducer.dart`의
/// `reduceSync`가 이 값을 `SyncState.hookSkew`에 매 응답(스냅샷·델타
/// 공통) **무조건 대입**한다([muteUntil]과 같은 절대값 관용 —
/// [seen]의 MAX 병합과 다르다: 훅이 갱신되면 그 기계가 목록에서
/// 사라져야 하므로 "낮아지지 않는다"가 아니라 "매번 그대로"가 맞다).
 final  List<HookSkewDto> _hookSkew;
/// 서버가 지금 서빙 중인 훅과 다른(구버전) 훅을 돌리는 기계 목록.
/// additive라 구형 응답에는 없을 수 있어 빈 리스트로 접힌다 — 빈
/// 배열은 "전부 최신"이지 "모름"이 아니다. `sync_reducer.dart`의
/// `reduceSync`가 이 값을 `SyncState.hookSkew`에 매 응답(스냅샷·델타
/// 공통) **무조건 대입**한다([muteUntil]과 같은 절대값 관용 —
/// [seen]의 MAX 병합과 다르다: 훅이 갱신되면 그 기계가 목록에서
/// 사라져야 하므로 "낮아지지 않는다"가 아니라 "매번 그대로"가 맞다).
@override@JsonKey(name: 'hook_skew') List<HookSkewDto> get hookSkew {
  if (_hookSkew is EqualUnmodifiableListView) return _hookSkew;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_hookSkew);
}


/// Create a copy of SyncResponseDto
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SyncResponseDtoCopyWith<_SyncResponseDto> get copyWith => __$SyncResponseDtoCopyWithImpl<_SyncResponseDto>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncResponseDtoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SyncResponseDto&&(identical(other.protocolVersion, protocolVersion) || other.protocolVersion == protocolVersion)&&(identical(other.reset, reset) || other.reset == reset)&&(identical(other.cursor, cursor) || other.cursor == cursor)&&(identical(other.hasMore, hasMore) || other.hasMore == hasMore)&&(identical(other.serverTime, serverTime) || other.serverTime == serverTime)&&(identical(other.prunedBelowId, prunedBelowId) || other.prunedBelowId == prunedBelowId)&&(identical(other.stallMs, stallMs) || other.stallMs == stallMs)&&(identical(other.muteUntil, muteUntil) || other.muteUntil == muteUntil)&&(identical(other.uiLang, uiLang) || other.uiLang == uiLang)&&const DeepCollectionEquality().equals(other._sessions, _sessions)&&const DeepCollectionEquality().equals(other._transitions, _transitions)&&const DeepCollectionEquality().equals(other._sessionsTouched, _sessionsTouched)&&const DeepCollectionEquality().equals(other._seen, _seen)&&const DeepCollectionEquality().equals(other._hookSkew, _hookSkew));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,protocolVersion,reset,cursor,hasMore,serverTime,prunedBelowId,stallMs,muteUntil,uiLang,const DeepCollectionEquality().hash(_sessions),const DeepCollectionEquality().hash(_transitions),const DeepCollectionEquality().hash(_sessionsTouched),const DeepCollectionEquality().hash(_seen),const DeepCollectionEquality().hash(_hookSkew));

@override
String toString() {
  return 'SyncResponseDto(protocolVersion: $protocolVersion, reset: $reset, cursor: $cursor, hasMore: $hasMore, serverTime: $serverTime, prunedBelowId: $prunedBelowId, stallMs: $stallMs, muteUntil: $muteUntil, uiLang: $uiLang, sessions: $sessions, transitions: $transitions, sessionsTouched: $sessionsTouched, seen: $seen, hookSkew: $hookSkew)';
}


}

/// @nodoc
abstract mixin class _$SyncResponseDtoCopyWith<$Res> implements $SyncResponseDtoCopyWith<$Res> {
  factory _$SyncResponseDtoCopyWith(_SyncResponseDto value, $Res Function(_SyncResponseDto) _then) = __$SyncResponseDtoCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'protocol_version') int protocolVersion, bool reset, int cursor,@JsonKey(name: 'has_more') bool hasMore,@JsonKey(name: 'server_time') int serverTime,@JsonKey(name: 'pruned_below_id') int prunedBelowId,@JsonKey(name: 'stall_ms') int stallMs,@JsonKey(name: 'mute_until') int? muteUntil,@JsonKey(name: 'ui_lang') String? uiLang, List<SessionViewDto> sessions, List<TransitionDto> transitions,@JsonKey(name: 'sessions_touched') List<String> sessionsTouched, List<SeenMarkerDto> seen,@JsonKey(name: 'hook_skew') List<HookSkewDto> hookSkew
});




}
/// @nodoc
class __$SyncResponseDtoCopyWithImpl<$Res>
    implements _$SyncResponseDtoCopyWith<$Res> {
  __$SyncResponseDtoCopyWithImpl(this._self, this._then);

  final _SyncResponseDto _self;
  final $Res Function(_SyncResponseDto) _then;

/// Create a copy of SyncResponseDto
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? protocolVersion = null,Object? reset = null,Object? cursor = null,Object? hasMore = null,Object? serverTime = null,Object? prunedBelowId = null,Object? stallMs = null,Object? muteUntil = freezed,Object? uiLang = freezed,Object? sessions = null,Object? transitions = null,Object? sessionsTouched = null,Object? seen = null,Object? hookSkew = null,}) {
  return _then(_SyncResponseDto(
protocolVersion: null == protocolVersion ? _self.protocolVersion : protocolVersion // ignore: cast_nullable_to_non_nullable
as int,reset: null == reset ? _self.reset : reset // ignore: cast_nullable_to_non_nullable
as bool,cursor: null == cursor ? _self.cursor : cursor // ignore: cast_nullable_to_non_nullable
as int,hasMore: null == hasMore ? _self.hasMore : hasMore // ignore: cast_nullable_to_non_nullable
as bool,serverTime: null == serverTime ? _self.serverTime : serverTime // ignore: cast_nullable_to_non_nullable
as int,prunedBelowId: null == prunedBelowId ? _self.prunedBelowId : prunedBelowId // ignore: cast_nullable_to_non_nullable
as int,stallMs: null == stallMs ? _self.stallMs : stallMs // ignore: cast_nullable_to_non_nullable
as int,muteUntil: freezed == muteUntil ? _self.muteUntil : muteUntil // ignore: cast_nullable_to_non_nullable
as int?,uiLang: freezed == uiLang ? _self.uiLang : uiLang // ignore: cast_nullable_to_non_nullable
as String?,sessions: null == sessions ? _self._sessions : sessions // ignore: cast_nullable_to_non_nullable
as List<SessionViewDto>,transitions: null == transitions ? _self._transitions : transitions // ignore: cast_nullable_to_non_nullable
as List<TransitionDto>,sessionsTouched: null == sessionsTouched ? _self._sessionsTouched : sessionsTouched // ignore: cast_nullable_to_non_nullable
as List<String>,seen: null == seen ? _self._seen : seen // ignore: cast_nullable_to_non_nullable
as List<SeenMarkerDto>,hookSkew: null == hookSkew ? _self._hookSkew : hookSkew // ignore: cast_nullable_to_non_nullable
as List<HookSkewDto>,
  ));
}


}


/// @nodoc
mixin _$PushConfigDto {

/// 서버가 실제로 발송 가능한 채널 목록(예: `['fcm']`). 비어 있으면
/// 자격증명이 없다는 뜻이다.
 List<String> get channels;/// 웹 FCM SDK 초기화 인자(apiKey/projectId/appId/messagingSenderId 등).
/// 키 구성이 SDK 버전마다 달라서 맵 그대로 들고 다닌다.
@JsonKey(name: 'firebase_config') Map<String, Object?> get firebaseConfig;/// 웹 푸시 구독에 쓰는 VAPID 공개키.
@JsonKey(name: 'vapid_key') String? get vapidKey;/// macOS/iOS 상주 앱이 `Firebase.initializeApp`에 코드로 주입하는 Apple
/// 앱 설정(apiKey/appId/messagingSenderId/projectId 등). 웹의
/// [firebaseConfig]와 **동형이지만 값이 다른 앱**이다 — 서버는
/// `FIREBASE_APPLE_CONFIG` env를 파싱해 그대로 전달만 한다(A안 설계 ③).
@JsonKey(name: 'apple_config') Map<String, Object?> get appleConfig;/// 서버가 직접 말한 "웹 클라이언트가 지금 `getToken()`을 불러도 되는가".
/// dashboard-server는 `web_config`와 `vapid_key`가 **둘 다** 있을 때만 true를
/// 보낸다. 서버가 이 값을 안 보내면(구형 응답) null이고, 그때는
/// [canSubscribeOnWeb]이 값의 존재로 직접 판정한다 — 즉 null은 "모름"이지
/// "false"가 아니다.
@JsonKey(name: 'client_ready') bool? get clientReady;/// [clientReady]의 Apple판 — "상주 앱이 지금 APNs 등록을 시도해도
/// 되는가". dashboard-server는 `apple_config`가 있을 때만 true를 보낸다.
/// 서버가 이 값을 안 보내면(D-server 이전의 구형 응답) null이고, 그때는
/// [canSubscribeOnApple]이 값의 존재로 직접 판정한다 — null은 "모름"이지
/// "false"가 아니다([clientReady]와 같은 관용).
@JsonKey(name: 'apple_client_ready') bool? get appleClientReady;/// 서비스워커 경로 등 서버가 얹어 보내는 부가 설정. 모르는 값은
/// 그대로 보관만 한다.
 Map<String, Object?> get options;
/// Create a copy of PushConfigDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PushConfigDtoCopyWith<PushConfigDto> get copyWith => _$PushConfigDtoCopyWithImpl<PushConfigDto>(this as PushConfigDto, _$identity);

  /// Serializes this PushConfigDto to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PushConfigDto&&const DeepCollectionEquality().equals(other.channels, channels)&&const DeepCollectionEquality().equals(other.firebaseConfig, firebaseConfig)&&(identical(other.vapidKey, vapidKey) || other.vapidKey == vapidKey)&&const DeepCollectionEquality().equals(other.appleConfig, appleConfig)&&(identical(other.clientReady, clientReady) || other.clientReady == clientReady)&&(identical(other.appleClientReady, appleClientReady) || other.appleClientReady == appleClientReady)&&const DeepCollectionEquality().equals(other.options, options));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(channels),const DeepCollectionEquality().hash(firebaseConfig),vapidKey,const DeepCollectionEquality().hash(appleConfig),clientReady,appleClientReady,const DeepCollectionEquality().hash(options));

@override
String toString() {
  return 'PushConfigDto(channels: $channels, firebaseConfig: $firebaseConfig, vapidKey: $vapidKey, appleConfig: $appleConfig, clientReady: $clientReady, appleClientReady: $appleClientReady, options: $options)';
}


}

/// @nodoc
abstract mixin class $PushConfigDtoCopyWith<$Res>  {
  factory $PushConfigDtoCopyWith(PushConfigDto value, $Res Function(PushConfigDto) _then) = _$PushConfigDtoCopyWithImpl;
@useResult
$Res call({
 List<String> channels,@JsonKey(name: 'firebase_config') Map<String, Object?> firebaseConfig,@JsonKey(name: 'vapid_key') String? vapidKey,@JsonKey(name: 'apple_config') Map<String, Object?> appleConfig,@JsonKey(name: 'client_ready') bool? clientReady,@JsonKey(name: 'apple_client_ready') bool? appleClientReady, Map<String, Object?> options
});




}
/// @nodoc
class _$PushConfigDtoCopyWithImpl<$Res>
    implements $PushConfigDtoCopyWith<$Res> {
  _$PushConfigDtoCopyWithImpl(this._self, this._then);

  final PushConfigDto _self;
  final $Res Function(PushConfigDto) _then;

/// Create a copy of PushConfigDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? channels = null,Object? firebaseConfig = null,Object? vapidKey = freezed,Object? appleConfig = null,Object? clientReady = freezed,Object? appleClientReady = freezed,Object? options = null,}) {
  return _then(_self.copyWith(
channels: null == channels ? _self.channels : channels // ignore: cast_nullable_to_non_nullable
as List<String>,firebaseConfig: null == firebaseConfig ? _self.firebaseConfig : firebaseConfig // ignore: cast_nullable_to_non_nullable
as Map<String, Object?>,vapidKey: freezed == vapidKey ? _self.vapidKey : vapidKey // ignore: cast_nullable_to_non_nullable
as String?,appleConfig: null == appleConfig ? _self.appleConfig : appleConfig // ignore: cast_nullable_to_non_nullable
as Map<String, Object?>,clientReady: freezed == clientReady ? _self.clientReady : clientReady // ignore: cast_nullable_to_non_nullable
as bool?,appleClientReady: freezed == appleClientReady ? _self.appleClientReady : appleClientReady // ignore: cast_nullable_to_non_nullable
as bool?,options: null == options ? _self.options : options // ignore: cast_nullable_to_non_nullable
as Map<String, Object?>,
  ));
}

}


/// Adds pattern-matching-related methods to [PushConfigDto].
extension PushConfigDtoPatterns on PushConfigDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PushConfigDto value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PushConfigDto() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PushConfigDto value)  $default,){
final _that = this;
switch (_that) {
case _PushConfigDto():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PushConfigDto value)?  $default,){
final _that = this;
switch (_that) {
case _PushConfigDto() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<String> channels, @JsonKey(name: 'firebase_config')  Map<String, Object?> firebaseConfig, @JsonKey(name: 'vapid_key')  String? vapidKey, @JsonKey(name: 'apple_config')  Map<String, Object?> appleConfig, @JsonKey(name: 'client_ready')  bool? clientReady, @JsonKey(name: 'apple_client_ready')  bool? appleClientReady,  Map<String, Object?> options)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PushConfigDto() when $default != null:
return $default(_that.channels,_that.firebaseConfig,_that.vapidKey,_that.appleConfig,_that.clientReady,_that.appleClientReady,_that.options);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<String> channels, @JsonKey(name: 'firebase_config')  Map<String, Object?> firebaseConfig, @JsonKey(name: 'vapid_key')  String? vapidKey, @JsonKey(name: 'apple_config')  Map<String, Object?> appleConfig, @JsonKey(name: 'client_ready')  bool? clientReady, @JsonKey(name: 'apple_client_ready')  bool? appleClientReady,  Map<String, Object?> options)  $default,) {final _that = this;
switch (_that) {
case _PushConfigDto():
return $default(_that.channels,_that.firebaseConfig,_that.vapidKey,_that.appleConfig,_that.clientReady,_that.appleClientReady,_that.options);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<String> channels, @JsonKey(name: 'firebase_config')  Map<String, Object?> firebaseConfig, @JsonKey(name: 'vapid_key')  String? vapidKey, @JsonKey(name: 'apple_config')  Map<String, Object?> appleConfig, @JsonKey(name: 'client_ready')  bool? clientReady, @JsonKey(name: 'apple_client_ready')  bool? appleClientReady,  Map<String, Object?> options)?  $default,) {final _that = this;
switch (_that) {
case _PushConfigDto() when $default != null:
return $default(_that.channels,_that.firebaseConfig,_that.vapidKey,_that.appleConfig,_that.clientReady,_that.appleClientReady,_that.options);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _PushConfigDto extends PushConfigDto {
  const _PushConfigDto({final  List<String> channels = const <String>[], @JsonKey(name: 'firebase_config') final  Map<String, Object?> firebaseConfig = const <String, Object?>{}, @JsonKey(name: 'vapid_key') this.vapidKey, @JsonKey(name: 'apple_config') final  Map<String, Object?> appleConfig = const <String, Object?>{}, @JsonKey(name: 'client_ready') this.clientReady, @JsonKey(name: 'apple_client_ready') this.appleClientReady, final  Map<String, Object?> options = const <String, Object?>{}}): _channels = channels,_firebaseConfig = firebaseConfig,_appleConfig = appleConfig,_options = options,super._();
  factory _PushConfigDto.fromJson(Map<String, dynamic> json) => _$PushConfigDtoFromJson(json);

/// 서버가 실제로 발송 가능한 채널 목록(예: `['fcm']`). 비어 있으면
/// 자격증명이 없다는 뜻이다.
 final  List<String> _channels;
/// 서버가 실제로 발송 가능한 채널 목록(예: `['fcm']`). 비어 있으면
/// 자격증명이 없다는 뜻이다.
@override@JsonKey() List<String> get channels {
  if (_channels is EqualUnmodifiableListView) return _channels;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_channels);
}

/// 웹 FCM SDK 초기화 인자(apiKey/projectId/appId/messagingSenderId 등).
/// 키 구성이 SDK 버전마다 달라서 맵 그대로 들고 다닌다.
 final  Map<String, Object?> _firebaseConfig;
/// 웹 FCM SDK 초기화 인자(apiKey/projectId/appId/messagingSenderId 등).
/// 키 구성이 SDK 버전마다 달라서 맵 그대로 들고 다닌다.
@override@JsonKey(name: 'firebase_config') Map<String, Object?> get firebaseConfig {
  if (_firebaseConfig is EqualUnmodifiableMapView) return _firebaseConfig;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_firebaseConfig);
}

/// 웹 푸시 구독에 쓰는 VAPID 공개키.
@override@JsonKey(name: 'vapid_key') final  String? vapidKey;
/// macOS/iOS 상주 앱이 `Firebase.initializeApp`에 코드로 주입하는 Apple
/// 앱 설정(apiKey/appId/messagingSenderId/projectId 등). 웹의
/// [firebaseConfig]와 **동형이지만 값이 다른 앱**이다 — 서버는
/// `FIREBASE_APPLE_CONFIG` env를 파싱해 그대로 전달만 한다(A안 설계 ③).
 final  Map<String, Object?> _appleConfig;
/// macOS/iOS 상주 앱이 `Firebase.initializeApp`에 코드로 주입하는 Apple
/// 앱 설정(apiKey/appId/messagingSenderId/projectId 등). 웹의
/// [firebaseConfig]와 **동형이지만 값이 다른 앱**이다 — 서버는
/// `FIREBASE_APPLE_CONFIG` env를 파싱해 그대로 전달만 한다(A안 설계 ③).
@override@JsonKey(name: 'apple_config') Map<String, Object?> get appleConfig {
  if (_appleConfig is EqualUnmodifiableMapView) return _appleConfig;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_appleConfig);
}

/// 서버가 직접 말한 "웹 클라이언트가 지금 `getToken()`을 불러도 되는가".
/// dashboard-server는 `web_config`와 `vapid_key`가 **둘 다** 있을 때만 true를
/// 보낸다. 서버가 이 값을 안 보내면(구형 응답) null이고, 그때는
/// [canSubscribeOnWeb]이 값의 존재로 직접 판정한다 — 즉 null은 "모름"이지
/// "false"가 아니다.
@override@JsonKey(name: 'client_ready') final  bool? clientReady;
/// [clientReady]의 Apple판 — "상주 앱이 지금 APNs 등록을 시도해도
/// 되는가". dashboard-server는 `apple_config`가 있을 때만 true를 보낸다.
/// 서버가 이 값을 안 보내면(D-server 이전의 구형 응답) null이고, 그때는
/// [canSubscribeOnApple]이 값의 존재로 직접 판정한다 — null은 "모름"이지
/// "false"가 아니다([clientReady]와 같은 관용).
@override@JsonKey(name: 'apple_client_ready') final  bool? appleClientReady;
/// 서비스워커 경로 등 서버가 얹어 보내는 부가 설정. 모르는 값은
/// 그대로 보관만 한다.
 final  Map<String, Object?> _options;
/// 서비스워커 경로 등 서버가 얹어 보내는 부가 설정. 모르는 값은
/// 그대로 보관만 한다.
@override@JsonKey() Map<String, Object?> get options {
  if (_options is EqualUnmodifiableMapView) return _options;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_options);
}


/// Create a copy of PushConfigDto
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PushConfigDtoCopyWith<_PushConfigDto> get copyWith => __$PushConfigDtoCopyWithImpl<_PushConfigDto>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PushConfigDtoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PushConfigDto&&const DeepCollectionEquality().equals(other._channels, _channels)&&const DeepCollectionEquality().equals(other._firebaseConfig, _firebaseConfig)&&(identical(other.vapidKey, vapidKey) || other.vapidKey == vapidKey)&&const DeepCollectionEquality().equals(other._appleConfig, _appleConfig)&&(identical(other.clientReady, clientReady) || other.clientReady == clientReady)&&(identical(other.appleClientReady, appleClientReady) || other.appleClientReady == appleClientReady)&&const DeepCollectionEquality().equals(other._options, _options));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_channels),const DeepCollectionEquality().hash(_firebaseConfig),vapidKey,const DeepCollectionEquality().hash(_appleConfig),clientReady,appleClientReady,const DeepCollectionEquality().hash(_options));

@override
String toString() {
  return 'PushConfigDto(channels: $channels, firebaseConfig: $firebaseConfig, vapidKey: $vapidKey, appleConfig: $appleConfig, clientReady: $clientReady, appleClientReady: $appleClientReady, options: $options)';
}


}

/// @nodoc
abstract mixin class _$PushConfigDtoCopyWith<$Res> implements $PushConfigDtoCopyWith<$Res> {
  factory _$PushConfigDtoCopyWith(_PushConfigDto value, $Res Function(_PushConfigDto) _then) = __$PushConfigDtoCopyWithImpl;
@override @useResult
$Res call({
 List<String> channels,@JsonKey(name: 'firebase_config') Map<String, Object?> firebaseConfig,@JsonKey(name: 'vapid_key') String? vapidKey,@JsonKey(name: 'apple_config') Map<String, Object?> appleConfig,@JsonKey(name: 'client_ready') bool? clientReady,@JsonKey(name: 'apple_client_ready') bool? appleClientReady, Map<String, Object?> options
});




}
/// @nodoc
class __$PushConfigDtoCopyWithImpl<$Res>
    implements _$PushConfigDtoCopyWith<$Res> {
  __$PushConfigDtoCopyWithImpl(this._self, this._then);

  final _PushConfigDto _self;
  final $Res Function(_PushConfigDto) _then;

/// Create a copy of PushConfigDto
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? channels = null,Object? firebaseConfig = null,Object? vapidKey = freezed,Object? appleConfig = null,Object? clientReady = freezed,Object? appleClientReady = freezed,Object? options = null,}) {
  return _then(_PushConfigDto(
channels: null == channels ? _self._channels : channels // ignore: cast_nullable_to_non_nullable
as List<String>,firebaseConfig: null == firebaseConfig ? _self._firebaseConfig : firebaseConfig // ignore: cast_nullable_to_non_nullable
as Map<String, Object?>,vapidKey: freezed == vapidKey ? _self.vapidKey : vapidKey // ignore: cast_nullable_to_non_nullable
as String?,appleConfig: null == appleConfig ? _self._appleConfig : appleConfig // ignore: cast_nullable_to_non_nullable
as Map<String, Object?>,clientReady: freezed == clientReady ? _self.clientReady : clientReady // ignore: cast_nullable_to_non_nullable
as bool?,appleClientReady: freezed == appleClientReady ? _self.appleClientReady : appleClientReady // ignore: cast_nullable_to_non_nullable
as bool?,options: null == options ? _self._options : options // ignore: cast_nullable_to_non_nullable
as Map<String, Object?>,
  ));
}


}


/// @nodoc
mixin _$PushLogEntryDto {

 String get transport; String get target; String get result; String? get detail;@JsonKey(name: 'created_at') int get createdAt;
/// Create a copy of PushLogEntryDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PushLogEntryDtoCopyWith<PushLogEntryDto> get copyWith => _$PushLogEntryDtoCopyWithImpl<PushLogEntryDto>(this as PushLogEntryDto, _$identity);

  /// Serializes this PushLogEntryDto to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PushLogEntryDto&&(identical(other.transport, transport) || other.transport == transport)&&(identical(other.target, target) || other.target == target)&&(identical(other.result, result) || other.result == result)&&(identical(other.detail, detail) || other.detail == detail)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,transport,target,result,detail,createdAt);

@override
String toString() {
  return 'PushLogEntryDto(transport: $transport, target: $target, result: $result, detail: $detail, createdAt: $createdAt)';
}


}

/// @nodoc
abstract mixin class $PushLogEntryDtoCopyWith<$Res>  {
  factory $PushLogEntryDtoCopyWith(PushLogEntryDto value, $Res Function(PushLogEntryDto) _then) = _$PushLogEntryDtoCopyWithImpl;
@useResult
$Res call({
 String transport, String target, String result, String? detail,@JsonKey(name: 'created_at') int createdAt
});




}
/// @nodoc
class _$PushLogEntryDtoCopyWithImpl<$Res>
    implements $PushLogEntryDtoCopyWith<$Res> {
  _$PushLogEntryDtoCopyWithImpl(this._self, this._then);

  final PushLogEntryDto _self;
  final $Res Function(PushLogEntryDto) _then;

/// Create a copy of PushLogEntryDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? transport = null,Object? target = null,Object? result = null,Object? detail = freezed,Object? createdAt = null,}) {
  return _then(_self.copyWith(
transport: null == transport ? _self.transport : transport // ignore: cast_nullable_to_non_nullable
as String,target: null == target ? _self.target : target // ignore: cast_nullable_to_non_nullable
as String,result: null == result ? _self.result : result // ignore: cast_nullable_to_non_nullable
as String,detail: freezed == detail ? _self.detail : detail // ignore: cast_nullable_to_non_nullable
as String?,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [PushLogEntryDto].
extension PushLogEntryDtoPatterns on PushLogEntryDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PushLogEntryDto value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PushLogEntryDto() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PushLogEntryDto value)  $default,){
final _that = this;
switch (_that) {
case _PushLogEntryDto():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PushLogEntryDto value)?  $default,){
final _that = this;
switch (_that) {
case _PushLogEntryDto() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String transport,  String target,  String result,  String? detail, @JsonKey(name: 'created_at')  int createdAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PushLogEntryDto() when $default != null:
return $default(_that.transport,_that.target,_that.result,_that.detail,_that.createdAt);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String transport,  String target,  String result,  String? detail, @JsonKey(name: 'created_at')  int createdAt)  $default,) {final _that = this;
switch (_that) {
case _PushLogEntryDto():
return $default(_that.transport,_that.target,_that.result,_that.detail,_that.createdAt);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String transport,  String target,  String result,  String? detail, @JsonKey(name: 'created_at')  int createdAt)?  $default,) {final _that = this;
switch (_that) {
case _PushLogEntryDto() when $default != null:
return $default(_that.transport,_that.target,_that.result,_that.detail,_that.createdAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _PushLogEntryDto implements PushLogEntryDto {
  const _PushLogEntryDto({this.transport = '', this.target = '', this.result = '', this.detail, @JsonKey(name: 'created_at') this.createdAt = 0});
  factory _PushLogEntryDto.fromJson(Map<String, dynamic> json) => _$PushLogEntryDtoFromJson(json);

@override@JsonKey() final  String transport;
@override@JsonKey() final  String target;
@override@JsonKey() final  String result;
@override final  String? detail;
@override@JsonKey(name: 'created_at') final  int createdAt;

/// Create a copy of PushLogEntryDto
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PushLogEntryDtoCopyWith<_PushLogEntryDto> get copyWith => __$PushLogEntryDtoCopyWithImpl<_PushLogEntryDto>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PushLogEntryDtoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PushLogEntryDto&&(identical(other.transport, transport) || other.transport == transport)&&(identical(other.target, target) || other.target == target)&&(identical(other.result, result) || other.result == result)&&(identical(other.detail, detail) || other.detail == detail)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,transport,target,result,detail,createdAt);

@override
String toString() {
  return 'PushLogEntryDto(transport: $transport, target: $target, result: $result, detail: $detail, createdAt: $createdAt)';
}


}

/// @nodoc
abstract mixin class _$PushLogEntryDtoCopyWith<$Res> implements $PushLogEntryDtoCopyWith<$Res> {
  factory _$PushLogEntryDtoCopyWith(_PushLogEntryDto value, $Res Function(_PushLogEntryDto) _then) = __$PushLogEntryDtoCopyWithImpl;
@override @useResult
$Res call({
 String transport, String target, String result, String? detail,@JsonKey(name: 'created_at') int createdAt
});




}
/// @nodoc
class __$PushLogEntryDtoCopyWithImpl<$Res>
    implements _$PushLogEntryDtoCopyWith<$Res> {
  __$PushLogEntryDtoCopyWithImpl(this._self, this._then);

  final _PushLogEntryDto _self;
  final $Res Function(_PushLogEntryDto) _then;

/// Create a copy of PushLogEntryDto
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? transport = null,Object? target = null,Object? result = null,Object? detail = freezed,Object? createdAt = null,}) {
  return _then(_PushLogEntryDto(
transport: null == transport ? _self.transport : transport // ignore: cast_nullable_to_non_nullable
as String,target: null == target ? _self.target : target // ignore: cast_nullable_to_non_nullable
as String,result: null == result ? _self.result : result // ignore: cast_nullable_to_non_nullable
as String,detail: freezed == detail ? _self.detail : detail // ignore: cast_nullable_to_non_nullable
as String?,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}


/// @nodoc
mixin _$DiagnosticsDto {

@JsonKey(name: 'last_event_at') int? get lastEventAt;@JsonKey(name: 'max_transition_id') int get maxTransitionId;@JsonKey(name: 'pruned_below_id') int get prunedBelowId;@JsonKey(name: 'last_push') PushLogEntryDto? get lastPush;@JsonKey(name: 'device_failure_count') int get deviceFailureCount;@JsonKey(name: 'subscription_failure_count') int get subscriptionFailureCount;/// 채널별 자격증명 유무(예: `{'fcm': true, 'web-push': false}`).
 Map<String, bool> get channels;@JsonKey(name: 'table_counts') Map<String, int> get tableCounts;
/// Create a copy of DiagnosticsDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DiagnosticsDtoCopyWith<DiagnosticsDto> get copyWith => _$DiagnosticsDtoCopyWithImpl<DiagnosticsDto>(this as DiagnosticsDto, _$identity);

  /// Serializes this DiagnosticsDto to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DiagnosticsDto&&(identical(other.lastEventAt, lastEventAt) || other.lastEventAt == lastEventAt)&&(identical(other.maxTransitionId, maxTransitionId) || other.maxTransitionId == maxTransitionId)&&(identical(other.prunedBelowId, prunedBelowId) || other.prunedBelowId == prunedBelowId)&&(identical(other.lastPush, lastPush) || other.lastPush == lastPush)&&(identical(other.deviceFailureCount, deviceFailureCount) || other.deviceFailureCount == deviceFailureCount)&&(identical(other.subscriptionFailureCount, subscriptionFailureCount) || other.subscriptionFailureCount == subscriptionFailureCount)&&const DeepCollectionEquality().equals(other.channels, channels)&&const DeepCollectionEquality().equals(other.tableCounts, tableCounts));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,lastEventAt,maxTransitionId,prunedBelowId,lastPush,deviceFailureCount,subscriptionFailureCount,const DeepCollectionEquality().hash(channels),const DeepCollectionEquality().hash(tableCounts));

@override
String toString() {
  return 'DiagnosticsDto(lastEventAt: $lastEventAt, maxTransitionId: $maxTransitionId, prunedBelowId: $prunedBelowId, lastPush: $lastPush, deviceFailureCount: $deviceFailureCount, subscriptionFailureCount: $subscriptionFailureCount, channels: $channels, tableCounts: $tableCounts)';
}


}

/// @nodoc
abstract mixin class $DiagnosticsDtoCopyWith<$Res>  {
  factory $DiagnosticsDtoCopyWith(DiagnosticsDto value, $Res Function(DiagnosticsDto) _then) = _$DiagnosticsDtoCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'last_event_at') int? lastEventAt,@JsonKey(name: 'max_transition_id') int maxTransitionId,@JsonKey(name: 'pruned_below_id') int prunedBelowId,@JsonKey(name: 'last_push') PushLogEntryDto? lastPush,@JsonKey(name: 'device_failure_count') int deviceFailureCount,@JsonKey(name: 'subscription_failure_count') int subscriptionFailureCount, Map<String, bool> channels,@JsonKey(name: 'table_counts') Map<String, int> tableCounts
});


$PushLogEntryDtoCopyWith<$Res>? get lastPush;

}
/// @nodoc
class _$DiagnosticsDtoCopyWithImpl<$Res>
    implements $DiagnosticsDtoCopyWith<$Res> {
  _$DiagnosticsDtoCopyWithImpl(this._self, this._then);

  final DiagnosticsDto _self;
  final $Res Function(DiagnosticsDto) _then;

/// Create a copy of DiagnosticsDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? lastEventAt = freezed,Object? maxTransitionId = null,Object? prunedBelowId = null,Object? lastPush = freezed,Object? deviceFailureCount = null,Object? subscriptionFailureCount = null,Object? channels = null,Object? tableCounts = null,}) {
  return _then(_self.copyWith(
lastEventAt: freezed == lastEventAt ? _self.lastEventAt : lastEventAt // ignore: cast_nullable_to_non_nullable
as int?,maxTransitionId: null == maxTransitionId ? _self.maxTransitionId : maxTransitionId // ignore: cast_nullable_to_non_nullable
as int,prunedBelowId: null == prunedBelowId ? _self.prunedBelowId : prunedBelowId // ignore: cast_nullable_to_non_nullable
as int,lastPush: freezed == lastPush ? _self.lastPush : lastPush // ignore: cast_nullable_to_non_nullable
as PushLogEntryDto?,deviceFailureCount: null == deviceFailureCount ? _self.deviceFailureCount : deviceFailureCount // ignore: cast_nullable_to_non_nullable
as int,subscriptionFailureCount: null == subscriptionFailureCount ? _self.subscriptionFailureCount : subscriptionFailureCount // ignore: cast_nullable_to_non_nullable
as int,channels: null == channels ? _self.channels : channels // ignore: cast_nullable_to_non_nullable
as Map<String, bool>,tableCounts: null == tableCounts ? _self.tableCounts : tableCounts // ignore: cast_nullable_to_non_nullable
as Map<String, int>,
  ));
}
/// Create a copy of DiagnosticsDto
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PushLogEntryDtoCopyWith<$Res>? get lastPush {
    if (_self.lastPush == null) {
    return null;
  }

  return $PushLogEntryDtoCopyWith<$Res>(_self.lastPush!, (value) {
    return _then(_self.copyWith(lastPush: value));
  });
}
}


/// Adds pattern-matching-related methods to [DiagnosticsDto].
extension DiagnosticsDtoPatterns on DiagnosticsDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _DiagnosticsDto value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _DiagnosticsDto() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _DiagnosticsDto value)  $default,){
final _that = this;
switch (_that) {
case _DiagnosticsDto():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _DiagnosticsDto value)?  $default,){
final _that = this;
switch (_that) {
case _DiagnosticsDto() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(name: 'last_event_at')  int? lastEventAt, @JsonKey(name: 'max_transition_id')  int maxTransitionId, @JsonKey(name: 'pruned_below_id')  int prunedBelowId, @JsonKey(name: 'last_push')  PushLogEntryDto? lastPush, @JsonKey(name: 'device_failure_count')  int deviceFailureCount, @JsonKey(name: 'subscription_failure_count')  int subscriptionFailureCount,  Map<String, bool> channels, @JsonKey(name: 'table_counts')  Map<String, int> tableCounts)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _DiagnosticsDto() when $default != null:
return $default(_that.lastEventAt,_that.maxTransitionId,_that.prunedBelowId,_that.lastPush,_that.deviceFailureCount,_that.subscriptionFailureCount,_that.channels,_that.tableCounts);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(name: 'last_event_at')  int? lastEventAt, @JsonKey(name: 'max_transition_id')  int maxTransitionId, @JsonKey(name: 'pruned_below_id')  int prunedBelowId, @JsonKey(name: 'last_push')  PushLogEntryDto? lastPush, @JsonKey(name: 'device_failure_count')  int deviceFailureCount, @JsonKey(name: 'subscription_failure_count')  int subscriptionFailureCount,  Map<String, bool> channels, @JsonKey(name: 'table_counts')  Map<String, int> tableCounts)  $default,) {final _that = this;
switch (_that) {
case _DiagnosticsDto():
return $default(_that.lastEventAt,_that.maxTransitionId,_that.prunedBelowId,_that.lastPush,_that.deviceFailureCount,_that.subscriptionFailureCount,_that.channels,_that.tableCounts);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(name: 'last_event_at')  int? lastEventAt, @JsonKey(name: 'max_transition_id')  int maxTransitionId, @JsonKey(name: 'pruned_below_id')  int prunedBelowId, @JsonKey(name: 'last_push')  PushLogEntryDto? lastPush, @JsonKey(name: 'device_failure_count')  int deviceFailureCount, @JsonKey(name: 'subscription_failure_count')  int subscriptionFailureCount,  Map<String, bool> channels, @JsonKey(name: 'table_counts')  Map<String, int> tableCounts)?  $default,) {final _that = this;
switch (_that) {
case _DiagnosticsDto() when $default != null:
return $default(_that.lastEventAt,_that.maxTransitionId,_that.prunedBelowId,_that.lastPush,_that.deviceFailureCount,_that.subscriptionFailureCount,_that.channels,_that.tableCounts);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _DiagnosticsDto extends DiagnosticsDto {
  const _DiagnosticsDto({@JsonKey(name: 'last_event_at') this.lastEventAt, @JsonKey(name: 'max_transition_id') this.maxTransitionId = 0, @JsonKey(name: 'pruned_below_id') this.prunedBelowId = 0, @JsonKey(name: 'last_push') this.lastPush, @JsonKey(name: 'device_failure_count') this.deviceFailureCount = 0, @JsonKey(name: 'subscription_failure_count') this.subscriptionFailureCount = 0, final  Map<String, bool> channels = const <String, bool>{}, @JsonKey(name: 'table_counts') final  Map<String, int> tableCounts = const <String, int>{}}): _channels = channels,_tableCounts = tableCounts,super._();
  factory _DiagnosticsDto.fromJson(Map<String, dynamic> json) => _$DiagnosticsDtoFromJson(json);

@override@JsonKey(name: 'last_event_at') final  int? lastEventAt;
@override@JsonKey(name: 'max_transition_id') final  int maxTransitionId;
@override@JsonKey(name: 'pruned_below_id') final  int prunedBelowId;
@override@JsonKey(name: 'last_push') final  PushLogEntryDto? lastPush;
@override@JsonKey(name: 'device_failure_count') final  int deviceFailureCount;
@override@JsonKey(name: 'subscription_failure_count') final  int subscriptionFailureCount;
/// 채널별 자격증명 유무(예: `{'fcm': true, 'web-push': false}`).
 final  Map<String, bool> _channels;
/// 채널별 자격증명 유무(예: `{'fcm': true, 'web-push': false}`).
@override@JsonKey() Map<String, bool> get channels {
  if (_channels is EqualUnmodifiableMapView) return _channels;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_channels);
}

 final  Map<String, int> _tableCounts;
@override@JsonKey(name: 'table_counts') Map<String, int> get tableCounts {
  if (_tableCounts is EqualUnmodifiableMapView) return _tableCounts;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_tableCounts);
}


/// Create a copy of DiagnosticsDto
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$DiagnosticsDtoCopyWith<_DiagnosticsDto> get copyWith => __$DiagnosticsDtoCopyWithImpl<_DiagnosticsDto>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$DiagnosticsDtoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _DiagnosticsDto&&(identical(other.lastEventAt, lastEventAt) || other.lastEventAt == lastEventAt)&&(identical(other.maxTransitionId, maxTransitionId) || other.maxTransitionId == maxTransitionId)&&(identical(other.prunedBelowId, prunedBelowId) || other.prunedBelowId == prunedBelowId)&&(identical(other.lastPush, lastPush) || other.lastPush == lastPush)&&(identical(other.deviceFailureCount, deviceFailureCount) || other.deviceFailureCount == deviceFailureCount)&&(identical(other.subscriptionFailureCount, subscriptionFailureCount) || other.subscriptionFailureCount == subscriptionFailureCount)&&const DeepCollectionEquality().equals(other._channels, _channels)&&const DeepCollectionEquality().equals(other._tableCounts, _tableCounts));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,lastEventAt,maxTransitionId,prunedBelowId,lastPush,deviceFailureCount,subscriptionFailureCount,const DeepCollectionEquality().hash(_channels),const DeepCollectionEquality().hash(_tableCounts));

@override
String toString() {
  return 'DiagnosticsDto(lastEventAt: $lastEventAt, maxTransitionId: $maxTransitionId, prunedBelowId: $prunedBelowId, lastPush: $lastPush, deviceFailureCount: $deviceFailureCount, subscriptionFailureCount: $subscriptionFailureCount, channels: $channels, tableCounts: $tableCounts)';
}


}

/// @nodoc
abstract mixin class _$DiagnosticsDtoCopyWith<$Res> implements $DiagnosticsDtoCopyWith<$Res> {
  factory _$DiagnosticsDtoCopyWith(_DiagnosticsDto value, $Res Function(_DiagnosticsDto) _then) = __$DiagnosticsDtoCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'last_event_at') int? lastEventAt,@JsonKey(name: 'max_transition_id') int maxTransitionId,@JsonKey(name: 'pruned_below_id') int prunedBelowId,@JsonKey(name: 'last_push') PushLogEntryDto? lastPush,@JsonKey(name: 'device_failure_count') int deviceFailureCount,@JsonKey(name: 'subscription_failure_count') int subscriptionFailureCount, Map<String, bool> channels,@JsonKey(name: 'table_counts') Map<String, int> tableCounts
});


@override $PushLogEntryDtoCopyWith<$Res>? get lastPush;

}
/// @nodoc
class __$DiagnosticsDtoCopyWithImpl<$Res>
    implements _$DiagnosticsDtoCopyWith<$Res> {
  __$DiagnosticsDtoCopyWithImpl(this._self, this._then);

  final _DiagnosticsDto _self;
  final $Res Function(_DiagnosticsDto) _then;

/// Create a copy of DiagnosticsDto
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? lastEventAt = freezed,Object? maxTransitionId = null,Object? prunedBelowId = null,Object? lastPush = freezed,Object? deviceFailureCount = null,Object? subscriptionFailureCount = null,Object? channels = null,Object? tableCounts = null,}) {
  return _then(_DiagnosticsDto(
lastEventAt: freezed == lastEventAt ? _self.lastEventAt : lastEventAt // ignore: cast_nullable_to_non_nullable
as int?,maxTransitionId: null == maxTransitionId ? _self.maxTransitionId : maxTransitionId // ignore: cast_nullable_to_non_nullable
as int,prunedBelowId: null == prunedBelowId ? _self.prunedBelowId : prunedBelowId // ignore: cast_nullable_to_non_nullable
as int,lastPush: freezed == lastPush ? _self.lastPush : lastPush // ignore: cast_nullable_to_non_nullable
as PushLogEntryDto?,deviceFailureCount: null == deviceFailureCount ? _self.deviceFailureCount : deviceFailureCount // ignore: cast_nullable_to_non_nullable
as int,subscriptionFailureCount: null == subscriptionFailureCount ? _self.subscriptionFailureCount : subscriptionFailureCount // ignore: cast_nullable_to_non_nullable
as int,channels: null == channels ? _self._channels : channels // ignore: cast_nullable_to_non_nullable
as Map<String, bool>,tableCounts: null == tableCounts ? _self._tableCounts : tableCounts // ignore: cast_nullable_to_non_nullable
as Map<String, int>,
  ));
}

/// Create a copy of DiagnosticsDto
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$PushLogEntryDtoCopyWith<$Res>? get lastPush {
    if (_self.lastPush == null) {
    return null;
  }

  return $PushLogEntryDtoCopyWith<$Res>(_self.lastPush!, (value) {
    return _then(_self.copyWith(lastPush: value));
  });
}
}


/// @nodoc
mixin _$PushChannelResultDto {

 int get sent; int get removed;/// 보내지 않았다면 그 사유(자격증명 미설정·대상 없음 등).
 String? get skipped;
/// Create a copy of PushChannelResultDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PushChannelResultDtoCopyWith<PushChannelResultDto> get copyWith => _$PushChannelResultDtoCopyWithImpl<PushChannelResultDto>(this as PushChannelResultDto, _$identity);

  /// Serializes this PushChannelResultDto to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PushChannelResultDto&&(identical(other.sent, sent) || other.sent == sent)&&(identical(other.removed, removed) || other.removed == removed)&&(identical(other.skipped, skipped) || other.skipped == skipped));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,sent,removed,skipped);

@override
String toString() {
  return 'PushChannelResultDto(sent: $sent, removed: $removed, skipped: $skipped)';
}


}

/// @nodoc
abstract mixin class $PushChannelResultDtoCopyWith<$Res>  {
  factory $PushChannelResultDtoCopyWith(PushChannelResultDto value, $Res Function(PushChannelResultDto) _then) = _$PushChannelResultDtoCopyWithImpl;
@useResult
$Res call({
 int sent, int removed, String? skipped
});




}
/// @nodoc
class _$PushChannelResultDtoCopyWithImpl<$Res>
    implements $PushChannelResultDtoCopyWith<$Res> {
  _$PushChannelResultDtoCopyWithImpl(this._self, this._then);

  final PushChannelResultDto _self;
  final $Res Function(PushChannelResultDto) _then;

/// Create a copy of PushChannelResultDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? sent = null,Object? removed = null,Object? skipped = freezed,}) {
  return _then(_self.copyWith(
sent: null == sent ? _self.sent : sent // ignore: cast_nullable_to_non_nullable
as int,removed: null == removed ? _self.removed : removed // ignore: cast_nullable_to_non_nullable
as int,skipped: freezed == skipped ? _self.skipped : skipped // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [PushChannelResultDto].
extension PushChannelResultDtoPatterns on PushChannelResultDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PushChannelResultDto value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PushChannelResultDto() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PushChannelResultDto value)  $default,){
final _that = this;
switch (_that) {
case _PushChannelResultDto():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PushChannelResultDto value)?  $default,){
final _that = this;
switch (_that) {
case _PushChannelResultDto() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int sent,  int removed,  String? skipped)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PushChannelResultDto() when $default != null:
return $default(_that.sent,_that.removed,_that.skipped);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int sent,  int removed,  String? skipped)  $default,) {final _that = this;
switch (_that) {
case _PushChannelResultDto():
return $default(_that.sent,_that.removed,_that.skipped);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int sent,  int removed,  String? skipped)?  $default,) {final _that = this;
switch (_that) {
case _PushChannelResultDto() when $default != null:
return $default(_that.sent,_that.removed,_that.skipped);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _PushChannelResultDto implements PushChannelResultDto {
  const _PushChannelResultDto({this.sent = 0, this.removed = 0, this.skipped});
  factory _PushChannelResultDto.fromJson(Map<String, dynamic> json) => _$PushChannelResultDtoFromJson(json);

@override@JsonKey() final  int sent;
@override@JsonKey() final  int removed;
/// 보내지 않았다면 그 사유(자격증명 미설정·대상 없음 등).
@override final  String? skipped;

/// Create a copy of PushChannelResultDto
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PushChannelResultDtoCopyWith<_PushChannelResultDto> get copyWith => __$PushChannelResultDtoCopyWithImpl<_PushChannelResultDto>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PushChannelResultDtoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PushChannelResultDto&&(identical(other.sent, sent) || other.sent == sent)&&(identical(other.removed, removed) || other.removed == removed)&&(identical(other.skipped, skipped) || other.skipped == skipped));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,sent,removed,skipped);

@override
String toString() {
  return 'PushChannelResultDto(sent: $sent, removed: $removed, skipped: $skipped)';
}


}

/// @nodoc
abstract mixin class _$PushChannelResultDtoCopyWith<$Res> implements $PushChannelResultDtoCopyWith<$Res> {
  factory _$PushChannelResultDtoCopyWith(_PushChannelResultDto value, $Res Function(_PushChannelResultDto) _then) = __$PushChannelResultDtoCopyWithImpl;
@override @useResult
$Res call({
 int sent, int removed, String? skipped
});




}
/// @nodoc
class __$PushChannelResultDtoCopyWithImpl<$Res>
    implements _$PushChannelResultDtoCopyWith<$Res> {
  __$PushChannelResultDtoCopyWithImpl(this._self, this._then);

  final _PushChannelResultDto _self;
  final $Res Function(_PushChannelResultDto) _then;

/// Create a copy of PushChannelResultDto
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? sent = null,Object? removed = null,Object? skipped = freezed,}) {
  return _then(_PushChannelResultDto(
sent: null == sent ? _self.sent : sent // ignore: cast_nullable_to_non_nullable
as int,removed: null == removed ? _self.removed : removed // ignore: cast_nullable_to_non_nullable
as int,skipped: freezed == skipped ? _self.skipped : skipped // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$TestPushResultDto {

 bool get ok;/// 발송용으로 적재된 합성 전이의 커서 id.
@JsonKey(name: 'transition_id') int get transitionId; Map<String, PushChannelResultDto> get channels;
/// Create a copy of TestPushResultDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TestPushResultDtoCopyWith<TestPushResultDto> get copyWith => _$TestPushResultDtoCopyWithImpl<TestPushResultDto>(this as TestPushResultDto, _$identity);

  /// Serializes this TestPushResultDto to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TestPushResultDto&&(identical(other.ok, ok) || other.ok == ok)&&(identical(other.transitionId, transitionId) || other.transitionId == transitionId)&&const DeepCollectionEquality().equals(other.channels, channels));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,ok,transitionId,const DeepCollectionEquality().hash(channels));

@override
String toString() {
  return 'TestPushResultDto(ok: $ok, transitionId: $transitionId, channels: $channels)';
}


}

/// @nodoc
abstract mixin class $TestPushResultDtoCopyWith<$Res>  {
  factory $TestPushResultDtoCopyWith(TestPushResultDto value, $Res Function(TestPushResultDto) _then) = _$TestPushResultDtoCopyWithImpl;
@useResult
$Res call({
 bool ok,@JsonKey(name: 'transition_id') int transitionId, Map<String, PushChannelResultDto> channels
});




}
/// @nodoc
class _$TestPushResultDtoCopyWithImpl<$Res>
    implements $TestPushResultDtoCopyWith<$Res> {
  _$TestPushResultDtoCopyWithImpl(this._self, this._then);

  final TestPushResultDto _self;
  final $Res Function(TestPushResultDto) _then;

/// Create a copy of TestPushResultDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? ok = null,Object? transitionId = null,Object? channels = null,}) {
  return _then(_self.copyWith(
ok: null == ok ? _self.ok : ok // ignore: cast_nullable_to_non_nullable
as bool,transitionId: null == transitionId ? _self.transitionId : transitionId // ignore: cast_nullable_to_non_nullable
as int,channels: null == channels ? _self.channels : channels // ignore: cast_nullable_to_non_nullable
as Map<String, PushChannelResultDto>,
  ));
}

}


/// Adds pattern-matching-related methods to [TestPushResultDto].
extension TestPushResultDtoPatterns on TestPushResultDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TestPushResultDto value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TestPushResultDto() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TestPushResultDto value)  $default,){
final _that = this;
switch (_that) {
case _TestPushResultDto():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TestPushResultDto value)?  $default,){
final _that = this;
switch (_that) {
case _TestPushResultDto() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( bool ok, @JsonKey(name: 'transition_id')  int transitionId,  Map<String, PushChannelResultDto> channels)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TestPushResultDto() when $default != null:
return $default(_that.ok,_that.transitionId,_that.channels);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( bool ok, @JsonKey(name: 'transition_id')  int transitionId,  Map<String, PushChannelResultDto> channels)  $default,) {final _that = this;
switch (_that) {
case _TestPushResultDto():
return $default(_that.ok,_that.transitionId,_that.channels);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( bool ok, @JsonKey(name: 'transition_id')  int transitionId,  Map<String, PushChannelResultDto> channels)?  $default,) {final _that = this;
switch (_that) {
case _TestPushResultDto() when $default != null:
return $default(_that.ok,_that.transitionId,_that.channels);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _TestPushResultDto extends TestPushResultDto {
  const _TestPushResultDto({this.ok = false, @JsonKey(name: 'transition_id') this.transitionId = 0, final  Map<String, PushChannelResultDto> channels = const <String, PushChannelResultDto>{}}): _channels = channels,super._();
  factory _TestPushResultDto.fromJson(Map<String, dynamic> json) => _$TestPushResultDtoFromJson(json);

@override@JsonKey() final  bool ok;
/// 발송용으로 적재된 합성 전이의 커서 id.
@override@JsonKey(name: 'transition_id') final  int transitionId;
 final  Map<String, PushChannelResultDto> _channels;
@override@JsonKey() Map<String, PushChannelResultDto> get channels {
  if (_channels is EqualUnmodifiableMapView) return _channels;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_channels);
}


/// Create a copy of TestPushResultDto
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TestPushResultDtoCopyWith<_TestPushResultDto> get copyWith => __$TestPushResultDtoCopyWithImpl<_TestPushResultDto>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$TestPushResultDtoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _TestPushResultDto&&(identical(other.ok, ok) || other.ok == ok)&&(identical(other.transitionId, transitionId) || other.transitionId == transitionId)&&const DeepCollectionEquality().equals(other._channels, _channels));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,ok,transitionId,const DeepCollectionEquality().hash(_channels));

@override
String toString() {
  return 'TestPushResultDto(ok: $ok, transitionId: $transitionId, channels: $channels)';
}


}

/// @nodoc
abstract mixin class _$TestPushResultDtoCopyWith<$Res> implements $TestPushResultDtoCopyWith<$Res> {
  factory _$TestPushResultDtoCopyWith(_TestPushResultDto value, $Res Function(_TestPushResultDto) _then) = __$TestPushResultDtoCopyWithImpl;
@override @useResult
$Res call({
 bool ok,@JsonKey(name: 'transition_id') int transitionId, Map<String, PushChannelResultDto> channels
});




}
/// @nodoc
class __$TestPushResultDtoCopyWithImpl<$Res>
    implements _$TestPushResultDtoCopyWith<$Res> {
  __$TestPushResultDtoCopyWithImpl(this._self, this._then);

  final _TestPushResultDto _self;
  final $Res Function(_TestPushResultDto) _then;

/// Create a copy of TestPushResultDto
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? ok = null,Object? transitionId = null,Object? channels = null,}) {
  return _then(_TestPushResultDto(
ok: null == ok ? _self.ok : ok // ignore: cast_nullable_to_non_nullable
as bool,transitionId: null == transitionId ? _self.transitionId : transitionId // ignore: cast_nullable_to_non_nullable
as int,channels: null == channels ? _self._channels : channels // ignore: cast_nullable_to_non_nullable
as Map<String, PushChannelResultDto>,
  ));
}


}


/// @nodoc
mixin _$AckResultDto {

 bool get ok; String? get state;/// 실제로 전이했을 때만 값이 있다(정본: 기록된 `UserAck` 이벤트가 만든
/// 전이 id). no-op이면 null.
@JsonKey(name: 'transition_id') int? get transitionId;
/// Create a copy of AckResultDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AckResultDtoCopyWith<AckResultDto> get copyWith => _$AckResultDtoCopyWithImpl<AckResultDto>(this as AckResultDto, _$identity);

  /// Serializes this AckResultDto to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AckResultDto&&(identical(other.ok, ok) || other.ok == ok)&&(identical(other.state, state) || other.state == state)&&(identical(other.transitionId, transitionId) || other.transitionId == transitionId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,ok,state,transitionId);

@override
String toString() {
  return 'AckResultDto(ok: $ok, state: $state, transitionId: $transitionId)';
}


}

/// @nodoc
abstract mixin class $AckResultDtoCopyWith<$Res>  {
  factory $AckResultDtoCopyWith(AckResultDto value, $Res Function(AckResultDto) _then) = _$AckResultDtoCopyWithImpl;
@useResult
$Res call({
 bool ok, String? state,@JsonKey(name: 'transition_id') int? transitionId
});




}
/// @nodoc
class _$AckResultDtoCopyWithImpl<$Res>
    implements $AckResultDtoCopyWith<$Res> {
  _$AckResultDtoCopyWithImpl(this._self, this._then);

  final AckResultDto _self;
  final $Res Function(AckResultDto) _then;

/// Create a copy of AckResultDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? ok = null,Object? state = freezed,Object? transitionId = freezed,}) {
  return _then(_self.copyWith(
ok: null == ok ? _self.ok : ok // ignore: cast_nullable_to_non_nullable
as bool,state: freezed == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as String?,transitionId: freezed == transitionId ? _self.transitionId : transitionId // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}

}


/// Adds pattern-matching-related methods to [AckResultDto].
extension AckResultDtoPatterns on AckResultDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AckResultDto value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AckResultDto() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AckResultDto value)  $default,){
final _that = this;
switch (_that) {
case _AckResultDto():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AckResultDto value)?  $default,){
final _that = this;
switch (_that) {
case _AckResultDto() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( bool ok,  String? state, @JsonKey(name: 'transition_id')  int? transitionId)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AckResultDto() when $default != null:
return $default(_that.ok,_that.state,_that.transitionId);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( bool ok,  String? state, @JsonKey(name: 'transition_id')  int? transitionId)  $default,) {final _that = this;
switch (_that) {
case _AckResultDto():
return $default(_that.ok,_that.state,_that.transitionId);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( bool ok,  String? state, @JsonKey(name: 'transition_id')  int? transitionId)?  $default,) {final _that = this;
switch (_that) {
case _AckResultDto() when $default != null:
return $default(_that.ok,_that.state,_that.transitionId);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _AckResultDto implements AckResultDto {
  const _AckResultDto({this.ok = false, this.state, @JsonKey(name: 'transition_id') this.transitionId});
  factory _AckResultDto.fromJson(Map<String, dynamic> json) => _$AckResultDtoFromJson(json);

@override@JsonKey() final  bool ok;
@override final  String? state;
/// 실제로 전이했을 때만 값이 있다(정본: 기록된 `UserAck` 이벤트가 만든
/// 전이 id). no-op이면 null.
@override@JsonKey(name: 'transition_id') final  int? transitionId;

/// Create a copy of AckResultDto
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AckResultDtoCopyWith<_AckResultDto> get copyWith => __$AckResultDtoCopyWithImpl<_AckResultDto>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AckResultDtoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AckResultDto&&(identical(other.ok, ok) || other.ok == ok)&&(identical(other.state, state) || other.state == state)&&(identical(other.transitionId, transitionId) || other.transitionId == transitionId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,ok,state,transitionId);

@override
String toString() {
  return 'AckResultDto(ok: $ok, state: $state, transitionId: $transitionId)';
}


}

/// @nodoc
abstract mixin class _$AckResultDtoCopyWith<$Res> implements $AckResultDtoCopyWith<$Res> {
  factory _$AckResultDtoCopyWith(_AckResultDto value, $Res Function(_AckResultDto) _then) = __$AckResultDtoCopyWithImpl;
@override @useResult
$Res call({
 bool ok, String? state,@JsonKey(name: 'transition_id') int? transitionId
});




}
/// @nodoc
class __$AckResultDtoCopyWithImpl<$Res>
    implements _$AckResultDtoCopyWith<$Res> {
  __$AckResultDtoCopyWithImpl(this._self, this._then);

  final _AckResultDto _self;
  final $Res Function(_AckResultDto) _then;

/// Create a copy of AckResultDto
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? ok = null,Object? state = freezed,Object? transitionId = freezed,}) {
  return _then(_AckResultDto(
ok: null == ok ? _self.ok : ok // ignore: cast_nullable_to_non_nullable
as bool,state: freezed == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as String?,transitionId: freezed == transitionId ? _self.transitionId : transitionId // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}


}


/// @nodoc
mixin _$PushSubscriptionDto {

 String get endpoint; String get p256dh; String get auth;
/// Create a copy of PushSubscriptionDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PushSubscriptionDtoCopyWith<PushSubscriptionDto> get copyWith => _$PushSubscriptionDtoCopyWithImpl<PushSubscriptionDto>(this as PushSubscriptionDto, _$identity);

  /// Serializes this PushSubscriptionDto to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PushSubscriptionDto&&(identical(other.endpoint, endpoint) || other.endpoint == endpoint)&&(identical(other.p256dh, p256dh) || other.p256dh == p256dh)&&(identical(other.auth, auth) || other.auth == auth));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,endpoint,p256dh,auth);

@override
String toString() {
  return 'PushSubscriptionDto(endpoint: $endpoint, p256dh: $p256dh, auth: $auth)';
}


}

/// @nodoc
abstract mixin class $PushSubscriptionDtoCopyWith<$Res>  {
  factory $PushSubscriptionDtoCopyWith(PushSubscriptionDto value, $Res Function(PushSubscriptionDto) _then) = _$PushSubscriptionDtoCopyWithImpl;
@useResult
$Res call({
 String endpoint, String p256dh, String auth
});




}
/// @nodoc
class _$PushSubscriptionDtoCopyWithImpl<$Res>
    implements $PushSubscriptionDtoCopyWith<$Res> {
  _$PushSubscriptionDtoCopyWithImpl(this._self, this._then);

  final PushSubscriptionDto _self;
  final $Res Function(PushSubscriptionDto) _then;

/// Create a copy of PushSubscriptionDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? endpoint = null,Object? p256dh = null,Object? auth = null,}) {
  return _then(_self.copyWith(
endpoint: null == endpoint ? _self.endpoint : endpoint // ignore: cast_nullable_to_non_nullable
as String,p256dh: null == p256dh ? _self.p256dh : p256dh // ignore: cast_nullable_to_non_nullable
as String,auth: null == auth ? _self.auth : auth // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [PushSubscriptionDto].
extension PushSubscriptionDtoPatterns on PushSubscriptionDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PushSubscriptionDto value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PushSubscriptionDto() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PushSubscriptionDto value)  $default,){
final _that = this;
switch (_that) {
case _PushSubscriptionDto():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PushSubscriptionDto value)?  $default,){
final _that = this;
switch (_that) {
case _PushSubscriptionDto() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String endpoint,  String p256dh,  String auth)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PushSubscriptionDto() when $default != null:
return $default(_that.endpoint,_that.p256dh,_that.auth);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String endpoint,  String p256dh,  String auth)  $default,) {final _that = this;
switch (_that) {
case _PushSubscriptionDto():
return $default(_that.endpoint,_that.p256dh,_that.auth);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String endpoint,  String p256dh,  String auth)?  $default,) {final _that = this;
switch (_that) {
case _PushSubscriptionDto() when $default != null:
return $default(_that.endpoint,_that.p256dh,_that.auth);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _PushSubscriptionDto implements PushSubscriptionDto {
  const _PushSubscriptionDto({required this.endpoint, required this.p256dh, required this.auth});
  factory _PushSubscriptionDto.fromJson(Map<String, dynamic> json) => _$PushSubscriptionDtoFromJson(json);

@override final  String endpoint;
@override final  String p256dh;
@override final  String auth;

/// Create a copy of PushSubscriptionDto
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PushSubscriptionDtoCopyWith<_PushSubscriptionDto> get copyWith => __$PushSubscriptionDtoCopyWithImpl<_PushSubscriptionDto>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PushSubscriptionDtoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PushSubscriptionDto&&(identical(other.endpoint, endpoint) || other.endpoint == endpoint)&&(identical(other.p256dh, p256dh) || other.p256dh == p256dh)&&(identical(other.auth, auth) || other.auth == auth));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,endpoint,p256dh,auth);

@override
String toString() {
  return 'PushSubscriptionDto(endpoint: $endpoint, p256dh: $p256dh, auth: $auth)';
}


}

/// @nodoc
abstract mixin class _$PushSubscriptionDtoCopyWith<$Res> implements $PushSubscriptionDtoCopyWith<$Res> {
  factory _$PushSubscriptionDtoCopyWith(_PushSubscriptionDto value, $Res Function(_PushSubscriptionDto) _then) = __$PushSubscriptionDtoCopyWithImpl;
@override @useResult
$Res call({
 String endpoint, String p256dh, String auth
});




}
/// @nodoc
class __$PushSubscriptionDtoCopyWithImpl<$Res>
    implements _$PushSubscriptionDtoCopyWith<$Res> {
  __$PushSubscriptionDtoCopyWithImpl(this._self, this._then);

  final _PushSubscriptionDto _self;
  final $Res Function(_PushSubscriptionDto) _then;

/// Create a copy of PushSubscriptionDto
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? endpoint = null,Object? p256dh = null,Object? auth = null,}) {
  return _then(_PushSubscriptionDto(
endpoint: null == endpoint ? _self.endpoint : endpoint // ignore: cast_nullable_to_non_nullable
as String,p256dh: null == p256dh ? _self.p256dh : p256dh // ignore: cast_nullable_to_non_nullable
as String,auth: null == auth ? _self.auth : auth // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
