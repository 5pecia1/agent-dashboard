import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/integrations/data/grok_bot_models.dart';
import 'package:my_dashboard/src/integrations/data/grok_usage_models.dart';
import 'package:my_dashboard/src/integrations/state/grok_usage_provider.dart';
import 'package:my_dashboard/src/integrations/state/usage_config.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/grok_quota_panel.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/grok_setup.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';

void main() {
  testWidgets('꺼져 있으면 패널을 그리지 않고 웹에서는 청구 주소를 호출하지 않는다', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          grokUsageSupportedProvider.overrideWithValue(false),
          grokInitialEnabledProvider.overrideWithValue(true),
          httpSendProvider.overrideWithValue((request) async {
            calls++;
            return const ApiResponse(statusCode: 200, body: '{}');
          }),
        ],
        child: const MaterialApp(home: Scaffold(body: GrokQuotaPanel())),
      ),
    );
    await tester.pump();
    expect(find.byType(GrokQuotaPanel), findsOneWidget);
    expect(find.text('grok.title'), findsNothing);
    expect(calls, 0);
  });

  testWidgets('웹 설정에는 Grok Bot 스위치가 없다', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          grokUsageSupportedProvider.overrideWithValue(false),
          configLoadFnProvider.overrideWithValue(
            () async => const DashboardConfigValues(),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: GrokSetup())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grok-enabled')), findsNothing);
    expect(find.byKey(const ValueKey('grok-bot-enabled')), findsNothing);
    expect(find.text('grok.macos_only_body'), findsOneWidget);
  });

  testWidgets('사용률과 리셋 문구를 그린다', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, names, values) => '$key ${values.join(' ')}',
          ),
          grokUsageControllerProvider.overrideWith(
            () => _FixedGrok(
              GrokUsageState(
                enabled: true,
                updatedAt: DateTime(2026, 9, 28, 9, 30),
                reading: GrokUsageReading(
                  usedPercent: 75,
                  window: GrokUsageWindow.weekly,
                  plan: 'SuperGrok',
                  accountLabel: 'person@example.test',
                  resetsAt: DateTime.now().add(
                    const Duration(days: 2, hours: 3),
                  ),
                ),
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: GrokQuotaPanel()),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('grok.title'), findsOneWidget);
    expect(find.text('grok.percent 75'), findsOneWidget);
    expect(find.text('SuperGrok'), findsOneWidget);
    expect(find.text('person@example.test'), findsOneWidget);
    expect(find.textContaining('grok.reset_days'), findsOneWidget);
  });

  testWidgets('Grok Bot 오류가 CLI 사용률을 지우지 않고 두 막대가 최소 폭에 들어간다', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, names, values) => '$key ${values.join(' ')}',
          ),
          grokUsageControllerProvider.overrideWith(
            () => _FixedGrok(
              GrokUsageState(
                cliEnabled: true,
                botEnabled: true,
                reading: GrokUsageReading(
                  usedPercent: 75,
                  window: GrokUsageWindow.weekly,
                  plan: 'SuperGrok',
                ),
                botReading: const GrokUsageReading(
                  usedPercent: 40,
                  window: GrokUsageWindow.weekly,
                  plan: 'SuperGrok',
                ),
                botErrorKey: 'grok.bot_unauthorized',
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: SizedBox(width: 280, child: GrokQuotaPanel()),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('grok.weekly'), findsOneWidget);
    expect(find.text('grok.bot_metric'), findsOneWidget);
    expect(find.text('grok.percent 75'), findsOneWidget);
    expect(find.text('grok.percent 40'), findsOneWidget);
    expect(find.text('grok.bot_unauthorized'), findsNothing);
    expect(find.text('grok.stale'), findsNothing);
    expect(find.byTooltip('grok.bot_unauthorized\ngrok.stale'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('grok-cli-reading-warning')),
      findsNothing,
    );
    expect(
      _warningColor(tester, const ValueKey('grok-bot-reading-warning')),
      AppTokens.light.warn,
    );
  });

  testWidgets('로그인 만료여도 마지막 사용률은 남고 경고는 그 숫자 옆 점으로만 보인다', (tester) async {
    await _pumpGrok(
      tester,
      GrokUsageState(
        cliEnabled: true,
        botEnabled: true,
        updatedAt: DateTime(2026, 9, 29, 19, 8),
        errorKey: 'grok.sign_in_expired',
        reading: GrokUsageReading(
          usedPercent: 26,
          window: GrokUsageWindow.weekly,
          plan: 'SuperGrok',
          accountLabel: 'person@example.test',
          resetsAt: DateTime.now().add(const Duration(days: 5)),
        ),
        botReading: const GrokUsageReading(
          usedPercent: 0,
          window: GrokUsageWindow.weekly,
          plan: 'SuperGrok',
        ),
      ),
    );

    expect(find.text('grok.sign_in_expired'), findsNothing);
    expect(find.text('grok.stale'), findsNothing);
    expect(find.text('grok.percent 26'), findsOneWidget);
    expect(find.text('grok.percent 0'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('grok-bot-reading-warning')),
      findsNothing,
    );
    expect(find.byTooltip('grok.sign_in_expired\ngrok.stale'), findsOneWidget);

    final percent = tester.getRect(find.text('grok.percent 26'));
    final dot = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('grok-cli-reading-warning')),
        matching: find.byType(Container),
      ),
    );
    expect(dot.width, 8);
    expect(dot.height, 8);
    expect(dot.left, greaterThan(percent.right));
    expect(dot.left, lessThan(percent.right + 16));
    expect(dot.center.dy, closeTo(percent.center.dy, 1));
    expect(
      _warningColor(tester, const ValueKey('grok-cli-reading-warning')),
      AppTokens.dark.warn,
    );
    expect(
      _warningShape(tester, const ValueKey('grok-cli-reading-warning')),
      BoxShape.circle,
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer();
    addTearDown(gesture.removePointer);
    await gesture.moveTo(dot.center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('grok.sign_in_expired\ngrok.stale'), findsOneWidget);
  });

  testWidgets('CLI와 Grok Bot 경고는 각자 숫자 옆 점에 따로 붙는다', (tester) async {
    await _pumpGrok(
      tester,
      const GrokUsageState(
        cliEnabled: true,
        botEnabled: true,
        errorKey: 'grok.sign_in_expired',
        botErrorKey: 'grok.bot_keychain_denied',
        reading: GrokUsageReading(
          usedPercent: 26,
          window: GrokUsageWindow.weekly,
        ),
        botReading: GrokUsageReading(
          usedPercent: 4,
          window: GrokUsageWindow.weekly,
        ),
      ),
    );

    expect(find.text('grok.sign_in_expired'), findsNothing);
    expect(find.text('grok.bot_keychain_denied'), findsNothing);
    expect(find.text('grok.stale'), findsNothing);
    expect(find.byTooltip('grok.sign_in_expired\ngrok.stale'), findsOneWidget);
    expect(
      find.byTooltip('grok.bot_keychain_denied\ngrok.stale'),
      findsOneWidget,
    );
  });

  testWidgets('사용률이 없으면 경고 문장을 카드에 그대로 둔다', (tester) async {
    await _pumpGrok(
      tester,
      const GrokUsageState(
        cliEnabled: true,
        botEnabled: true,
        errorKey: 'grok.signed_out',
        botErrorKey: 'grok.bot_signed_out',
        noticeKey: 'grok.no_usage',
      ),
    );

    expect(find.text('grok.signed_out'), findsOneWidget);
    expect(find.text('grok.bot_signed_out'), findsOneWidget);
    expect(find.text('grok.no_usage'), findsOneWidget);
    expect(find.text('grok.stale'), findsNothing);
    expect(find.byType(Tooltip), findsNothing);
  });

  testWidgets('macOS 스위치가 설정을 저장하고 컨트롤러를 켠다', (tester) async {
    DashboardConfigValues saved = const DashboardConfigValues();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          grokUsageSupportedProvider.overrideWithValue(true),
          configLoadFnProvider.overrideWithValue(
            () async => const DashboardConfigValues(),
          ),
          configPatchFnProvider.overrideWithValue((mutate) async {
            saved = mutate(saved);
          }),
          grokAuthReadProvider.overrideWithValue(
            () => const GrokAuthReadResult.missing(),
          ),
          grokBotPreviewProvider.overrideWithValue(
            () => const GrokBotPreview.missing(),
          ),
          grokBotUnlockProvider.overrideWithValue(
            (preview) async => const GrokBotAuthReadResult.missing(),
          ),
          httpSendProvider.overrideWithValue(
            (request) async => const ApiResponse(statusCode: 200, body: '{}'),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: GrokSetup()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('grok-enabled')));
    await tester.pumpAndSettle();
    expect(saved.grokEnabled, isTrue);
    expect(saved.grokBotEnabled, isFalse);
    expect(find.text('grok.saved'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('grok-bot-enabled')));
    await tester.pumpAndSettle();
    expect(saved.grokEnabled, isTrue);
    expect(saved.grokBotEnabled, isTrue);
    expect(find.text('grok.bot_saved'), findsOneWidget);
  });
}

class _FixedGrok extends GrokUsageController {
  _FixedGrok(this.initial);
  final GrokUsageState initial;
  @override
  GrokUsageState build() => initial;
  @override
  void setActive(bool active) {}
}

Future<void> _pumpGrok(WidgetTester tester, GrokUsageState state) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        i18nTranslateOverride.overrideWithValue((key, locale) => key),
        i18nTranslateArgsOverride.overrideWithValue(
          (key, locale, names, values) => '$key ${values.join(' ')}',
        ),
        grokUsageControllerProvider.overrideWith(() => _FixedGrok(state)),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(body: GrokQuotaPanel()),
      ),
    ),
  );
}

Color _warningColor(WidgetTester tester, ValueKey<String> key) =>
    _warningDecoration(tester, key).color!;

BoxShape _warningShape(WidgetTester tester, ValueKey<String> key) =>
    _warningDecoration(tester, key).shape;

BoxDecoration _warningDecoration(WidgetTester tester, ValueKey<String> key) {
  final box = tester.widget<Container>(
    find.descendant(of: find.byKey(key), matching: find.byType(Container)),
  );
  return box.decoration! as BoxDecoration;
}
