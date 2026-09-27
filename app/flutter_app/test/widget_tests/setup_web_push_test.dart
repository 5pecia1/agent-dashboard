/// T17f: 설정 화면의 "브라우저 알림 허용" 버튼이 지키는 두 계약.
///
/// 1. **데스크톱에는 없다.** [isWasmRuntimeProvider]가 false면 그 절이
///    위젯 트리에 아예 들어가지 않는다 — 골든(`setup_page_*.png`)이 그
///    사실 위에 서 있다.
/// 2. **권한 프롬프트는 이 버튼 뒤에서만.** 버튼을 누르기 전에는
///    [webPushPermissionRequestProvider]가 한 번도 불리지 않고, 누르면
///    권한 -> 등록 순서로 정확히 한 번씩 불린다. 권한을 못 받으면 등록까지
///    내려가지 않는다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart' show LocaleDto;
import 'package:my_dashboard/src/state/capability_provider.dart' show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/push_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart'
    show SyncController, SyncControllerState, syncControllerProvider;
import 'package:my_dashboard/src/ui/setup_page.dart';
// `Override`는 `flutter_riverpod` barrel에 없다 — 정본 위치에서 이름만
// 가져온다(`config_provider.dart`가 같은 이유로 같은 일을 한다).
// ignore: depend_on_referenced_packages
import 'package:riverpod/misc.dart' show Override;

/// 키의 마지막 dotted 세그먼트를 그대로 돌려주는 결정적 번역기
/// (`goldens_test.dart`와 같은 관용).
String _translate(String key, LocaleDto locale) => key;

String _translateArgs(
  String key,
  LocaleDto locale,
  List<String> argKeys,
  List<String> argVals,
) => key;

/// 설정 화면은 지연 빌드되는 스크롤 목록이라, 기본 800x600 뷰포트에서는
/// 화면 아래쪽 절이 아예 만들어지지 않는다. 이 화면 전체가 한 번에 들어가는
/// 크기로 잠근다(골든이 `_useViewport`로 하는 것과 같은 일).
void _useTallViewport(WidgetTester tester) {
  final view = tester.view
    ..devicePixelRatio = 1.0
    ..physicalSize = const Size(500, 1600);
  addTearDown(() {
    view
      ..resetDevicePixelRatio()
      ..resetPhysicalSize();
  });
}

/// TASK MUTE-impl: SetupPage가 이제 muteStateListenable(=
/// syncControllerProvider 파생)을 watch한다 — 이 화면 단독 렌더에서는
/// `dashboardConfigValuesProvider`를 override하지 않아 진짜
/// SyncController.build()가 그 provider를 읽으면 던진다. 이 파일이
/// 검증하려는 브라우저 알림 버튼 계약과 무관한 실패라 아무 일도 하지
/// 않는 가짜로 갈아 끼운다(`setup_resident_toggle_test.dart`의
/// `_NoopSyncController`와 같은 관용).
class _NoopSyncController extends SyncController {
  @override
  SyncControllerState build() => const SyncControllerState();
}

Widget _setupPage({
  required bool isWeb,
  required List<Override> extra,
}) => ProviderScope(
  overrides: [
    i18nTranslateOverride.overrideWithValue(_translate),
    i18nTranslateArgsOverride.overrideWithValue(_translateArgs),
    configLoadFnProvider.overrideWithValue(() async => DashboardConfigValues.empty),
    isWasmRuntimeProvider.overrideWithValue(isWeb),
    syncControllerProvider.overrideWith(_NoopSyncController.new),
    ...extra,
  ],
  child: const MaterialApp(home: SetupPage()),
);

void main() {
  testWidgets('데스크톱 런타임에는 브라우저 알림 절이 아예 없다', (tester) async {
    _useTallViewport(tester);
    await tester.pumpWidget(
      _setupPage(
        isWeb: false,
        extra: [
          webPushPermissionRequestProvider.overrideWithValue(
            () async => throw StateError('데스크톱에서 권한을 물으면 안 된다.'),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('setup.web_push_action'), findsNothing);
    expect(find.text('setup.section.web_push'), findsNothing);
  });

  testWidgets('웹에서는 버튼이 보이고, 누르기 전에는 권한을 묻지 않는다', (tester) async {
    _useTallViewport(tester);
    var permissionCalls = 0;
    var registerCalls = 0;
    await tester.pumpWidget(
      _setupPage(
        isWeb: true,
        extra: [
          webPushPermissionRequestProvider.overrideWithValue(() async {
            permissionCalls += 1;
            return true;
          }),
          pushRegistrarProvider.overrideWithValue(({String? label}) async {
            registerCalls += 1;
            expect(label, isNull, reason: '기기 이름을 비워 뒀으면 보내지 않는다');
            return const PushRegistrationResult(
              availability: PushAvailability.registered,
              token: 'fcm-web-token',
            );
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('setup.web_push_action'), findsOneWidget);
    expect(permissionCalls, 0, reason: '화면을 띄운 것만으로 프롬프트가 뜨면 안 된다');

    await tester.tap(find.text('setup.web_push_action'));
    await tester.pumpAndSettle();

    expect(permissionCalls, 1);
    expect(registerCalls, 1);
    expect(find.text('setup.web_push_registered'), findsOneWidget);
  });

  testWidgets('권한을 거부하면 등록까지 내려가지 않는다', (tester) async {
    _useTallViewport(tester);
    var registerCalls = 0;
    await tester.pumpWidget(
      _setupPage(
        isWeb: true,
        extra: [
          webPushPermissionRequestProvider.overrideWithValue(() async => false),
          pushRegistrarProvider.overrideWithValue(({String? label}) async {
            registerCalls += 1;
            return const PushRegistrationResult(
              availability: PushAvailability.registered,
            );
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('setup.web_push_action'));
    await tester.pumpAndSettle();

    expect(registerCalls, 0);
    expect(find.text('setup.web_push_permission_denied'), findsOneWidget);
  });
}
