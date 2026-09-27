import 'package:my_dashboard/src/state/usage_integrations.dart';
import 'package:my_dashboard/src/state/dashboard_extensions.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_models.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_models.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/platform/tray_command.dart';
import 'package:my_dashboard/src/platform/tray_native.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart';
import 'package:my_dashboard/src/integrations/state/devin_usage_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/integrations/state/teamclaude_provider.dart';
import 'package:tray_manager/tray_manager.dart';

const _team = TeamClaudeConnection(
  baseUrl: 'https://team.test',
  apiKey: 'demo',
);
const _devin = DevinConnection(baseUrl: 'https://devin.test', apiKey: 'demo');

class _FixedSync extends SyncController {
  @override
  SyncControllerState build() => const SyncControllerState();
}

void main() {
  testWidgets('메뉴 설치가 실패해도 다음 열기는 다시 시도하며 실패한 메뉴를 띄우지 않는다', (tester) async {
    late WidgetRef ref;
    var installs = 0;
    var opens = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...usageDashboardUiOverrides,
          localeProvider.overrideWithValue(LocaleDto.en),
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          syncControllerProvider.overrideWith(_FixedSync.new),
          trayMenuApplyFnProvider.overrideWithValue((items) async {
            if (++installs == 1) throw StateError('temporary menu failure');
          }),
          trayMenuPopupFnProvider.overrideWithValue(() async {
            opens++;
          }),
        ],
        child: Consumer(
          builder: (context, value, child) {
            ref = value;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final menu = TrayMenu(ref);
    await menu.show();
    expect(opens, 0);
    expect(menu.debugAppliedState, isNull);
    await menu.show();
    expect(installs, 2);
    expect(opens, 1);
  });

  testWidgets('늦은 사용량 조회를 기다리지 않고 열며 열린 메뉴의 클릭 항목을 보존한다', (tester) async {
    late WidgetRef ref;
    final menus = <List<MenuItem>>[];
    final requests = <ApiRequest>[];
    var popup = Completer<void>();
    var response = Completer<ApiResponse>();
    var opens = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...usageDashboardUiOverrides,
          localeProvider.overrideWithValue(LocaleDto.en),
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, keys, values) => '$key ${values.join(' ')}',
          ),
          syncControllerProvider.overrideWith(_FixedSync.new),
          trayMenuApplyFnProvider.overrideWithValue(
            (items) async => menus.add(items),
          ),
          trayMenuPopupFnProvider.overrideWithValue(() {
            opens++;
            return popup.future;
          }),
          httpSendProvider.overrideWithValue((request) {
            requests.add(request);
            return response.future;
          }),
        ],
        child: Consumer(
          builder: (context, value, child) {
            ref = value;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final controller = ref.read(devinUsageControllerProvider.notifier);
    controller.setActive(false);
    controller.configure(_devin);
    response.complete(
      ApiResponse(
        statusCode: 200,
        body: jsonEncode({
          'userStatus': {
            'planStatus': {'weeklyQuotaRemainingPercent': 70},
          },
        }),
      ),
    );
    await tester.pump();
    expect(ref.read(devinUsageControllerProvider).quota!.weeklyUsedPercent, 30);
    requests.clear();
    response = Completer<ApiResponse>();
    final menu = TrayMenu(ref);
    final opened = menu.show();
    await tester.pump();
    expect(opens, 1, reason: 'HTTP 응답은 아직 없지만 메뉴는 열려 있어야 한다');
    expect(requests, hasLength(1));
    expect(
      menus.single.where((item) => item.label?.contains('30%') ?? false),
      hasLength(1),
    );
    final openId = menus.single.first.id;
    expect(menus.single.first.key, TrayCommand.open.menuItemKey);
    expect(
      menus.single
          .where((item) => item.label?.contains('30%') ?? false)
          .single
          .disabled,
      isTrue,
    );
    await menu.show();
    expect(opens, 1, reason: '이미 열린 메뉴를 다시 열거나 추가 조회하지 않는다');

    response.complete(
      ApiResponse(
        statusCode: 200,
        body: jsonEncode({
          'userStatus': {
            'planStatus': {'weeklyQuotaRemainingPercent': 40},
          },
        }),
      ),
    );
    await tester.pump();
    await menu.apply(
      muted: true,
      muteUntil: 123,
      labels: ref.read(dashboardTrayLabelsProvider),
    );
    expect(menus, hasLength(1), reason: '열린 네이티브 메뉴와 클릭 ID 조회표를 교체하지 않는다');
    expect(menus.single.first.id, openId);
    popup.complete();
    await opened;

    popup = Completer<void>();
    response = Completer<ApiResponse>();
    final reopened = menu.show();
    await tester.pump();
    expect(opens, 2);
    expect(
      menus.last.any((item) => item.label?.contains('60%') ?? false),
      isTrue,
    );
    response.complete(const ApiResponse(statusCode: 500, body: '{}'));
    await tester.pump();
    popup.complete();
    await reopened;

    popup = Completer<void>();
    final afterFailure = menu.show();
    await tester.pump();
    final labels = menus.last.map((item) => item.label ?? '').join('\n');
    expect(labels, contains('60%'));
    expect(labels, contains('tray.usage_refresh_failed'));
    expect(labels, contains('tray.usage_cached'));
    popup.complete();
    await afterFailure;
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('숨긴 창에서도 두 원천을 병렬 조회하며 중복 요청과 정기 타이머를 만들지 않는다', (tester) async {
    late WidgetRef ref;
    final pending = <String, Completer<ApiResponse>>{};
    final paths = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...usageDashboardUiOverrides,
          httpSendProvider.overrideWithValue((request) {
            paths.add(request.url.path);
            return pending
                .putIfAbsent(request.url.path, Completer<ApiResponse>.new)
                .future;
          }),
        ],
        child: Consumer(
          builder: (context, value, child) {
            ref = value;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final team = ref.read(teamClaudeControllerProvider.notifier)
      ..setActive(false);
    final devin = ref.read(devinUsageControllerProvider.notifier)
      ..setActive(false);
    team.configure(_team);
    devin.configure(_devin);
    final first = ref.read(trayUsageRefreshFnProvider)();
    final second = ref.read(trayUsageRefreshFnProvider)();
    expect(paths, [kTeamClaudeStatusPath, kDevinUserStatusPath]);
    pending[kTeamClaudeStatusPath]!.complete(
      const ApiResponse(statusCode: 200, body: '{"accounts":[]}'),
    );
    pending[kDevinUserStatusPath]!.complete(
      const ApiResponse(statusCode: 200, body: '{"userStatus":{}}'),
    );
    await tester.pump();
    expect(paths, [
      kTeamClaudeStatusPath,
      kDevinUserStatusPath,
      kTeamClaudeQuotaPath,
    ]);
    pending[kTeamClaudeQuotaPath]!.complete(
      const ApiResponse(statusCode: 200, body: '{"accounts":[]}'),
    );
    await Future.wait([first, second]);
    await tester.pump(const Duration(minutes: 1));
    expect(paths, hasLength(3), reason: '우클릭 조회가 백그라운드 폴링을 켜면 안 된다');
    expect(ref.read(teamClaudeControllerProvider).updatedAt, isNotNull);
    expect(ref.read(devinUsageControllerProvider).updatedAt, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('사용량 연결이 없으면 새 조회 요청을 만들지 않는다', (tester) async {
    late WidgetRef ref;
    var calls = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...usageDashboardUiOverrides,
          httpSendProvider.overrideWithValue((request) async {
            calls++;
            return const ApiResponse(statusCode: 500, body: '{}');
          }),
        ],
        child: Consumer(
          builder: (context, value, child) {
            ref = value;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await ref.read(trayUsageRefreshFnProvider)();
    expect(calls, 0);
  });
}
