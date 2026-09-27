//! capability 조회의 FFI 표면.
//!
//! codegen이 이 모듈에서 `flutter_app/lib/src/rust/api/capability.dart`를
//! 만들고, Flutter 쪽 `lib/src/state/capability_provider.dart`가 그 파일의
//! [`capability_for`]/[`CapabilityDto`]/[`UnsupportedReasonDto`]를 감싼다 —
//! 여기 이름을 바꾸면 그 시임의 typedef도 함께 고쳐야 한다.
//!
//! 코어 타입([`app_core::capability::Capability`])을 그대로 노출하지 않고
//! `*Dto` 타입으로 한 번 옮겨 담는 이유: 브리지에 실리는 타입은 Dart 표현이
//! 결정되는 공개 계약이라, 코어 도메인 타입이 내부 사정으로 바뀔 때 Dart
//! 쪽이 곧바로 깨지지 않도록 이 경계에서 끊는다. 대신 두 타입을 잇는
//! 변환은 아래 `From` impl 한 곳에만 둔다.

use app_core::capability::{Capability, UnsupportedReason};

/// [`app_core::capability::UnsupportedReason`]의 브리지 표현.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnsupportedReasonDto {
    /// wasm(web/PWA) 런타임이라 네이티브 OS 호스트가 없다.
    NoWasmHost,
    /// 네이티브(데스크톱/모바일) 런타임이라 브라우저 호스트가 없다 —
    /// [`app_core::capability::Host::Web`] 기능을 네이티브에서 물었을 때다.
    NoBrowserHost,
    /// 앱의 플러그인 실행 경로가 없거나 실제 동작이 아직 확인되지 않았다.
    NotConfigured,
    /// 카탈로그에 없는 capability id.
    UnknownCapability,
}

/// [`app_core::capability::Capability`]의 브리지 표현.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CapabilityDto {
    /// 이 런타임에서 쓸 수 있다.
    Supported,
    /// 쓸 수 없다.
    Unsupported {
        /// 왜 못 쓰는지.
        reason: UnsupportedReasonDto,
    },
}

impl From<UnsupportedReason> for UnsupportedReasonDto {
    fn from(reason: UnsupportedReason) -> Self {
        match reason {
            UnsupportedReason::NoWasmHost => Self::NoWasmHost,
            UnsupportedReason::NoBrowserHost => Self::NoBrowserHost,
            UnsupportedReason::NotConfigured => Self::NotConfigured,
            UnsupportedReason::UnknownCapability => Self::UnknownCapability,
        }
    }
}

impl From<Capability> for CapabilityDto {
    fn from(capability: Capability) -> Self {
        match capability {
            Capability::Supported => Self::Supported,
            Capability::Unsupported { reason } => Self::Unsupported {
                reason: reason.into(),
            },
        }
    }
}

/// 현재 런타임에서 `capability_id` 기능을 쓸 수 있는지 조회한다.
///
/// 동기 호출(`frb(sync)`)이라 Dart 쪽에서 `Future` 없이 위젯 `build`
/// 안에서 바로 부를 수 있다 — 조회가 정적 테이블 룩업 하나뿐이라 비동기
/// 왕복을 물릴 이유가 없다.
#[flutter_rust_bridge::frb(sync)]
#[must_use]
pub fn capability_for(
    capability_id: String,
    window_control_ready: bool,
    global_hotkey_ready: bool,
    notify_local_ready: bool,
) -> CapabilityDto {
    app_core::capability::capability_with_readiness(
        &capability_id,
        app_core::capability::DesktopReadiness {
            window_control: window_control_ready,
            global_hotkey: global_hotkey_ready,
            notify_local: notify_local_ready,
        },
    )
    .into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 준비된_데스크톱_기능은_지원으로_변환된다() {
        assert_eq!(
            capability_for("desktop.window_control".to_owned(), true, false, false),
            CapabilityDto::Supported
        );
    }

    #[test]
    fn 프로브_성공_전_notify_local은_미구성으로_변환된다() {
        assert_eq!(
            capability_for("notify.local".to_owned(), false, false, false),
            CapabilityDto::Unsupported {
                reason: UnsupportedReasonDto::NotConfigured,
            }
        );
        assert_eq!(
            capability_for("notify.local".to_owned(), false, false, true),
            CapabilityDto::Supported
        );
    }

    #[test]
    fn 알_수_없는_id는_미지원_사유와_함께_변환된다() {
        assert_eq!(
            capability_for("no.such.capability".to_owned(), true, true, true),
            CapabilityDto::Unsupported {
                reason: UnsupportedReasonDto::UnknownCapability,
            }
        );
    }

    #[test]
    fn 코어_미지원_사유가_dto로_그대로_옮겨진다() {
        let dto: CapabilityDto = Capability::Unsupported {
            reason: UnsupportedReason::NoWasmHost,
        }
        .into();
        assert_eq!(
            dto,
            CapabilityDto::Unsupported {
                reason: UnsupportedReasonDto::NoWasmHost,
            }
        );
    }

    #[test]
    fn 연결되지_않은_기능의_사유도_브리지에_전달된다() {
        let dto: CapabilityDto = Capability::Unsupported {
            reason: UnsupportedReason::NotConfigured,
        }
        .into();
        assert_eq!(
            dto,
            CapabilityDto::Unsupported {
                reason: UnsupportedReasonDto::NotConfigured,
            }
        );
    }

    #[test]
    fn 브라우저_호스트_미지원_사유도_dto로_그대로_옮겨진다() {
        let dto: CapabilityDto = Capability::Unsupported {
            reason: UnsupportedReason::NoBrowserHost,
        }
        .into();
        assert_eq!(
            dto,
            CapabilityDto::Unsupported {
                reason: UnsupportedReasonDto::NoBrowserHost,
            }
        );
    }

    #[test]
    fn 웹_전용_기능은_네이티브_호출에서_브라우저_미지원으로_변환된다() {
        assert_eq!(
            capability_for("notify.web_push".to_owned(), false, false, false),
            CapabilityDto::Unsupported {
                reason: UnsupportedReasonDto::NoBrowserHost,
            }
        );
    }
}
