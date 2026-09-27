/// [SessionCard] 위젯 테스트 — B/F 표시 보강(마지막 신호 라벨)의 렌더링 경로.
///
/// 순수 판정(`showLastSignalLabelFor`)은
/// `unit_tests/session_card_pure_test.dart`가 값만으로 이미 닫았다 — 여기서는
/// 그 판정이 실제로 카드에 올바른 i18n 키를 그린다는 배선만 확인한다.
/// `i18nTranslateArgsOverride`를 `key`만 돌려주도록(인자 무시) 고정해
/// 두므로, `session.card.last_signal`처럼 인자가 있는 키도 그 키 이름
/// 그대로 화면에 남는다(sessions_page_test.dart와 같은 관용).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart' show SyncState;
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show isSessionStaleFnProvider, stateLabelKeyFnProvider;
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart' show kSessionCardGridExtent;
import 'package:my_dashboard/src/ui/widgets/session_card.dart';
import 'package:my_dashboard/src/ui/widgets/state_chip.dart' show StateChip;

class _FixedSyncController extends SyncController {
  _FixedSyncController(this._state);

  final SyncControllerState _state;

  @override
  SyncControllerState build() => _state;
}

Future<void> _pumpCard(WidgetTester tester, SessionViewDto session) =>
    tester.pumpWidget(
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
            () => _FixedSyncController(const SyncControllerState()),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: SessionCard(session: session)),
        ),
      ),
    );

void main() {
  group('SessionCard: 마지막 신호 라벨 (B/F 표시 보강)', () {
    testWidgets('working 카드는 상대 시간 대신 last_signal 라벨을 보여준다', (tester) async {
      const session = SessionViewDto(
        key: 'claude-code:s1',
        state: 'working',
        source: 'claude-code',
        sessionId: 's1',
        project: 'my-dashboard',
        host: 'dev-mac',
        lastOccurredAt: 5000,
        updatedAt: 5000,
      );
      await _pumpCard(tester, session);
      await tester.pump();

      expect(find.text('session.card.last_signal'), findsOneWidget);
      // 대체된 자리이므로 평범한 상대 시간 키는 같은 줄에 남지 않는다.
      expect(find.text('time.just_now'), findsNothing);
      expect(find.text('time.minutes_ago'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('working이 아닌 카드는 last_signal 라벨이 없다(평범한 상대 시간만)', (
      tester,
    ) async {
      const session = SessionViewDto(
        key: 'claude-code:s1',
        state: 'waiting_input',
        source: 'claude-code',
        sessionId: 's1',
        project: 'my-dashboard',
        host: 'dev-mac',
        lastOccurredAt: 5000,
        updatedAt: 5000,
      );
      await _pumpCard(tester, session);
      await tester.pump();

      expect(find.text('session.card.last_signal'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group(
    'SessionCard: last_signal은 서버 시계끼리만 비교한다 '
    '(Opus escalation 판정 E 리뷰 지적 medium 수정)',
    () {
      // 기본 _pumpCard의 i18nTranslateArgsOverride는 args를 버리고 키만
      // 돌려주므로(위 그룹) 'session.card.last_signal'의 {time} 인자 안쪽까지는
      // 못 본다 - 여기서는 그 인자값(내부 relativeTimeText가 고른 키)까지
      // 새어 나오도록 override를 바꿔서, 실제로 어느 시계 쌍을 비교했는지
      // 검증한다.
      Future<void> pumpWithVisibleArgs(
        WidgetTester tester,
        SessionViewDto session, {
        required int serverTimeMs,
      }) => tester.pumpWidget(
        ProviderScope(
          overrides: [
            i18nTranslateOverride.overrideWithValue((key, locale) => key),
            i18nTranslateArgsOverride.overrideWithValue(
              // last_signal의 {time} 인자만 그대로 드러낸다(그 인자 자체가
              // relativeTimeText의 결과 키다 - time.* 계열 호출은 이 override를
              // 타더라도 자기 키를 그대로 돌려줘 기존 관용과 같다).
              (key, locale, argKeys, argVals) =>
                  key == 'session.card.last_signal' ? argVals.join('|') : key,
            ),
            stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
            isSessionStaleFnProvider.overrideWithValue(
              ({required int now, required int updatedAt, required int staleMs}) =>
                  false,
            ),
            syncControllerProvider.overrideWith(
              () => _FixedSyncController(
                SyncControllerState(sync: SyncState(serverTime: serverTimeMs)),
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(body: SessionCard(session: session)),
          ),
        ),
      );

      testWidgets(
        '기기 시계·클라이언트 기계 시계(lastOccurredAt)가 서버 시계와 크게 어긋나도 '
        'last_signal은 서버 시계(lastProgressAt vs serverTime)만 본다',
        (tester) async {
          const session = SessionViewDto(
            key: 'claude-code:s1',
            state: 'working',
            source: 'claude-code',
            sessionId: 's1',
            project: 'my-dashboard',
            host: 'dev-mac',
            // 클라이언트 기계 시계: 실제 기기 시계(테스트 실행 시각, 2026년대의
            // 큰 epoch 값)보다 한참 과거인 값. 금지된 교차 시계 비교(기기
            // DateTime.now() 또는 이 값과의 비교)가 조금이라도 섞여 있으면
            // "며칠/몇 년 전"으로 튄다.
            lastOccurredAt: 5000,
            updatedAt: 5000,
            // 서버 시계: serverTime과 정확히 같다 - 방금 진척이 있었다는 뜻.
            lastProgressAt: 10_000,
          );
          await pumpWithVisibleArgs(tester, session, serverTimeMs: 10_000);
          await tester.pump();

          // 서버 시계끼리 비교하면 델타 0 -> "방금 전".
          expect(find.text('time.just_now'), findsOneWidget);
          // 기기 시계나 lastOccurredAt과 비교했다면 수십 년 델타 -> "N일 전"으로
          // 새어 나왔을 것이다 - 리뷰가 지적한 정확히 그 회귀.
          expect(find.text('time.days_ago'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  group('UserAck-impl: 칩 탭이 카드의 상세 이동 탭과 겹치지 않는다', () {
    testWidgets(
      'waiting_input 카드에서 상태 칩을 탭하면 ack API를 1회 부르고, '
      '카드 자체의 onTap(상세 이동)은 트리거되지 않는다',
      (tester) async {
        const session = SessionViewDto(
          key: 'claude-code:s1',
          state: 'waiting_input',
          source: 'claude-code',
          sessionId: 's1',
          project: 'my-dashboard',
          host: 'dev-mac',
          lastOccurredAt: 5000,
          updatedAt: 5000,
        );

        var apiCalls = 0;
        var navigated = 0;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              i18nTranslateOverride.overrideWithValue((key, locale) => key),
              i18nTranslateArgsOverride.overrideWithValue(
                (key, locale, argKeys, argVals) => key,
              ),
              stateLabelKeyFnProvider.overrideWithValue(
                (s) => 'label.${s.name}',
              ),
              isSessionStaleFnProvider.overrideWithValue(
                ({
                  required int now,
                  required int updatedAt,
                  required int staleMs,
                }) => false,
              ),
              // 실제 `ackSession` 본문이 돌게 하려고 `build()`만 고정한
              // `_FixedSyncController`를 쓴다 — `sync.sessions`에 이 카드의
              // 세션 키를 미리 채워 둬야 `ackSession`의 이른 반환(맵에 없는
              // 키 무시, sync_controller_test.dart 참고)에 걸리지 않는다.
              syncControllerProvider.overrideWith(
                () => _FixedSyncController(
                  const SyncControllerState(
                    sync: SyncState(
                      sessions: <String, SessionViewDto>{
                        'claude-code:s1': session,
                      },
                    ),
                  ),
                ),
              ),
              dashboardApiConfigProvider.overrideWithValue(
                DashboardApiConfig(baseUrl: Uri.parse('https://example.test')),
              ),
              httpSendProvider.overrideWithValue((ApiRequest request) async {
                apiCalls++;
                return const ApiResponse(
                  statusCode: 200,
                  body: '{"ok":true,"state":"working","transition_id":1}',
                );
              }),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              home: Scaffold(
                body: SessionCard(
                  session: session,
                  onTap: () => navigated++,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.byType(StateChip));
        await tester.pump();

        expect(
          navigated,
          0,
          reason: '칩 탭은 중첩된 제스처 감지기가 먼저 받아 카드의 상세 이동 onTap까지 '
              '번지면 안 된다',
        );
        expect(apiCalls, 1, reason: '칩 탭이 ackSession -> api.ack()을 정확히 1회 불러야 한다');
        expect(tester.takeException(), isNull);
      },
    );
  });

  group(
    'SessionCard: 배지 줄 Wrap 최악 3줄이 그리드 칸 높이 안에 들어간다 '
    '(검증 리뷰 지적 medium 수정 — narrow_width_test.dart는 i18n 키를 그대로 '
    '에코해 실제 라벨 길이를 못 본다)',
    () {
      // sessions_page.dart의 kSessionCardGridExtent 문서 코멘트가 설명하는
      // 실측(177/203/223)과 같은 en 라벨 - i18n.rs의 실제 문구를 그대로
      // 옮긴다(드리프트 시 이 테스트가 먼저 깨진다).
      String realEn(String key, dynamic locale) => switch (key) {
        'state.waiting_input' => 'Waiting for input',
        'session.card.stale_badge' => 'Stale',
        'session.source.claude_code' => 'Claude Code',
        _ => key,
      };

      testWidgets(
        'state=waiting_input + stale 배지(최악의 3줄 조합)가 kSessionCardGridExtent로 '
        '높이를 강제해도 오버플로를 내지 않는다',
        (tester) async {
          const longMessage =
              'Running the full test suite now, this may take a couple of '
              'minutes before the results are ready to review in detail.';
          final session = SessionViewDto(
            key: 'claude-code:s1',
            state: 'waiting_input',
            source: 'claude-code',
            sessionId: 's1',
            project: 'my-dashboard',
            host: 'dev-mac',
            lastOccurredAt: 5000,
            updatedAt: 5000,
            stale: true,
            lastMessage: longMessage,
          );

          for (final width in [320.0, 300.0, 290.0, 260.0]) {
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  i18nTranslateOverride.overrideWithValue(realEn),
                  i18nTranslateArgsOverride.overrideWithValue(
                    (key, locale, argKeys, argVals) => realEn(key, locale),
                  ),
                  stateLabelKeyFnProvider.overrideWithValue(
                    (s) => 'state.${s.name == 'waitingInput' ? 'waiting_input' : s.name}',
                  ),
                  isSessionStaleFnProvider.overrideWithValue(
                    ({
                      required int now,
                      required int updatedAt,
                      required int staleMs,
                    }) => false,
                  ),
                  syncControllerProvider.overrideWith(
                    () => _FixedSyncController(const SyncControllerState()),
                  ),
                ],
                child: MaterialApp(
                  theme: AppTheme.light(),
                  home: Scaffold(
                    body: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: width,
                        height: kSessionCardGridExtent,
                        child: SessionCard(session: session),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            expect(
              tester.takeException(),
              isNull,
              reason: 'width=$width에서 kSessionCardGridExtent가 최악 3줄 배지를 못 담았다',
            );
          }
        },
      );
    },
  );
}
