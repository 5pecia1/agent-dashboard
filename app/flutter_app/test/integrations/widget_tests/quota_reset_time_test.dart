import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/i18n/usage_catalog.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/quota_widgets.dart';

void main() {
  test('formatDashboardDate는 월과 일을 0으로 채운 yyyy-MM-dd를 만든다', () {
    expect(formatDashboardDate(DateTime(2026, 1, 2)), '2026-01-02');
    expect(formatDashboardDate(DateTime(2026, 12, 31)), '2026-12-31');
  });

  testWidgets('모든 제공자는 남은 시간만 표시하고 초기화 날짜와 툴팁은 표시하지 않는다', (tester) async {
    final reset = DateTime.now().add(const Duration(days: 3));
    for (final locale in [LocaleDto.ko, LocaleDto.en]) {
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(locale),
          overrides: [
            localeProvider.overrideWithValue(locale),
            extensionTranslationProvider.overrideWithValue(usageTranslation),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Column(
                children: [
                  for (final provider in ['teamclaude', 'devin', 'grok'])
                    QuotaResetTime(keyPrefix: provider, reset: reset),
                ],
              ),
            ),
          ),
        ),
      );
      final texts = tester.widgetList<Text>(find.byType(Text)).toList();
      expect(texts, hasLength(3));
      final remaining = locale == LocaleDto.ko
          ? RegExp(r'^\d+일 \d+시간 후$')
          : RegExp(r'^\d+d \d+h to reset$');
      for (final text in texts) {
        expect(text.data, matches(remaining));
        expect(text.data, isNot(contains(formatDashboardDate(reset))));
      }
      expect(find.byType(Tooltip), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}
