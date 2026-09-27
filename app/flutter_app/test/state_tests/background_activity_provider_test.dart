/// `background_activity_provider.dart`의 App Nap 방지 판정을 실제
/// `AppLifecycleListener`/`MethodChannel` 없이 닫는다(TASK P-impl (1)).
/// [backgroundActivityLifecycleWatchFnProvider]/[backgroundActivityApplyFnProvider]를
/// 전부 override하므로 네이티브 호출이 절대 일어나지 않는다.
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/state/background_activity_provider.dart';

void main() {
  group('shouldPreventAppNap (순수 판정)', () {
    test('상주 && hidden일 때만 true다', () {
      expect(
        shouldPreventAppNap(residentEnabled: true, lifecycle: AppLifecycleState.hidden),
        isTrue,
      );
      expect(
        shouldPreventAppNap(residentEnabled: false, lifecycle: AppLifecycleState.hidden),
        isFalse,
      );
      expect(
        shouldPreventAppNap(residentEnabled: true, lifecycle: AppLifecycleState.resumed),
        isFalse,
      );
      expect(
        shouldPreventAppNap(residentEnabled: true, lifecycle: AppLifecycleState.inactive),
        isFalse,
        reason: 'inactive는 창이 여전히 보이는 상태라 숨김이 아니다',
      );
      expect(
        shouldPreventAppNap(residentEnabled: false, lifecycle: AppLifecycleState.resumed),
        isFalse,
      );
    });
  });

  group('BackgroundActivityController (조립)', () {
    late List<bool> applyCalls;
    late StreamController<AppLifecycleState> lifecycle;

    ProviderContainer buildContainer() {
      applyCalls = <bool>[];
      lifecycle = StreamController<AppLifecycleState>.broadcast(sync: true);
      return ProviderContainer(
        overrides: [
          backgroundActivityLifecycleWatchFnProvider.overrideWithValue(() => lifecycle.stream),
          backgroundActivityApplyFnProvider.overrideWithValue((bool active) async {
            applyCalls.add(active);
          }),
        ],
      );
    }

    test('TASK P-impl (1): 상주 상태에서 창이 숨겨지면 begin, 돌아오면 end를 정확히 1회씩 부른다', () async {
      final container = buildContainer();
      addTearDown(() {
        lifecycle.close();
        container.dispose();
      });
      container.read(backgroundActivityControllerProvider); // build() 트리거

      container.read(backgroundActivityControllerProvider.notifier).setResident(true);
      await Future<void>.delayed(Duration.zero);
      expect(applyCalls, isEmpty, reason: '상주만으로는 아직 숨겨지지 않았으니 걸 이유가 없다');

      lifecycle.add(AppLifecycleState.hidden); // 창이 완전히 사라짐
      await Future<void>.delayed(Duration.zero);
      expect(applyCalls, [true], reason: 'App Nap 방지를 걸어야 한다(begin)');
      expect(container.read(backgroundActivityControllerProvider), isTrue);

      lifecycle.add(AppLifecycleState.resumed); // 창이 돌아옴
      await Future<void>.delayed(Duration.zero);
      expect(applyCalls, [true, false], reason: '창이 돌아오면 풀어야 한다(end)');
      expect(container.read(backgroundActivityControllerProvider), isFalse);
    });

    test('TASK P-impl (1): 상주가 꺼져 있으면 숨겨져도 걸지 않는다', () async {
      final container = buildContainer();
      addTearDown(() {
        lifecycle.close();
        container.dispose();
      });
      container.read(backgroundActivityControllerProvider);
      container.read(backgroundActivityControllerProvider.notifier).setResident(false);

      lifecycle.add(AppLifecycleState.hidden);
      await Future<void>.delayed(Duration.zero);

      expect(applyCalls, isEmpty);
      expect(container.read(backgroundActivityControllerProvider), isFalse);
    });

    test('TASK P-impl (1): 숨겨진 채로 상주를 끄면 즉시 end가 불린다', () async {
      final container = buildContainer();
      addTearDown(() {
        lifecycle.close();
        container.dispose();
      });
      container.read(backgroundActivityControllerProvider);
      container.read(backgroundActivityControllerProvider.notifier).setResident(true);

      lifecycle.add(AppLifecycleState.hidden);
      await Future<void>.delayed(Duration.zero);
      expect(applyCalls, [true]);

      container.read(backgroundActivityControllerProvider.notifier).setResident(false);
      await Future<void>.delayed(Duration.zero);
      expect(applyCalls, [true, false], reason: '상주를 끄면 숨김 상태 그대로여도 방지를 풀어야 한다');
    });

    test('TASK P-impl (1): 같은 판정 값이 반복되면 중복 호출하지 않는다', () async {
      final container = buildContainer();
      addTearDown(() {
        lifecycle.close();
        container.dispose();
      });
      container.read(backgroundActivityControllerProvider);
      container.read(backgroundActivityControllerProvider.notifier).setResident(true);

      lifecycle.add(AppLifecycleState.hidden);
      await Future<void>.delayed(Duration.zero);
      expect(applyCalls, [true]);

      // hidden -> hidden: 판정 값이 그대로(true)라 다시 부르면 안 된다.
      lifecycle.add(AppLifecycleState.hidden);
      await Future<void>.delayed(Duration.zero);
      expect(applyCalls, [true], reason: '판정 값이 안 바뀌면 다시 부르지 않는다');

      // inactive는 hidden이 아니므로 판정이 false로 바뀐다 — 이건 실제 변화다.
      lifecycle.add(AppLifecycleState.inactive);
      await Future<void>.delayed(Duration.zero);
      expect(applyCalls, [true, false]);

      // inactive -> inactive: 판정 값이 그대로(false)라 다시 부르면 안 된다.
      lifecycle.add(AppLifecycleState.inactive);
      await Future<void>.delayed(Duration.zero);
      expect(applyCalls, [true, false], reason: '판정 값이 안 바뀌면 다시 부르지 않는다');
    });
  });
}
