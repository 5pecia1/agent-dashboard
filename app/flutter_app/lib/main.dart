import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod/misc.dart' show Override;

import 'package:my_dashboard/src/app.dart';
import 'package:my_dashboard/src/platform/feature_setup.dart';
import 'package:my_dashboard/src/rust/frb_generated.dart';
import 'package:my_dashboard/src/rust/api.dart';
import 'package:my_dashboard/src/state/capability_provider.dart'
    show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/notification_click_inbox.dart';
import 'package:my_dashboard/src/state/http_provider.dart';
import 'package:my_dashboard/src/state/usage_integrations.dart';
import 'package:my_dashboard/src/ui/config_read_failure.dart';

typedef DashboardBootOverrides =
    List<Override> Function(DashboardConfigValues config);

/// 대시보드 루트 `ProviderScope`의 키. 설정을 읽지 못해 실패 화면을 먼저
/// 띄운 경우 두 번째 `runApp`이 이 루트를 이전 루트와 비교한다 — 키가
/// 다르면 제자리 갱신(override 개수가 다른 컨테이너 재사용) 대신 새로
/// 붙인다(`ui/config_read_failure.dart`의 `ConfigReadFailureApp` 참고).
const Key kDashboardRootKey = ValueKey<String>('dashboard-root');

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
  final greeting = greet(name: 'Agent Dashboard');

  // `configLoadFnProvider`를 일회용 `ProviderContainer`로 읽는 건 그
  // provider가 상태 없는 시임(저장소에서 읽는 함수 하나)이라 안전하다 —
  // `main.dart`는 `ffi_allowed`(quality.json)에 있어 이 시임을 직접 다뤄도
  // `quality_check.py boundary`에 걸리지 않는다. `isWasmRuntimeProvider`도
  // 상태 없는 값(`kIsWeb`)이다.
  final bootContainer = ProviderContainer();
  final ConfigLoadFn load;
  final bool webRuntime;
  try {
    load = bootContainer.read(configLoadFnProvider);
    webRuntime = bootContainer.read(isWasmRuntimeProvider);
  } finally {
    bootContainer.dispose();
  }

  // 읽기에 성공하면 예전처럼 첫 `runApp` 전에 대시보드를 조립한다. 읽지
  // 못하면 실패 화면을 띄우고, 다시 읽기에 성공한 순간 대시보드 루트로
  // 바꿔 끼운다(`runApp`을 다시 부르면 루트가 교체된다). 웹에서 브라우저가
  // 저장소를 막았으면 예전처럼 저장된 설정 없이 시작한다(`buildBootRoot`).
  runApp(
    await buildBootRoot(
      load: load,
      webRuntime: webRuntime,
      dashboard: (stored) => buildDashboardRoot(
        stored,
        app: SolApp(greeting: greeting),
        configure: configure,
        extensions: extensions,
      ),
      replaceRoot: runApp,
    ),
  );
}

/// 읽은 설정으로 대시보드 루트를 조립한다. FFI를 부르지 않으므로 테스트가
/// 운영과 같은 조립을 그대로 쓸 수 있다.
///
/// T-wire: `dashboardConfigValuesProvider`/`dashboardApiConfigProvider`
/// (`dashboard_api.dart`)/`httpSendProvider`는 override 없이 읽으면
/// 던진다(각자 문서에 적힌 계약) — 이 세 자리를 실제 값으로 채운다.
/// [configure](개인 빌드가 구운 기본값)는 읽기에 성공한 값에만 적용된다.
/// 예외는 웹에서 브라우저가 저장소를 막아 빈 값으로 시작하는 부팅이다
/// (`ui/config_read_failure.dart`의 `shouldBootWithoutStoredConfig`).
/// 해석할 수 없는 서버 주소는 [bootConfigValuesFor]가 스냅샷에서 비운다 —
/// 그래서 스냅샷에 주소가 있으면 시작 API 설정도 있다.
Widget buildDashboardRoot(
  DashboardConfigValues stored, {
  required Widget app,
  DashboardConfigValues Function(DashboardConfigValues)? configure,
  DashboardBootOverrides? extensions,
}) {
  final configValues = bootConfigValuesFor(configure?.call(stored) ?? stored);

  // T-wire 계약(U-fix): 서버 주소가 아직 없으면(첫 실행) placeholder URL로
  // 채워 넣지 않는다 — `dashboardApiConfigFor`가 이때 null을 돌려주므로 시작
  // API 설정이 비어 있고, 그 상태에서 `dashboardApiConfigProvider`(또는
  // `dashboardApiProvider`)를 읽으면 던지는 게 정상이다 —
  // `sync_controller.dart`(unconfigured 게이팅)와 `app.dart`(push 등록
  // 게이팅)가 서버 주소가 없는 동안 두 자리 모두 아예 읽지 않는다는 계약으로
  // "네트워크 0"을 지킨다.
  //
  // 이 값은 시작값일 뿐이다. `dashboardApiConfigProvider`는 첫 실행이든
  // 아니든 항상 [dashboardApiConfigProviderOverride]로 꽂아 지금 쓰는 값을
  // 따라가게 한다 — 설정 화면이 서버 주소나 토큰을 저장하면 재시작 없이 그
  // 값으로 요청한다(`config_provider.dart`의 `DashboardApiConfigController`).
  final apiConfig = dashboardApiConfigFor(
    serverUrl: configValues.serverUrl,
    clientToken: configValues.clientToken,
  );

  return ProviderScope(
    key: kDashboardRootKey,
    overrides: [
      dashboardConfigValuesProvider.overrideWithValue(configValues),
      // 빌드 기본값이 아니라 저장소에서 읽은 값으로 정한다 — 실행 중에 이
      // 파일이 사라지면 백그라운드 저장이 새 파일을 만들지 않는다
      // (`config_provider.dart`의 `backgroundConfigPatch`).
      storedConfigAtBootProvider.overrideWithValue(!stored.isEmpty),
      dashboardInitialApiConfigProvider.overrideWithValue(apiConfig),
      dashboardApiConfigProviderOverride,
      httpSendProviderOverride,
      ...usageDashboardOverrides(configValues),
      ...?extensions?.call(configValues),
    ],
    child: app,
  );
}
