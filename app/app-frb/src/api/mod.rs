//! flutter_rust_bridge API 표면.
//!
//! Dart가 호출할 함수를 여기(또는 여기서 갈라져 나온 하위 모듈)에 추가한다.
//! `flutter_rust_bridge_codegen`이 이 모듈을 읽어(`rust_input: crate::api`)
//! `frb_generated.rs`와 Dart 바인딩을 만들어낸다 — `mise run frb:codegen`으로
//! 재생성한다.
//!
//! 하위 모듈 하나가 Dart 파일 하나가 된다:
//!
//! | 이 모듈 | 생성되는 Dart | 감싸는 Flutter 파일 |
//! |---|---|---|
//! | [`capability`] | `lib/src/rust/api/capability.dart` | `lib/src/state/capability_provider.dart` |
//! | [`i18n`] | `lib/src/rust/api/i18n.dart` | `lib/src/i18n/t.dart` |
//! | [`dashboard`] | `lib/src/rust/api/dashboard.dart` | (아직 없음 — 세션 목록 화면 트랙에서 추가) |
//!
//! 이 표의 오른쪽 두 열은 codegen을 돌려야 생긴다 — 여기 함수·타입 이름을
//! 바꾸면 Flutter 쪽 시임/어댑터의 typedef도 함께 고쳐야 한다.
//!
//! `greet`는 브리지 배선이 Rust → codegen → Dart까지 끝까지 이어지는지
//! 확인하기 위한 자리표시자다. 실제 기능이 생기면 지운다.

pub mod capability;
pub mod dashboard;
pub mod i18n;

/// FFI 배선 확인용 자리표시자 함수 — 실제 기능이 추가되면 지운다.
#[flutter_rust_bridge::frb(sync)]
#[must_use]
pub fn greet(name: String) -> String {
    format!("Hello, {name}!")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn greet는_이름을_인사말에_그대로_넣는다() {
        assert_eq!(greet("my_dashboard".to_owned()), "Hello, my_dashboard!");
    }
}
