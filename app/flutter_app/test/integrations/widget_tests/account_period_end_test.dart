import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/i18n/usage_catalog.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_models.dart';
import 'package:my_dashboard/src/integrations/data/grok_usage_models.dart';
import 'package:my_dashboard/src/integrations/state/devin_usage_provider.dart';
import 'package:my_dashboard/src/integrations/state/grok_usage_provider.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/account_period_end.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/devin_quota_panel.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/grok_quota_panel.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/quota_widgets.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';

class _Devin extends DevinUsageController {
  _Devin(this.initial);
  final DevinUsageState initial;
  @override
  DevinUsageState build() => initial;
  @override
  void setActive(bool active) {}
}

class _Grok extends GrokUsageController {
  _Grok(this.initial);
  final GrokUsageState initial;
  @override
  GrokUsageState build() => initial;
  @override
  void setActive(bool active) {}
}

void main() {
  final end = DateTime.utc(2020, 1, 2, 3, 34);
  final local = end.toLocal();
  final date = formatDashboardDate(local);
  final clock =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';

  Future<void> pump(
    WidgetTester tester, {
    required Widget child,
    LocaleDto locale = LocaleDto.en,
    DevinUsageState devin = const DevinUsageState(),
    GrokUsageState grok = const GrokUsageState(),
  }) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localeProvider.overrideWithValue(locale),
          extensionTranslationProvider.overrideWithValue(usageTranslation),
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          devinUsageControllerProvider.overrideWith(() => _Devin(devin)),
          grokUsageControllerProvider.overrideWith(() => _Grok(grok)),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(body: SingleChildScrollView(child: child)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('지난 기간 종료일도 현지 날짜와 24시간제로 표시하고 결제일로 바꾸지 않는다', (tester) async {
    await pump(
      tester,
      child: AccountPeriodEnd(labelKey: 'devin.plan_period_end', endsAt: end),
    );
    expect(
      find.text('Plan period ends $date $clock ${local.timeZoneName}'),
      findsOneWidget,
    );
    expect(find.textContaining('payment'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('종료일이 없으면 날짜 행을 그리지 않는다', (tester) async {
    await pump(
      tester,
      child: const AccountPeriodEnd(labelKey: 'devin.plan_period_end'),
    );
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('Devin 조회가 실패해도 마지막 날짜와 오래된 정보 안내를 함께 표시한다', (tester) async {
    await pump(
      tester,
      locale: LocaleDto.ko,
      devin: DevinUsageState(
        connection: const DevinConnection(
          baseUrl: 'https://test.invalid',
          apiKey: 'test',
        ),
        quota: DevinQuota(planEndsAt: end, weeklyRemainingPercent: 50),
        errorKey: 'devin.network_error',
      ),
      child: const DevinQuotaPanel(),
    );
    expect(
      find.text('플랜 기간 종료: $date $clock ${local.timeZoneName}'),
      findsOneWidget,
    );
    expect(find.text(ko['devin.stale']!), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Grok 조회가 실패해도 청구 날짜와 오래된 정보 툴팁을 함께 표시한다', (tester) async {
    await pump(
      tester,
      grok: GrokUsageState(
        cliEnabled: true,
        reading: GrokUsageReading(
          usedPercent: 25,
          window: GrokUsageWindow.weekly,
          billingPeriodEndsAt: end,
        ),
        errorKey: 'grok.network_error',
      ),
      child: const GrokQuotaPanel(),
    );
    expect(
      find.text('Billing period ends $date $clock ${local.timeZoneName}'),
      findsOneWidget,
    );
    final tooltips = tester.widgetList<Tooltip>(find.byType(Tooltip));
    expect(
      tooltips.any(
        (tooltip) => tooltip.message?.contains(en['grok.stale']!) == true,
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('CLI를 끄면 이전 CLI 청구 날짜를 Bot 카드에 표시하지 않는다', (tester) async {
    await pump(
      tester,
      grok: GrokUsageState(
        cliEnabled: false,
        botEnabled: true,
        reading: GrokUsageReading(
          usedPercent: 25,
          window: GrokUsageWindow.weekly,
          billingPeriodEndsAt: end,
        ),
        botReading: const GrokUsageReading(
          usedPercent: 10,
          window: GrokUsageWindow.weekly,
        ),
      ),
      child: const GrokQuotaPanel(),
    );
    expect(find.textContaining('Billing period ends'), findsNothing);
    expect(find.text('Grok Bot'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
