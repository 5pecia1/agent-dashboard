import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/models/feature_sample.dart';

void main() {
  test('모델의_복사와_JSON_왕복이_타입과_값을_보존한다', () {
    const original = FeatureSample(value: 'example');
    final copied = original.copyWith(count: 1);
    expect(original.count, 0);
    expect(copied, const FeatureSample(value: 'example', count: 1));
    expect(FeatureSample.fromJson(copied.toJson()), copied);
  });
}
