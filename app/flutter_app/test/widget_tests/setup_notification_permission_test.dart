/// 후속(T16 denied 구분): 설정 화면의 macOS 알림 권한 UI 세 가지를 실제
/// 플러그인/프로세스/서버 없이 닫는다.
///
/// 1. `notificationPermissionDeniedProvider`가 true면 경고 배너 + "시스템
///    설정 열기" 버튼이 뜨고, 버튼을 누르면 `openNotificationSettingsProvider`
///    가 정확히 한 번 불린다.
/// 2. `notificationUsesOsascriptFallbackProvider`가 true면 클릭 이동이
///    안 되는 폴백 모드라는 한 줄 고지가 뜬다(완료 기준 (d)).
/// 3. "테스트 알림" 버튼을 누르면 실제 API 호출보다 먼저
///    `notificationReprobeProvider`가 불린다(재프로브 계약) — 이 테스트는
///    그 provider를 override하므로 실제 macOS 알림 프로브/osascript는
///    절대 실행되지 않는다.
///
/// `setup_resident_toggle_test.dart`와 같은 관용(결정적 번역기, 메모리
/// config store, 큰 뷰포트)을 그대로 쓴다.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/platform/feature_status.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart' show LocaleDto;
import 'package:my_dashboard/src/state/capability_provider.dart' show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/notification_probe_provider.dart';
import 'package:my_dashboard/src/state/resident_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart'
    show SyncController, SyncControllerState, syncControllerProvider;
import 'package:my_dashboard/src/ui/setup_page.dart';
// `Override`는 `flutter_riverpod` barrel에 없다(`setup_resident_toggle_test.dart`
// 와 같은 이유).
// ignore: depend_on_referenced_packages
import 'package:riverpod/misc.dart' show Override;

String _translate(String key, LocaleDto locale) => key;

String _translateArgs(
  String key,
  LocaleDto locale,
  List<String> argKeys,
  List<String> argVals,
) => key;

void _useTallViewport(WidgetTester tester) {
  final view = tester.view
    ..devicePixelRatio = 1.0
    ..physicalSize = const Size(500, 2000);
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
/// 검증하려는 권한 배너/재프로브 계약과 무관한 실패라 아무 일도 하지
/// 않는 가짜로 갈아 끼운다(`setup_resident_toggle_test.dart`의
/// `_NoopSyncController`와 같은 관용).
class _NoopSyncController extends SyncController {
  @override
  SyncControllerState build() => const SyncControllerState();
}

class _MemoryConfigStore {
  DashboardConfigValues values = DashboardConfigValues.empty;

  Future<DashboardConfigValues> load() async => values;

  Future<void> save(DashboardConfigValues next) async {
    values = next;
  }
}

final Uri _base = Uri.parse('https://dash.example.dev');

final _apiConfigOverride = dashboardApiConfigProvider.overrideWithValue(
  DashboardApiConfig(baseUrl: _base),
);

/// 성공하는 test-push 응답을 흉내내는 전송 — 실제 서버 없이 `testPush`
/// 호출 자체가 예외 없이 끝나게 한다(이 테스트가 보려는 건 재프로브 순서지
/// test-push 결과 자체가 아니다).
Future<ApiResponse> _fakeTestPushSend(ApiRequest request) async => ApiResponse(
  statusCode: 200,
  body: jsonEncode(<String, dynamic>{
    'ok': true,
    'transition_id': 1,
    'channels': <String, dynamic>{},
  }),
);

Widget _setupPage({required List<Override> extra}) => ProviderScope(
  overrides: [
    i18nTranslateOverride.overrideWithValue(_translate),
    i18nTranslateArgsOverride.overrideWithValue(_translateArgs),
    isWasmRuntimeProvider.overrideWithValue(false),
    residentToggleSupportedProvider.overrideWithValue(false),
    syncControllerProvider.overrideWith(_NoopSyncController.new),
    ...extra,
  ],
  child: const MaterialApp(home: SetupPage()),
);

void main() {
  tearDown(() {
    // 전역 싱글턴 — 다음 테스트로 상태가 새지 않게 되돌린다.
    desktopFeatureStatus.notifyPermissionDeniedChanged(false);
    desktopFeatureStatus.notifyLocalChanged(false);
  });

  group('권한 거부 배너', () {
    testWidgets('permissionDenied가 false면 배너도 osascript 고지도 없다(골든 기본값)', (
      tester,
    ) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore();
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
            notificationPermissionDeniedProvider.overrideWithValue(false),
            notificationUsesOsascriptFallbackProvider.overrideWithValue(false),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('setup.notification_permission_denied_title'), findsNothing);
      expect(find.text('setup.notification_osascript_fallback_note'), findsNothing);
    });

    testWidgets('permissionDenied가 true면 경고 배너와 설정 열기 버튼이 뜬다', (tester) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore();
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
            notificationPermissionDeniedProvider.overrideWithValue(true),
            notificationUsesOsascriptFallbackProvider.overrideWithValue(false),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('setup.notification_permission_denied_title'), findsOneWidget);
      expect(find.text('setup.notification_permission_denied_body'), findsOneWidget);
      expect(find.text('setup.notification_permission_denied_action'), findsOneWidget);
    });

    testWidgets('설정 열기 버튼을 누르면 openNotificationSettingsProvider가 정확히 한 번 불린다', (
      tester,
    ) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore();
      var opened = 0;
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
            notificationPermissionDeniedProvider.overrideWithValue(true),
            notificationUsesOsascriptFallbackProvider.overrideWithValue(false),
            openNotificationSettingsProvider.overrideWithValue(() async {
              opened += 1;
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('setup.notification_permission_denied_action'));
      await tester.pumpAndSettle();

      expect(opened, 1);
    });
  });

  group('osascript 폴백 고지 (완료 기준 (d))', () {
    testWidgets('osascript 폴백 중이면 클릭 이동 불가 고지가 한 줄 뜬다', (tester) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore();
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
            notificationPermissionDeniedProvider.overrideWithValue(false),
            notificationUsesOsascriptFallbackProvider.overrideWithValue(true),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('setup.notification_osascript_fallback_note'), findsOneWidget);
      // denied가 아닌데 폴백 고지만 뜬 상황이니 경고 배너는 없어야 한다.
      expect(find.text('setup.notification_permission_denied_title'), findsNothing);
    });
  });

  group('테스트 알림 버튼의 재프로브 (재프로브 계약)', () {
    testWidgets('버튼을 누르면 실제 API 호출보다 먼저 재프로브가 불린다', (tester) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore();
      final callOrder = <String>[];
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
            notificationPermissionDeniedProvider.overrideWithValue(false),
            notificationUsesOsascriptFallbackProvider.overrideWithValue(false),
            notificationReprobeProvider.overrideWithValue(() async {
              callOrder.add('reprobe');
            }),
            _apiConfigOverride,
            httpSendProvider.overrideWithValue((request) async {
              callOrder.add('api');
              return _fakeTestPushSend(request);
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('setup.test_notification_action'));
      await tester.pumpAndSettle();

      expect(
        callOrder,
        ['reprobe', 'api'],
        reason: '권한을 방금 켰을 수도 있으니 재프로브가 API 호출보다 먼저 끝나야 한다',
      );
    });

  });
}
