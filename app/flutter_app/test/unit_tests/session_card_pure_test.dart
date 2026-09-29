/// `ui/widgets/session_card.dart`의 순수 함수 둘 — [sourceLabelKeyFor],
/// [projectBasename] — 을 위젯을 펌프하지 않고 값만으로 닫는다.
///
/// 검증 지적(high): 이 두 함수는 배지/제목 결함 수정의 핵심인데도 실제로
/// 호출·단언하는 테스트가 하나도 없었다 — 'claude-code'를 다시
/// 'claude_code'로 되돌려도, 제목을 basename에서 전체 경로로 되돌려도
/// 기존 285개 테스트는 green이었다. 아래가 그 회귀를 잡는다.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show SessionStateDto;
import 'package:my_dashboard/src/ui/widgets/session_card.dart';

void main() {
  group('sourceLabelKeyFor', () {
    test('정본 값(하이픈, contracts/dashboard-protocol.v1.json)이 각자의 키로 매핑된다', () {
      expect(sourceLabelKeyFor('claude-code'), 'session.source.claude_code');
      expect(sourceLabelKeyFor('codex'), 'session.source.codex');
      expect(sourceLabelKeyFor('devin'), 'session.source.devin');
      expect(sourceLabelKeyFor('grok'), 'session.source.grok');
      expect(sourceLabelKeyFor('antigravity'), 'session.source.antigravity');
    });

    test('밑줄 변형(정본 밖 값)은 generic으로 접힌다 — 하이픈 매칭이 되돌아가면 이 테스트가 깨진다', () {
      expect(sourceLabelKeyFor('claude_code'), 'session.source.generic');
    });

    test('등록되지 않은 값·빈 문자열도 generic으로 접혀 화면이 죽지 않는다', () {
      expect(sourceLabelKeyFor('unknown-source'), 'session.source.generic');
      expect(sourceLabelKeyFor(''), 'session.source.generic');
    });
  });

  group('projectBasename', () {
    test('POSIX 절대경로에서 마지막 세그먼트만 남는다', () {
      expect(
        projectBasename('/Users/example/projects/my-dashboard'),
        'my-dashboard',
      );
    });

    test('Windows 구분자(\\)도 인식한다', () {
      expect(projectBasename(r'C:\Users\sol\my-project'), 'my-project');
    });

    test('끝에 남는 구분자는 건너뛴다', () {
      expect(projectBasename('/a/b/c/'), 'c');
      expect(projectBasename(r'C:\a\b\'), 'b');
    });

    test('세그먼트가 하나도 안 남으면(빈 문자열·구분자뿐) 원본을 그대로 돌려준다', () {
      expect(projectBasename(''), '');
      expect(projectBasename('/'), '/');
      expect(projectBasename('///'), '///');
    });

    test('구분자가 없는 단일 세그먼트는 그대로다', () {
      expect(projectBasename('my-dashboard'), 'my-dashboard');
    });
  });

  group('sessionIdAbbreviation', () {
    test('8자보다 길면 앞 8자만 자르고 # 접두를 붙인다', () {
      expect(
        sessionIdAbbreviation('very-long-session-identifier-that-keeps-going'),
        '#very-lon',
      );
    });

    test('8자 이하면 자르지 않고 있는 그대로 # 접두만 붙인다', () {
      expect(sessionIdAbbreviation('abcd'), '#abcd');
      expect(sessionIdAbbreviation('abcdefgh'), '#abcdefgh');
    });
  });

  // B/F 표시 보강: working 카드에만 "마지막 신호 N분 전" 라벨을 켠다.
  group('showLastSignalLabelFor', () {
    test('working이면 true', () {
      expect(showLastSignalLabelFor(SessionStateDto.working), isTrue);
    });

    test('working이 아니면(idle/waiting_input/done/ended/stalled) false', () {
      expect(showLastSignalLabelFor(SessionStateDto.idle), isFalse);
      expect(showLastSignalLabelFor(SessionStateDto.waitingInput), isFalse);
      expect(showLastSignalLabelFor(SessionStateDto.done), isFalse);
      expect(showLastSignalLabelFor(SessionStateDto.ended), isFalse);
      expect(showLastSignalLabelFor(SessionStateDto.stalled), isFalse);
    });
  });
}
