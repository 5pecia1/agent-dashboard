import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_models.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/integrations/state/usage_config.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/integrations/state/devin_usage_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/devin_quota_panel.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/devin_setup.dart';

import '../unit_tests/devin_usage_test.dart' show userStatusFixture, connection;

class _FixedController extends DevinUsageController {
  _FixedController(this.initial);
  final DevinUsageState initial;
  @override
  DevinUsageState build() => initial;
  @override
  void setActive(bool active) {}
}

ProviderScope _wrap({
  required DevinUsageState state,
  DashboardConfigValues? saved,
  List<ApiRequest>? requests,
  required Widget child,
}) {
  var values = saved ?? const DashboardConfigValues();
  return ProviderScope(
    overrides: [
      i18nTranslateOverride.overrideWithValue(
        (key, locale) => key.split('.').last,
      ),
      i18nTranslateArgsOverride.overrideWithValue(
        (key, locale, names, values) => key.split('.').last,
      ),
      devinUsageControllerProvider.overrideWith(() => _FixedController(state)),
      configLoadFnProvider.overrideWithValue(() async => values),
      configSaveFnProvider.overrideWithValue((value) async {
        values = value;
      }),
      if (requests != null)
        httpSendProvider.overrideWithValue((request) async {
          requests.add(request);
          return ApiResponse(
            statusCode: 200,
            body: jsonEncode(userStatusFixture()),
          );
        }),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('주간 사용률과 리셋 요금제 계정명을 보여주고 일간은 플랜이 숨기면 그리지 않는다', (tester) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _wrap(
        state: DevinUsageState(
          connection: connection,
          quota: DevinQuota.fromUserStatus(userStatusFixture()),
          updatedAt: DateTime(2026, 9, 16),
        ),
        child: const SingleChildScrollView(child: DevinQuotaPanel()),
      ),
    );
    await tester.pumpAndSettle();
    // i18n 가짜는 키의 마지막 마디를 돌려주므로 제목은 'title'로 렌더링된다.
    expect(find.text('title'), findsOneWidget);
    expect(find.text('Max'), findsOneWidget);
    expect(find.text('tester'), findsOneWidget);
    expect(find.text('52%'), findsOneWidget);
    expect(find.text('reset_days'), findsOneWidget);
    expect(find.text('reset_clock'), findsOneWidget);
    // hideDailyQuota 플랜이라 일간 지표는 없다.
    expect(find.text('daily'), findsNothing);
    expect(find.text('overage'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('미설정 패널은 보이지 않고 저장 직후 새 키로 조회하며 해제하면 사라진다', (tester) async {
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var saved = const DashboardConfigValues(
      serverUrl: 'https://dash.test',
      clientToken: 'dash-key',
      cursor: 4,
      themeMode: 'dark',
    );
    final requests = <ApiRequest>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          i18nTranslateOverride.overrideWithValue(
            (key, locale) => key.split('.').last,
          ),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, names, values) => key.split('.').last,
          ),
          configLoadFnProvider.overrideWithValue(() async => saved),
          configSaveFnProvider.overrideWithValue((value) async {
            saved = value;
          }),
          httpSendProvider.overrideWithValue((request) async {
            requests.add(request);
            return ApiResponse(
              statusCode: 200,
              body: jsonEncode(userStatusFixture()),
            );
          }),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: Column(children: [DevinSetup(), DevinQuotaPanel()]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.text('52%'), findsNothing);
    await tester.tap(find.text('title'));
    await tester.pumpAndSettle();
    // 주소는 표준 서버가 미리 채워져 있다 — 키만 입력하면 된다.
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('devin-url')))
          .controller!
          .text,
      kDevinDefaultApiServer,
    );
    await tester.enterText(
      find.byKey(const ValueKey('devin-key')),
      'typed-key',
    );
    await tester.tap(find.text('connect'));
    await tester.pumpAndSettle();
    expect(saved.devin!.apiKey, 'typed-key');
    expect(saved.serverUrl, 'https://dash.test');
    expect(saved.clientToken, 'dash-key');
    expect(saved.cursor, 4);
    expect(saved.themeMode, 'dark');
    expect(requests.first.method, 'POST');
    expect(requests.first.url.path, kDevinUserStatusPath);
    final body = jsonDecode(requests.first.body!) as Map<String, dynamic>;
    expect((body['metadata'] as Map<String, dynamic>)['api_key'], 'typed-key');
    expect(find.text('52%'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('devin-key')))
          .obscureText,
      isTrue,
    );
    await tester.tap(find.text('disconnect'));
    await tester.pumpAndSettle();
    expect(saved.devin, isNull);
    expect(find.text('52%'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
