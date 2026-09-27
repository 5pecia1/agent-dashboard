/// 좁은 화면(휴대폰 PWA) 폭 테스트 — 완료 기준 (e): T15가 추가한 4개
/// 화면 모두 가로 스크롤/오버플로 없이 렌더링돼야 한다.
///
/// `goldens_test.dart`의 `_useViewport` 패턴을 그대로 가져와 뷰포트를
/// 360x800(흔한 휴대폰 논리 폭)으로 고정한다. 각 화면은 제목이 길거나
/// 항목이 많은 픽스처를 일부러 준다 — `RenderFlex overflowed` 같은
/// 예외가 `tester.takeException()`에 남으면 테스트가 실패한다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart' show isSessionStaleFnProvider, stateLabelKeyFnProvider;
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/diagnostics_page.dart';
import 'package:my_dashboard/src/ui/session_detail_page.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';
import 'package:my_dashboard/src/ui/setup_page.dart';

const _narrowViewport = Size(360, 800);

void _useNarrowViewport(WidgetTester tester) {
  final view = tester.view
    ..devicePixelRatio = 1.0
    ..physicalSize = _narrowViewport;
  addTearDown(() {
    view
      ..resetDevicePixelRatio()
      ..resetPhysicalSize();
  });
}

class _FixedSyncController extends SyncController {
  _FixedSyncController(this._state);

  final SyncControllerState _state;

  @override
  SyncControllerState build() => _state;
}

final _longSession = SessionViewDto(
  key: 'claude-code:very-long-session-identifier-that-keeps-going',
  state: 'waiting_input',
  source: 'claude-code',
  sessionId: 'very-long-session-identifier-that-keeps-going',
  project: '아주 길고 좁은 화면에서 줄바꿈 없이는 안 들어갈 만큼 긴 프로젝트 이름입니다',
  host: 'a-very-long-hostname.internal.example.corp',
  lastMessage:
      '이 메시지는 아주 길게 이어져서 카드 폭을 넘어가는지 확인하려는 목적의 '
      '문장입니다 — 줄바꿈 없이 한 줄로 렌더링을 시도하면 오버플로가 난다.',
  updatedAt: 2000,
  lastOccurredAt: 2000,
);

final _pendingAlert = TransitionDto(
  id: 1,
  sessionKey: _longSession.key,
  toState: 'stalled',
  fromState: 'working',
  project: _longSession.project,
  host: _longSession.host,
  message: 'stalled로 전이됨 — 이 문구도 폭을 넘어가면 안 된다.',
  occurredAt: 1500,
  createdAt: 1500,
);

// 다섯 화면 테스트가 공유하는 시임 override는 헬퍼 함수로 뽑지 않고 각
// `ProviderScope`에 그대로 나열한다 — `Override`(반환 타입)는
// `flutter_riverpod` 배럴에 없어서(`package:riverpod/misc.dart`에만 있다,
// `config_provider.dart` 상단 문서 참고) 헬퍼의 반환 타입을 명시하려면
// 그 import를 새로 들여야 한다. 각 리스트 리터럴은 타입을 표기할 필요가
// 없는 위치(named argument)에 바로 놓여 그 문제를 피한다.

void main() {
  testWidgets('SessionsPage: 좁은 폭에서 오버플로 없이 렌더링된다', (tester) async {
    _useNarrowViewport(tester);
    final controllerState = SyncControllerState(
      sync: SyncState(
        cursor: 1000,
        sessions: {_longSession.key: _longSession},
        pendingAlerts: [_pendingAlert],
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, argKeys, argVals) => key,
          ),
          stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
          isSessionStaleFnProvider.overrideWithValue(
            ({required int now, required int updatedAt, required int staleMs}) =>
                false,
          ),
          syncControllerProvider.overrideWith(
            () => _FixedSyncController(controllerState),
          ),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const SessionsPage()),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'SessionsPage: 좁은 폭에서는 프로젝트가 여러 개라도 그리드가 실제로 1열이다 (완료 기준 e)',
    (tester) async {
      _useNarrowViewport(tester);
      final sessions = <String, SessionViewDto>{
        for (final entry in [
          (key: 'claude-code:s1', project: '/repo/one'),
          (key: 'claude-code:s2', project: '/repo/two'),
          (key: 'claude-code:s3', project: '/repo/three'),
        ])
          entry.key: SessionViewDto(
            key: entry.key,
            state: 'working',
            source: 'claude-code',
            sessionId: entry.key,
            project: entry.project,
            updatedAt: 1000,
          ),
      };
      final controllerState = SyncControllerState(
        sync: SyncState(cursor: 1000, sessions: sessions),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            i18nTranslateOverride.overrideWithValue((key, locale) => key),
            i18nTranslateArgsOverride.overrideWithValue(
              (key, locale, argKeys, argVals) => key,
            ),
            stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
            isSessionStaleFnProvider.overrideWithValue(
              ({required int now, required int updatedAt, required int staleMs}) =>
                  false,
            ),
            syncControllerProvider.overrideWith(
              () => _FixedSyncController(controllerState),
            ),
          ],
          child: MaterialApp(theme: AppTheme.light(), home: const SessionsPage()),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      // 실제로 1열인지: 서로 다른 두 카드의 x좌표가 같아야 한다(같은 열에
      // 세로로 쌓임) — 오버플로가 없는 것만으로는 열 수를 증명하지 못한다.
      final cardFinder = find.byType(Card);
      expect(cardFinder, findsNWidgets(3));
      final lefts = [
        for (var i = 0; i < 3; i++) tester.getTopLeft(cardFinder.at(i)).dx,
      ];
      expect(lefts.toSet(), hasLength(1), reason: '세 카드 모두 같은 x좌표(1열)여야 한다');
    },
  );

  testWidgets('SessionDetailPage: 좁은 폭에서 오버플로 없이 렌더링된다', (tester) async {
    _useNarrowViewport(tester);
    final controllerState = SyncControllerState(
      sync: SyncState(
        cursor: 1000,
        sessions: {_longSession.key: _longSession},
        pendingAlerts: [_pendingAlert],
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, argKeys, argVals) => key,
          ),
          stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
          isSessionStaleFnProvider.overrideWithValue(
            ({required int now, required int updatedAt, required int staleMs}) =>
                false,
          ),
          syncControllerProvider.overrideWith(
            () => _FixedSyncController(controllerState),
          ),
          dashboardApiConfigProvider.overrideWithValue(
            DashboardApiConfig(baseUrl: Uri.parse('https://example.test')),
          ),
          httpSendProvider.overrideWithValue(
            (ApiRequest request) async => ApiResponse(
              statusCode: 200,
              body:
                  '{"events":[{"id":1,"session_key":"s:k","source":"claude-code",'
                  '"event":"UserPromptSubmit","message":"${_longSession.lastMessage}","received_at":1800}],'
                  '"has_more":false,"next_before_id":null}',
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SessionDetailPage(session: _longSession),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('SetupPage: 좁은 폭에서 오버플로 없이 렌더링된다', (tester) async {
    _useNarrowViewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, argKeys, argVals) => key,
          ),
          stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
          isSessionStaleFnProvider.overrideWithValue(
            ({required int now, required int updatedAt, required int staleMs}) =>
                false,
          ),
          configLoadFnProvider.overrideWithValue(
            () async => DashboardConfigValues.empty,
          ),
          // TASK MUTE-impl: SetupPage가 이제 muteStateListenable(=
          // syncControllerProvider 파생)을 watch한다 — 이 화면 단독
          // 렌더에서는 dashboardConfigValuesProvider를 override하지 않아
          // 진짜 SyncController.build()가 그 provider를 읽으면 던진다.
          // 이 테스트가 검증하려는 오버플로 여부와 무관하니 고정 상태로
          // 갈아 끼운다(`goldens_test.dart`의 `_GoldenFixedSyncController`
          // 와 같은 관용).
          syncControllerProvider.overrideWith(
            () => _FixedSyncController(const SyncControllerState()),
          ),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const SetupPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('DiagnosticsPage: 좁은 폭에서 오버플로 없이 렌더링된다(로드 성공)', (tester) async {
    _useNarrowViewport(tester);
    const diagnosticsBody = '''
{
  "last_event_at": 1700000000000,
  "max_transition_id": 42,
  "pruned_below_id": 1,
  "device_failure_count": 0,
  "subscription_failure_count": 0,
  "channels": {"fcm": true, "web-push": false, "이런-이름의-채널도-있을-수-있다": true},
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
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, argKeys, argVals) => key,
          ),
          stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
          isSessionStaleFnProvider.overrideWithValue(
            ({required int now, required int updatedAt, required int staleMs}) =>
                false,
          ),
          dashboardApiConfigProvider.overrideWithValue(
            DashboardApiConfig(baseUrl: Uri.parse('https://example.test')),
          ),
          httpSendProvider.overrideWithValue(
            (request) async =>
                const ApiResponse(statusCode: 200, body: diagnosticsBody),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const DiagnosticsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('DiagnosticsPage: 좁은 폭에서 오버플로 없이 렌더링된다(오류 상태)', (tester) async {
    _useNarrowViewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, argKeys, argVals) => key,
          ),
          stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
          isSessionStaleFnProvider.overrideWithValue(
            ({required int now, required int updatedAt, required int staleMs}) =>
                false,
          ),
          dashboardApiConfigProvider.overrideWithValue(
            DashboardApiConfig(baseUrl: Uri.parse('https://example.test')),
          ),
          httpSendProvider.overrideWithValue(
            (request) async =>
                const ApiResponse(statusCode: 500, body: '{"error":"boom"}'),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const DiagnosticsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
