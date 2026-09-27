import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/quota_widgets.dart';

void main() {
  test('formatDashboardDate는 월과 일을 0으로 채운 yyyy-MM-dd를 만든다', () {
    expect(formatDashboardDate(DateTime(2026, 1, 2)), '2026-01-02');
    expect(formatDashboardDate(DateTime(2026, 12, 31)), '2026-12-31');
  });

  testWidgets('리셋 표시와 툴팁은 로케일 날짜가 아니라 yyyy-MM-dd를 쓴다', (tester) async {
    final reset = DateTime.now().add(const Duration(days: 3));
    final expected = formatDashboardDate(reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          i18nTranslateOverride.overrideWithValue(
            (key, locale) => key.split('.').last,
          ),
          // 인자를 그대로 이어 붙이는 가짜 — 위젯이 넘긴 날짜 문자열을 검증한다.
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, names, values) => values.join(' '),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: QuotaResetTime(keyPrefix: 'devin', reset: reset),
          ),
        ),
      ),
    );
    final clockTexts = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data)
        .whereType<String>();
    final clockText = clockTexts.firstWhere((d) => d.startsWith(expected));
    expect(clockText, matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')));
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, startsWith(expected));
    expect(tooltip.message, matches(RegExp(r'^\d{4}-\d{2}-\d{2}')));
  });
}
