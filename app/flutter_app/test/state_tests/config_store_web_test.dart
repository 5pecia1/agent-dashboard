@TestOn('browser')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/config_store_web.dart';
import 'package:my_dashboard/src/state/dashboard_host.dart';
import 'package:web/web.dart' as web;

void main() {
  const activeKey = 'browser-config-fixture.config.v1';
  const backupKey = '$activeKey.before-extensions';
  const unrelatedKey = 'another-browser-fixture.config.v1.before-extensions';
  final storage = web.window.localStorage;
  setUp(() {
    final original = dashboardHost;
    final prior = {
      for (final key in [activeKey, backupKey, unrelatedKey])
        key: storage.getItem(key),
    };
    dashboardHost = DashboardHost(stateDirectoryName: 'browser-config-fixture');
    addTearDown(() {
      dashboardHost = original;
      for (final entry in prior.entries) {
        if (entry.value == null) {
          storage.removeItem(entry.key);
        } else {
          storage.setItem(entry.key, entry.value!);
        }
      }
    });
    for (final key in prior.keys) {
      storage.removeItem(key);
    }
    storage.setItem(backupKey, '{"client_token":"old-fixture"}');
    storage.setItem(unrelatedKey, 'unrelated');
  });

  test('기존 설정을 보존하면서 이 앱의 폐기된 브라우저 백업을 없앤다', () async {
    const raw = '{"client_token":"active-fixture","ui_lang":"ko"}';
    storage.setItem(activeKey, raw);
    expect((await loadDashboardConfig()).clientToken, 'active-fixture');
    expect(storage.getItem(activeKey), raw);
    expect(storage.getItem(backupKey), isNull);
    expect(storage.getItem(unrelatedKey), 'unrelated');
  });

  test('현재 설정이 지워졌거나 잘못된 경우에도 예전 인증정보를 남기지 않는다', () async {
    expect(await loadDashboardConfig(), DashboardConfigValues.empty);
    expect(storage.getItem(backupKey), isNull);
    storage.setItem(backupKey, 'old-fixture');
    storage.setItem(activeKey, '{');
    await expectLater(
      loadDashboardConfig(),
      throwsA(isA<ConfigReadException>()),
    );
    expect(storage.getItem(activeKey), '{');
    expect(storage.getItem(backupKey), isNull);
  });

  test('저장부터 시작하거나 계정을 바꿔도 예전 토큰의 복사본을 만들지 않는다', () async {
    storage.setItem(activeKey, '{"client_token":"first-fixture"}');
    final updated = DashboardConfigValues.empty.copyWith(
      clientToken: 'next-fixture',
    );
    await saveDashboardConfig(updated);
    final stored =
        jsonDecode(storage.getItem(activeKey)!) as Map<String, dynamic>;
    expect(stored['client_token'], 'next-fixture');
    expect(storage.getItem(backupKey), isNull);
    expect(storage.getItem(unrelatedKey), 'unrelated');
  });
}
