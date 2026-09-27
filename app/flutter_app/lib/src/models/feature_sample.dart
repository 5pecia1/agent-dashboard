import 'package:freezed_annotation/freezed_annotation.dart';

part 'feature_sample.freezed.dart';
part 'feature_sample.g.dart';

/// A replaceable model example, independent of product data and behavior.
@freezed
abstract class FeatureSample with _$FeatureSample {
  const factory FeatureSample({required String value, @Default(0) int count}) =
      _FeatureSample;

  factory FeatureSample.fromJson(Map<String, dynamic> json) =>
      _$FeatureSampleFromJson(json);
}
