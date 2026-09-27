/// [StateChip] 위젯 테스트 — 완료 기준 (c)의 "6개 상태별 칩" 조각.
///
/// `SessionStateDto` 6종 각각이 서로 다른 라벨 텍스트로 렌더링되는지,
/// 그리고 [colorForSessionState]가 라이트/다크 토큰 양쪽에서 6개 서로
/// 다른 색을 돌려주는지를 값으로 확인한다.
///
/// `stateLabelKeyFnProvider`는 FRB를 태우지 않는 결정적 가짜로 갈아끼운다
/// (`t13_seams_boot_test.dart`와 같은 이유 — 네이티브 dylib/wasm 없이
/// 위젯 테스트가 떠야 한다).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart' show SessionStateDto, stateLabelKeyFnProvider;
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/widgets/state_chip.dart';

void main() {
  const states = SessionStateDto.values;

  for (final state in states) {
    testWidgets('StateChip: ${state.name} 상태가 자기 라벨 키로 렌더링된다', (
      tester,
    ) async {
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
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(body: StateChip(state: state)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('label.${state.name}'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test('colorForSessionState: 6개 상태 색이 라이트 토큰에서 전부 서로 다르다', () {
    final colors = states.map((s) => colorForSessionState(AppTokens.light, s)).toSet();
    expect(colors, hasLength(states.length));
  });

  test('colorForSessionState: 6개 상태 색이 다크 토큰에서 전부 서로 다르다', () {
    final colors = states.map((s) => colorForSessionState(AppTokens.dark, s)).toSet();
    expect(colors, hasLength(states.length));
  });

  test('sessionStateDtoFromCode가 정본 6개 코드를 각 상태로 옮기고, 알 수 없는 코드는 idle로 접는다', () {
    const table = {
      'idle': SessionStateDto.idle,
      'working': SessionStateDto.working,
      'waiting_input': SessionStateDto.waitingInput,
      'done': SessionStateDto.done,
      'ended': SessionStateDto.ended,
      'stalled': SessionStateDto.stalled,
    };
    for (final entry in table.entries) {
      expect(sessionStateDtoFromCode(entry.key), entry.value);
    }
    expect(sessionStateDtoFromCode('bogus'), SessionStateDto.idle);
  });

  group('UserAck-impl: onTap 게이팅(waiting_input만 탭 가능)', () {
    Future<void> pumpChip(
      WidgetTester tester, {
      required SessionStateDto state,
      required VoidCallback onTap,
    }) => tester.pumpWidget(
      ProviderScope(
        overrides: [
          i18nTranslateOverride.overrideWithValue((key, locale) => key),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, locale, argKeys, argVals) => key,
          ),
          stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: StateChip(state: state, onTap: onTap)),
        ),
      ),
    );

    testWidgets('waiting_input 칩을 탭하면 onTap이 호출된다', (tester) async {
      var tapped = 0;
      await pumpChip(
        tester,
        state: SessionStateDto.waitingInput,
        onTap: () => tapped++,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(StateChip));
      await tester.pump();

      expect(tapped, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'waiting_input 칩은 툴팁으로 session.card.ack_tooltip 키를 노출한다',
      (tester) async {
        await pumpChip(
          tester,
          state: SessionStateDto.waitingInput,
          onTap: () {},
        );
        await tester.pumpAndSettle();

        final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
        expect(tooltip.message, 'session.card.ack_tooltip');
      },
    );

    for (final state in SessionStateDto.values.where(
      (s) => s != SessionStateDto.waitingInput,
    )) {
      testWidgets(
        '${state.name} 칩은 onTap이 주어져도 탭해도 호출되지 않는다(이중 방어)',
        (tester) async {
          var tapped = 0;
          await pumpChip(tester, state: state, onTap: () => tapped++);
          await tester.pumpAndSettle();

          // 비대화형이면 Tooltip/GestureDetector로 감싸지 않는다 — 예전과
          // 같은 `Semantics(child: chip)` 모양 그대로여야 한다.
          expect(find.byType(Tooltip), findsNothing);

          await tester.tap(find.byType(StateChip));
          await tester.pump();

          expect(tapped, 0, reason: 'waiting_input이 아니면 onTap을 받아도 무시해야 한다');
          expect(tester.takeException(), isNull);
        },
      );
    }
  });
}
