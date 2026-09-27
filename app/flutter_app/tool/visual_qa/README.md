# tool/visual_qa/

골든 테스트(`test/widget_tests/goldens_test.dart`)는 Ahem 폴백 폰트로
렌더링된다 — 호스트 간 픽셀 결정성을 지키려는 의도적 선택이다. 그
대가로 한글 실제 글리프 렌더링(자모 조합, 폰트 fallback 체인)이나
말줄임(ellipsis) 처리처럼, 사람 눈으로만 판별되는 시각 회귀는 골든이
잡지 못한다.

골든이 못 잡는 시각 회귀를 사람 눈으로 직접 확인하는 별도 진입점을
여기 둔다. **`lib/`도 `test/`도 아니다** — 앱 코드도 자동화된 테스트도
아닌, `flutter run -t tool/visual_qa/<시나리오>_main.dart -d <device>`로
사람이 직접 띄워서 눈으로 확인하는 수동 QA 전용 진입점이다.

각 시나리오는 실제 위젯과 Provider override를 사용한다. 입력과 저장은
시나리오에 따라 격리하며, 네이티브 기능을 확인하는 진입점은 macOS 플러그인과
Rust 번들이 필요하다. 아래 명령은 `app/flutter_app`에서 실행한다.


## 트레이 작업 창 전환

```sh
mise exec -- flutter run -d macos -t tool/visual_qa/window_navigation_main.dart
```

실제 트레이와 macOS 창 조회·전환을 사용하되 서버 요청·개인 설정·연결 규칙·읽음 처리는 메모리로 격리한다. 손쉬운 사용 권한은 해당 실행 앱에 직접 허용해야 한다. 코드 서명이 바뀐 빌드에서는 설정의 기존 허용 표시와 실제 권한 상태가 다를 수 있으므로 다시 조회하여 확인한다.

1. VS Code 창 두 개를 열고 트레이의 미확인 항목을 선택한다. 앱 필터에서 Code를 고른 뒤 특정 창을 선택하고 제목 규칙을 저장한다.
2. 다른 에이전트의 항목을 선택해 같은 호스트·프로젝트의 규칙을 공유하는지 확인한다. `Native focus: focused`와 실제 앞에 나온 창을 함께 확인한다.
3. 미읽음 초기화 후 `5초 뒤 새 알림`을 누르고 트레이를 연다. 새 알림이 온 뒤 처음 표시한 항목을 눌러 `latest=30`, `seen=10`, `unread=true`가 유지되는지 확인한다.
4. 대상 창 최소화·앱 숨김·다른 Space·전체 화면, 선택 도중 창 종료, 권한 없음, 선택 취소를 확인한다. 전환 실패·취소에는 읽음 호출이 없어야 한다.
5. 실제 배포에는 기본 `lib/main.dart`를 다시 빌드한다. QA 진입점을 운영 설치본으로 남기지 않는다.

## macOS 배너에서 작업 창으로 이동

```sh
mise exec -- flutter run -d macos -t tool/visual_qa/notification_window_main.dart
```

다른 창을 기본 대상으로 쓰려면 실행·빌드 명령에 `--dart-define=QA_WINDOW_APP=com.microsoft.VSCode --dart-define='QA_WINDOW_TITLE=검증할 창의 정확한 제목'`을 추가한다.
이 옵션으로 지정한 기본 규칙은 같은 QA 번들을 종료 후 다시 실행해도 유지된다. 실제 창 제목을 소스에 저장하지 않는다.

이 진입점은 실제 macOS 로컬 배너와 창 조회·전환을 사용한다. 서버 요청은 차단하고 개인 설정·토큰을 읽지 않으며, 설정·규칙·읽음은 메모리에만 보관한다. 화면의 `network sends=0`과 `Blocked HTTP requests`를 함께 확인한다. 화면의 `알림 백엔드`가 `flutterLocalNotifications`여야 배너 클릭을 검사할 수 있다. `osascript`에는 클릭 콜백이 없다. 시작 전에 macOS 설정의 알림에서 해당 앱을 허용한다. 배너가 보이지 않으면 알림 표시 방식과 집중 모드를 확인하고, 이미 받은 알림은 알림 센터에서 찾는다. 백엔드나 알림 권한을 확인하지 못한 상태는 환경 미설정으로 기록한다.

같은 앱 ID의 운영 앱은 먼저 종료한다. QA 빌드가 코드 서명을 바꾸면 손쉬운 사용 설정의 허용 표시가 켜져 있어도 실제 조회는 `trusted=false`일 수 있다. macOS 설정에서 해당 QA 실행 앱의 권한을 사용자가 확인하고 다시 조회한다. 필요하면 기존 항목을 제거한 뒤 실제 실행 중인 번들을 다시 추가한다. 시스템이 인증을 요구하면 사용자가 승인해야 하며, 권한 저장소를 직접 수정하지 않는다.

1. VS Code에 QA 대상으로 쓸 창을 연다. 기본 규칙은 앱 `com.microsoft.VSCode`의 제목이 정확히 `Dashboard`인 창이다. 다른 제목을 사용할 때는 `연결 대상 확인·변경`에서 선택하고 메모리 규칙을 저장한다. 이 화면에 `my-dashboard`, `notification-qa.local`, `/visual-qa/my-dashboard`가 고정되어 있는지, 창 목록을 스크롤해도 대상이 보이는지 확인한다.
2. `가짜 동기화 목록에 세션 포함`을 끈 채 `배너 보내기 (전이 10)`를 누른다. 배너를 클릭해 선택한 작업 창이 앞으로 오고 `Native focus: focused`가 되는지 확인한다. 대시보드 세션 상세를 거치지 않아야 하며, `cachedSessions=0`에서도 `Seen`에 원본 상한 `2000000010`이 기록되어야 한다.
3. 읽음을 초기화하고 배너를 다시 보낸 뒤 `새 전이 30`을 누른다. 이전 배너를 클릭했을 때 `latest=2000000030`, `seen=2000000010`, `unread=true`가 남는지 확인한다. 최소화하거나 숨긴 대상은 복원된 실제 창과 `Native focus: focused`를 함께 확인한다. 선택 중 닫힌 창은 전환 실패를 안내해야 하며, 실패하거나 선택을 취소하면 `Seen` 기록이 추가되지 않아야 한다.
4. 종료 후 클릭은 **같은 QA 번들을 OS가 다시 실행하는 상태**에서 확인한다. `배너 보내기 → Cmd+Q 종료`를 누르고 앱을 완전히 종료한 뒤 알림 센터의 QA 배너를 클릭한다. 재실행된 QA 앱이 첫 프레임 이후 클릭을 처리하고 실제 대상 창으로 이동하는지 확인한다. 메모리 규칙은 종료하면 초기화되므로, 이 검사는 기본 `Dashboard` 규칙으로 수행하거나 재실행 후 나타나는 선택 화면에서 창을 고른다. 운영 설치본이 대신 열리면 QA 결과로 인정하지 않는다.
5. 설치 위치에서 Release QA를 확인해야 한다면 아래 백업 명령을 먼저 실행하고 출력된 경로를 보관한다. `app/flutter_app`에서 `mise exec -- flutter build macos --release -t tool/visual_qa/notification_window_main.dart`로 빌드하고, 앱을 종료한 뒤 산출물 `build/macos/Build/Products/Release/my_dashboard.app`을 `/Applications/my_dashboard.app`에 복사해 실행한다. 설치 위치·서명이 바뀐 뒤에는 접근성 권한을 다시 확인한다.

```sh
mkdir -p "$HOME/Library/Application Support/my-dashboard/backups"
notification_qa_backup="$(mktemp -d "$HOME/Library/Application Support/my-dashboard/backups/notification-qa.XXXXXX")"
ditto /Applications/my_dashboard.app "$notification_qa_backup/my_dashboard.app"
echo "$notification_qa_backup"
```

검사가 끝나면 QA 앱을 종료하고 저장소 루트에서 기본 `lib/main.dart`를 다시 빌드하고 실행한다. 운영 앱에서도 접근성 조회가 가능한지 확인한다. 이 명령은 현재 소스의 운영 빌드를 설치한다. 빌드가 실패해 이전 설치본으로 되돌려야 한다면, 실행 중인 앱을 종료하고 보관한 `notification_qa_backup`의 `my_dashboard.app`을 `/Applications`에 복원한다. 메모리 규칙은 운영 설정 파일에 저장되지 않는다.

```sh
cd app
mise run build
open flutter_app/build/macos/Build/Products/Release/my_dashboard.app
```

이미 받은 로컬 배너의 종료 후 클릭과, 앱이 종료된 동안 새 배너를 받는 APNs 동작은 별도 검사다. 이 진입점은 APNs를 등록하지 않는다. APNs 실물 검증에는 별도의 서명·entitlement·서버 Firebase 설정이 필요하며, 로컬 배너의 성공으로 대신할 수 없다. 전달과 읽음 경계는 [알림 클릭 처리](../../lib/src/ui/notification_click_actions.dart)와 [회귀 검사](../../test/widget_tests/notification_app_wiring_test.dart)에서 확인한다.
