//! surface 중립 기능 지원 여부(capability) 조회.
//!
//! 같은 코어가 데스크톱(네이티브 링크)과 web/PWA(wasm)에서 함께 도는데,
//! 기능마다 필요한 실행 호스트가 다르다 — 일부는 wasm 런타임에 존재하지
//! 않는 OS 호스트가 필요하고(전역 단축키 등록, 네이티브 창 제어, 로컬
//! 알림 등), 반대로 일부는 브라우저 API에만 있어 네이티브 데스크톱에는
//! 없다(Web Push 구독 등). 그 차이를 화면 코드가 `kIsWeb` 같은
//! 플랫폼 분기로 직접 판단하면 판단 기준이 UI 쪽에 흩어진다 — 대신 코어가
//! capability id 하나로 답하고, 각 surface는 그 답만 읽는다.
//!
//! 실제 런타임 판정은 [`capability_for`]가 `cfg!(target_arch = "wasm32")`로
//! 하고, 판정 규칙 자체는 [`resolve`]/[`host_unsupported_reason`]에 순수
//! 함수로 분리돼 있다 — 그래야 네이티브 테스트 호스트에서도 wasm 분기를
//! 그대로 검증할 수 있다.

use phf::{Map, phf_map};

/// capability가 요구하는 실행 호스트.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum Host {
    /// 데스크톱/모바일 네이티브 링크에서만 동작한다(OS 플러그인 호출 등).
    Native,
    /// 브라우저(web/PWA, wasm32)에서만 동작한다(Web Push 구독 등 브라우저
    /// 전용 API).
    Web,
    /// 네이티브와 Web 양쪽에서 다 동작한다.
    Any,
}

/// 기능이 지원되지 않는 이유.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum UnsupportedReason {
    /// wasm(web/PWA) 런타임이라 이 기능이 요구하는 네이티브 OS 호스트가 없다.
    NoWasmHost,
    /// 네이티브(데스크톱/모바일) 런타임이라 이 기능이 요구하는 브라우저
    /// 호스트가 없다 — [`Host::Web`] 기능을 네이티브에서 물었을 때다.
    NoBrowserHost,
    /// 플러그인 실행 경로가 없거나 실제 동작을 아직 확인하지 못했다.
    NotConfigured,
    /// 카탈로그([`CAPABILITIES`])에 없는 id다 — 대개 오타이거나, 기능을
    /// 제거하면서 호출부를 함께 지우지 않은 흔적이다.
    UnknownCapability,
}

/// 한 capability의 현재 런타임 지원 상태.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum Capability {
    /// 이 런타임에서 쓸 수 있다.
    Supported,
    /// 쓸 수 없다 — UI는 이 상태를 숨기지 말고 이유와 함께 드러낸다.
    Unsupported {
        /// 왜 못 쓰는지.
        reason: UnsupportedReason,
    },
}

/// 알려진 capability id → 요구 호스트.
///
/// 실제 기능이 생기면 여기에 행을 추가한다. 플러그인 실행 결과(초기화
/// 성공 여부 등)는 카탈로그가 아니라 호출자가 [`DesktopReadiness`]로
/// 전달한다 — 이 표는 "어떤 호스트가 필요한가"만 답한다.
static CAPABILITIES: Map<&'static str, Host> = phf_map! {
    "desktop.window_control"  => Host::Native,
    "desktop.global_hotkey"   => Host::Native,
    "notify.local"            => Host::Native,
    "notify.web_push"         => Host::Web,
};

/// Flutter 호스트가 실제 초기화·콜백 성공 후 전달하는 상태. 기본은 미지원이다.
#[derive(Debug, Default, Clone, Copy)]
pub struct DesktopReadiness {
    /// 창 플러그인 초기화와 창 조회가 성공했다.
    pub window_control: bool,
    /// 현재 등록된 자기 단축키에서 실제 콜백을 한 번 이상 받았다.
    pub global_hotkey: bool,
    /// T16: 최초 실행 1회 프로브(권한 요청 + 자기 테스트 알림)가
    /// flutter_local_notifications나 osascript 폴백 중 하나로 실제 알림을
    /// 띄울 수 있음을 확인했다. `window_control`/`global_hotkey`와 같은
    /// 자리 — 카탈로그에 host만 있고 실제 동작 확인은 호출자 책임이다.
    pub notify_local: bool,
}

/// 현재 빌드 타깃에서 `id` 기능을 쓸 수 있는지 조회한다.
#[must_use]
pub fn capability_for(id: &str) -> Capability {
    capability_with_readiness(id, DesktopReadiness::default())
}

/// OS 호스트가 소유하는 준비 상태를 사용하되 호스트 요구사항(Native/Web)은
/// 그대로 유지한다.
#[must_use]
pub fn capability_with_readiness(id: &str, readiness: DesktopReadiness) -> Capability {
    resolve(id, cfg!(target_arch = "wasm32"), readiness)
}

/// `host`가 요구하는 실행 환경과 실제 런타임(`is_wasm`)을 대조한다.
/// 지원되면 `None`, 아니면 그 이유. [`resolve`]와 분리해 둔 이유는 이
/// Host↔런타임 대조 규칙 자체를 카탈로그 조회 없이 전수(3×2) 테스트할 수
/// 있게 하려는 것이다.
const fn host_unsupported_reason(host: Host, is_wasm: bool) -> Option<UnsupportedReason> {
    match (host, is_wasm) {
        (Host::Native, true) => Some(UnsupportedReason::NoWasmHost),
        (Host::Web, false) => Some(UnsupportedReason::NoBrowserHost),
        (Host::Native, false) | (Host::Web, true) | (Host::Any, _) => None,
    }
}

/// [`capability_for`]의 순수 판정 규칙 — 런타임 감지를 인자로 받아 테스트가
/// 네이티브 호스트에서도 wasm 분기를 그대로 태울 수 있게 한다.
fn resolve(id: &str, is_wasm: bool, readiness: DesktopReadiness) -> Capability {
    let Some(host) = CAPABILITIES.get(id).copied() else {
        return Capability::Unsupported {
            reason: UnsupportedReason::UnknownCapability,
        };
    };
    if let Some(reason) = host_unsupported_reason(host, is_wasm) {
        return Capability::Unsupported { reason };
    }
    let configured = match id {
        "desktop.window_control" => readiness.window_control,
        "desktop.global_hotkey" => readiness.global_hotkey,
        // T16: 프로브가 끝나기 전에는 어느 백엔드로도 알림을 못 띄웠을 수
        // 있다 — window_control/global_hotkey와 같은 이유로 기본 지원
        // 처리(과거 동작)를 접고 실제 확인 결과를 요구한다.
        "notify.local" => readiness.notify_local,
        _ => true,
    };
    if !configured {
        return Capability::Unsupported {
            reason: UnsupportedReason::NotConfigured,
        };
    }
    Capability::Supported
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_불일치_사유는_host_종류별로_정확히_갈린다() {
        // Host × is_wasm 전수(3×2) — resolve가 아니라 이 판정 규칙 자체를
        // 카탈로그와 무관하게 직접 검증한다("Host별 resolve 분기").
        assert_eq!(host_unsupported_reason(Host::Native, false), None);
        assert_eq!(
            host_unsupported_reason(Host::Native, true),
            Some(UnsupportedReason::NoWasmHost)
        );
        assert_eq!(host_unsupported_reason(Host::Web, true), None);
        assert_eq!(
            host_unsupported_reason(Host::Web, false),
            Some(UnsupportedReason::NoBrowserHost)
        );
        assert_eq!(host_unsupported_reason(Host::Any, false), None);
        assert_eq!(host_unsupported_reason(Host::Any, true), None);
    }

    #[test]
    fn 연결하지_않은_데스크톱_기능은_지원으로_표시하지_않는다() {
        // T16: notify.local도 실제 확인(프로브) 전에는 window_control/
        // global_hotkey와 똑같이 미확인 상태다.
        for id in [
            "desktop.window_control",
            "desktop.global_hotkey",
            "notify.local",
        ] {
            assert_eq!(
                resolve(id, false, DesktopReadiness::default()),
                Capability::Unsupported {
                    reason: UnsupportedReason::NotConfigured,
                },
                "id={id}"
            );
        }
    }

    #[test]
    fn 실제_준비_상태만_해당_기능을_활성화한다() {
        let readiness = DesktopReadiness {
            window_control: true,
            global_hotkey: false,
            notify_local: false,
        };
        assert_eq!(
            resolve("desktop.window_control", false, readiness),
            Capability::Supported
        );
        assert_eq!(
            resolve("desktop.global_hotkey", false, readiness),
            Capability::Unsupported {
                reason: UnsupportedReason::NotConfigured
            }
        );
        assert_eq!(
            resolve("desktop.window_control", true, readiness),
            Capability::Unsupported {
                reason: UnsupportedReason::NoWasmHost
            }
        );
        assert_eq!(
            resolve(
                "desktop.global_hotkey",
                false,
                DesktopReadiness {
                    window_control: false,
                    global_hotkey: true,
                    notify_local: false,
                }
            ),
            Capability::Supported
        );
    }

    #[test]
    fn 프로브_결과만_notify_local을_활성화한다() {
        // desktop.window_control/global_hotkey와 같은 자리 — 다른 readiness
        // 필드가 무엇이든 notify_local 자신의 값만 이 id의 결과를 가른다.
        let probed_ok = DesktopReadiness {
            window_control: false,
            global_hotkey: false,
            notify_local: true,
        };
        assert_eq!(
            resolve("notify.local", false, probed_ok),
            Capability::Supported
        );
        assert_eq!(
            resolve("notify.local", true, probed_ok),
            Capability::Unsupported {
                reason: UnsupportedReason::NoWasmHost
            }
        );
        assert_eq!(
            resolve("notify.local", false, DesktopReadiness::default()),
            Capability::Unsupported {
                reason: UnsupportedReason::NotConfigured
            }
        );
    }

    #[test]
    fn wasm에서는_네이티브_호스트가_필요한_기능이_미지원이다() {
        assert_eq!(
            resolve(
                "desktop.global_hotkey",
                true,
                DesktopReadiness {
                    window_control: true,
                    global_hotkey: true,
                    notify_local: true,
                }
            ),
            Capability::Unsupported {
                reason: UnsupportedReason::NoWasmHost,
            }
        );
    }

    #[test]
    fn 웹_전용_푸시_기능은_브라우저에서만_지원된다() {
        assert_eq!(
            resolve("notify.web_push", true, DesktopReadiness::default()),
            Capability::Supported
        );
        assert_eq!(
            resolve("notify.web_push", false, DesktopReadiness::default()),
            Capability::Unsupported {
                reason: UnsupportedReason::NoBrowserHost
            }
        );
    }

    #[test]
    fn 카탈로그에_없는_id는_런타임과_무관하게_미지원이다() {
        let expected = Capability::Unsupported {
            reason: UnsupportedReason::UnknownCapability,
        };
        assert_eq!(
            resolve("no.such.capability", false, DesktopReadiness::default()),
            expected
        );
        assert_eq!(
            resolve("no.such.capability", true, DesktopReadiness::default()),
            expected
        );
    }
}
