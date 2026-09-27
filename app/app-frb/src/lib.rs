//! my_dashboard Flutter 프런트엔드용 flutter_rust_bridge cdylib.
//!
//! [`api`] 모듈이 Flutter가 실제로 호출하는 표면이다 — Dart에 새 함수를
//! 노출하려면 거기에 추가한다. 도메인 로직 자체는 여기 두지 않고
//! `app-core`에 있는 걸 그대로 가져다 쓴다 — 이 크레이트는 FFI 배선만
//! 책임진다.
//!
//! `frb_generated.rs`는 codegen 산출물이다. 초기화가 바인딩을 만들고,
//! verify는 격리된 복사본에서 재생성하여 drift를 검사한다.

#![cfg_attr(
    test,
    allow(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::get_unwrap,
        clippy::tests_outside_test_module,
        clippy::print_stdout,
        clippy::unreachable,
        clippy::string_add,
        clippy::manual_let_else,
        reason = "테스트는 unwrap/expect/panic을 관용적으로 쓰며 프로덕션 restriction \
                  lint를 만족할 필요가 없다"
    )
)]

pub mod api;

#[allow(
    unsafe_code,
    clippy::all,
    clippy::pedantic,
    clippy::nursery,
    clippy::restriction,
    clippy::cargo,
    reason = "Generated FRB code is checked by codegen drift, not handwritten lints"
)]
mod frb_generated;
