/// TASK D-app 배선 (4): "알림을 눌렀다" 신호가 실제로 앱을 움직이는지.
///
/// 직전 게이트가 발견한 구멍이 정확히 여기였다 — `web/push_sw.js`는
/// `BroadcastChannel('dashboard')`로 신호를 던지고 있었는데 **듣는 쪽이
/// 아무도 없었다**(`sync_controller.dart` 상단이 "그 사건을 알려줄 이벤트
/// 소스가 아예 없다"고 남겨 둔 자리). 이 파일은 그 구멍이 메워졌다는 것을
/// 브라우저·서비스 워커·플러그인 없이 증명한다: [pushSignalWatchProvider]
/// 시임 하나만 갈아끼워 신호를 손으로 흘려 넣고, 앱이 (1) sync를 즉시 다시
/// 당기고 (2) 그 세션 상세로 딥링크하는지 본다.
///
/// 실제 `BroadcastChannel` 배선(웹) / `onMessageOpenedApp`(macOS)은 각각
/// `push_signal_web.dart` / `apns_push_native.dart`에 있고, 그 둘이 이
/// 스트림에 흘려 넣는 값의 모양은 `push_signal_test.dart`가 닫는다.
///
/// 같은 자리(`_AppHome.initState`)가 지는 나머지 배선 하나 — 저장된 상주
/// 설정을 네이티브에 미는 것(설계 ④) — 도 여기서 함께 본다. 부팅 배선은
/// 한 곳에 모여 있으므로 검증도 한 파일에 둔다.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/app.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart' show SyncState;
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/platform/push_signal.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart' show LocaleDto;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show isSessionStaleFnProvider, stateLabelKeyFnProvider;
import 'package:my_dashboard/src/state/push_provider.dart';
import 'package:my_dashboard/src/state/resident_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/ui/session_detail_page.dart' show SessionDeepLinkPage;

String _translate(String key, LocaleDto locale) => key;

String _translateArgs(
  String key,
  LocaleDto locale,
  List<String> argKeys,
  List<String> argVals,
) => key;

/// `triggerNow`가 실제로 불렸는지만 기록하는 컨트롤러. 진짜 타이머·네트워크
/// 없이 "재조회를 당겼다"를 관찰할 수 있게 한다(`app_wiring_test.dart`의
/// `_BootProbeController`와 같은 관용 — `cursor: 0`을 주는 이유도 같다:
/// 기본값은 세션 목록을 무한 스피너로 접어 `pumpAndSettle`을 죽인다).
class _TriggerProbeController extends SyncController {
  static int triggerCount = 0;

  @override
  SyncControllerState build() => const SyncControllerState(
    sync: SyncState(cursor: 0),
  );

  @override
  void triggerNow({bool force = false}) {
    triggerCount += 1;
  }
}

final _commonOverrides = [
  i18nTranslateOverride.overrideWithValue(_translate),
  i18nTranslateArgsOverride.overrideWithValue(_translateArgs),
  stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
  isSessionStaleFnProvider.overrideWithValue(
    ({required int now, required int updatedAt, required int staleMs}) => false,
  ),
];

Future<StreamController<PushSignal>> _pumpAppWithSignals(
  WidgetTester tester,
) async {
  final signals = StreamController<PushSignal>.broadcast();
  addTearDown(signals.close);
  _TriggerProbeController.triggerCount = 0;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ..._commonOverrides,
        dashboardConfigValuesProvider.overrideWithValue(
          const DashboardConfigValues(serverUrl: 'https://example.test'),
        ),
        syncControllerProvider.overrideWith(_TriggerProbeController.new),
        pushSignalWatchProvider.overrideWithValue(() => signals.stream),
      ],
      child: const SolApp(),
    ),
  );
  await tester.pumpAndSettle();
  return signals;
}

void main() {
  testWidgets('알림 클릭 신호를 받으면 sync를 즉시 재조회한다', (tester) async {
    final signals = await _pumpAppWithSignals(tester);
    expect(
      _TriggerProbeController.triggerCount,
      0,
      reason: '신호가 오기 전에는 즉시 트리거가 없다',
    );

    signals.add(
      pushSignalFromMap(<String, Object?>{
        'type': 'notification-click',
        'refresh': true,
        'session_key': 'claude_code:s1',
        'link': '/?session=claude_code%3As1',
      }),
    );
    await tester.pumpAndSettle();

    expect(_TriggerProbeController.triggerCount, 1);
  });

  testWidgets('알림 클릭 신호는 그 세션 상세로 딥링크한다', (tester) async {
    final signals = await _pumpAppWithSignals(tester);
    expect(find.byType(SessionDeepLinkPage), findsNothing);

    signals.add(
      pushSignalFromMap(<String, Object?>{
        'type': 'notification-click',
        'session_key': 'claude_code:s1',
      }),
    );
    await tester.pumpAndSettle();

    // 세션 카드를 탭했을 때와 정확히 같은 라우트(`app_router.dart`)다.
    expect(find.byType(SessionDeepLinkPage), findsOneWidget);
  });

  testWidgets('session_key가 비어 와도 link에서 복구해 딥링크한다', (tester) async {
    final signals = await _pumpAppWithSignals(tester);

    signals.add(
      pushSignalFromMap(<String, Object?>{
        'type': 'notification-click',
        'session_key': '',
        'link': '/?session=codex%3As2',
      }),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SessionDeepLinkPage), findsOneWidget);
  });

  testWidgets('세션을 알 수 없는 신호는 재조회만 하고 라우트를 얹지 않는다', (tester) async {
    final signals = await _pumpAppWithSignals(tester);

    signals.add(
      pushSignalFromMap(<String, Object?>{
        'type': 'notification-click',
        'link': '/',
      }),
    );
    await tester.pumpAndSettle();

    expect(_TriggerProbeController.triggerCount, 1);
    expect(find.byType(SessionDeepLinkPage), findsNothing);
  });

  testWidgets('refresh:false 신호는 재조회를 당기지 않는다', (tester) async {
    final signals = await _pumpAppWithSignals(tester);

    signals.add(
      pushSignalFromMap(<String, Object?>{
        'type': 'notification-click',
        'refresh': false,
        'session_key': 'claude_code:s1',
      }),
    );
    await tester.pumpAndSettle();

    expect(_TriggerProbeController.triggerCount, 0);
    expect(find.byType(SessionDeepLinkPage), findsOneWidget);
  });

  group('부팅이 저장된 상주 설정을 네이티브에 민다 (A안 설계 ④)', () {
    Future<List<bool>> pumpBootWithResident(
      WidgetTester tester,
      DashboardConfigValues values,
    ) async {
      final applied = <bool>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._commonOverrides,
            dashboardConfigValuesProvider.overrideWithValue(values),
            configLoadFnProvider.overrideWithValue(() async => values),
            syncControllerProvider.overrideWith(_TriggerProbeController.new),
            pushSignalWatchProvider.overrideWithValue(
              () => const Stream<PushSignal>.empty(),
            ),
            residentModeApplyProvider.overrideWithValue((enabled) async {
              applied.add(enabled);
            }),
          ],
          child: const SolApp(),
        ),
      );
      await tester.pumpAndSettle();
      return applied;
    }

    testWidgets('저장된 값이 꺼짐이면 꺼짐을 민다', (tester) async {
      final applied = await pumpBootWithResident(
        tester,
        const DashboardConfigValues(
          serverUrl: 'https://example.test',
          resident: false,
        ),
      );
      expect(applied, <bool>[false]);
    });

    testWidgets('한 번도 정한 적 없으면 기본값(켜짐)을 민다', (tester) async {
      final applied = await pumpBootWithResident(
        tester,
        const DashboardConfigValues(serverUrl: 'https://example.test'),
      );
      expect(applied, <bool>[kResidentDefault]);
    });
  });
}
