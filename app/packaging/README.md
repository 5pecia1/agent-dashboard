# 무서명 앱 패키징

초기화할 때 선택한 타깃만 패키징한다. 해당 OS에서 다음 명령을 실행한다.

```sh
mise run verify
python3 scripts/package.py linux --tag v0.1.0
python3 scripts/package.py macos --tag v0.1.0
python3 scripts/package.py windows --tag v0.1.0
python3 scripts/package.py web --tag v0.1.0
```

Linux는 deb와 AppImage, macOS는 dmg, Windows는 msix, web은 tar.gz를 만든다.
산출물과 SHA-256 목록은 `target/packages/<target>`에 놓인다. 같은 타깃의 이전 임시 산출물은
재생성할 때 교체한다. Linux에는 dpkg-deb와 appimagetool이 필요하며, release workflow가
고정된 appimagetool 1.9.1을 다운로드하고 SHA-256을 확인한다.

앱 SemVer의 정본은 `Cargo.toml`의 `workspace.package.version`이다.
`pubspec.yaml`의 빌드 번호 앞 버전과 같아야 하며, MSIX는 숫자 세 부분 뒤에 `.0`을 붙인다.
태그가 있으면 `v<앱 버전>`과 정확히 같아야 한다. `scripts/version_check.py`가 불일치를 거부한다.
플랫폼 자체의 `SOL_PLATFORM_VERSION`은 앱 버전과 별개다.

수동 릴리즈의 입력 태그는 이미 존재해야 한다. workflow는 그 태그의 커밋을 먼저 확정한 뒤,
검사와 모든 패키징 잡을 같은 SHA로 checkout한다. 선택한 OS의 모든 잡이 성공한 후에만
단일 게시 잡이 GitHub Release를 만든다. 입력 태그를 비우면 산출물만 보관하며 게시하지 않는다.
하나의 패키징 잡이라도 실패하거나 산출물이 비어 있으면 게시하지 않는다.

모든 패키지는 무서명이다. MSIX에는 `sign_msix: false`를 명시했다. 배포용 인증서, Windows
서명, macOS 서명·notarization은 각 소비 프로젝트가 별도 단계로 연결한다. 여기서 만드는
무서명 MSIX는 일반 사용자 설치 검증을 대신하지 않으며, 실제 배포에는 Windows의 서명 조건을
충족해야 한다. 실패한 게시를 재시도할 때는 같은 태그·SHA로 실행하고, 기존 자산과 체크섬을
대조한다. 여러 외부 패키지 레지스트리에 대한 원자적 게시를 보장하지 않는다.

검증은 OS별로 기록한다. 설치한 패키지에서 앱을 실행하고 Rust 인사말이 화면에 나타나는지
확인한다. web은 초기 부팅, 네트워크를 끈 뒤 재부팅, 새 버전으로 전환한 뒤 Rust 응답까지
확인한다. 다른 OS의 성공이나 `flutter build web` 성공으로 실행 검증을 대체하지 않는다.

참고: [공식 FRB 통합](https://cjycode.com/flutter_rust_bridge/manual/integrate/builtin),
[MSIX 옵션](https://pub.dev/packages/msix), [appimagetool](https://github.com/AppImage/appimagetool/releases/tag/1.9.1).

릴리즈 구현 정본은 중앙 `.github/workflows/device-app-release.yml` 재사용 workflow다.
앱 씨앗의 `release.yml`은 고정 플랫폼 태그를 호출하는 얇은 진입점이다. 제품 코드가 `app/`에
있는 조합형 repo는 루트 `.github/workflows/device-app-release.yml`에서 `app-directory: app`을
넘긴다. 중첩 디렉터리의 `.github/workflows`는 GitHub가 실행하지 않으므로 조합기가 루트 진입점을 만든다.

release의 Ubuntu 24.04 호스트 검사는 고정 Docker 이미지의 검사와 실행 환경이 다르다.
Linux 골든과 전체 조합 계약의 정본 검사는 소비 repo CI의 pinned Linux QA 이미지에서 수행한다.
release 호스트에서도 기존 골든을 비교하며, 차이가 나면 실패한다. 자동으로 갱신하거나 다른 OS
골든을 대신 쓰지 않는다.

AppImage runtime은 `packaging/appimage-runtimes.json`의 SHA256으로 확인한 파일을
`appimagetool --runtime-file`에 넘긴다. upstream의 `continuous` URL 내용이 바뀌면 다운로드는
실패하므로, 공식 asset을 다시 검토해 digest를 갱신해야 한다. 도구의 암묵적 runtime 다운로드를
허용하지 않는다. ARM Mac에서 x86_64 AppImage runtime을 검증할 때는 기본 실행 계층이
static-PIE ELF를 거부해 명시적 QEMU가 필요했던 기록이 있으며, 그 결과는 native Linux 결과와 구분한다.
