// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'feature_sample.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_FeatureSample _$FeatureSampleFromJson(Map<String, dynamic> json) =>
    _FeatureSample(
      value: json['value'] as String,
      count: (json['count'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$FeatureSampleToJson(_FeatureSample instance) =>
    <String, dynamic>{'value': instance.value, 'count': instance.count};
