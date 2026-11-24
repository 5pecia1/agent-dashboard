import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/agent_dashboard.dart';
import 'package:my_dashboard/src/state/dashboard_extensions.dart'
    show dashboardHomeSectionsProvider, dashboardSetupSectionsProvider;
import 'package:my_dashboard/src/state/dashboard_host.dart';
import 'package:my_dashboard/src/state/usage_integrations.dart';

void main() {
  test('기본 앱과 외부 앱은 자신의 상태와 트레이 자산을 찾는다', () {
    final public = DashboardHost();
    final consumer = DashboardHost(
      stateDirectoryName: 'sample-dashboard',
      packageAssets: true,
    );
    const icon = 'assets/tray_icon.png';
    expect(
      public.stateDirectory('/home/test'),
      '/home/test/.local/state/my-dashboard',
    );
    expect(
      consumer.stateDirectory('/home/test'),
      '/home/test/.local/state/sample-dashboard',
    );
    expect(public.storageKey('config.v1'), 'my-dashboard.config.v1');
    expect(consumer.storageKey('config.v1'), 'sample-dashboard.config.v1');
    expect(public.assetKey(icon), icon);
    expect(consumer.assetKey(icon), 'packages/my_dashboard/$icon');
    for (final invalid in ['', '..', '../sample', '/tmp/example']) {
      expect(
        () => DashboardHost(stateDirectoryName: invalid),
        throwsArgumentError,
      );
    }
  });

  test('외부 앱 홈과 설정 항목은 기본 패널 뒤에 추가된다', () {
    const extra = Text('extra');
    final base = ProviderContainer(overrides: usageDashboardUiOverrides);
    final consumer = ProviderContainer(
      overrides: [
        ...usageDashboardUiOverrides,
        additionalHomeSectionsProvider.overrideWithValue([extra]),
        additionalSetupSectionsProvider.overrideWithValue([extra]),
      ],
    );
    addTearDown(base.dispose);
    addTearDown(consumer.dispose);
    for (final sections in [
      dashboardHomeSectionsProvider,
      dashboardSetupSectionsProvider,
    ]) {
      expect(base.read(sections), isNotEmpty);
      expect(consumer.read(sections), [...base.read(sections), extra]);
    }
  });
}
