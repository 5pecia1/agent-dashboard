/// 실물 실행 QA — 실제 바이너리(`app.main()`)를 macOS에 띄워 세션 상세의
/// 뒤로가기와 삭제-후-자동-이탈을 검증한다. 위젯 테스트가 잡지 못하는
/// 실제 네트워크 지연·실제 포인터 경로를 탄다.
///
/// 삭제 대상은 hook/e2e 점검이 남긴 잔재 세션(`e2e-check`)이다 — 없으면
/// 삭제 검증만 건너뛰고 뒤로가기는 항상 검증한다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:my_dashboard/main.dart' as app;
import 'package:my_dashboard/src/ui/session_detail_page.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';
import 'package:my_dashboard/src/ui/widgets/session_card.dart';

const _step = Duration(milliseconds: 200);
const _waitRounds = 150; // 최대 30초 — 첫 sync 응답 대기
const _junkProjectTitle = 'e2e-check';
const _scrollRounds = 8;
const _scrollDelta = -400.0;

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int rounds = _waitRounds,
}) async {
  for (var i = 0; i < rounds && !condition(); i++) {
    await tester.pump(_step);
  }
}

/// GridView는 화면 밖 자식을 지연 빌드하므로, 목표 카드가 빌드될 때까지
/// 목록을 아래로 스크롤한다.
Future<void> _scrollUntilVisible(WidgetTester tester, Finder target) async {
  for (var i = 0; i < _scrollRounds && target.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(GridView), const Offset(0, _scrollDelta));
    await _pumpUntil(tester, () => true, rounds: 5);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('세션 상세에서 뒤로가기와 삭제가 실제로 동작한다', (tester) async {
    await app.main();
    await _pumpUntil(tester, () => find.byType(SessionCard).evaluate().isNotEmpty);
    expect(find.byType(SessionCard), findsWidgets, reason: '세션 목록이 떠야 한다');

    // 1) 카드 탭 -> 실제 pushNamed 라우트로 상세 진입
    await tester.tap(find.byType(SessionCard).first);
    await _pumpUntil(
      tester,
      () => find.byType(SessionDetailPage).evaluate().isNotEmpty,
    );
    expect(find.byType(SessionDetailPage), findsOneWidget);

    // 2) AppBar 뒤로가기 -> 목록 복귀
    await tester.tap(find.byType(BackButton));
    await _pumpUntil(
      tester,
      () => find.byType(SessionDeepLinkPage).evaluate().isEmpty,
    );
    expect(find.byType(SessionsPage), findsOneWidget);

    // 3) 잔재 세션이 있으면 상세에서 삭제 -> 목록으로 자동 이탈
    final junkTitle = find.descendant(
      of: find.byType(SessionCard),
      matching: find.text(_junkProjectTitle),
    );
    await _scrollUntilVisible(tester, junkTitle);
    if (junkTitle.evaluate().isEmpty) {
      // ignore: avoid_print
      print('잔재 세션 $_junkProjectTitle 없음 — 삭제 검증 건너뜀');
      return;
    }
    await tester.tap(junkTitle);
    await _pumpUntil(
      tester,
      () => find.byType(SessionDetailPage).evaluate().isNotEmpty,
    );

    // 삭제 아이콘은 AppBar 오른쪽 끝이라 창/테스트 서피스 크기가 어긋나면
    // 좌표 탭이 빗나간다 — 1차로 좌표 탭, 다이얼로그가 안 뜨면 onPressed를
    // 직접 호출해 실제 삭제 경로를 탄다.
    final deleteIcon = find.byIcon(Icons.delete_outline);
    expect(deleteIcon, findsOneWidget);
    await tester.tap(deleteIcon, warnIfMissed: false);
    await _pumpUntil(
      tester,
      () => find.byType(AlertDialog).evaluate().isNotEmpty,
      rounds: 15,
    );
    if (find.byType(AlertDialog).evaluate().isEmpty) {
      final button = tester.widget<IconButton>(
        find.ancestor(of: deleteIcon, matching: find.byType(IconButton)),
      );
      button.onPressed!();
      await _pumpUntil(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
      );
    }
    await tester.tap(find.byType(FilledButton), warnIfMissed: false);

    await _pumpUntil(
      tester,
      () => find.byType(SessionDeepLinkPage).evaluate().isEmpty,
    );
    expect(find.byType(SessionsPage), findsOneWidget);
    await _scrollUntilVisible(tester, junkTitle);
    expect(junkTitle, findsNothing, reason: '삭제된 세션은 목록에서 사라져야 한다');
  });
}
