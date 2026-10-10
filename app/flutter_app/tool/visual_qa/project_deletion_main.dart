/// Real translations and widgets with in-memory deletion requests.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart';
import 'package:my_dashboard/src/rust/frb_generated.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';

const _fixtureProject = '/workspace/my-dashboard';
const _requestDelay = Duration(milliseconds: 800);

class _FixtureSync extends SyncController {
  @override
  SyncControllerState build() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final sessions = [
      for (final source in ['claude-code', 'codex', 'devin'])
        SessionViewDto(
          key: '$source:fixture',
          sessionId: 'fixture',
          source: source,
          project: _fixtureProject,
          host: source == 'codex' ? 'linux-host' : 'mac-host',
          state: 'waiting_input',
          lastTransitionId: 10,
          updatedAt: now,
        ),
      SessionViewDto(
        key: 'grok:other-project',
        sessionId: 'other-project',
        source: 'grok',
        project: '/other/my-dashboard',
        host: 'mac-host',
        state: 'done',
        updatedAt: now,
      ),
    ];
    return SyncControllerState(
      sync: SyncState(
        cursor: 10,
        sessions: {for (final session in sessions) session.key: session},
        pendingAlerts: [
          TransitionDto(
            id: 10,
            sessionKey: sessions.first.key,
            project: _fixtureProject,
            toState: 'waiting_input',
            fromState: 'working',
            occurredAt: now,
            createdAt: now,
          ),
        ],
      ),
    );
  }
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
  bool _largeText = const bool.fromEnvironment('QA_LARGE_TEXT');
  bool _failSecond = false;
  int _reset = 0;

  @override
  Widget build(BuildContext context) => ProviderScope(
    key: ValueKey('$_english/$_largeText/$_failSecond/$_reset'),
    overrides: [
      localeProvider.overrideWithValue(_english ? LocaleDto.en : LocaleDto.ko),
      syncControllerProvider.overrideWith(_FixtureSync.new),
      dashboardConfigValuesProvider.overrideWithValue(
        const DashboardConfigValues(),
      ),
      dashboardInitialApiConfigProvider.overrideWithValue(
        DashboardApiConfig(baseUrl: Uri.parse('https://fixture.invalid')),
      ),
      dashboardApiConfigProviderOverride,
      httpSendProvider.overrideWithValue((request) async {
        if (request.method != 'DELETE') {
          throw StateError('Fixture only supports deletion');
        }
        await Future<void>.delayed(_requestDelay);
        return ApiResponse(
          statusCode:
              _failSecond && request.url.pathSegments.last == 'codex:fixture'
              ? 500
              : 200,
          body: '{}',
        );
      }),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(_largeText ? 2 : 1)),
        child: child!,
      ),
      home: Scaffold(
        body: Column(
          children: [
            Wrap(
              children: [
                _toggle('English', _english, (v) => _english = v),
                _toggle('Large text', _largeText, (v) => _largeText = v),
                _toggle(
                  'Fail one request',
                  _failSecond,
                  (v) => _failSecond = v,
                ),
                TextButton(
                  onPressed: () => setState(() => _reset++),
                  child: const Text('Reset fixture'),
                ),
              ],
            ),
            const Expanded(child: SessionsPage()),
          ],
        ),
      ),
    ),
  );

  Widget _toggle(String label, bool value, void Function(bool) update) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label),
      Switch(value: value, onChanged: (v) => setState(() => update(v))),
    ],
  );
}
