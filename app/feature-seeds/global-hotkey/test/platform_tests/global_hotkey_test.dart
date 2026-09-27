import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sol_app/src/platform/feature_status.dart';
import 'package:sol_app/src/platform/global_hotkey.dart';

void main() {
  test('명시한_키의_성공한_등록만_지원하고_자신의_키만_해제한다', () async {
    final status = DesktopFeatureStatus();
    addTearDown(status.dispose);
    var received = 0;
    void Function()? nativeEvent;
    final removed = <String>[];
    final binding = HotKey(
      identifier: 'test.binding',
      key: PhysicalKeyboardKey.f12,
    );
    final driver = GlobalHotkeys(
      status: status,
      supported: () => true,
      register: (key, {keyDownHandler}) async {
        nativeEvent = () => keyDownHandler!(key);
      },
      unregister: (key) async {
        removed.add(key.identifier);
      },
    );
    expect(status.globalHotkey, isFalse);
    expect(driver.hasRegistrations, isFalse);
    expect(
      await driver.register(binding, () {
        received++;
      }),
      isTrue,
    );
    expect(status.globalHotkey, isFalse);
    expect(driver.hasRegistrations, isTrue);
    expect(driver.hasConfirmedCallbacks, isFalse);
    nativeEvent!();
    expect(received, 1);
    expect(status.globalHotkey, isTrue);
    expect(driver.hasConfirmedCallbacks, isTrue);
    await driver.dispose();
    expect(removed, ['test.binding']);
    expect(status.globalHotkey, isFalse);
    nativeEvent!();
    expect(received, 1);
    await driver.dispose();
    expect(removed, hasLength(1));
  });

  test('등록_실패와_호스트_부재는_지원을_허위로_표시하지_않는다', () async {
    final status = DesktopFeatureStatus();
    addTearDown(status.dispose);
    final binding = HotKey(key: PhysicalKeyboardKey.f12);
    final driver = GlobalHotkeys(
      status: status,
      supported: () => true,
      register: (key, {keyDownHandler}) async {
        throw PlatformException(code: 'occupied');
      },
    );
    expect(await driver.register(binding, () {}), isFalse);
    expect(status.globalHotkey, isFalse);
    final unsupported = GlobalHotkeys(
      supported: () => false,
      register: (key, {keyDownHandler}) async {
        fail('native call');
      },
    );
    expect(await unsupported.register(binding, () {}), isFalse);
  });
}
