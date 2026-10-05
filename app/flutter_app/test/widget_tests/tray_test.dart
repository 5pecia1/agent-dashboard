/// TASK TRAY-impl 완료 기준 (6) — 나머지 세 가지를 실제 `tray_manager`
/// 플러그인/네이티브 채널 없이 시임 override로 확인한다:
///
/// 1. 메뉴 빌드 라벨이 i18n 키를 쓴다(`buildTrayMenuItems`).
/// 2. "알림 음소거 30분"이 [dashboardApiProvider] 시임을 정확히 1회
///    부른다(`trayMuteProvider`).
/// 3. 웹/비macOS에서 `installTray`가 no-op이다 — 웹은 `tray_web.dart`를
///    직접(파사드를 거치지 않고) import해 진짜 웹 코드 경로를 그대로
///    테스트하고, 비macOS는 `tray_native.dart`의 [traySupportedProvider]를
///    override해 같은 가드를 확인한다.
///
/// [buildTrayMenuItems]/[installTray]는 `WidgetRef`가 필요해서
/// (`t.dart`의 [tRead] 계약) `t13_seams_boot_test.dart`와 같은 방식으로
/// 최소 프로브 위젯을 하나 띄워 진짜 `WidgetRef`를 얻는다.
library;

import 'dart:async' show Completer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart'
    show SessionViewDto, kDashboardStateStalled, kDashboardStateWaitingInput;
import 'package:my_dashboard/src/data/sync_reducer.dart' show SyncState;
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/platform/tray_command.dart';
import 'package:my_dashboard/src/platform/tray_native.dart' as tray_native;
import 'package:my_dashboard/src/platform/tray_web.dart' as tray_web;
import 'package:my_dashboard/src/rust/api/i18n.dart' show LocaleDto;
import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show stateLabelKeyFnProvider;
import 'package:my_dashboard/src/state/config_provider.dart'
    show dashboardApiConfigControllerProvider;
import 'package:my_dashboard/src/state/sync_controller.dart'
    show SyncController, SyncControllerState, syncControllerProvider;
import 'package:tray_manager/tray_manager.dart' show MenuItem;

// ignore: depend_on_referenced_packages
import 'package:riverpod/misc.dart' show Override;

/// 키의 마지막 세그먼트가 아니라 키 자체를 돌려주는 결정적 번역기
/// (`setup_resident_toggle_test.dart`와 같은 관용) — 라벨이 어느 i18n
/// 키에서 왔는지 그대로 드러난다.
String _translate(String key, LocaleDto locale) => key;

/// 인자가 있는 조회는 키와 함께 인자까지 그대로 돌려준다 —
/// 툴팁(`tray.tooltip_unseen`)이 `{count}`를 실제로 채우는지 카탈로그
/// 문구에 의존하지 않고 확인할 수 있다.
String _translateArgs(
  String key,
  LocaleDto locale,
  List<String> argKeys,
  List<String> argVals,
) {
  final pairs = <String>[
    for (var i = 0; i < argKeys.length; i += 1) '${argKeys[i]}=${argVals[i]}',
  ];
  return pairs.isEmpty ? key : '$key|${pairs.join(',')}';
}

/// [action]을 위젯 트리가 뜬 다음(진짜 `WidgetRef`가 있는 상태에서) 한 번
/// 실행하고 끝난다 — `t13_seams_boot_test.dart`의 `_SeamProbe`와 같은 자리.
class _RefProbe extends ConsumerStatefulWidget {
  const _RefProbe(this.action);

  final void Function(WidgetRef ref) action;

  @override
  ConsumerState<_RefProbe> createState() => _RefProbeState();
}

class _RefProbeState extends ConsumerState<_RefProbe> {
  @override
  void initState() {
    super.initState();
    widget.action(ref);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Future<void> _pumpProbe(
  WidgetTester tester,
  List<Override> overrides,
  void Function(WidgetRef ref) action,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        i18nTranslateOverride.overrideWithValue(_translate),
        i18nTranslateArgsOverride.overrideWithValue(_translateArgs),
        ...overrides,
      ],
      child: MaterialApp(home: _RefProbe(action)),
    ),
  );
  await tester.pumpAndSettle();
}

/// `markSeen` 호출을 기록만 하는 고정 컨트롤러 — `sessions_page_test.dart`의
/// `_FixedSyncController`와 같은 관용이다. 서버 호출 없이 "시임이 어느 세션
/// 키로 불렸는가"만 본다(`markSeen` 자체의 낙관 갱신·서버 왕복은
/// `sync_controller_seen_delete_test.dart`가 이미 덮는다).
class _RecordingSyncController extends SyncController {
  final seenKeys = <String>[];

  @override
  SyncControllerState build() => const SyncControllerState();

  @override
  Future<void> markSeen(String key) async {
    seenKeys.add(key);
  }
}

void main() {
  setUp(tray_native.debugResetTrayInstallStateForTest);

  group('buildTrayMenuItems (메뉴 라벨 i18n)', () {
    testWidgets('세 항목 + 구분선이고, 라벨은 각자의 i18n 키로 만들어진다', (tester) async {
      late List<MenuItem> items;
      await _pumpProbe(tester, [], (ref) {
        items = tray_native.buildTrayMenuItems(ref);
      });

      expect(items, hasLength(4), reason: '열기/음소거/구분선/종료');
      expect(items[0].key, TrayCommand.open.menuItemKey);
      expect(items[0].label, 'tray.open');
      expect(items[1].key, TrayCommand.mute30.menuItemKey);
      expect(items[1].label, 'tray.mute_30');
      expect(items[2].type, 'separator', reason: '열기/종료를 가르는 구분선');
      expect(items[3].key, TrayCommand.quit.menuItemKey);
      expect(items[3].label, 'tray.quit');
    });
  });

  group('trayMuteProvider (완료 기준 (4): 음소거는 시임을 정확히 1회 부른다)', () {
    testWidgets('성공하면 dashboardApi.mute(minutes: 30)을 정확히 1회 호출한다', (
      tester,
    ) async {
      final seenRequests = <ApiRequest>[];
      await _pumpProbe(tester, [
        dashboardApiConfigProvider.overrideWithValue(
          DashboardApiConfig(baseUrl: Uri.parse('https://api.example.test')),
        ),
        httpSendProvider.overrideWithValue((request) async {
          seenRequests.add(request);
          return const ApiResponse(statusCode: 200, body: '{"mute_until":123}');
        }),
      ], (ref) => ref.read(tray_native.trayMuteProvider)());

      expect(seenRequests, hasLength(1));
      expect(seenRequests.single.method, 'POST');
      expect(seenRequests.single.url.path, kMutePath);
      expect(seenRequests.single.body, '{"minutes":30}');
    });

    testWidgets('서버 오류는 크래시하지 않는다(디버그 출력만) — 위젯이 계속 뜬 채로 남는다', (tester) async {
      var callCount = 0;
      await _pumpProbe(tester, [
        dashboardApiConfigProvider.overrideWithValue(
          DashboardApiConfig(baseUrl: Uri.parse('https://api.example.test')),
        ),
        httpSendProvider.overrideWithValue((request) async {
          callCount += 1;
          return const ApiResponse(statusCode: 500, body: '{"error":"boom"}');
        }),
      ], (ref) => ref.read(tray_native.trayMuteProvider)());

      expect(callCount, 1, reason: '실패해도 재시도 없이 정확히 1회만 부른다');
      expect(find.byType(SizedBox), findsOneWidget, reason: '예외가 위로 새지 않았다');
    });

    testWidgets('서버 주소 없이 부팅해 API가 없어도 던지지 않고 실패를 돌려준다', (tester) async {
      // `dashboardApiConfigProvider`를 override하지 않는다 — 첫 실행이나
      // 해석할 수 없는 저장 주소로 부팅한 세션과 같다. 읽는 순간 나는 오류가
      // `DashboardApiException`이 아니어도 트레이 동작은 실패 값으로 끝난다.
      bool? muted;
      bool? unmuted;
      await _pumpProbe(tester, [], (ref) {
        ref.read(tray_native.trayMuteProvider)().then((ok) => muted = ok);
        ref.read(tray_native.trayUnmuteProvider)().then((ok) => unmuted = ok);
      });

      expect(muted, isFalse);
      expect(unmuted, isFalse);
    });
  });

  group(
    'trayUnmuteProvider (TASK MUTE-impl: 해제는 minutes:0으로 같은 엔드포인트를 부른다)',
    () {
      // 검증 지적(high): trayUnmuteProvider를 실제로 호출·단언하는 테스트가
      // 이전에 하나도 없었다 — trayMuteProvider와 대칭인 이 테스트가 그
      // 회귀를 잡는다.
      testWidgets('성공하면 dashboardApi.mute(minutes: 0)을 정확히 1회 호출한다', (
        tester,
      ) async {
        final seenRequests = <ApiRequest>[];
        await _pumpProbe(tester, [
          dashboardApiConfigProvider.overrideWithValue(
            DashboardApiConfig(baseUrl: Uri.parse('https://api.example.test')),
          ),
          httpSendProvider.overrideWithValue((request) async {
            seenRequests.add(request);
            return const ApiResponse(
              statusCode: 200,
              body: '{"mute_until":null}',
            );
          }),
        ], (ref) => ref.read(tray_native.trayUnmuteProvider)());

        expect(seenRequests, hasLength(1));
        expect(seenRequests.single.method, 'POST');
        expect(seenRequests.single.url.path, kMutePath);
        expect(seenRequests.single.body, '{"minutes":0}');
      });

      testWidgets('서버 오류는 크래시하지 않는다(디버그 출력만)', (tester) async {
        var callCount = 0;
        await _pumpProbe(tester, [
          dashboardApiConfigProvider.overrideWithValue(
            DashboardApiConfig(baseUrl: Uri.parse('https://api.example.test')),
          ),
          httpSendProvider.overrideWithValue((request) async {
            callCount += 1;
            return const ApiResponse(statusCode: 500, body: '{"error":"boom"}');
          }),
        ], (ref) => ref.read(tray_native.trayUnmuteProvider)());

        expect(callCount, 1, reason: '실패해도 재시도 없이 정확히 1회만 부른다');
        expect(find.byType(SizedBox), findsOneWidget, reason: '예외가 위로 새지 않았다');
      });
    },
  );

  group('buildTrayMenuItems (muted 분기, TASK MUTE-impl)', () {
    // 검증 지적(high): muted 분기(해제 항목이 mute30 자리를 갈아 끼우는가)
    // 를 단언하는 테스트가 이전에 하나도 없었다 — 기본(비음소거) 4항목만
    // 확인하는 위 그룹과 대칭으로 채운다.
    testWidgets('muted:true + muteUntil이 있으면 mute30 대신 unmute 항목이 그 자리를 차지한다', (
      tester,
    ) async {
      late List<MenuItem> items;
      final muteUntil = DateTime(2026, 9, 11, 3, 5).millisecondsSinceEpoch;
      await _pumpProbe(tester, [], (ref) {
        items = tray_native.buildTrayMenuItems(
          ref,
          muted: true,
          muteUntil: muteUntil,
        );
      });

      expect(items, hasLength(4));
      expect(items[1].key, TrayCommand.unmute.menuItemKey);
      expect(items[1].label, 'tray.mute_unmute|time=03:05');
      expect(
        items.any((item) => item.key == TrayCommand.mute30.menuItemKey),
        isFalse,
        reason: 'muted일 때는 mute30 항목이 없어야 한다(배타적으로 갈아 낀다)',
      );
    });

    testWidgets('muted:true인데 muteUntil이 null이면 방어적으로 mute30 항목을 유지한다', (
      tester,
    ) async {
      late List<MenuItem> items;
      await _pumpProbe(tester, [], (ref) {
        items = tray_native.buildTrayMenuItems(ref, muted: true);
      });

      expect(items[1].key, TrayCommand.mute30.menuItemKey);
    });
  });

  group('TrayMenu (뮤트/해제 메뉴 갱신 중복 억제, TASK MUTE-impl)', () {
    // 검증 지적(high): TrayMenu 클래스(apply의 중복 억제, muted 분기 갈아
    // 끼움)를 실제로 호출·단언하는 테스트가 이전에 하나도 없었다 — 같은
    // 자리의 TrayBadge 테스트와 대칭으로 채운다.
    testWidgets('상태가 실제로 바뀔 때만 setContextMenu 시임을 부르고, 같은 값이면 건드리지 않는다', (
      tester,
    ) async {
      final calls = <List<MenuItem>>[];
      late WidgetRef capturedRef;
      await _pumpProbe(tester, [
        tray_native.trayMenuApplyFnProvider.overrideWithValue((items) async {
          calls.add(items);
        }),
      ], (ref) => capturedRef = ref);

      final menu = tray_native.TrayMenu(capturedRef);
      expect(menu.debugAppliedState, isNull, reason: '아직 아무것도 밀어 넣지 않았다');

      // 비음소거 -> 비음소거: 첫 apply는 부른다.
      await menu.apply(muted: false, muteUntil: null, serverRevision: 0);
      expect(calls, hasLength(1));
      expect(calls.last[1].key, TrayCommand.mute30.menuItemKey);

      // 폴링이 같은 상태를 다시 들고 와도 채널을 건드리지 않는다.
      await menu.apply(muted: false, muteUntil: null, serverRevision: 0);
      expect(calls, hasLength(1), reason: '값이 바뀌지 않았으면 채널을 건드리지 않는다');

      // 음소거로 바뀌면 "해제" 항목으로 갈아 끼운다.
      final muteUntil = DateTime(2026, 9, 11, 3, 5).millisecondsSinceEpoch;
      await menu.apply(muted: true, muteUntil: muteUntil, serverRevision: 0);
      expect(calls, hasLength(2));
      expect(calls.last[1].key, TrayCommand.unmute.menuItemKey);
      expect(calls.last[1].label, 'tray.mute_unmute|time=03:05');
      expect(menu.debugAppliedState?.muted, isTrue);
      expect(menu.debugAppliedState?.muteUntil, muteUntil);

      // 해제되면 다시 30분 항목으로 되돌아온다.
      await menu.apply(muted: false, muteUntil: null, serverRevision: 0);
      expect(calls, hasLength(3));
      expect(calls.last[1].key, TrayCommand.mute30.menuItemKey);
    });
  });

  group('주의 배지 (TASK A-impl (2), 완료 기준 (4)(c))', () {
    test('SyncState.attentionSessionCount는 waiting_input + stalled만 센다', () {
      const state = SyncState(
        cursor: 10,
        sessions: <String, SessionViewDto>{
          'claude_code:s1': SessionViewDto(
            key: 'claude_code:s1',
            state: 'waiting_input',
          ),
          'claude_code:s2': SessionViewDto(
            key: 'claude_code:s2',
            state: 'stalled',
          ),
          'codex:s3': SessionViewDto(key: 'codex:s3', state: 'working'),
          // `done`은 (2026-09-14부터는 더 이상 배너 대상도 아니지만) 사람을
          // 기다리는 상태가 아니므로 애초에 배지에서는 세지 않는다.
          'codex:s4': SessionViewDto(key: 'codex:s4', state: 'done'),
          'codex:s5': SessionViewDto(key: 'codex:s5', state: 'ended'),
          'codex:s6': SessionViewDto(key: 'codex:s6', state: 'idle'),
        },
      );

      expect(state.attentionSessionCount, 2);
      expect(const SyncState().attentionSessionCount, 0);
    });

    test('SyncState.unseenSessionCount는 활성 세션 중 isSessionUnseen만 센다', () {
      const state = SyncState(
        cursor: 10,
        sessions: <String, SessionViewDto>{
          'claude_code:s1': SessionViewDto(
            key: 'claude_code:s1',
            state: 'waiting_input',
            lastTransitionId: 5,
          ),
          'claude_code:s2': SessionViewDto(
            key: 'claude_code:s2',
            state: 'working',
            lastTransitionId: 3,
          ),
          'codex:s3': SessionViewDto(
            key: 'codex:s3',
            state: 'ended',
            lastTransitionId: 9,
          ),
        },
        seenTransitionIds: <String, int>{'claude_code:s2': 3},
        seenWatermark: 0,
      );

      // s1: seen 정보 없음 + lastTransitionId(5) > seenWatermark(0) ->
      // 미확인. s2: seen == lastTransitionId -> 이미 읽음. s3: ended라
      // activeSessions에서 아예 빠진다(값과 무관하게 세지 않는다).
      expect(state.unseenSessionCount, 1);
      expect(const SyncState().unseenSessionCount, 0);
    });

    test('SyncState.unseenReportableSessionCount는 working 미확인은 빼고 센다'
        '(뷰의 unseenSessionCount와 다른 축)', () {
      const state = SyncState(
        cursor: 10,
        sessions: <String, SessionViewDto>{
          'claude_code:s1': SessionViewDto(
            key: 'claude_code:s1',
            state: 'working',
            lastTransitionId: 5,
          ),
          'claude_code:s2': SessionViewDto(
            key: 'claude_code:s2',
            state: 'done',
            lastTransitionId: 7,
          ),
        },
        seenWatermark: 0,
      );

      // 뷰(카드 미확인 점)는 working도 미확인으로 센다 — 둘 다 unseen.
      expect(state.unseenSessionCount, 2);
      // 트레이는 미는 신호면이라 "그냥 일하는 중"인 working을 빼고
      // done(확인할 결과)만 남는다.
      expect(state.unseenReportableSessionCount, 1);
    });

    test('working 미확인 세션만 있으면 트레이 제목은 빈 값이다', () {
      const state = SyncState(
        cursor: 10,
        sessions: <String, SessionViewDto>{
          'claude_code:s1': SessionViewDto(
            key: 'claude_code:s1',
            state: 'working',
            lastTransitionId: 5,
          ),
        },
        seenWatermark: 0,
      );

      expect(state.unseenReportableSessionCount, 0);
      expect(
        tray_native.trayBadgeTitle(state.unseenReportableSessionCount),
        '',
      );
    });

    test('working이 done으로 바뀌는 순간 unseenReportableSessionCount가 오른다', () {
      const working = SessionViewDto(
        key: 'claude_code:s1',
        state: 'working',
        lastTransitionId: 5,
      );
      final before = SyncState(
        cursor: 10,
        sessions: {'claude_code:s1': working},
        seenWatermark: 0,
      );
      final after = before.copyWith(
        cursor: 11,
        sessions: {
          'claude_code:s1': working.copyWith(
            state: 'done',
            lastTransitionId: 6,
          ),
        },
      );

      expect(before.unseenReportableSessionCount, 0);
      expect(after.unseenReportableSessionCount, 1);
    });

    test('아이콘(attention) 축은 트레이 unseen 필터와 무관하게 그대로다 — '
        'working이 빠져도 attentionSessionCount 계산에는 애초에 관여하지 않았다', () {
      const state = SyncState(
        cursor: 10,
        sessions: <String, SessionViewDto>{
          'claude_code:s1': SessionViewDto(
            key: 'claude_code:s1',
            state: 'working',
            lastTransitionId: 5,
          ),
          'claude_code:s2': SessionViewDto(
            key: 'claude_code:s2',
            state: 'stalled',
            lastTransitionId: 7,
          ),
        },
        seenWatermark: 0,
      );

      expect(state.attentionSessionCount, 1);
      expect(state.unseenReportableSessionCount, 1);
    });

    test('SyncState.waitingInputSessionCount/stalledSessionCount는 상태별로 따로 센다'
        '(트레이 아이콘 색의 근거 — 합산값으로는 색을 못 고른다)', () {
      const state = SyncState(
        cursor: 10,
        sessions: <String, SessionViewDto>{
          'claude_code:s1': SessionViewDto(
            key: 'claude_code:s1',
            state: kDashboardStateWaitingInput,
          ),
          'claude_code:s2': SessionViewDto(
            key: 'claude_code:s2',
            state: kDashboardStateWaitingInput,
          ),
          'claude_code:s3': SessionViewDto(
            key: 'claude_code:s3',
            state: kDashboardStateStalled,
          ),
          'codex:s4': SessionViewDto(key: 'codex:s4', state: 'working'),
          'codex:s5': SessionViewDto(key: 'codex:s5', state: 'done'),
        },
      );

      expect(state.waitingInputSessionCount, 2);
      expect(state.stalledSessionCount, 1);
      // 합산 getter(needsAttention)는 그대로 유지된다 — 두 파생값의 합과 같다.
      expect(state.attentionSessionCount, 3);
      expect(const SyncState().waitingInputSessionCount, 0);
      expect(const SyncState().stalledSessionCount, 0);
    });

    test('순수 판정: 제목/툴팁은 unseen 기준, 아이콘 색은 attention 심각도 기준 — 서로 다른 축', () {
      expect(tray_native.trayBadgeTitle(0), '');
      expect(tray_native.trayBadgeTitle(1), '1');
      expect(tray_native.trayBadgeTitle(12), '12');
      expect(
        tray_native.trayBadgeIconAssetPath(waiting: 0, stalled: 0),
        'assets/tray_icon.png',
      );
      expect(
        tray_native.trayBadgeIconAssetPath(waiting: 1, stalled: 0),
        'assets/tray_icon_attention_waiting.png',
      );
      expect(
        tray_native.trayBadgeIconAssetPath(waiting: 0, stalled: 1),
        'assets/tray_icon_attention_stalled.png',
      );
      expect(
        tray_native.trayBadgeIconAssetPath(waiting: 1, stalled: 1),
        'assets/tray_icon_attention_stalled.png',
        reason: 'stalled가 waiting보다 우선 — 더 심각한 색이 이긴다',
      );
      expect(tray_native.trayBadgeTooltipKey(0), 'tray.tooltip_idle');
      expect(tray_native.trayBadgeTooltipKey(3), 'tray.tooltip_unseen');
    });

    testWidgets('(unseen, waiting, stalled) 튜플이 실제로 바뀔 때만 setTitle/아이콘/툴팁 시임을 '
        '정확히 한 번씩 부른다 — 제목은 unseen, 아이콘 색은 심각도를 따른다', (tester) async {
      final calls = <({String title, String icon, String tooltip})>[];
      late WidgetRef capturedRef;
      await _pumpProbe(tester, [
        tray_native.trayBadgeApplyFnProvider.overrideWithValue(({
          required String title,
          required String iconAssetPath,
          required String tooltip,
        }) async {
          calls.add((title: title, icon: iconAssetPath, tooltip: tooltip));
        }),
      ], (ref) => capturedRef = ref);

      final badge = tray_native.TrayBadge(capturedRef);
      expect(badge.debugApplied, isNull, reason: '아직 아무것도 밀어 넣지 않았다');

      // 미확인 3 + waiting 1: 제목은 미확인 수, 아이콘은 호박(waiting) 변형.
      await badge.apply(unseen: 3, waiting: 1, stalled: 0);
      expect(calls, hasLength(1));
      expect(calls.last.title, '3');
      expect(calls.last.icon, 'assets/tray_icon_attention_waiting.png');
      expect(calls.last.tooltip, 'tray.tooltip_unseen|count=3');

      // 같은 튜플이 다시 와도(폴링은 3~30초마다 같은 맵을 들고 온다)
      // 네이티브를 다시 부르지 않는다.
      await badge.apply(unseen: 3, waiting: 1, stalled: 0);
      expect(calls, hasLength(1), reason: '값이 바뀌지 않았으면 채널을 건드리지 않는다');

      // 미확인 0 + waiting 1: 전부 읽었지만 여전히 입력을 기다리는
      // 세션이 있다 — 제목은 비지만 아이콘은 그대로 호박이다
      // (읽음과 무관한 축이라는 게 이 절의 핵심).
      await badge.apply(unseen: 0, waiting: 1, stalled: 0);
      expect(calls, hasLength(2));
      expect(calls.last.title, '', reason: "미확인이 0이면 setTitle('')");
      expect(calls.last.icon, 'assets/tray_icon_attention_waiting.png');
      expect(calls.last.tooltip, 'tray.tooltip_idle|count=0');

      // stalled가 뜨는 순간 아이콘은 적갈로 갈아탄다 — 숫자(unseen)와
      // 무관하게 색은 더 심각한 쪽을 따른다(stalled > waiting 우선).
      await badge.apply(unseen: 0, waiting: 1, stalled: 1);
      expect(calls, hasLength(3));
      expect(calls.last.title, '');
      expect(calls.last.icon, 'assets/tray_icon_attention_stalled.png');

      // 미확인 2 + attention 0: 반대 방향 — 아직 안 읽은 세션은 있지만
      // 다들 입력을 기다리는 중은 아니다. 제목은 뜨고 아이콘은 기본 보라로.
      await badge.apply(unseen: 2, waiting: 0, stalled: 0);
      expect(calls, hasLength(4));
      expect(calls.last.title, '2');
      expect(calls.last.icon, 'assets/tray_icon.png');
      expect(calls.last.tooltip, 'tray.tooltip_unseen|count=2');
      expect(badge.debugApplied, (unseen: 2, waiting: 0, stalled: 0));
    });
  });

  group('buildTrayMenuItems (안읽은 세션 항목 나열, TASK TRAY-unseen-menu)', () {
    testWidgets('미확인 세션이 있으면 "열기" 아래 구분선 사이에 세션 항목이 서브메뉴 없이 '
        '바로 나열되고, 각 항목이 세션별 동적 키와 "프로젝트 — 상태" 라벨을 갖는다', (tester) async {
      late List<MenuItem> items;
      await _pumpProbe(
        tester,
        [stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}')],
        (ref) {
          items = tray_native.buildTrayMenuItems(
            ref,
            unseen: const [
              SessionViewDto(
                key: 'claude_code:s1',
                state: 'waiting_input',
                project: '/repo/my-dashboard',
              ),
            ],
          );
        },
      );

      expect(items, hasLength(7), reason: '열기/구분선/세션/구분선/음소거/구분선/종료');
      expect(items[1].type, 'separator', reason: '세션 목록을 "열기"와 가르는 구분선');
      final sessionItem = items[2];
      expect(sessionItem.type, isNot('submenu'), reason: '서브메뉴가 아니라 최상위 항목이다');
      expect(sessionItem.key, 'tray_seen_claude_code:s1');
      // project는 basename만, state는 state.* 라벨을 거친 번역 결과다.
      expect(
        sessionItem.label,
        'tray.unseen_item|project=my-dashboard,state=label.waitingInput',
      );
      expect(items[3].type, 'separator', reason: '세션 목록과 음소거를 가르는 구분선');
      expect(items[4].key, TrayCommand.mute30.menuItemKey);
      expect(items[6].key, TrayCommand.quit.menuItemKey);
    });

    testWidgets('작업 표시 제목이 있으면 라벨의 project 자리가 "프로젝트 · 제목"이 된다', (
      tester,
    ) async {
      late List<MenuItem> items;
      await _pumpProbe(
        tester,
        [stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}')],
        (ref) {
          items = tray_native.buildTrayMenuItems(
            ref,
            unseen: const [
              SessionViewDto(
                key: 'claude_code:s1',
                state: 'waiting_input',
                project: '/repo/my-dashboard',
                displayTitle: '작업 A',
              ),
            ],
          );
        },
      );

      expect(
        items[2].label,
        'tray.unseen_item|project=my-dashboard · 작업 A,state=label.waitingInput',
      );
    });

    testWidgets('project가 비면 카드와 같은 폴백으로 sessionId를 라벨에 쓴다', (tester) async {
      late List<MenuItem> items;
      await _pumpProbe(
        tester,
        [stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}')],
        (ref) {
          items = tray_native.buildTrayMenuItems(
            ref,
            unseen: const [
              SessionViewDto(
                key: 'codex:s2',
                state: 'done',
                sessionId: 'sess-42',
              ),
            ],
          );
        },
      );

      expect(
        items[2].label,
        'tray.unseen_item|project=sess-42,state=label.done',
      );
    });

    testWidgets('세션 항목은 화면과 같은 순서 정본(알림 상태 우선 -> 최근 갱신 순)을 따른다', (
      tester,
    ) async {
      late List<MenuItem> items;
      await _pumpProbe(
        tester,
        [stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}')],
        (ref) {
          items = tray_native.buildTrayMenuItems(
            ref,
            // 입력 순서를 뒤집어 넣는다 — 정렬을 안 거치면 이 순서가 그대로 남는다.
            unseen: const [
              SessionViewDto(
                key: 'codex:old-done',
                state: 'done',
                project: '/repo/b',
                updatedAt: 100,
              ),
              SessionViewDto(
                key: 'claude_code:alert',
                state: 'waiting_input',
                project: '/repo/a',
                updatedAt: 1,
              ),
            ],
          );
        },
      );

      final keys = items
          .where((item) => traySeenSessionKey(item.key) != null)
          .map((item) => item.key)
          .toList();
      expect(keys, [
        'tray_seen_claude_code:alert',
        'tray_seen_codex:old-done',
      ], reason: '알림 대상 상태(waiting_input)가 updatedAt보다 먼저 온다');
    });

    testWidgets('미확인 세션이 아무리 많아도 상한 없이 전부 나열한다', (tester) async {
      late List<MenuItem> items;
      await _pumpProbe(
        tester,
        [stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}')],
        (ref) {
          items = tray_native.buildTrayMenuItems(
            ref,
            unseen: [
              for (var i = 0; i < 12; i += 1)
                SessionViewDto(
                  key: 'codex:s$i',
                  state: 'done',
                  project: '/repo/p$i',
                  updatedAt: i,
                ),
            ],
          );
        },
      );

      final sessionItems = items
          .where((item) => traySeenSessionKey(item.key) != null)
          .toList();
      expect(sessionItems, hasLength(12), reason: '항목 상한이 없다 — 전부 나열한다');
      expect(
        items
            .where((item) => item.type != 'separator')
            .any((item) => item.disabled),
        isFalse,
        reason:
            '"…외 N개" 같은 비활성 꼬리 항목은 더 이상 달지 않는다 '
            '(구분선은 태생이 disabled라 제외한다)',
      );
    });
  });

  group('traySeenSessionKey (세션 항목 동적 키 되짚기)', () {
    test('tray_seen_ 접두어 키에서 세션 키를 되짚고, 그 밖의 키는 null이다', () {
      expect(
        traySeenSessionKey(traySeenMenuKey('claude_code:abc')),
        'claude_code:abc',
      );
      // 세션 키에 `:`가 있어도 접두어 매칭만으로 안전하게 되짚는다.
      expect(traySeenSessionKey('tray_seen_codex:x:y'), 'codex:x:y');
      expect(traySeenSessionKey(TrayCommand.open.menuItemKey), isNull);
      expect(traySeenSessionKey(TrayCommand.quit.menuItemKey), isNull);
      expect(
        traySeenSessionKey('tray_seen_'),
        isNull,
        reason: '빈 세션 키는 없는 것으로 친다',
      );
      expect(traySeenSessionKey(null), isNull);
    });
  });

  group('TrayMenu (미확인 목록 변화, TASK TRAY-unseen-menu)', () {
    testWidgets('대기열의 A 메뉴가 B 전환 뒤 설치돼도 옛 세션을 선택하지 않는다', (tester) async {
      final firstApply = Completer<void>();
      final calls = <List<MenuItem>>[];
      late WidgetRef capturedRef;
      await _pumpProbe(tester, [
        tray_native.trayMenuApplyFnProvider.overrideWithValue((items) async {
          calls.add(items);
          if (calls.length == 1) await firstApply.future;
        }),
        stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
      ], (ref) => capturedRef = ref);
      SessionViewDto? selected;
      final menu = tray_native.TrayMenu(
        capturedRef,
        onSessionSelected: (session) async => selected = session,
      );
      final before = menu.apply(muted: true, muteUntil: 1, serverRevision: 0);
      await tester.pump();
      final queued = menu.apply(
        muted: false,
        muteUntil: null,
        serverRevision: 0,
        unseen: const [
          SessionViewDto(
            key: 'codex:old',
            state: 'waiting_input',
            project: '/work/old',
            host: 'mac',
            lastTransitionId: 10,
          ),
        ],
      );
      capturedRef
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: 'https://b.example.test', clientToken: null);
      firstApply.complete();
      await before;
      await queued;
      final oldRow = calls.last.singleWhere(
        (item) => item.key == traySeenMenuKey('codex:old'),
      );
      oldRow.onClick!(oldRow);
      await tester.pump();
      expect(selected, isNull);
    });

    testWidgets('미확인 목록의 내용이 바뀔 때만 setContextMenu 시임을 다시 부른다', (tester) async {
      final calls = <List<MenuItem>>[];
      late WidgetRef capturedRef;
      await _pumpProbe(tester, [
        tray_native.trayMenuApplyFnProvider.overrideWithValue((items) async {
          calls.add(items);
        }),
        stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
      ], (ref) => capturedRef = ref);

      final menu = tray_native.TrayMenu(capturedRef);
      const unseen = [
        SessionViewDto(
          key: 'claude_code:s1',
          state: 'waiting_input',
          project: '/repo/p',
        ),
      ];

      await menu.apply(
        muted: false,
        muteUntil: null,
        serverRevision: 0,
        unseen: unseen,
      );
      expect(calls, hasLength(1));
      expect(
        calls.last.map((item) => item.key),
        contains('tray_seen_claude_code:s1'),
        reason: '세션 항목이 최상위 메뉴에 직접 들어간다',
      );

      // 폴링이 내용은 같은 새 리스트 인스턴스를 들고 와도 채널을 건드리지
      // 않는다 — 레코드의 List는 참조 비교라 `==`로는 못 거르는 영역이다.
      await menu.apply(
        serverRevision: 0,
        muted: false,
        muteUntil: null,
        unseen: const [
          SessionViewDto(
            key: 'claude_code:s1',
            state: 'waiting_input',
            project: '/repo/p',
          ),
        ],
      );
      expect(calls, hasLength(1), reason: '목록 내용이 같으면 다시 그리지 않는다');

      // 세션이 하나 빠지면(읽음 처리됐다는 뜻) 세션 항목들이 통째로 사라진다.
      await menu.apply(muted: false, muteUntil: null, serverRevision: 0);
      expect(calls, hasLength(2));
      expect(
        calls.last.any((item) => traySeenSessionKey(item.key) != null),
        isFalse,
        reason: '미확인이 없으면 세션 항목 자체가 없다(구분선도 함께 접힌다)',
      );
    });
  });

  testWidgets('세션 항목은 표시 시점 스냅샷을 전달하고 먼저 읽음 처리하지 않는다', (tester) async {
    final controller = _RecordingSyncController();
    const displayed = SessionViewDto(
      key: 'codex:a',
      state: 'waiting_input',
      project: '/work/a',
      host: 'mac',
      lastTransitionId: 10,
    );
    SessionViewDto? selected;
    late List<MenuItem> items;
    await _pumpProbe(
      tester,
      [
        syncControllerProvider.overrideWith(() => controller),
        stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
      ],
      (ref) {
        items = tray_native.buildTrayMenuItems(
          ref,
          unseen: [displayed],
          onSessionSelected: (session) async {
            selected = session;
          },
        );
      },
    );
    final row = items.singleWhere(
      (item) => item.key == traySeenMenuKey(displayed.key),
    );
    row.onClick!(row);
    await tester.pumpAndSettle();
    expect(selected, same(displayed));
    expect(selected!.lastTransitionId, 10);
    expect(controller.seenKeys, isEmpty);
  });

  group('installTray 가드 (완료 기준 (6): 웹/비macOS는 no-op)', () {
    testWidgets('비macOS(traySupportedProvider=false)에서는 플러그인 채널을 건드리지 않는다', (
      tester,
    ) async {
      await _pumpProbe(tester, [
        tray_native.traySupportedProvider.overrideWithValue(false),
      ], (ref) => tray_native.installTray(ref));
      await tester.pumpAndSettle();

      expect(
        tray_native.debugTrayInstallAttempted,
        isFalse,
        reason: '가드에서 멈췄어야 한다 — trayManager 플러그인 채널까지 가면 안 된다',
      );
    });

    testWidgets('웹 거울(tray_web.dart)의 installTray는 항상 아무 것도 하지 않는다', (
      tester,
    ) async {
      // 웹 코드는 조건부 export로만 갈리므로 `flutter test`(VM)에서는
      // `tray.dart`를 통해 도달할 수 없다 — 이 파일을 직접 import해 진짜
      // 웹 경로 코드를 그대로 실행한다(dart:io를 전혀 쓰지 않으므로
      // VM에서 돌려도 안전하다).
      await _pumpProbe(tester, [], (ref) async {
        await tray_web.installTray(ref);
      });
      await tester.pumpAndSettle();
      // 예외 없이 끝났다는 것 자체가 계약이다 — 웹에는 확인할 부작용조차
      // 없다(트레이 자체가 존재하지 않는다).
      expect(tray_web.traySupportedProvider, isNotNull);
    });
  });
}
