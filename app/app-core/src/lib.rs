//! my_dashboard 도메인 코어.
//!
//! 이 크레이트는 UI/IPC에 의존하지 않는 순수 로직만 담는다 — 에러 타입
//! ([`error`]), 번역 카탈로그([`i18n`]), 런타임 기능 지원 여부([`capability`]),
//! 대시보드 세션 상태 어휘([`dashboard`])가 그 예다. `app-frb`(flutter_rust_bridge
//! cdylib)가 이 크레이트를 감싸 Flutter에 노출하지만, 이 크레이트 자체는
//! Flutter/FRB를 알지 못한다 — 나중에 다른 surface(예: CLI, 별도 HTTP host)가
//! 생기더라도 같은 로직을 그대로 재사용하기 위한 경계다.

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
                  lint를 만족할 필요가 없다 — Cargo의 [lints] 테이블은 cfg(test) \
                  조건부 오버라이드를 지원하지 않고(워크스페이스 lints를 상속한 \
                  크레이트는 로컬 [lints.rust]/[lints.clippy] 블록을 따로 둘 수 없다) \
                  이 크레이트 루트의 속성으로만 완화할 수 있다"
    )
)]

pub mod capability;
pub mod dashboard;
pub mod error;
pub mod i18n;
