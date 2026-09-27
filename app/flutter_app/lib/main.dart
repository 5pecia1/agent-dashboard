import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod/misc.dart' show Override;

import 'package:my_dashboard/src/app.dart';
import 'package:my_dashboard/src/platform/feature_setup.dart';
import 'package:my_dashboard/src/rust/frb_generated.dart';
import 'package:my_dashboard/src/rust/api.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/notification_click_inbox.dart';
import 'package:my_dashboard/src/state/http_provider.dart';

typedef DashboardBootOverrides =
    List<Override> Function(DashboardConfigValues config);

Future<void> main() => runDashboard();

Future<void> runDashboard({
  DashboardConfigValues Function(DashboardConfigValues)? configure,
  DashboardBootOverrides? extensions,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  // `mise run frb:codegen`이 만드는 RustLib 초기화. app-core를 로드해야
  // capability_provider.dart / i18n/t.dart의 FRB 호출이 실제로 응답한다.
  // codegen을 아직 돌리지 않았다면 lib/src/rust/**가 존재하지 않으므로
  // 이 import 자체가 실패한다 — 그럴 땐 codegen부터 먼저 돌린다.
  await RustLib.init();
  // OS 클릭은 UI가 준비되기 전에도 도착할 수 있다. 먼저 보관하고
  // 루트 화면의 첫 프레임 뒤 inbox consumer가 작업 창으로 전달한다.
  await initializeSelectedFeatures(
    onNotificationTap: notificationClickInbox.add,
  );
  final greeting = greet(name: 'my_dashboard');

  // T-wire: `dashboardConfigValuesProvider`/`dashboardApiConfigProvider`
  // (`dashboard_api.dart`)/`httpSendProvider`는 override 없이 읽으면
  // 던진다(각자 문서에 적힌 계약) — `runApp` 전에 이 세 자리를 실제 값으로
  // 채운다. `configLoadFnProvider`를 일회용 `ProviderContainer`로 읽는 건
  // 그 provider가 상태 없는 시임(저장소에서 읽는 함수 하나)이라 안전하다 —
  // `main.dart`는 `ffi_allowed`(quality.json)에 있어 이 시임을 직접 다뤄도
  // `quality_check.py boundary`에 걸리지 않는다.
  final bootContainer = ProviderContainer();
  final DashboardConfigValues configValues;
  try {
    final stored = await bootContainer.read(configLoadFnProvider)();
    configValues = configure?.call(stored) ?? stored;
  } finally {
    bootContainer.dispose();
  }

  // T-wire 계약(U-fix): 서버 주소가 아직 없으면(첫 실행) placeholder URL로
  // 채워 넣지 않는다 — `dashboardApiConfigOverrideFor`가 이때 null을 돌려
  // 주므로 `dashboardApiConfigProvider`를 아예 override하지 않는다. 이
  // 상태에서 그 provider(또는 `dashboardApiProvider`)를 읽으면 던지는 게
  // 정상이다 — `sync_controller.dart`(unconfigured 게이팅)와
  // `app.dart`(push 등록 게이팅)가 서버 주소가 없는 동안 두 자리 모두
  // 아예 읽지 않는다는 계약으로 "네트워크 0"을 지킨다.
  final apiConfigOverride = dashboardApiConfigOverrideFor(configValues);

  runApp(
    ProviderScope(
      overrides: [
        dashboardConfigValuesProvider.overrideWithValue(configValues),
        ?apiConfigOverride,
        httpSendProviderOverride,
        ...?extensions?.call(configValues),
      ],
      child: SolApp(greeting: greeting),
    ),
  );
}
