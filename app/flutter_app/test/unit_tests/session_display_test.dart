import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/util/session_display.dart';

void main() {
  group('sessionDisplayName', () {
    test('제목이 있으면 "{프로젝트 basename} · {제목}"이다', () {
      expect(
        sessionDisplayName(
          project: '/repo/demo',
          fallback: 's1',
          displayTitle: '작업 A',
        ),
        'demo · 작업 A',
      );
    });

    test('제목이 없거나 공백이면 프로젝트 basename만 돌려준다', () {
      expect(
        sessionDisplayName(project: '/repo/demo', fallback: 's1'),
        'demo',
      );
      expect(
        sessionDisplayName(
          project: '/repo/demo',
          fallback: 's1',
          displayTitle: '',
        ),
        'demo',
      );
      expect(
        sessionDisplayName(
          project: '/repo/demo',
          fallback: 's1',
          displayTitle: '   ',
        ),
        'demo',
      );
    });

    test('제목이 프로젝트 이름과 같으면 "demo · demo"로 중복 표기하지 않는다', () {
      expect(
        sessionDisplayName(
          project: '/repo/demo',
          fallback: 's1',
          displayTitle: 'demo',
        ),
        'demo',
      );
    });

    test('프로젝트가 없거나 비면 fallback 자리에 제목을 얹는다', () {
      expect(
        sessionDisplayName(
          project: null,
          fallback: 'claude-code:s1',
          displayTitle: '작업 A',
        ),
        'claude-code:s1 · 작업 A',
      );
      expect(
        sessionDisplayName(project: '', fallback: 's1'),
        's1',
      );
    });

    test('제목 양끝 공백은 접는다(서버 정규화와 같은 빈 값 판정)', () {
      expect(
        sessionDisplayName(
          project: '/repo/demo',
          fallback: 's1',
          displayTitle: '  작업 A  ',
        ),
        'demo · 작업 A',
      );
    });

    test('Windows 구분자 경로도 basename만 취한다', () {
      expect(
        sessionDisplayName(
          project: r'C:\work\demo',
          fallback: 's1',
          displayTitle: 'fix',
        ),
        'demo · fix',
      );
    });
  });
}
