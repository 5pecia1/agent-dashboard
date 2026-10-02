/// 연동 패널(TeamClaude·Devin·Grok)이 저장된 설정을 읽지 못할 때: 입력과
/// 연결·해제·스위치를 잠근 채 한 줄 안내와 "다시 시도"만 보인다.
///
/// 예전에는 읽기 실패가 저장 오류 문구와 함께 빈 입력으로 풀려, 연결이나
/// 해제를 누르면 빈 값 위에 저장해 서버 자격증명과 다른 연동 설정을 지웠다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/integrations/state/grok_usage_provider.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/devin_setup.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/grok_setup.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/teamclaude_setup.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';

const ConfigReadException _accessFailure = ConfigReadException(
  ConfigReadFailureKind.access,
  location: '/fixture/config.json',
  detail: 'Cannot open file: Permission denied (errno 13)',
);

const DashboardConfigValues _stored = DashboardConfigValues(
  serverUrl: 'https://dash.example.test',
  clientToken: 'stored-client-token',
  extra: <String, Object?>{
    'teamclaude': <String, Object?>{
      'url': 'https://tc.example.test',
      'api_key': 'stored-teamclaude-key',
    },
    'devin': <String, Object?>{
      'url': 'https://devin.example.test',
      'api_key': 'stored-devin-key',
    },
    'grok': <String, Object?>{'enabled': true, 'bot': true},
  },
);

/// 처음에는 읽기에 실패하고, [recover] 뒤에는 저장된 값을 돌려주는 저장소.
class _FlakyStore {
  bool failing = true;
  int loads = 0;
  final List<DashboardConfigValues> saves = <DashboardConfigValues>[];

  Future<DashboardConfigValues> load() async {
    loads += 1;
    if (failing) throw _accessFailure;
    return _stored;
  }

  Future<void> save(DashboardConfigValues values) async => saves.add(values);
}

Future<void> _pumpPanel(
  WidgetTester tester,
  Widget panel,
  _FlakyStore store,
) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = const Size(600, 1200);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        i18nTranslateOverride.overrideWithValue((key, locale) => key),
        i18nTranslateArgsOverride.overrideWithValue(
          (key, locale, argKeys, argVals) => key,
        ),
        grokUsageSupportedProvider.overrideWithValue(true),
        configLoadFnProvider.overrideWithValue(store.load),
        configSaveFnProvider.overrideWithValue(store.save),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: SingleChildScrollView(child: panel)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byType(ExpansionTile));
  await tester.pumpAndSettle();
}

void _expectLockedWithInlineError(WidgetTester tester) {
  expect(find.text('config.read_failed.inline'), findsOneWidget);
  expect(find.text('setup.save_error'), findsNothing);
  expect(find.text('action.retry'), findsOneWidget);
}

Future<void> _retry(WidgetTester tester, _FlakyStore store) async {
  store.failing = false;
  await tester.tap(find.text('action.retry'));
  await tester.pumpAndSettle();
  expect(find.text('config.read_failed.inline'), findsNothing);
}

void _expectTextFields(WidgetTester tester, {required bool enabled}) {
  final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
  expect(fields, hasLength(2));
  for (final field in fields) {
    expect(field.enabled, enabled);
  }
}

void main() {
  testWidgets('TeamClaude 패널은 읽기 실패 동안 입력과 연결·해제를 잠그고 다시 읽으면 저장된 연결을 채운다', (
    tester,
  ) async {
    final store = _FlakyStore();
    await _pumpPanel(tester, const TeamClaudeSetup(), store);

    _expectLockedWithInlineError(tester);
    _expectTextFields(tester, enabled: false);
    final connect = find.widgetWithText(FilledButton, 'teamclaude.connect');
    final disconnect = find.widgetWithText(TextButton, 'teamclaude.disconnect');
    expect(tester.widget<FilledButton>(connect).onPressed, isNull);
    expect(tester.widget<TextButton>(disconnect).onPressed, isNull);
    await tester.tap(disconnect, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(store.saves, isEmpty);

    await _retry(tester, store);

    _expectTextFields(tester, enabled: true);
    final key = tester.widget<TextField>(
      find.byKey(const ValueKey('teamclaude-key')),
    );
    expect(key.controller!.text, 'stored-teamclaude-key');
    final url = tester.widget<TextField>(
      find.byKey(const ValueKey('teamclaude-url')),
    );
    expect(url.controller!.text, contains('tc.example.test'));
    expect(tester.widget<FilledButton>(connect).onPressed, isNotNull);
    expect(store.saves, isEmpty);
  });

  testWidgets('Devin 패널은 읽기 실패 동안 입력과 연결·해제를 잠그고 다시 읽으면 저장된 연결을 채운다', (
    tester,
  ) async {
    final store = _FlakyStore();
    await _pumpPanel(tester, const DevinSetup(), store);

    _expectLockedWithInlineError(tester);
    _expectTextFields(tester, enabled: false);
    final connect = find.widgetWithText(FilledButton, 'devin.connect');
    final disconnect = find.widgetWithText(TextButton, 'devin.disconnect');
    expect(tester.widget<FilledButton>(connect).onPressed, isNull);
    expect(tester.widget<TextButton>(disconnect).onPressed, isNull);
    await tester.tap(disconnect, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(store.saves, isEmpty);

    await _retry(tester, store);

    _expectTextFields(tester, enabled: true);
    final key = tester.widget<TextField>(
      find.byKey(const ValueKey('devin-key')),
    );
    expect(key.controller!.text, 'stored-devin-key');
    final url = tester.widget<TextField>(
      find.byKey(const ValueKey('devin-url')),
    );
    expect(url.controller!.text, contains('devin.example.test'));
    expect(tester.widget<TextButton>(disconnect).onPressed, isNotNull);
    expect(store.saves, isEmpty);
  });

  testWidgets('Grok 패널은 읽기 실패 동안 두 스위치를 잠그고 다시 읽으면 저장된 선택을 보인다', (
    tester,
  ) async {
    final store = _FlakyStore();
    await _pumpPanel(tester, const GrokSetup(), store);

    _expectLockedWithInlineError(tester);
    final cli = find.byKey(const ValueKey('grok-enabled'));
    final bot = find.byKey(const ValueKey('grok-bot-enabled'));
    expect(tester.widget<SwitchListTile>(cli).onChanged, isNull);
    expect(tester.widget<SwitchListTile>(bot).onChanged, isNull);
    await tester.tap(cli, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(store.saves, isEmpty);

    await _retry(tester, store);

    expect(tester.widget<SwitchListTile>(cli).value, isTrue);
    expect(tester.widget<SwitchListTile>(bot).value, isTrue);
    expect(tester.widget<SwitchListTile>(cli).onChanged, isNotNull);
    expect(store.saves, isEmpty);
  });
}
