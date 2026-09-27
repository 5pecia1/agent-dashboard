/// 세션 상태 배지 — `contracts/dashboard-protocol.v1.json`의 `states.enum`
/// 6종을 색·라벨로 표시하는 유일한 위젯.
///
/// 색은 항상 [AppTokensX.tokens]의 상태별 6개 토큰만 읽는다(hex 리터럴은
/// `theme/app_tokens.dart`에만 있다 — `quality_check.py theme`). 라벨은
/// [stateLabelKeyFnProvider]가 돌려주는 i18n 키를 [t]로 옮긴다 — 이 위젯은
/// 상태 이름 문자열을 직접 화면에 박지 않는다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';

/// [sessionStateDtoFromCode]는 이제 `state/dashboard_provider.dart`(FRB
/// 어댑터)에 산다 — 알림 제목(`state/notify_provider.dart`)이 같은 매핑을
/// 쓰게 되면서 state 계층이 이 위젯 파일을 import해야 하는 역방향 의존이
/// 생겼기 때문이다(그 파일 문서 참고). 이 칩이 그 이름의 역사적 출처라
/// 기존 import 경로(`state_chip.dart`)를 그대로 살려 두기 위해 재노출한다 —
/// 화면 계층 호출부(`session_card.dart`, `session_detail_page.dart`,
/// `catchup_panel.dart`)와 그 테스트는 한 줄도 바뀌지 않는다.
export 'package:my_dashboard/src/state/dashboard_provider.dart'
    show sessionStateDtoFromCode;

/// [state]에 대응하는 배지 색 토큰. 이 함수 하나만 [AppTokens]의 상태별
/// 6개 필드를 참조한다 — 다른 위젯은 이 함수를 거친다.
Color colorForSessionState(AppTokens tokens, SessionStateDto state) =>
    switch (state) {
      SessionStateDto.idle => tokens.stateIdle,
      SessionStateDto.working => tokens.stateWorking,
      SessionStateDto.waitingInput => tokens.stateWaitingInput,
      SessionStateDto.done => tokens.stateDone,
      SessionStateDto.ended => tokens.stateEnded,
      SessionStateDto.stalled => tokens.stateStalled,
    };

/// 상태 배지 하나. `SessionStateDto` 6종 전부를 이 위젯 하나로 표시한다.
///
/// UserAck-impl: [onTap]이 있고 [state]가 [SessionStateDto.waitingInput]일
/// 때만 탭 가능해진다 — 그 밖의 다섯 상태는 [onTap]을 받아도(호출자가 실수로
/// 넘겨도) 예전처럼 비대화형으로 남는다(이중 방어, `session_card.dart`가
/// 이미 state로 한 번 걸러 넘긴다).
class StateChip extends ConsumerWidget {
  const StateChip({super.key, required this.state, this.onTap});

  final SessionStateDto state;

  /// waiting_input 칩을 탭했을 때 부를 콜백. 이 위젯은 낙관 갱신·API
  /// 호출을 직접 하지 않는다 — 그건 호출자(`session_card.dart` ->
  /// `SyncController.ackSession`)의 몫이고, 여기는 "탭했다"는 사실만
  /// 전달한다(위젯이 상태 관리 계층을 모르게 해 테스트가 쉽다).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labelKey = ref.read(stateLabelKeyFnProvider)(state);
    final label = t(ref, labelKey);
    final color = colorForSessionState(context.tokens, state);
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    final interactive = state == SessionStateDto.waitingInput && onTap != null;
    if (!interactive) {
      return Semantics(label: label, child: chip);
    }

    // 이 칩은 카드 본문 전체를 덮는 `InkWell`(상세 화면 이동, `session_card
    // .dart`) 안에 놓인다 — 그 위에 겹치는 탭 영역을 만들면서도 상세 이동을
    // 트리거하면 안 된다. 별도로 손대지 않아도 되는 이유: 중첩된 제스처
    // 감지기는 더 안쪽(구체적) 쪽이 바깥쪽보다 먼저 탭을 받는 것이
    // Flutter의 표준 동작이다(`ListTile` 안의 `Checkbox`/`IconButton`과 같은
    // 원리) — `behavior: opaque`만 줘서 칩의 투명한 배경(원 안쪽 여백)까지
    // 탭 영역에 포함시킨다. `session_card_test.dart`의 탭 테스트가 상세
    // 이동이 트리거되지 않는지까지 함께 검증한다.
    return Tooltip(
      message: t(ref, 'session.card.ack_tooltip'),
      child: Semantics(
        label: label,
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: chip,
        ),
      ),
    );
  }
}
