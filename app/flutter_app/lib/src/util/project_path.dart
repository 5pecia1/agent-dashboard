/// 프로젝트 경로에서 표시용 이름을 뽑는 순수 함수 하나.
///
/// 원래는 `ui/widgets/session_card.dart`(카드 제목) 안에 있었다. 알림 제목도
/// 같은 규칙을 쓰게 되면서(`state/notify_provider.dart`의 [payloadForAlert] —
/// 알림 제목도 프로젝트 이름으로 시작한다) ui와 state **두 계층**이
/// 함께 쓰는 값이 됐고, 어느 한쪽에 두면 다른 쪽이 그 계층을 import하게
/// 된다 — `util/mute_time.dart`가 정확히 같은 이유로 이 자리에 있다(그 파일
/// 문서 참고). 시계도 i18n도 Flutter도 만지지 않아 단위 테스트가 값만으로
/// 경계를 재현한다.
///
/// 기존 호출부(`ui/widgets/session_card.dart`, `ui/session_detail_page.dart`,
/// `ui/sessions_page.dart`, `ui/widgets/alert_banner.dart`)는 그대로 둔다 —
/// `session_card.dart`가 이 이름을 그대로 재노출(export)하므로 import 경로가
/// 바뀌지 않는다. 이 파일을 직접 import하는 쪽은 새로 쓰는 state 계층이다.
library;

/// `SessionViewDto.project`/`TransitionDto.project`(보통 절대경로)에서
/// 마지막 경로 세그먼트만 뽑는다 — 표시 규칙: 카드 제목과 알림 제목은
/// "현 디렉토리 이름"만 보이고, 전체 경로는 [Tooltip]과
/// `session_detail_page.dart`에서 본다. POSIX(`/`)와 Windows(`\`) 구분자 둘
/// 다 인식하고, 끝에 남는 구분자는 건너뛴다. 세그먼트가 하나도 안 남으면
/// (빈 문자열·구분자뿐인 경로) 원본을 그대로 돌려준다.
String projectBasename(String path) {
  var end = path.length;
  while (end > 0 && (path[end - 1] == '/' || path[end - 1] == '\\')) {
    end--;
  }
  var start = end;
  while (start > 0 && path[start - 1] != '/' && path[start - 1] != '\\') {
    start--;
  }
  final segment = path.substring(start, end);
  return segment.isEmpty ? path : segment;
}
