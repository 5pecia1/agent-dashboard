/// `resident_mode_native.dart`의 웹 거울 — 항상 no-op이다.
///
/// 브라우저 탭에는 "창을 닫아도 백그라운드 유지"라는 개념 자체가 없다
/// (탭을 닫으면 페이지는 사라지고, 그 뒤의 알림은 서비스 워커가 맡는다 —
/// `web/push_sw.js`). 그래서 설정 화면도 웹에서는 이 토글을 그리지 않는다
/// ([hasResidentToggleHost]가 false다).
///
/// 이 파일이 따로 필요한 이유는 `local_notifications_web.dart`와 같다 —
/// 없으면 조건부 import가 `dart:io`를 쓰는 네이티브 구현을 웹 컴파일
/// 타깃까지 끌고 들어가 빌드가 깨진다.
library;

/// 웹에는 상주 토글이 없다.
bool get hasResidentToggleHost => false;

/// no-op. 밀어 넣을 네이티브 쪽이 없다.
Future<void> applyResidentMode(bool enabled) async {}

/// no-op. 웹에는 숨길 앱 창 개념이 없다.
Future<void> hideResidentWindow() async {}
