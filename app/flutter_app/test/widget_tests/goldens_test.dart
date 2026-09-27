/// 골든 회귀 테스트 — 주요 화면의 참조 스크린샷을 고정해 의도치 않은
/// 시각적 드리프트를 CI에서 자동으로 잡아낸다.
///
/// 왜 한 파일에 모으나
/// -------------------
/// 화면별로 `matchesGoldenFile` 테스트 하나를 `test/goldens/` 아래 PNG
/// 하나에 고정한다. `flutter test --tags=golden`이 dart_test.yaml에
/// 선언된 `golden` 태그로 이 레인만 골라 돌린다 — 태그 없는 테스트는
/// 평소 `flutter test` 통과 대상에 그대로 남는다.
///
/// 결정성 조건
/// -----------
/// 1. `flutter test`의 기본 텍스트 렌더링은 Ahem(정사각형 폴백 폰트)이라
///    글리프가 전부 단색 블록으로 그려진다 — 안티에일리어싱/힌팅 차이로
///    호스트마다 다른 PNG가 나오는 걸 막으려는 의도적 선택이다. 그래서
///    이 아래 테스트들도 실제 폰트 렌더링(한글 자모 조합, 말줄임 등)의
///    시각 회귀는 못 잡는다 — 그건 `tool/visual_qa/`의 몫이다.
/// 2. 각 테스트는 `tester.view.physicalSize` / `devicePixelRatio`를 고정
///    크기로 펌프해 레이아웃을 잠그고, `addTearDown`에서 뷰포트를
///    원복한다 — 같은 파일의 다음 테스트가 깨끗한 상태로 시작한다.
///
/// 최초 실행 안내: 이 파일을 처음 돌리면 `test/goldens/`에 참조 PNG가
/// 아직 없어서 실패한다. 다음으로 베이스라인을 한 번 만들고 커밋한다:
///
/// ```sh
/// flutter test --update-goldens --tags=golden
/// ```
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/app.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart' show LocaleDto;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/usage_integrations.dart';
import 'package:my_dashboard/src/state/notify_provider.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart' show isSessionStaleFnProvider, stateLabelKeyFnProvider;
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/ui/diagnostics_page.dart';
import 'package:my_dashboard/src/ui/session_detail_page.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';
import 'package:my_dashboard/src/ui/setup_page.dart';

/// 골든이 네이티브 카탈로그 없이도 고정 문자열을 그리도록 하는 결정적
/// 번역기 — 키의 마지막 dotted 세그먼트를 그대로 돌려준다. 실제 문구가
/// 아니라 "이 키가 호출됐다"만 확인하면 되는 골든에는 이걸로 충분하다.
String _goldenTranslate(String key, LocaleDto locale) => switch (key) {
  'app.title' => 'Sol App',
  'capability.available' => 'Available',
  _ => key,
};

String _goldenTranslateArgs(
  String key,
  LocaleDto locale,
  List<String> argKeys,
  List<String> argVals,
) => key.split('.').last;

/// 위젯 트리를 고정 크기로 펌프하고, 테스트가 끝나면 뷰포트를 원복한다.
void _useViewport(WidgetTester tester, Size logical) {
  final view = tester.view
    ..devicePixelRatio = 1.0
    ..physicalSize = logical;
  addTearDown(() {
    view
      ..resetDevicePixelRatio()
      ..resetPhysicalSize();
  });
}

/// T15가 추가한 화면들의 골든이 공유하는 고정 세션/전이 픽스처.
/// `_goldenTranslate`(마지막 dotted 세그먼트만 돌려주는 결정적 번역기)와
/// 함께 쓰므로 문자열 길이는 평범한 실제 문구 정도로만 맞춘다 — 극단적인
/// 긴 문자열 회귀는 `narrow_width_test.dart`의 몫이다.
final _goldenSession = SessionViewDto(
  key: 'claude-code:s1',
  state: 'waiting_input',
  source: 'claude-code',
  sessionId: 's1',
  project: 'my-dashboard',
  host: 'dev-mac',
  lastMessage: '입력을 기다리는 중입니다',
  updatedAt: 2000,
  lastOccurredAt: 2000,
);

final _goldenAlert = TransitionDto(
  id: 1,
  sessionKey: _goldenSession.key,
  toState: 'stalled',
  fromState: 'working',
  project: _goldenSession.project,
  host: _goldenSession.host,
  message: 'stalled로 전이됨',
  occurredAt: 1500,
  createdAt: 1500,
);

class _GoldenFixedSyncController extends SyncController {
  _GoldenFixedSyncController(this._state);

  final SyncControllerState _state;

  @override
  SyncControllerState build() => _state;
}

void main() {
  group('Goldens', () {
    testWidgets('홈_화면_골든', tags: <String>['golden'], (tester) async {
      // T-wire: 홈이 `SolApp` -> `_AppHome` -> (서버 주소 있음) ->
      // `SessionsPage`로 바뀌었다. `dashboardConfigValuesProvider`에
      // `serverUrl`을 채워 설정 화면으로 유도되는 분기를 피하고,
      // `syncControllerProvider`는 `세션_목록_화면_골든`과 같은 고정
      // 픽스처로 override해 실제 앱 셸(라우팅 포함)을 통해서도 같은
      // 화면이 결정적으로 그려지는지 고정한다.
      _useViewport(tester, const Size(400, 700));
      final controllerState = SyncControllerState(
        sync: SyncState(
          cursor: 1000,
          sessions: {_goldenSession.key: _goldenSession},
          pendingAlerts: [_goldenAlert],
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // Screen goldens never send OS notifications for fixture alerts.
            localNotifyFnProvider.overrideWithValue((_) async {}),
            i18nTranslateOverride.overrideWithValue(_goldenTranslate),
            i18nTranslateArgsOverride.overrideWithValue(_goldenTranslateArgs),
            stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
            isSessionStaleFnProvider.overrideWithValue(
              ({required int now, required int updatedAt, required int staleMs}) => false,
            ),
            dashboardConfigValuesProvider.overrideWithValue(
              const DashboardConfigValues(serverUrl: 'https://example.test'),
            ),
            syncControllerProvider.overrideWith(() => _GoldenFixedSyncController(controllerState)),
          ],
          child: const SolApp(),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          '../goldens/home_page_${Platform.operatingSystem}.png',
        ),
      );
    });

    testWidgets('세션_목록_화면_골든', tags: <String>['golden'], (tester) async {
      _useViewport(tester, const Size(400, 700));
      final controllerState = SyncControllerState(
        sync: SyncState(
          cursor: 1000,
          sessions: {_goldenSession.key: _goldenSession},
          pendingAlerts: [_goldenAlert],
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            i18nTranslateOverride.overrideWithValue(_goldenTranslate),
            i18nTranslateArgsOverride.overrideWithValue(_goldenTranslateArgs),
            stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
            isSessionStaleFnProvider.overrideWithValue(
              ({required int now, required int updatedAt, required int staleMs}) => false,
            ),
            syncControllerProvider.overrideWith(() => _GoldenFixedSyncController(controllerState)),
          ],
          child: const MaterialApp(home: SessionsPage()),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          '../goldens/sessions_page_${Platform.operatingSystem}.png',
        ),
      );
    });

    testWidgets('세션_상세_화면_골든', tags: <String>['golden'], (tester) async {
      _useViewport(tester, const Size(400, 700));
      final controllerState = SyncControllerState(
        sync: SyncState(
          cursor: 1000,
          sessions: {_goldenSession.key: _goldenSession},
          pendingAlerts: [_goldenAlert],
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            i18nTranslateOverride.overrideWithValue(_goldenTranslate),
            i18nTranslateArgsOverride.overrideWithValue(_goldenTranslateArgs),
            stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
            isSessionStaleFnProvider.overrideWithValue(
              ({required int now, required int updatedAt, required int staleMs}) => false,
            ),
            syncControllerProvider.overrideWith(() => _GoldenFixedSyncController(controllerState)),
            dashboardApiConfigProvider.overrideWithValue(
              DashboardApiConfig(baseUrl: Uri.parse('https://example.test')),
            ),
            httpSendProvider.overrideWithValue(
              (request) async => request.url.path == kEventsPath
                  ? const ApiResponse(
                      statusCode: 200,
                      body:
                          '{"events":['
                          '{"id":3,"session_key":"claude-code:s1","source":"claude-code","event":"UserPromptSubmit","message":"저장된 발언","received_at":1800},'
                          '{"id":2,"session_key":"claude-code:s1","source":"claude-code","event":"Notification","message":null,"received_at":1500}'
                          '],"has_more":false,"next_before_id":null}',
                    )
                  : const ApiResponse(statusCode: 200, body: '{}'),
            ),
          ],
          child: MaterialApp(home: SessionDetailPage(session: _goldenSession)),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          '../goldens/session_detail_page_${Platform.operatingSystem}.png',
        ),
      );
    });

    testWidgets('설정_화면_골든', tags: <String>['golden'], (tester) async {
      _useViewport(tester, const Size(400, 700));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...usageDashboardOverrides(DashboardConfigValues.empty),
            i18nTranslateOverride.overrideWithValue(_goldenTranslate),
            i18nTranslateArgsOverride.overrideWithValue(_goldenTranslateArgs),
            stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
            isSessionStaleFnProvider.overrideWithValue(
              ({required int now, required int updatedAt, required int staleMs}) => false,
            ),
            configLoadFnProvider.overrideWithValue(() async => DashboardConfigValues.empty),
            // TASK MUTE-impl: SetupPage가 뮤트 상태 표시를 위해
            // `muteStateListenable`(syncControllerProvider 파생)을 새로
            // watch한다 — 이 화면은 SetupPage 단독 렌더라
            // `dashboardConfigValuesProvider`를 override하지 않으므로,
            // 진짜 SyncController.build()가 그 provider를 읽으면 던진다.
            // 이 골든이 검증하려는 것과 무관한 실패라 고정 상태(=음소거
            // 아님)로 갈아 끼운다.
            syncControllerProvider.overrideWith(
              () => _GoldenFixedSyncController(const SyncControllerState()),
            ),
          ],
          child: const MaterialApp(home: SetupPage()),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          '../goldens/setup_page_${Platform.operatingSystem}.png',
        ),
      );
    });

    testWidgets('진단_화면_골든', tags: <String>['golden'], (tester) async {
      _useViewport(tester, const Size(400, 700));
      const diagnosticsBody = '''
{
  "last_event_at": 1700000000000,
  "max_transition_id": 42,
  "pruned_below_id": 1,
  "device_failure_count": 0,
  "subscription_failure_count": 0,
  "channels": {"fcm": true, "web-push": false},
  "table_counts": {"dashboard_transitions": 1234, "dashboard_sessions": 12},
  "last_push": {
    "transport": "fcm",
    "target": "device-abcdefg",
    "result": "sent",
    "detail": null,
    "created_at": 1700000000000
  }
}
''';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            i18nTranslateOverride.overrideWithValue(_goldenTranslate),
            i18nTranslateArgsOverride.overrideWithValue(_goldenTranslateArgs),
            stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
            isSessionStaleFnProvider.overrideWithValue(
              ({required int now, required int updatedAt, required int staleMs}) => false,
            ),
            dashboardApiConfigProvider.overrideWithValue(
              DashboardApiConfig(baseUrl: Uri.parse('https://example.test')),
            ),
            httpSendProvider.overrideWithValue(
              (request) async => const ApiResponse(statusCode: 200, body: diagnosticsBody),
            ),
          ],
          child: const MaterialApp(home: DiagnosticsPage()),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          '../goldens/diagnostics_page_${Platform.operatingSystem}.png',
        ),
      );
    });
  });
}
