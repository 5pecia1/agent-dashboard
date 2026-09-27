/// `notification_probe_provider.dart`가 `desktopFeatureStatus`의 변화를
/// 실제로 구독자에게 전달하는지, override 가능한 함수 provider들이 실제
/// 플러그인/프로세스 없이 호출 여부만 확인할 수 있는지를 검증한다.
///
/// `capability_provider_test.dart`와 같은 패턴이다 — `desktopFeatureStatus`
/// 를 직접 조작해 ChangeNotifier -> Provider 반영을 확인한다. 이 테스트는
/// 실제 macOS 플러그인이나 `Process.run`을 절대 부르지 않는다(모든 함수형
/// provider를 override한다).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/platform/feature_status.dart';
import 'package:my_dashboard/src/state/notification_probe_provider.dart';

void main() {
  tearDown(() {
    // 전역 싱글턴이다 — 테스트끼리 상태가 새지 않게 기본값으로 되돌린다.
    desktopFeatureStatus.notifyPermissionDeniedChanged(false);
    desktopFeatureStatus.notifyLocalChanged(false);
  });

  test(
    'denied -> granted 전환: notifyPermissionDenied 구독자가 실시간으로 반영한다',
    () async {
      desktopFeatureStatus.notifyPermissionDeniedChanged(true);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final observed = <bool>[];
      container.listen(
        notificationPermissionDeniedProvider,
        (_, value) => observed.add(value),
        fireImmediately: true,
      );

      // 사용자가 시스템 설정에서 권한을 켠 뒤 재프로브가 성공한 상황을
      // 흉내낸다.
      desktopFeatureStatus.notifyPermissionDeniedChanged(false);
      await container.pump();

      expect(observed, [true, false]);
    },
  );

  test('알림 프로브가 아직 안 됐으면 permissionDenied는 기본값 false다', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(notificationPermissionDeniedProvider), isFalse);
  });

  test(
    '프로브를 실제로 부르지 않은 채로는 osascript 폴백 표시가 기본값 false다',
    () {
      // `currentNotificationBackend`는 `probeNotificationSupport()`가 실제로
      // 성공해야만 바뀐다 — 이 테스트는 그 함수를 부르지 않는다(실제
      // macOS 호스트에서 이 테스트 스위트를 돌려도 진짜 알림/osascript가
      // 실행되지 않아야 하기 때문이다). 그래서 여기서는 기본값만 확인한다.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(notificationUsesOsascriptFallbackProvider), isFalse);
    },
  );

  test('재프로브 provider는 override된 함수를 그대로 노출한다(실제 플러그인 호출 없음)', () async {
    var calls = 0;
    final container = ProviderContainer(
      overrides: [
        notificationReprobeProvider.overrideWithValue(() async {
          calls += 1;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(notificationReprobeProvider)();
    await container.read(notificationReprobeProvider)();

    expect(calls, 2);
  });

  test('시스템 설정 열기 provider는 override된 함수를 그대로 노출한다(실제 프로세스 호출 없음)', () async {
    var opened = false;
    final container = ProviderContainer(
      overrides: [
        openNotificationSettingsProvider.overrideWithValue(() async {
          opened = true;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(openNotificationSettingsProvider)();

    expect(opened, isTrue);
  });
}
