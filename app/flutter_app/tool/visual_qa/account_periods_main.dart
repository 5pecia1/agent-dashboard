/// Real usage cards with synthetic dates; no personal settings or network reads.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/i18n/usage_catalog.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_models.dart';
import 'package:my_dashboard/src/integrations/data/grok_usage_models.dart';
import 'package:my_dashboard/src/integrations/state/devin_usage_provider.dart';
import 'package:my_dashboard/src/integrations/state/grok_usage_provider.dart';
import 'package:my_dashboard/src/integrations/ui/usage_panels.dart';
import 'package:my_dashboard/src/integrations/state/teamclaude_provider.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart';
import 'package:my_dashboard/src/rust/frb_generated.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';

class _Devin extends DevinUsageController {
  _Devin(this.initial);
  final DevinUsageState initial;
  @override
  DevinUsageState build() => initial;
  @override
  void setActive(bool active) {}
  @override
  Future<void> refresh() async {}
}

class _Grok extends GrokUsageController {
  _Grok(this.initial);
  final GrokUsageState initial;
  @override
  GrokUsageState build() => initial;
  @override
  void setActive(bool active) {}
  @override
  Future<void> refresh({bool userInitiated = false}) async {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const _Scenario());
}

class _Scenario extends StatefulWidget {
  const _Scenario();
  @override
  State<_Scenario> createState() => _ScenarioState();
}

class _ScenarioState extends State<_Scenario> {
  bool _korean = !const bool.fromEnvironment('QA_ENGLISH');
  bool _stale = const bool.fromEnvironment('QA_STALE');
  bool _missing = const bool.fromEnvironment('QA_MISSING');
  bool _largeText = const bool.fromEnvironment('QA_LARGE_TEXT');

  @override
  Widget build(BuildContext context) {
    final end = _missing ? null : DateTime.utc(2026, 10, 14, 14, 21);
    return ProviderScope(
      key: ValueKey('$_korean/$_stale/$_missing/$_largeText'),
      overrides: [
        localeProvider.overrideWithValue(_korean ? LocaleDto.ko : LocaleDto.en),
        extensionTranslationProvider.overrideWithValue(usageTranslation),
        i18nTranslateOverride.overrideWithValue((key, locale) => key),
        teamClaudeInitialConnectionProvider.overrideWithValue(null),
        devinUsageControllerProvider.overrideWith(
          () => _Devin(
            DevinUsageState(
              connection: const DevinConnection(
                baseUrl: 'https://demo.invalid',
                apiKey: 'demo',
              ),
              quota: DevinQuota(
                accountName: 'Demo account',
                planName: 'Max',
                weeklyRemainingPercent: 48,
                weeklyResetAt: DateTime.utc(2026, 10, 12),
                planEndsAt: end,
                hideDailyQuota: true,
              ),
              errorKey: _stale ? 'devin.network_error' : null,
            ),
          ),
        ),
        grokUsageControllerProvider.overrideWith(
          () => _Grok(
            GrokUsageState(
              cliEnabled: true,
              reading: GrokUsageReading(
                usedPercent: 25,
                window: GrokUsageWindow.weekly,
                plan: 'SuperGrok',
                resetsAt: DateTime.utc(2026, 10, 12),
                billingPeriodEndsAt: end,
              ),
              errorKey: _stale ? 'grok.network_error' : null,
            ),
          ),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  Wrap(
                    children: [
                      _toggle('한국어', _korean, (v) => _korean = v),
                      _toggle('Stale reading', _stale, (v) => _stale = v),
                      _toggle('Missing date', _missing, (v) => _missing = v),
                      _toggle('Large text', _largeText, (v) => _largeText = v),
                    ],
                  ),
                  MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(_largeText ? 2 : 1),
                    ),
                    child: const String.fromEnvironment('QA_CARD_WIDTH').isEmpty
                        ? const UsagePanels()
                        : Align(
                            alignment: Alignment.topCenter,
                            child: SizedBox(
                              width: double.parse(
                                const String.fromEnvironment('QA_CARD_WIDTH'),
                              ),
                              child: const UsagePanels(),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toggle(String label, bool value, void Function(bool) update) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label),
      Switch(value: value, onChanged: (next) => setState(() => update(next))),
    ],
  );
}
