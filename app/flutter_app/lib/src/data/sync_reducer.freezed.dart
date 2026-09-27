// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'sync_reducer.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$SyncState {

/// `session_key` -> 세션 카드.
 Map<String, SessionViewDto> get sessions;/// 마지막으로 반영한 전이 id. null이면 아직 한 번도 동기화하지 않았다
/// (= 다음 요청은 `since` 없이 나가 스냅샷을 받는다).
 int? get cursor;/// 사용자가 아직 확인하지 않은 알림 전이(id 오름차순).
 List<TransitionDto> get pendingAlerts;/// 세션별로 마지막에 반영한 전이 id. `occurred_at` 동률일 때의 승자를
/// 정하는 데만 쓴다.
 Map<String, int> get lastTransitionIdBySession;/// 알림 판정을 마친 최대 전이 id. 이 값 이하는 중복이다.
 int get alertWatermark;/// 서버가 limit에 걸려 잘랐다. true면 즉시 한 번 더 당겨야 한다.
 bool get hasMore;/// 마지막 응답의 서버 시각(epoch ms).
 int get serverTime;/// 서버가 쓰는 `DASHBOARD_STALL_MS`.
 int get stallMs;/// 음소거 종료 시각(epoch ms). null이면 음소거 아님.
 int? get muteUntil;/// UI 표시 언어(서버 `dashboard_settings.ui_lang`, 정본은 서버 —
/// 서버 상태 계약). [muteUntil]/[hookSkew]와 같은 절대값
/// 서버 상태 관용 — [reduceSync]가 매 응답(스냅샷·델타 공통)마다
/// `response.uiLang`을 무조건 대입한다. `'ko'`/`'en'` 또는 null —
/// null이면 서버가 아직 정하지 않아 각 기기가 자기 플랫폼 로케일을
/// 쓴다(`i18n/t.dart`의 `localeProvider`, `app.dart`의 반영 배선 참고).
 String? get uiLang;/// 이 값보다 작은 전이 id는 서버에서 이미 정리됐다.
 int get prunedBelowId;/// `session_key` -> 사용자가 마지막으로 확인 처리(seen)한 전이 id.
///
/// 읽음 계약: 정본 `sync.response.seen`(최상위 배열, 스냅샷·델타
/// 공통, 절대값)을 접은 결과다 — 예전에는 이 사실이
/// `SessionViewDto.seenTransitionId`에도 같이 실려 왔지만, 같은 사실의
/// 복수 표현을 없애면서 이 맵이 유일한 표현이 됐다. [reduceSync]가 매
/// 응답마다 `response.seen`의 각 항목을 **MAX(로컬, 수신)**로
/// 멱등 병합한다(값을 낮추지 않는다) — 낙관 갱신(`SyncController.
/// markSeen`/`ackSession`) 직후, 아직 그 갱신을 반영하지 못한 채
/// 비행 중이던 옛 응답이 도착해도 이미 올라간 로컬 값을 되돌리지 않는다
/// (미확인 점이 잠깐 되살아나는 깜빡임 방지). 키가 아예 없으면(한
/// 번도 seen 정보를 받은 적 없음) [isSessionUnseen]이 [seenWatermark]로
/// 접는다.
 Map<String, int> get seenTransitionIds;/// 읽음/안읽음(seen) 기능의 "첫 도입 미확인 벽" 워터마크. null이면
/// "아직 한 번도 세운 적 없음"이고, 이 상태에서 받는 **첫 스냅샷**의
/// 커서로 딱 한 번만 올라간다([alertWatermark]가 매 reset마다 올라가는
/// 것과 달리, 이 값은 정말로 한 번만 올라간다 — 재연결·재설치·캐시
/// 삭제 뒤의 재스냅샷까지 벽을 다시 세우면 그 사이에 쌓인 진짜 미확인
/// 전이가 지워지기 때문이다). [isFirstBoot](`cursor == null`)를 트리거로
/// 쓰지 않는 이유: 이미 커서를 갖고 있던 기존 설치(이 기능 도입 이전에
/// 깔려 있던 앱)에 이 기능이 배포되면 `isFirstBoot`가 처음부터 false라
/// 벽이 영영 세워지지 않아 모든 카드가 미확인으로 뜬다(리뷰 지적 high).
/// 그래서 이 값 자체가 "세웠는가"의 유일한 신호이자, [restoreState]로
/// 영속화·복원된다(재기동마다 다시 0으로 풀리면 안 되므로).
/// [seenTransitionIds]에 키가 없는 세션(한 번도 seen 정보를 받은 적
/// 없음)은 이 값(null이면 0으로 접는다) 이하의 [SessionViewDto.
/// lastTransitionId]를 "첫 스냅샷 시점에 이미 본 것"으로 간주한다 —
/// [isSessionUnseen] 참고.
 int? get seenWatermark;/// 서버가 지금 서빙 중인 훅과 다른(구버전) 훅을 돌리는 기계 목록.
/// [muteUntil]과 같은 "절대값 서버 상태" 관용 — [reduceSync]가 매
/// 응답(스냅샷·델타 공통)마다 `response.hookSkew`를 그대로 대입한다.
/// [seenTransitionIds]의 MAX 병합과 달리 낮아지지 않는 값이 아니다:
/// 기계가 훅을 갱신하면 다음 응답에서 그 기계가 이 목록에서 통째로
/// 사라져야 하므로, 옛 값을 지키는 병합은 오히려 틀린 동작이다.
 List<HookSkewDto> get hookSkew;
/// Create a copy of SyncState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncStateCopyWith<SyncState> get copyWith => _$SyncStateCopyWithImpl<SyncState>(this as SyncState, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncState&&const DeepCollectionEquality().equals(other.sessions, sessions)&&(identical(other.cursor, cursor) || other.cursor == cursor)&&const DeepCollectionEquality().equals(other.pendingAlerts, pendingAlerts)&&const DeepCollectionEquality().equals(other.lastTransitionIdBySession, lastTransitionIdBySession)&&(identical(other.alertWatermark, alertWatermark) || other.alertWatermark == alertWatermark)&&(identical(other.hasMore, hasMore) || other.hasMore == hasMore)&&(identical(other.serverTime, serverTime) || other.serverTime == serverTime)&&(identical(other.stallMs, stallMs) || other.stallMs == stallMs)&&(identical(other.muteUntil, muteUntil) || other.muteUntil == muteUntil)&&(identical(other.uiLang, uiLang) || other.uiLang == uiLang)&&(identical(other.prunedBelowId, prunedBelowId) || other.prunedBelowId == prunedBelowId)&&const DeepCollectionEquality().equals(other.seenTransitionIds, seenTransitionIds)&&(identical(other.seenWatermark, seenWatermark) || other.seenWatermark == seenWatermark)&&const DeepCollectionEquality().equals(other.hookSkew, hookSkew));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(sessions),cursor,const DeepCollectionEquality().hash(pendingAlerts),const DeepCollectionEquality().hash(lastTransitionIdBySession),alertWatermark,hasMore,serverTime,stallMs,muteUntil,uiLang,prunedBelowId,const DeepCollectionEquality().hash(seenTransitionIds),seenWatermark,const DeepCollectionEquality().hash(hookSkew));

@override
String toString() {
  return 'SyncState(sessions: $sessions, cursor: $cursor, pendingAlerts: $pendingAlerts, lastTransitionIdBySession: $lastTransitionIdBySession, alertWatermark: $alertWatermark, hasMore: $hasMore, serverTime: $serverTime, stallMs: $stallMs, muteUntil: $muteUntil, uiLang: $uiLang, prunedBelowId: $prunedBelowId, seenTransitionIds: $seenTransitionIds, seenWatermark: $seenWatermark, hookSkew: $hookSkew)';
}


}

/// @nodoc
abstract mixin class $SyncStateCopyWith<$Res>  {
  factory $SyncStateCopyWith(SyncState value, $Res Function(SyncState) _then) = _$SyncStateCopyWithImpl;
@useResult
$Res call({
 Map<String, SessionViewDto> sessions, int? cursor, List<TransitionDto> pendingAlerts, Map<String, int> lastTransitionIdBySession, int alertWatermark, bool hasMore, int serverTime, int stallMs, int? muteUntil, String? uiLang, int prunedBelowId, Map<String, int> seenTransitionIds, int? seenWatermark, List<HookSkewDto> hookSkew
});




}
/// @nodoc
class _$SyncStateCopyWithImpl<$Res>
    implements $SyncStateCopyWith<$Res> {
  _$SyncStateCopyWithImpl(this._self, this._then);

  final SyncState _self;
  final $Res Function(SyncState) _then;

/// Create a copy of SyncState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? sessions = null,Object? cursor = freezed,Object? pendingAlerts = null,Object? lastTransitionIdBySession = null,Object? alertWatermark = null,Object? hasMore = null,Object? serverTime = null,Object? stallMs = null,Object? muteUntil = freezed,Object? uiLang = freezed,Object? prunedBelowId = null,Object? seenTransitionIds = null,Object? seenWatermark = freezed,Object? hookSkew = null,}) {
  return _then(_self.copyWith(
sessions: null == sessions ? _self.sessions : sessions // ignore: cast_nullable_to_non_nullable
as Map<String, SessionViewDto>,cursor: freezed == cursor ? _self.cursor : cursor // ignore: cast_nullable_to_non_nullable
as int?,pendingAlerts: null == pendingAlerts ? _self.pendingAlerts : pendingAlerts // ignore: cast_nullable_to_non_nullable
as List<TransitionDto>,lastTransitionIdBySession: null == lastTransitionIdBySession ? _self.lastTransitionIdBySession : lastTransitionIdBySession // ignore: cast_nullable_to_non_nullable
as Map<String, int>,alertWatermark: null == alertWatermark ? _self.alertWatermark : alertWatermark // ignore: cast_nullable_to_non_nullable
as int,hasMore: null == hasMore ? _self.hasMore : hasMore // ignore: cast_nullable_to_non_nullable
as bool,serverTime: null == serverTime ? _self.serverTime : serverTime // ignore: cast_nullable_to_non_nullable
as int,stallMs: null == stallMs ? _self.stallMs : stallMs // ignore: cast_nullable_to_non_nullable
as int,muteUntil: freezed == muteUntil ? _self.muteUntil : muteUntil // ignore: cast_nullable_to_non_nullable
as int?,uiLang: freezed == uiLang ? _self.uiLang : uiLang // ignore: cast_nullable_to_non_nullable
as String?,prunedBelowId: null == prunedBelowId ? _self.prunedBelowId : prunedBelowId // ignore: cast_nullable_to_non_nullable
as int,seenTransitionIds: null == seenTransitionIds ? _self.seenTransitionIds : seenTransitionIds // ignore: cast_nullable_to_non_nullable
as Map<String, int>,seenWatermark: freezed == seenWatermark ? _self.seenWatermark : seenWatermark // ignore: cast_nullable_to_non_nullable
as int?,hookSkew: null == hookSkew ? _self.hookSkew : hookSkew // ignore: cast_nullable_to_non_nullable
as List<HookSkewDto>,
  ));
}

}


/// Adds pattern-matching-related methods to [SyncState].
extension SyncStatePatterns on SyncState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SyncState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SyncState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SyncState value)  $default,){
final _that = this;
switch (_that) {
case _SyncState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SyncState value)?  $default,){
final _that = this;
switch (_that) {
case _SyncState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( Map<String, SessionViewDto> sessions,  int? cursor,  List<TransitionDto> pendingAlerts,  Map<String, int> lastTransitionIdBySession,  int alertWatermark,  bool hasMore,  int serverTime,  int stallMs,  int? muteUntil,  String? uiLang,  int prunedBelowId,  Map<String, int> seenTransitionIds,  int? seenWatermark,  List<HookSkewDto> hookSkew)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SyncState() when $default != null:
return $default(_that.sessions,_that.cursor,_that.pendingAlerts,_that.lastTransitionIdBySession,_that.alertWatermark,_that.hasMore,_that.serverTime,_that.stallMs,_that.muteUntil,_that.uiLang,_that.prunedBelowId,_that.seenTransitionIds,_that.seenWatermark,_that.hookSkew);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( Map<String, SessionViewDto> sessions,  int? cursor,  List<TransitionDto> pendingAlerts,  Map<String, int> lastTransitionIdBySession,  int alertWatermark,  bool hasMore,  int serverTime,  int stallMs,  int? muteUntil,  String? uiLang,  int prunedBelowId,  Map<String, int> seenTransitionIds,  int? seenWatermark,  List<HookSkewDto> hookSkew)  $default,) {final _that = this;
switch (_that) {
case _SyncState():
return $default(_that.sessions,_that.cursor,_that.pendingAlerts,_that.lastTransitionIdBySession,_that.alertWatermark,_that.hasMore,_that.serverTime,_that.stallMs,_that.muteUntil,_that.uiLang,_that.prunedBelowId,_that.seenTransitionIds,_that.seenWatermark,_that.hookSkew);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( Map<String, SessionViewDto> sessions,  int? cursor,  List<TransitionDto> pendingAlerts,  Map<String, int> lastTransitionIdBySession,  int alertWatermark,  bool hasMore,  int serverTime,  int stallMs,  int? muteUntil,  String? uiLang,  int prunedBelowId,  Map<String, int> seenTransitionIds,  int? seenWatermark,  List<HookSkewDto> hookSkew)?  $default,) {final _that = this;
switch (_that) {
case _SyncState() when $default != null:
return $default(_that.sessions,_that.cursor,_that.pendingAlerts,_that.lastTransitionIdBySession,_that.alertWatermark,_that.hasMore,_that.serverTime,_that.stallMs,_that.muteUntil,_that.uiLang,_that.prunedBelowId,_that.seenTransitionIds,_that.seenWatermark,_that.hookSkew);case _:
  return null;

}
}

}

/// @nodoc


class _SyncState extends SyncState {
  const _SyncState({final  Map<String, SessionViewDto> sessions = const <String, SessionViewDto>{}, this.cursor, final  List<TransitionDto> pendingAlerts = const <TransitionDto>[], final  Map<String, int> lastTransitionIdBySession = const <String, int>{}, this.alertWatermark = 0, this.hasMore = false, this.serverTime = 0, this.stallMs = kDefaultStallMs, this.muteUntil, this.uiLang, this.prunedBelowId = 0, final  Map<String, int> seenTransitionIds = const <String, int>{}, this.seenWatermark, final  List<HookSkewDto> hookSkew = const <HookSkewDto>[]}): _sessions = sessions,_pendingAlerts = pendingAlerts,_lastTransitionIdBySession = lastTransitionIdBySession,_seenTransitionIds = seenTransitionIds,_hookSkew = hookSkew,super._();
  

/// `session_key` -> 세션 카드.
 final  Map<String, SessionViewDto> _sessions;
/// `session_key` -> 세션 카드.
@override@JsonKey() Map<String, SessionViewDto> get sessions {
  if (_sessions is EqualUnmodifiableMapView) return _sessions;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_sessions);
}

/// 마지막으로 반영한 전이 id. null이면 아직 한 번도 동기화하지 않았다
/// (= 다음 요청은 `since` 없이 나가 스냅샷을 받는다).
@override final  int? cursor;
/// 사용자가 아직 확인하지 않은 알림 전이(id 오름차순).
 final  List<TransitionDto> _pendingAlerts;
/// 사용자가 아직 확인하지 않은 알림 전이(id 오름차순).
@override@JsonKey() List<TransitionDto> get pendingAlerts {
  if (_pendingAlerts is EqualUnmodifiableListView) return _pendingAlerts;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_pendingAlerts);
}

/// 세션별로 마지막에 반영한 전이 id. `occurred_at` 동률일 때의 승자를
/// 정하는 데만 쓴다.
 final  Map<String, int> _lastTransitionIdBySession;
/// 세션별로 마지막에 반영한 전이 id. `occurred_at` 동률일 때의 승자를
/// 정하는 데만 쓴다.
@override@JsonKey() Map<String, int> get lastTransitionIdBySession {
  if (_lastTransitionIdBySession is EqualUnmodifiableMapView) return _lastTransitionIdBySession;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_lastTransitionIdBySession);
}

/// 알림 판정을 마친 최대 전이 id. 이 값 이하는 중복이다.
@override@JsonKey() final  int alertWatermark;
/// 서버가 limit에 걸려 잘랐다. true면 즉시 한 번 더 당겨야 한다.
@override@JsonKey() final  bool hasMore;
/// 마지막 응답의 서버 시각(epoch ms).
@override@JsonKey() final  int serverTime;
/// 서버가 쓰는 `DASHBOARD_STALL_MS`.
@override@JsonKey() final  int stallMs;
/// 음소거 종료 시각(epoch ms). null이면 음소거 아님.
@override final  int? muteUntil;
/// UI 표시 언어(서버 `dashboard_settings.ui_lang`, 정본은 서버 —
/// 서버 상태 계약). [muteUntil]/[hookSkew]와 같은 절대값
/// 서버 상태 관용 — [reduceSync]가 매 응답(스냅샷·델타 공통)마다
/// `response.uiLang`을 무조건 대입한다. `'ko'`/`'en'` 또는 null —
/// null이면 서버가 아직 정하지 않아 각 기기가 자기 플랫폼 로케일을
/// 쓴다(`i18n/t.dart`의 `localeProvider`, `app.dart`의 반영 배선 참고).
@override final  String? uiLang;
/// 이 값보다 작은 전이 id는 서버에서 이미 정리됐다.
@override@JsonKey() final  int prunedBelowId;
/// `session_key` -> 사용자가 마지막으로 확인 처리(seen)한 전이 id.
///
/// 읽음 계약: 정본 `sync.response.seen`(최상위 배열, 스냅샷·델타
/// 공통, 절대값)을 접은 결과다 — 예전에는 이 사실이
/// `SessionViewDto.seenTransitionId`에도 같이 실려 왔지만, 같은 사실의
/// 복수 표현을 없애면서 이 맵이 유일한 표현이 됐다. [reduceSync]가 매
/// 응답마다 `response.seen`의 각 항목을 **MAX(로컬, 수신)**로
/// 멱등 병합한다(값을 낮추지 않는다) — 낙관 갱신(`SyncController.
/// markSeen`/`ackSession`) 직후, 아직 그 갱신을 반영하지 못한 채
/// 비행 중이던 옛 응답이 도착해도 이미 올라간 로컬 값을 되돌리지 않는다
/// (미확인 점이 잠깐 되살아나는 깜빡임 방지). 키가 아예 없으면(한
/// 번도 seen 정보를 받은 적 없음) [isSessionUnseen]이 [seenWatermark]로
/// 접는다.
 final  Map<String, int> _seenTransitionIds;
/// `session_key` -> 사용자가 마지막으로 확인 처리(seen)한 전이 id.
///
/// 읽음 계약: 정본 `sync.response.seen`(최상위 배열, 스냅샷·델타
/// 공통, 절대값)을 접은 결과다 — 예전에는 이 사실이
/// `SessionViewDto.seenTransitionId`에도 같이 실려 왔지만, 같은 사실의
/// 복수 표현을 없애면서 이 맵이 유일한 표현이 됐다. [reduceSync]가 매
/// 응답마다 `response.seen`의 각 항목을 **MAX(로컬, 수신)**로
/// 멱등 병합한다(값을 낮추지 않는다) — 낙관 갱신(`SyncController.
/// markSeen`/`ackSession`) 직후, 아직 그 갱신을 반영하지 못한 채
/// 비행 중이던 옛 응답이 도착해도 이미 올라간 로컬 값을 되돌리지 않는다
/// (미확인 점이 잠깐 되살아나는 깜빡임 방지). 키가 아예 없으면(한
/// 번도 seen 정보를 받은 적 없음) [isSessionUnseen]이 [seenWatermark]로
/// 접는다.
@override@JsonKey() Map<String, int> get seenTransitionIds {
  if (_seenTransitionIds is EqualUnmodifiableMapView) return _seenTransitionIds;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_seenTransitionIds);
}

/// 읽음/안읽음(seen) 기능의 "첫 도입 미확인 벽" 워터마크. null이면
/// "아직 한 번도 세운 적 없음"이고, 이 상태에서 받는 **첫 스냅샷**의
/// 커서로 딱 한 번만 올라간다([alertWatermark]가 매 reset마다 올라가는
/// 것과 달리, 이 값은 정말로 한 번만 올라간다 — 재연결·재설치·캐시
/// 삭제 뒤의 재스냅샷까지 벽을 다시 세우면 그 사이에 쌓인 진짜 미확인
/// 전이가 지워지기 때문이다). [isFirstBoot](`cursor == null`)를 트리거로
/// 쓰지 않는 이유: 이미 커서를 갖고 있던 기존 설치(이 기능 도입 이전에
/// 깔려 있던 앱)에 이 기능이 배포되면 `isFirstBoot`가 처음부터 false라
/// 벽이 영영 세워지지 않아 모든 카드가 미확인으로 뜬다(리뷰 지적 high).
/// 그래서 이 값 자체가 "세웠는가"의 유일한 신호이자, [restoreState]로
/// 영속화·복원된다(재기동마다 다시 0으로 풀리면 안 되므로).
/// [seenTransitionIds]에 키가 없는 세션(한 번도 seen 정보를 받은 적
/// 없음)은 이 값(null이면 0으로 접는다) 이하의 [SessionViewDto.
/// lastTransitionId]를 "첫 스냅샷 시점에 이미 본 것"으로 간주한다 —
/// [isSessionUnseen] 참고.
@override final  int? seenWatermark;
/// 서버가 지금 서빙 중인 훅과 다른(구버전) 훅을 돌리는 기계 목록.
/// [muteUntil]과 같은 "절대값 서버 상태" 관용 — [reduceSync]가 매
/// 응답(스냅샷·델타 공통)마다 `response.hookSkew`를 그대로 대입한다.
/// [seenTransitionIds]의 MAX 병합과 달리 낮아지지 않는 값이 아니다:
/// 기계가 훅을 갱신하면 다음 응답에서 그 기계가 이 목록에서 통째로
/// 사라져야 하므로, 옛 값을 지키는 병합은 오히려 틀린 동작이다.
 final  List<HookSkewDto> _hookSkew;
/// 서버가 지금 서빙 중인 훅과 다른(구버전) 훅을 돌리는 기계 목록.
/// [muteUntil]과 같은 "절대값 서버 상태" 관용 — [reduceSync]가 매
/// 응답(스냅샷·델타 공통)마다 `response.hookSkew`를 그대로 대입한다.
/// [seenTransitionIds]의 MAX 병합과 달리 낮아지지 않는 값이 아니다:
/// 기계가 훅을 갱신하면 다음 응답에서 그 기계가 이 목록에서 통째로
/// 사라져야 하므로, 옛 값을 지키는 병합은 오히려 틀린 동작이다.
@override@JsonKey() List<HookSkewDto> get hookSkew {
  if (_hookSkew is EqualUnmodifiableListView) return _hookSkew;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_hookSkew);
}


/// Create a copy of SyncState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SyncStateCopyWith<_SyncState> get copyWith => __$SyncStateCopyWithImpl<_SyncState>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SyncState&&const DeepCollectionEquality().equals(other._sessions, _sessions)&&(identical(other.cursor, cursor) || other.cursor == cursor)&&const DeepCollectionEquality().equals(other._pendingAlerts, _pendingAlerts)&&const DeepCollectionEquality().equals(other._lastTransitionIdBySession, _lastTransitionIdBySession)&&(identical(other.alertWatermark, alertWatermark) || other.alertWatermark == alertWatermark)&&(identical(other.hasMore, hasMore) || other.hasMore == hasMore)&&(identical(other.serverTime, serverTime) || other.serverTime == serverTime)&&(identical(other.stallMs, stallMs) || other.stallMs == stallMs)&&(identical(other.muteUntil, muteUntil) || other.muteUntil == muteUntil)&&(identical(other.uiLang, uiLang) || other.uiLang == uiLang)&&(identical(other.prunedBelowId, prunedBelowId) || other.prunedBelowId == prunedBelowId)&&const DeepCollectionEquality().equals(other._seenTransitionIds, _seenTransitionIds)&&(identical(other.seenWatermark, seenWatermark) || other.seenWatermark == seenWatermark)&&const DeepCollectionEquality().equals(other._hookSkew, _hookSkew));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_sessions),cursor,const DeepCollectionEquality().hash(_pendingAlerts),const DeepCollectionEquality().hash(_lastTransitionIdBySession),alertWatermark,hasMore,serverTime,stallMs,muteUntil,uiLang,prunedBelowId,const DeepCollectionEquality().hash(_seenTransitionIds),seenWatermark,const DeepCollectionEquality().hash(_hookSkew));

@override
String toString() {
  return 'SyncState(sessions: $sessions, cursor: $cursor, pendingAlerts: $pendingAlerts, lastTransitionIdBySession: $lastTransitionIdBySession, alertWatermark: $alertWatermark, hasMore: $hasMore, serverTime: $serverTime, stallMs: $stallMs, muteUntil: $muteUntil, uiLang: $uiLang, prunedBelowId: $prunedBelowId, seenTransitionIds: $seenTransitionIds, seenWatermark: $seenWatermark, hookSkew: $hookSkew)';
}


}

/// @nodoc
abstract mixin class _$SyncStateCopyWith<$Res> implements $SyncStateCopyWith<$Res> {
  factory _$SyncStateCopyWith(_SyncState value, $Res Function(_SyncState) _then) = __$SyncStateCopyWithImpl;
@override @useResult
$Res call({
 Map<String, SessionViewDto> sessions, int? cursor, List<TransitionDto> pendingAlerts, Map<String, int> lastTransitionIdBySession, int alertWatermark, bool hasMore, int serverTime, int stallMs, int? muteUntil, String? uiLang, int prunedBelowId, Map<String, int> seenTransitionIds, int? seenWatermark, List<HookSkewDto> hookSkew
});




}
/// @nodoc
class __$SyncStateCopyWithImpl<$Res>
    implements _$SyncStateCopyWith<$Res> {
  __$SyncStateCopyWithImpl(this._self, this._then);

  final _SyncState _self;
  final $Res Function(_SyncState) _then;

/// Create a copy of SyncState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? sessions = null,Object? cursor = freezed,Object? pendingAlerts = null,Object? lastTransitionIdBySession = null,Object? alertWatermark = null,Object? hasMore = null,Object? serverTime = null,Object? stallMs = null,Object? muteUntil = freezed,Object? uiLang = freezed,Object? prunedBelowId = null,Object? seenTransitionIds = null,Object? seenWatermark = freezed,Object? hookSkew = null,}) {
  return _then(_SyncState(
sessions: null == sessions ? _self._sessions : sessions // ignore: cast_nullable_to_non_nullable
as Map<String, SessionViewDto>,cursor: freezed == cursor ? _self.cursor : cursor // ignore: cast_nullable_to_non_nullable
as int?,pendingAlerts: null == pendingAlerts ? _self._pendingAlerts : pendingAlerts // ignore: cast_nullable_to_non_nullable
as List<TransitionDto>,lastTransitionIdBySession: null == lastTransitionIdBySession ? _self._lastTransitionIdBySession : lastTransitionIdBySession // ignore: cast_nullable_to_non_nullable
as Map<String, int>,alertWatermark: null == alertWatermark ? _self.alertWatermark : alertWatermark // ignore: cast_nullable_to_non_nullable
as int,hasMore: null == hasMore ? _self.hasMore : hasMore // ignore: cast_nullable_to_non_nullable
as bool,serverTime: null == serverTime ? _self.serverTime : serverTime // ignore: cast_nullable_to_non_nullable
as int,stallMs: null == stallMs ? _self.stallMs : stallMs // ignore: cast_nullable_to_non_nullable
as int,muteUntil: freezed == muteUntil ? _self.muteUntil : muteUntil // ignore: cast_nullable_to_non_nullable
as int?,uiLang: freezed == uiLang ? _self.uiLang : uiLang // ignore: cast_nullable_to_non_nullable
as String?,prunedBelowId: null == prunedBelowId ? _self.prunedBelowId : prunedBelowId // ignore: cast_nullable_to_non_nullable
as int,seenTransitionIds: null == seenTransitionIds ? _self._seenTransitionIds : seenTransitionIds // ignore: cast_nullable_to_non_nullable
as Map<String, int>,seenWatermark: freezed == seenWatermark ? _self.seenWatermark : seenWatermark // ignore: cast_nullable_to_non_nullable
as int?,hookSkew: null == hookSkew ? _self._hookSkew : hookSkew // ignore: cast_nullable_to_non_nullable
as List<HookSkewDto>,
  ));
}


}

// dart format on
