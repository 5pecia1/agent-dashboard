/// [SessionsPage] 위젯 테스트 — 완료 기준 (c)의 loading/error/empty/stale
/// 조각.
///
/// `syncControllerProvider`(`NotifierProvider`)를 `build()`만 override한
/// 고정 상태 서브클래스로 갈아끼운다 — 진짜 `SyncController.build()`는
/// `dashboardConfigValuesProvider`/`syncActivityWatchFnProvider`를 watch하고
/// `_scheduleNext`로 실제 사이클을 예약하므로, 이 화면 테스트는 그 경로를
/// 전혀 타지 않는다(이 서브클래스는 `triggerNow()`를 부르지 않는 한
/// 안전하다 — pull-to-refresh 제스처는 이 파일에서 의도적으로 건드리지
/// 않는다).
library;

import 'package:my_dashboard/src/state/usage_integrations.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_models.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_models.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/config_provider.dart'
    show DashboardConfigValues, dashboardConfigValuesProvider;
import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show isSessionStaleFnProvider, stateLabelKeyFnProvider;
import 'package:my_dashboard/src/integrations/state/devin_usage_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/integrations/state/teamclaude_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';
import 'package:my_dashboard/src/ui/widgets/alert_banner.dart';
import 'package:my_dashboard/src/ui/widgets/session_card.dart';

class _FixedSyncController extends SyncController {
  _FixedSyncController(this._state);

  final SyncControllerState _state;

  @override
  SyncControllerState build() => _state;
}

Future<void> _pumpSessionsPage(
  WidgetTester tester,
  SyncControllerState state, {
  SyncController? syncController,
  TeamClaudeController? teamClaudeController,
  DevinUsageController? devinUsageController,
}) => tester.pumpWidget(
  ProviderScope(
    overrides: [
      ...usageDashboardUiOverrides,
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
        () => syncController ?? _FixedSyncController(state),
      ),
      if (teamClaudeController != null)
        teamClaudeControllerProvider.overrideWith(() => teamClaudeController),
      if (devinUsageController != null)
        devinUsageControllerProvider.overrideWith(() => devinUsageController),
      // `HookSkewBanner`가 복사 아이콘 표시 여부를 판정하려고 자기 build()
      // 안에서 `dashboardConfigValuesProvider`를 직접 읽는다(`alert_banner.
      // dart` 문서 참고) — override 없이 읽으면 던지는 계약이라 이 화면을
      // 통째로 펌프하는 테스트도 그 provider를 채워 둬야 한다. serverUrl은
      // 이 파일의 관심사가 아니라(아이콘 자체는 `alert_banner_test.dart`가
      // 덮는다) null로 둔다.
      dashboardConfigValuesProvider.overrideWithValue(
        const DashboardConfigValues(),
      ),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const SessionsPage()),
  ),
);

const _activeSession = SessionViewDto(
  key: 'claude-code:s1',
  state: 'working',
  source: 'claude-code',
  sessionId: 's1',
  project: 'my-dashboard',
  host: 'dev-mac',
  updatedAt: 1000,
);

const _teamClaudeConnection = TeamClaudeConnection(
  baseUrl: 'https://tc.test',
  apiKey: 'test-key',
);
const _devinConnection = DevinConnection(
  baseUrl: 'https://devin.test',
  apiKey: 'test-key',
);

const _readySyncState = SyncControllerState(
  sync: SyncState(cursor: 1000, sessions: {'claude-code:s1': _activeSession}),
);

class _CountingSyncController extends SyncController {
  var triggers = 0;
  var forcedTriggers = 0;

  @override
  SyncControllerState build() => _readySyncState;

  @override
  void triggerNow({bool force = false}) {
    triggers++;
    if (force) forcedTriggers++;
  }

  void setPhase(SyncPhase phase) {
    state = _readySyncState.copyWith(phase: phase);
  }
}

class _CountingTeamClaude extends TeamClaudeController {
  var refreshes = 0;

  @override
  TeamClaudeState build() =>
      const TeamClaudeState(connection: _teamClaudeConnection);

  @override
  void setActive(bool active) {}

  @override
  Future<void> refresh() async {
    refreshes++;
  }

  void setLoading(bool loading) {
    state = TeamClaudeState(
      connection: _teamClaudeConnection,
      loading: loading,
    );
  }
}

class _CountingDevin extends DevinUsageController {
  var refreshes = 0;

  @override
  DevinUsageState build() =>
      const DevinUsageState(connection: _devinConnection);

  @override
  void setActive(bool active) {}

  @override
  Future<void> refresh() async {
    refreshes++;
  }

  void setLoading(bool loading) {
    state = DevinUsageState(connection: _devinConnection, loading: loading);
  }
}

void main() {
  group('sessionsScreenPhaseFor (순수 함수)', () {
    test('첫 동기화 전(cursor null, 오류 없음) -> loading', () {
      expect(
        sessionsScreenPhaseFor(const SyncControllerState()),
        SessionsScreenPhase.loading,
      );
    });

    test('첫 동기화가 오류로 끝남(cursor null, 오류 있음) -> error', () {
      final state = SyncControllerState(
        lastError: const SyncErrorInfo(
          kind: SyncErrorKind.network,
          message: 'boom',
          atMs: 0,
        ),
      );
      expect(sessionsScreenPhaseFor(state), SessionsScreenPhase.error);
    });

    test('동기화됐지만 활성 세션이 없음 -> empty', () {
      const state = SyncControllerState(sync: SyncState(cursor: 1000));
      expect(sessionsScreenPhaseFor(state), SessionsScreenPhase.empty);
    });

    test('이전 스냅샷은 있는데 최근 동기화가 실패 -> staleData', () {
      final state = SyncControllerState(
        sync: const SyncState(
          cursor: 1000,
          sessions: {'claude-code:s1': _activeSession},
        ),
        lastError: const SyncErrorInfo(
          kind: SyncErrorKind.server,
          message: 'boom',
          atMs: 0,
        ),
      );
      expect(sessionsScreenPhaseFor(state), SessionsScreenPhase.staleData);
    });

    test('동기화 정상, 활성 세션 있음, 오류 없음 -> ready', () {
      const state = SyncControllerState(
        sync: SyncState(
          cursor: 1000,
          sessions: {'claude-code:s1': _activeSession},
        ),
      );
      expect(sessionsScreenPhaseFor(state), SessionsScreenPhase.ready);
    });
  });

  group('SessionsPage 위젯', () {
    testWidgets('loading 단계: 로딩 문구가 보인다', (tester) async {
      await _pumpSessionsPage(tester, const SyncControllerState());
      await tester.pump();

      expect(find.text('session.list.loading'), findsOneWidget);
      expect(find.byType(SessionCard), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('error 단계: 오류 문구와 원문 오류 메시지가 보인다', (tester) async {
      final state = SyncControllerState(
        lastError: const SyncErrorInfo(
          kind: SyncErrorKind.network,
          message: 'DashboardNetworkFailure(null): boom',
          atMs: 0,
        ),
      );
      await _pumpSessionsPage(tester, state);
      await tester.pump();

      expect(find.text('session.list.error.title'), findsOneWidget);
      expect(find.text('DashboardNetworkFailure(null): boom'), findsOneWidget);
      expect(find.text('action.retry'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty 단계: 목록이 비었다는 문구가 보인다', (tester) async {
      const state = SyncControllerState(sync: SyncState(cursor: 1000));
      await _pumpSessionsPage(tester, state);
      await tester.pump();

      expect(find.text('session.list.empty.title'), findsOneWidget);
      expect(find.byType(SessionCard), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('stale 단계: 오류가 있어도 마지막 세션 카드가 그대로 보이고, StaleDataBanner가 뜬다', (
      tester,
    ) async {
      final state = SyncControllerState(
        sync: const SyncState(
          cursor: 1000,
          sessions: {'claude-code:s1': _activeSession},
        ),
        lastError: const SyncErrorInfo(
          kind: SyncErrorKind.server,
          message: 'boom',
          atMs: 0,
        ),
      );
      await _pumpSessionsPage(tester, state);
      await tester.pump();

      expect(find.byType(SessionCard), findsOneWidget);
      // 검증 지적(high): 이전 보고서는 "위젯 테스트로 확인"이라고 했지만
      // 실제로는 StaleDataBanner의 존재를 단언하는 테스트가 하나도
      // 없었다 — 이걸 지우거나 배너가 안 뜨게 되돌려도 아래가 없으면
      // green이 유지된다.
      expect(find.byType(StaleDataBanner), findsOneWidget);
      expect(find.text('session.list.empty.title'), findsNothing);
      expect(find.text('session.list.error.title'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ready 단계(오류 없음): StaleDataBanner가 뜨지 않는다', (tester) async {
      const state = SyncControllerState(
        sync: SyncState(
          cursor: 1000,
          sessions: {'claude-code:s1': _activeSession},
        ),
      );
      await _pumpSessionsPage(tester, state);
      await tester.pump();

      expect(find.byType(SessionCard), findsOneWidget);
      expect(find.byType(StaleDataBanner), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '검증 지적(medium): 활성 세션 0개 + 동기화 오류 조합에서도 StaleDataBanner가 뜬다(무표시 회귀 방지)',
      (tester) async {
        final state = SyncControllerState(
          sync: const SyncState(cursor: 1000),
          lastError: const SyncErrorInfo(
            kind: SyncErrorKind.network,
            message: 'boom',
            atMs: 0,
          ),
        );
        await _pumpSessionsPage(tester, state);
        await tester.pump();

        // phase 자체는 여전히 empty(친절한 "세션 없음" 문구가 우선)지만,
        // 동기화 실패를 알리는 배너는 phase와 무관하게 함께 뜬다 — 이
        // 조합에서 실패가 무표시로 남지 않는다는 게 이번 수정의 핵심.
        expect(sessionsScreenPhaseFor(state), SessionsScreenPhase.empty);
        expect(find.text('session.list.empty.title'), findsOneWidget);
        expect(find.byType(StaleDataBanner), findsOneWidget);
        expect(find.byType(SessionCard), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('empty 단계(오류 없음): StaleDataBanner가 뜨지 않는다', (tester) async {
      const state = SyncControllerState(sync: SyncState(cursor: 1000));
      await _pumpSessionsPage(tester, state);
      await tester.pump();

      expect(find.byType(StaleDataBanner), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('hookSkew가 비어 있지 않으면 HookSkewBanner가 뜨고 hookSkew 목록을 그대로 넘긴다', (
      tester,
    ) async {
      const hookSkew = <HookSkewDto>[
        HookSkewDto(
          host: 'dev-mac',
          rev: 'a1b2c3d4',
          project: '/workspace/example-project',
        ),
        HookSkewDto(host: 'dev-linux'),
      ];
      const state = SyncControllerState(
        sync: SyncState(
          cursor: 1000,
          sessions: {'claude-code:s1': _activeSession},
          hookSkew: hookSkew,
        ),
      );
      await _pumpSessionsPage(tester, state);
      await tester.pump();

      expect(find.byType(HookSkewBanner), findsOneWidget);
      expect(
        tester.widget<HookSkewBanner>(find.byType(HookSkewBanner)).hookSkew,
        hookSkew,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('hookSkew가 비어 있으면 HookSkewBanner가 뜨지 않는다', (tester) async {
      const state = SyncControllerState(
        sync: SyncState(
          cursor: 1000,
          sessions: {'claude-code:s1': _activeSession},
        ),
      );
      await _pumpSessionsPage(tester, state);
      await tester.pump();

      expect(find.byType(HookSkewBanner), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('HookSkewBanner는 StaleDataBanner와 독립적으로 동시에 뜰 수 있다', (
      tester,
    ) async {
      final state = SyncControllerState(
        sync: const SyncState(
          cursor: 1000,
          sessions: {'claude-code:s1': _activeSession},
          hookSkew: <HookSkewDto>[HookSkewDto(host: 'dev-mac')],
        ),
        lastError: const SyncErrorInfo(
          kind: SyncErrorKind.server,
          message: 'boom',
          atMs: 0,
        ),
      );
      await _pumpSessionsPage(tester, state);
      await tester.pump();

      expect(find.byType(StaleDataBanner), findsOneWidget);
      expect(find.byType(HookSkewBanner), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('통합 새로고침', () {
    testWidgets('앱바의 유일한 새로고침 버튼이 프로젝트 동기화와 두 쿼터 갱신을 함께 부른다', (tester) async {
      final sync = _CountingSyncController();
      final teamClaude = _CountingTeamClaude();
      final devin = _CountingDevin();
      await _pumpSessionsPage(
        tester,
        _readySyncState,
        syncController: sync,
        teamClaudeController: teamClaude,
        devinUsageController: devin,
      );
      await tester.pump();

      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.byTooltip('session.list.action.refresh'), findsOneWidget);
      expect(find.byTooltip('teamclaude.refresh'), findsNothing);
      expect(find.byTooltip('devin.refresh'), findsNothing);

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();

      expect(sync.triggers, 1);
      expect(sync.forcedTriggers, 1);
      expect(teamClaude.refreshes, 1);
      expect(devin.refreshes, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('당겨서 새로고침도 같은 세 경로를 호출한다', (tester) async {
      final sync = _CountingSyncController();
      final teamClaude = _CountingTeamClaude();
      final devin = _CountingDevin();
      await _pumpSessionsPage(
        tester,
        _readySyncState,
        syncController: sync,
        teamClaudeController: teamClaude,
        devinUsageController: devin,
      );
      await tester.pump();

      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();

      expect(sync.triggers, 1);
      expect(sync.forcedTriggers, 1);
      expect(teamClaude.refreshes, 1);
      expect(devin.refreshes, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('세 원천 중 하나라도 갱신 중이면 새로고침 버튼이 비활성화된다', (tester) async {
      final sync = _CountingSyncController();
      final teamClaude = _CountingTeamClaude();
      final devin = _CountingDevin();
      await _pumpSessionsPage(
        tester,
        _readySyncState,
        syncController: sync,
        teamClaudeController: teamClaude,
        devinUsageController: devin,
      );
      await tester.pump();

      IconButton refreshButton() => tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.refresh),
          matching: find.byType(IconButton),
        ),
      );

      expect(refreshButton().onPressed, isNotNull);
      teamClaude.setLoading(true);
      await tester.pump();
      expect(refreshButton().onPressed, isNull);
      teamClaude.setLoading(false);
      devin.setLoading(true);
      await tester.pump();
      expect(refreshButton().onPressed, isNull);
      devin.setLoading(false);
      sync.setPhase(SyncPhase.syncing);
      await tester.pump();
      expect(refreshButton().onPressed, isNull);
      sync.setPhase(SyncPhase.idle);
      await tester.pump();
      expect(refreshButton().onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });
  });
}
