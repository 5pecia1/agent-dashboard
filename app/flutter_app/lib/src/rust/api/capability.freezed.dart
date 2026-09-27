// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'capability.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$CapabilityDto {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CapabilityDto);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'CapabilityDto()';
}


}

/// @nodoc
class $CapabilityDtoCopyWith<$Res>  {
$CapabilityDtoCopyWith(CapabilityDto _, $Res Function(CapabilityDto) __);
}


/// Adds pattern-matching-related methods to [CapabilityDto].
extension CapabilityDtoPatterns on CapabilityDto {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( CapabilityDto_Supported value)?  supported,TResult Function( CapabilityDto_Unsupported value)?  unsupported,required TResult orElse(),}){
final _that = this;
switch (_that) {
case CapabilityDto_Supported() when supported != null:
return supported(_that);case CapabilityDto_Unsupported() when unsupported != null:
return unsupported(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( CapabilityDto_Supported value)  supported,required TResult Function( CapabilityDto_Unsupported value)  unsupported,}){
final _that = this;
switch (_that) {
case CapabilityDto_Supported():
return supported(_that);case CapabilityDto_Unsupported():
return unsupported(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( CapabilityDto_Supported value)?  supported,TResult? Function( CapabilityDto_Unsupported value)?  unsupported,}){
final _that = this;
switch (_that) {
case CapabilityDto_Supported() when supported != null:
return supported(_that);case CapabilityDto_Unsupported() when unsupported != null:
return unsupported(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  supported,TResult Function( UnsupportedReasonDto reason)?  unsupported,required TResult orElse(),}) {final _that = this;
switch (_that) {
case CapabilityDto_Supported() when supported != null:
return supported();case CapabilityDto_Unsupported() when unsupported != null:
return unsupported(_that.reason);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  supported,required TResult Function( UnsupportedReasonDto reason)  unsupported,}) {final _that = this;
switch (_that) {
case CapabilityDto_Supported():
return supported();case CapabilityDto_Unsupported():
return unsupported(_that.reason);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  supported,TResult? Function( UnsupportedReasonDto reason)?  unsupported,}) {final _that = this;
switch (_that) {
case CapabilityDto_Supported() when supported != null:
return supported();case CapabilityDto_Unsupported() when unsupported != null:
return unsupported(_that.reason);case _:
  return null;

}
}

}

/// @nodoc


class CapabilityDto_Supported extends CapabilityDto {
  const CapabilityDto_Supported(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CapabilityDto_Supported);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'CapabilityDto.supported()';
}


}




/// @nodoc


class CapabilityDto_Unsupported extends CapabilityDto {
  const CapabilityDto_Unsupported({required this.reason}): super._();
  

/// 왜 못 쓰는지.
 final  UnsupportedReasonDto reason;

/// Create a copy of CapabilityDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CapabilityDto_UnsupportedCopyWith<CapabilityDto_Unsupported> get copyWith => _$CapabilityDto_UnsupportedCopyWithImpl<CapabilityDto_Unsupported>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CapabilityDto_Unsupported&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'CapabilityDto.unsupported(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $CapabilityDto_UnsupportedCopyWith<$Res> implements $CapabilityDtoCopyWith<$Res> {
  factory $CapabilityDto_UnsupportedCopyWith(CapabilityDto_Unsupported value, $Res Function(CapabilityDto_Unsupported) _then) = _$CapabilityDto_UnsupportedCopyWithImpl;
@useResult
$Res call({
 UnsupportedReasonDto reason
});




}
/// @nodoc
class _$CapabilityDto_UnsupportedCopyWithImpl<$Res>
    implements $CapabilityDto_UnsupportedCopyWith<$Res> {
  _$CapabilityDto_UnsupportedCopyWithImpl(this._self, this._then);

  final CapabilityDto_Unsupported _self;
  final $Res Function(CapabilityDto_Unsupported) _then;

/// Create a copy of CapabilityDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
  return _then(CapabilityDto_Unsupported(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as UnsupportedReasonDto,
  ));
}


}

// dart format on
