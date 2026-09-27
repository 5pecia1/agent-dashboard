/// `state/theme_mode_provider.dart`의 순수 함수 — [parseThemeMode],
/// [themeModeConfigValue] — 를 위젯/Notifier 없이 값만으로 닫는다.
library;

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/state/theme_mode_provider.dart';

void main() {
  group('parseThemeMode', () {
    test("'light'/'dark'는 각자의 ThemeMode로 매핑된다", () {
      expect(parseThemeMode('light'), ThemeMode.light);
      expect(parseThemeMode('dark'), ThemeMode.dark);
    });

    test("'system'은 ThemeMode.system으로 매핑된다", () {
      expect(parseThemeMode('system'), ThemeMode.system);
    });

    test('null이나 알 수 없는 값은 전부 ThemeMode.system으로 접힌다', () {
      expect(parseThemeMode(null), ThemeMode.system);
      expect(parseThemeMode(''), ThemeMode.system);
      expect(parseThemeMode('손상된-값'), ThemeMode.system);
    });
  });

  group('themeModeConfigValue', () {
    test('세 ThemeMode 값이 각자의 저장용 문자열로 뒤집힌다', () {
      expect(themeModeConfigValue(ThemeMode.system), 'system');
      expect(themeModeConfigValue(ThemeMode.light), 'light');
      expect(themeModeConfigValue(ThemeMode.dark), 'dark');
    });

    test('parseThemeMode의 왕복(round-trip)이 항등이다', () {
      for (final mode in ThemeMode.values) {
        expect(parseThemeMode(themeModeConfigValue(mode)), mode);
      }
    });
  });
}
