/// `state/theme_mode_provider.dart`의 [ThemeModeController] 조립을
/// [ProviderContainer]만으로 닫는다 — 순수 함수([parseThemeMode],
/// [themeModeConfigValue])는 `unit_tests/theme_mode_provider_pure_test.dart`가
/// 이미 값만으로 다룬다.
library;

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/state/theme_mode_provider.dart';

void main() {
  group('ThemeModeController', () {
    test('build()의 기본값은 ThemeMode.system이다 — dashboardConfigValuesProvider를 몰라도 죽지 않는다', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(themeModeControllerProvider), ThemeMode.system);
    });

    test('setThemeMode가 state를 그대로 반영하고, 구독자가 다시 그려진다', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final seen = <ThemeMode>[];
      container.listen(
        themeModeControllerProvider,
        (previous, next) => seen.add(next),
        fireImmediately: true,
      );

      container.read(themeModeControllerProvider.notifier).setThemeMode(ThemeMode.dark);
      container.read(themeModeControllerProvider.notifier).setThemeMode(ThemeMode.light);

      expect(seen, [ThemeMode.system, ThemeMode.dark, ThemeMode.light]);
      expect(container.read(themeModeControllerProvider), ThemeMode.light);
    });
  });
}
