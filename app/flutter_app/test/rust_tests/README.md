# test/rust_tests/

FRB(flutter_rust_bridge) 경계를 넘는 **계약**을 검증하는 Dart 테스트 자리다.

Rust 쪽 로직의 동작 자체(순수 함수 단위 테스트, 파싱 규칙 등)는 app-core의
Rust 테스트(`cargo test`)가 맡는다. 이 디렉터리에 두는 테스트는 그것과
층이 다르다 — "Dart가 그 로직을 FRB로 건네받을 때, DTO가 계약대로 (역)
직렬화되는가"만 본다. 예를 들면:

- 특정 크기 제한을 넘는 페이로드를 Rust 쪽에 보내면 어떤 예외 타입/코드로
  거부되는지가 Dart에서 본 그대로인지
- enum variant 이름이 Rust `#[frb]` 선언과 생성된 Dart enum 양쪽에서
  어긋나지 않는지
- freezed 유니온으로 노출된 Rust enum의 각 variant를 Dart 쪽 `switch`가
  전부 처리하는지(새 variant 추가 시 컴파일 에러로 잡히는지)

이 템플릿은 capability/i18n 두 시임 외에 도메인 로직이 없는 스캐폴드라
아직 비어 있다. 실제 프로젝트가 app-core에 새 FRB API를 추가하면, 그
경계 계약을 검증하는 테스트를 여기에 쌓는다.
