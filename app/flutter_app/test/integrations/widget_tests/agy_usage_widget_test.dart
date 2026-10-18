import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/i18n/usage_catalog.dart';
import 'package:my_dashboard/src/integrations/data/agy_usage_models.dart';
import 'package:my_dashboard/src/integrations/platform/tray_usage.dart';
import 'package:my_dashboard/src/integrations/state/agy_usage_provider.dart';
import 'package:my_dashboard/src/integrations/state/usage_config.dart';
import 'package:my_dashboard/src/integrations/ui/usage_panels.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/agy_quota_panel.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/agy_setup.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';

import '../fixtures/agy_usage_fixture.dart';

class _FixedAgy extends AgyUsageController {
  _FixedAgy(this.initial);
  final AgyUsageState initial;
  @override
  AgyUsageState build() => initial;
  @override
  void setActive(bool active) {}
}

AgyUsageReading _reading() => agyUsageReadingFromJson(
  agyUsageFixtureData(
    resetAt: DateTime.now()
        .toUtc()
        .add(const Duration(days: 3))
        .toIso8601String(),
  ),
);

Widget _app(Widget child, {double scale = 1}) => MaterialApp(
  theme: AppTheme.dark(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('한 행에 카드가 하나 남아도 부모의 가용 폭을 채운다', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localeProvider.overrideWithValue(LocaleDto.en),
          extensionTranslationProvider.overrideWithValue(usageTranslation),
          agyUsageControllerProvider.overrideWith(
            () => _FixedAgy(AgyUsageState(enabled: true, reading: _reading())),
          ),
        ],
        child: _app(
          const Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 320,
              child: Column(children: [AgyQuotaPanel()]),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.getSize(find.byType(AgyQuotaPanel)).width, 320);
    expect(tester.takeException(), isNull);
  });
  testWidgets('홈과 트레이에서 모델 그룹의 네 사용률을 각각 표시한다', (tester) async {
    final state = AgyUsageState(enabled: true, reading: _reading());
    late List<String> tray;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localeProvider.overrideWithValue(LocaleDto.en),
          extensionTranslationProvider.overrideWithValue(usageTranslation),
          agyUsageControllerProvider.overrideWith(() => _FixedAgy(state)),
        ],
        child: _app(
          Consumer(
            builder: (context, ref, child) {
              tray = buildTrayUsageLabels(ref, agy: state);
              return const UsagePanels();
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(AgyQuotaPanel), findsOneWidget);
    expect(find.text('Gemini'), findsOneWidget);
    expect(find.text('Claude / GPT'), findsOneWidget);
    for (final value in ['42%', '19%', '2%', '1%']) {
      expect(find.text(value), findsOneWidget);
    }
    expect(find.text('5 hours'), findsNWidgets(2));
    expect(find.text('Weekly'), findsNWidgets(2));
    expect(tray, [
      'Usage',
      'Antigravity · Gemini · 5 hours 42% · Weekly 19%',
      'Antigravity · Claude / GPT · 5 hours 2% · Weekly 1%',
    ]);
    expect(find.textContaining('2030-'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('오래된 숫자를 유지하며 경고는 숫자 옆 점과 트레이 상태로 표시한다', (tester) async {
    final state = AgyUsageState(
      enabled: true,
      reading: _reading(),
      errorKey: 'agy.timeout',
    );
    late List<String> tray;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localeProvider.overrideWithValue(LocaleDto.en),
          extensionTranslationProvider.overrideWithValue(usageTranslation),
          agyUsageControllerProvider.overrideWith(() => _FixedAgy(state)),
        ],
        child: _app(
          Consumer(
            builder: (context, ref, child) {
              tray = buildTrayUsageLabels(ref, agy: state);
              return const AgyQuotaPanel();
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('42%'), findsOneWidget);
    expect(find.text(en['agy.timeout']!), findsNothing);
    expect(
      find.byTooltip('${en['agy.timeout']}\n${en['agy.stale']}'),
      findsNWidgets(4),
    );
    final dot = tester.widget<Container>(
      find.byKey(const ValueKey('agy-warning-gemini-5h')),
    );
    expect((dot.decoration! as BoxDecoration).color, AppTokens.dark.warn);
    expect(tray.last, 'Antigravity · Refresh failed · Last successful reading');
  });

  testWidgets('영어와 한국어 320px 글자 두 배에서도 지표가 카드 안에서 줄바꿈된다', (tester) async {
    tester.view.physicalSize = const Size(320, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    for (final locale in [LocaleDto.en, LocaleDto.ko]) {
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(locale),
          overrides: [
            localeProvider.overrideWithValue(locale),
            extensionTranslationProvider.overrideWithValue(usageTranslation),
            agyUsageControllerProvider.overrideWith(
              () =>
                  _FixedAgy(AgyUsageState(enabled: true, reading: _reading())),
            ),
          ],
          child: _app(const AgyQuotaPanel(), scale: 2),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final five = tester.getRect(
        find.byKey(const ValueKey('agy-percent-gemini-5h')),
      );
      final weekly = tester.getRect(
        find.byKey(const ValueKey('agy-percent-gemini-weekly')),
      );
      expect(weekly.top, greaterThan(five.bottom));
      expect(five.right, lessThanOrEqualTo(320));
      expect(weekly.right, lessThanOrEqualTo(320));
    }
  });

  testWidgets('빈 값은 0퍼센트 대신 정보 없음이고 처음 조회 실패는 안내를 표시한다', (tester) async {
    final data = agyUsageFixtureData();
    agyFixtureBuckets(data).first.remove('remaining_fraction');
    agyFixtureBuckets(data).first.remove('reset_time');
    var state = AgyUsageState(
      enabled: true,
      reading: agyUsageReadingFromJson(data),
    );
    Future<void> pump() async {
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(state),
          overrides: [
            localeProvider.overrideWithValue(LocaleDto.en),
            extensionTranslationProvider.overrideWithValue(usageTranslation),
            agyUsageControllerProvider.overrideWith(() => _FixedAgy(state)),
          ],
          child: _app(const AgyQuotaPanel()),
        ),
      );
      await tester.pump();
    }

    await pump();
    expect(find.text('Unknown'), findsOneWidget);
    expect(find.text('Reset unknown'), findsOneWidget);
    expect(find.text('0%'), findsNothing);
    state = const AgyUsageState(enabled: true, errorKey: 'agy.not_installed');
    await pump();
    expect(find.text(en['agy.not_installed']!), findsOneWidget);
    expect(find.text('0%'), findsNothing);
    state = const AgyUsageState();
    await pump();
    expect(find.text('Antigravity'), findsNothing);
  });

  testWidgets('설정 읽기에 실패하면 저장을 막고 복구 뒤 기존 설정을 보존하며 스위치를 켠다', (tester) async {
    var loadFails = true;
    var saves = 0;
    var fetches = 0;
    var saved = const DashboardConfigValues(extra: {'opaque': 'keep'});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localeProvider.overrideWithValue(LocaleDto.en),
          extensionTranslationProvider.overrideWithValue(usageTranslation),
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          agyUsageSupportedProvider.overrideWithValue(true),
          agyUsageFetchProvider.overrideWithValue(() async {
            fetches++;
            return _reading();
          }),
          configLoadFnProvider.overrideWithValue(() async {
            if (loadFails) throw const FormatException('fixture');
            return saved;
          }),
          configPatchFnProvider.overrideWithValue((patch) async {
            saves++;
            saved = patch(saved);
          }),
        ],
        child: _app(const AgySetup()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    SwitchListTile tile() =>
        tester.widget(find.byKey(const ValueKey('agy-enabled')));
    expect(tile().onChanged, isNull);
    expect(saves, 0);
    loadFails = false;
    await tester.tap(find.text('action.retry'));
    await tester.pumpAndSettle();
    expect(tile().onChanged, isNotNull);
    await tester.tap(find.byKey(const ValueKey('agy-enabled')));
    await tester.pumpAndSettle();
    expect(saved.agyEnabled, isTrue);
    expect(saved.extra['opaque'], 'keep');
    expect(saves, 1);
    expect(fetches, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('저장 실패면 사용량을 켜지 않고 웹에는 macOS 전용 안내만 표시한다', (tester) async {
    var fetches = 0;
    Future<void> pump(bool supported) async {
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(supported),
          overrides: [
            localeProvider.overrideWithValue(LocaleDto.en),
            extensionTranslationProvider.overrideWithValue(usageTranslation),
            i18nTranslateOverride.overrideWithValue((key, locale) => key),
            agyUsageSupportedProvider.overrideWithValue(supported),
            agyUsageFetchProvider.overrideWithValue(() async {
              fetches++;
              return _reading();
            }),
            configLoadFnProvider.overrideWithValue(
              () async => const DashboardConfigValues(),
            ),
            configPatchFnProvider.overrideWithValue(
              (patch) async => throw StateError('fixture'),
            ),
          ],
          child: _app(const AgySetup()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
    }

    await pump(true);
    await tester.tap(find.byKey(const ValueKey('agy-enabled')));
    await tester.pumpAndSettle();
    expect(find.text('setup.save_error'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const ValueKey('agy-enabled')))
          .value,
      isFalse,
    );
    expect(fetches, 0);
    await pump(false);
    expect(find.byKey(const ValueKey('agy-enabled')), findsNothing);
    expect(find.text(en['agy.macos_only_body']!), findsOneWidget);
    expect(fetches, 0);
  });
}
