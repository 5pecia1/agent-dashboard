import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sol_app/src/platform/feature_status.dart';
import 'package:sol_app/src/platform/window_control.dart';

void main() {
  test('실제_창_호출_성공과_실패가_준비_상태에_반영된다', () async {
    final status = DesktopFeatureStatus();
    addTearDown(status.dispose);
    Size? resized;
    final driver = WindowControl(
      status: status,
      supported: () => true,
      initialize: () async {},
      resize: (size) async {
        resized = size;
      },
      show: () async {
        throw PlatformException(code: 'window-unavailable');
      },
    );
    expect(status.windowControl, isFalse);
    expect(await driver.initialize(), isTrue);
    expect(await driver.resize(const Size(640, 480)), isTrue);
    expect(resized, const Size(640, 480));
    expect(await driver.show(), isFalse);
    expect(status.windowControl, isFalse);
    expect(driver.lastError, isA<PlatformException>());
  });

  test('호스트가_없으면_플러그인을_호출하지_않는다', () async {
    final driver = WindowControl(
      supported: () => false,
      initialize: () async {
        fail('native call');
      },
    );
    expect(await driver.initialize(), isFalse);
  });
}
