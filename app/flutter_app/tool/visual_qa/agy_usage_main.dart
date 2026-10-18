/// Isolated native QA: settings stay in memory. Live mode only queries agy.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/integrations/data/agy_usage_models.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_models.dart';
import 'package:my_dashboard/src/integrations/data/grok_usage_models.dart';
import 'package:my_dashboard/src/integrations/platform/tray_usage.dart';
import 'package:my_dashboard/src/integrations/state/agy_usage_provider.dart';
import 'package:my_dashboard/src/integrations/state/devin_usage_provider.dart';
import 'package:my_dashboard/src/integrations/state/grok_usage_provider.dart';
import 'package:my_dashboard/src/integrations/state/usage_config.dart';
import 'package:my_dashboard/src/integrations/ui/usage_panels.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/agy_setup.dart';
import 'package:my_dashboard/src/platform/tray_native.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart';
import 'package:my_dashboard/src/rust/frb_generated.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/state/usage_integrations.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:tray_manager/tray_manager.dart';

import '../../test/integrations/fixtures/agy_usage_fixture.dart';

const _trayAsset = 'assets/tray_icon.png';
const _qaNarrowWidth = 320.0;

class _FixtureAgy extends AgyUsageController {
  _FixtureAgy(this.initial);
  final AgyUsageState initial;
  @override
  AgyUsageState build() => initial;
  @override
  void setActive(bool active) {}
  @override
  Future<void> refresh({bool userInitiated = false}) async {}
  @override
  void configure(bool enabled) => state = AgyUsageState(
    enabled: enabled,
    reading: enabled ? initial.reading : null,
    errorKey: enabled ? initial.errorKey : null,
  );
}

class _FixtureDevin extends DevinUsageController {
  @override
  DevinUsageState build() => DevinUsageState(
    connection: const DevinConnection(
      baseUrl: 'https://demo.invalid',
      apiKey: 'demo',
    ),
    quota: DevinQuota(
      weeklyRemainingPercent: 48,
      weeklyResetAt: DateTime.now().add(const Duration(days: 3)),
      hideDailyQuota: true,
    ),
  );
  @override
  void setActive(bool active) {}
  @override
  Future<void> refresh() async {}
}

class _FixtureGrok extends GrokUsageController {
  @override
  GrokUsageState build() => GrokUsageState(
    enabled: true,
    reading: GrokUsageReading(
      usedPercent: 25,
      window: GrokUsageWindow.weekly,
      resetsAt: DateTime.now().add(const Duration(days: 3)),
    ),
  );
  @override
  void setActive(bool active) {}
  @override
  Future<void> refresh({bool userInitiated = false}) async {}
}

class _FixtureSync extends SyncController {
  @override
  SyncControllerState build() => const SyncControllerState();
  @override
  void triggerNow({bool force = false}) {}
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
  bool _english = const bool.fromEnvironment('QA_ENGLISH');
  bool _large = const bool.fromEnvironment('QA_LARGE_TEXT');
  bool _narrow = const bool.fromEnvironment('QA_NARROW');
  bool _live = const bool.fromEnvironment('QA_LIVE');
  bool _stale = false;
  bool _missing = false;
  bool _dark = false;
  DashboardConfigValues _config = const DashboardConfigValues(
    extra: {
      'antigravity': {'enabled': true},
    },
  );

  @override
  Widget build(BuildContext context) {
    final fixture = agyUsageReadingFromJson(
      agyUsageFixtureData(
        resetAt: DateTime.now()
            .toUtc()
            .add(const Duration(days: 3))
            .toIso8601String(),
      ),
    );
    return ProviderScope(
      key: ValueKey(
        '$_english/$_large/$_narrow/$_live/$_stale/$_missing/$_dark',
      ),
      overrides: [
        ...usageDashboardOverrides(_config),
        ...usageDashboardUiOverrides,
        localeProvider.overrideWithValue(
          _english ? LocaleDto.en : LocaleDto.ko,
        ),
        agyUsageSupportedProvider.overrideWithValue(true),
        if (!_live)
          agyUsageControllerProvider.overrideWith(
            () => _FixtureAgy(
              AgyUsageState(
                enabled: _config.agyEnabled,
                reading: _missing ? null : fixture,
                errorKey: _missing
                    ? 'agy.not_installed'
                    : _stale
                    ? 'agy.timeout'
                    : null,
              ),
            ),
          ),
        devinUsageControllerProvider.overrideWith(_FixtureDevin.new),
        grokUsageControllerProvider.overrideWith(_FixtureGrok.new),
        syncControllerProvider.overrideWith(_FixtureSync.new),
        dashboardConfigValuesProvider.overrideWithValue(_config),
        configLoadFnProvider.overrideWithValue(() async => _config),
        configPatchFnProvider.overrideWithValue((patch) async {
          _config = patch(_config);
        }),
        httpSendProvider.overrideWithValue(
          (request) async => throw StateError('QA does not send HTTP requests'),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _dark ? AppTheme.dark() : AppTheme.light(),
        home: Consumer(
          builder: (context, ref, child) {
            final agy = ref.watch(agyUsageControllerProvider);
            final tray = buildTrayUsageLabels(ref, agy: agy);
            return Scaffold(
              appBar: AppBar(title: const Text('Antigravity usage QA')),
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    Wrap(
                      children: [
                        _toggle('English', _english, (v) => _english = v),
                        _toggle('Large text', _large, (v) => _large = v),
                        _toggle('320px', _narrow, (v) => _narrow = v),
                        _toggle('Dark', _dark, (v) => _dark = v),
                        _toggle(
                          'Installed agy (live)',
                          _live,
                          (v) => _live = v,
                        ),
                        if (!_live) ...[
                          _toggle('Stale', _stale, (v) => _stale = v),
                          _toggle('No reading', _missing, (v) => _missing = v),
                        ],
                      ],
                    ),
                    Text(
                      _live
                          ? 'Reading mode: installed CLI'
                          : 'Reading mode: fixture',
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed: () => ref
                              .read(agyUsageControllerProvider.notifier)
                              .refresh(userInitiated: true),
                          child: const Text('Refresh'),
                        ),
                        OutlinedButton(
                          onPressed: () async {
                            await trayManager.setIcon(
                              _trayAsset,
                              isTemplate: false,
                            );
                            if (context.mounted) await TrayMenu(ref).show();
                          },
                          child: const Text('Open native tray menu'),
                        ),
                      ],
                    ),
                    MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(_large ? 2 : 1)),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: _narrow ? _qaNarrowWidth : null,
                          child: const UsagePanels(),
                        ),
                      ),
                    ),
                    for (final label in tray) Text(label),
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: AgySetup(),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _toggle(String label, bool value, void Function(bool) change) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label),
      Switch(value: value, onChanged: (v) => setState(() => change(v))),
    ],
  );
}
