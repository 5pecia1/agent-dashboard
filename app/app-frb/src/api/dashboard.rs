//! 대시보드 세션 상태 어휘의 FFI 표면.
//!
//! codegen이 이 모듈에서 `flutter_app/lib/src/rust/api/dashboard.dart`를
//! 만든다. 이 T11 시점에는 이 모듈을 감싸는 Flutter 화면이 아직 없다 —
//! 세션 목록 화면이 생기는 트랙에서 `capability`/`i18n`과 같은 3계층
//! Provider 패턴으로 감싼다.
//!
//! [`app_core::dashboard`]가 단일 정본이다. 여기서는 그 타입을 `*Dto`로
//! 한 번 옮겨 담아 브리지에 실리는 Dart 표현을 코어 도메인 타입의 내부
//! 변경으로부터 끊어둔다(`capability`/`i18n` 모듈과 같은 이유).

use app_core::dashboard::{EventSource, SessionOrderKey, SessionState};

/// [`app_core::dashboard::SessionState`]의 브리지 표현.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionStateDto {
    /// 세션이 열려 있고 사람의 입력을 기다린다.
    Idle,
    /// 에이전트가 실행 중이다.
    Working,
    /// 질문·승인 대기.
    WaitingInput,
    /// 턴 실행을 마쳤다.
    Done,
    /// 세션이 끝났다.
    Ended,
    /// working이었는데 신호가 끊겼다(서버가 만드는 derived 상태).
    Stalled,
}

impl From<SessionState> for SessionStateDto {
    fn from(state: SessionState) -> Self {
        match state {
            SessionState::Idle => Self::Idle,
            SessionState::Working => Self::Working,
            SessionState::WaitingInput => Self::WaitingInput,
            SessionState::Done => Self::Done,
            SessionState::Ended => Self::Ended,
            SessionState::Stalled => Self::Stalled,
        }
    }
}

impl From<SessionStateDto> for SessionState {
    fn from(dto: SessionStateDto) -> Self {
        match dto {
            SessionStateDto::Idle => Self::Idle,
            SessionStateDto::Working => Self::Working,
            SessionStateDto::WaitingInput => Self::WaitingInput,
            SessionStateDto::Done => Self::Done,
            SessionStateDto::Ended => Self::Ended,
            SessionStateDto::Stalled => Self::Stalled,
        }
    }
}

/// [`app_core::dashboard::EventSource`]의 브리지 표현.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventSourceDto {
    /// Claude Code.
    ClaudeCode,
    /// Codex CLI.
    Codex,
    /// Devin CLI.
    Devin,
    /// 임의의 스크립트·CI가 직접 상태를 신고하는 통로.
    Generic,
}

impl From<EventSourceDto> for EventSource {
    fn from(dto: EventSourceDto) -> Self {
        match dto {
            EventSourceDto::ClaudeCode => Self::ClaudeCode,
            EventSourceDto::Codex => Self::Codex,
            EventSourceDto::Devin => Self::Devin,
            EventSourceDto::Generic => Self::Generic,
        }
    }
}

/// 화면 목록 정렬에 필요한 최소 필드의 브리지 표현.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SessionOrderKeyDto {
    /// 현재 세션 상태.
    pub state: SessionStateDto,
    /// 마지막 갱신 시각(epoch ms).
    pub updated_at: i64,
}

impl From<SessionOrderKeyDto> for SessionOrderKey {
    fn from(dto: SessionOrderKeyDto) -> Self {
        Self {
            state: dto.state.into(),
            updated_at: dto.updated_at,
        }
    }
}

impl From<SessionOrderKey> for SessionOrderKeyDto {
    fn from(key: SessionOrderKey) -> Self {
        Self {
            state: key.state.into(),
            updated_at: key.updated_at,
        }
    }
}

/// `(source, event)`가 어느 상태로 이어지는지 조회한다. 표에 없는 조합은
/// `None` — 상태를 바꾸지 않는다는 뜻이다.
#[flutter_rust_bridge::frb(sync)]
#[must_use]
pub fn state_for_event(source: EventSourceDto, event: String) -> Option<SessionStateDto> {
    app_core::dashboard::state_for_event(source.into(), &event).map(Into::into)
}

/// 상태 → i18n 키(`translate`/`translate_args`와 함께 쓴다).
#[flutter_rust_bridge::frb(sync)]
#[must_use]
pub fn state_label_key(state: SessionStateDto) -> String {
    app_core::dashboard::label_key(state.into()).to_owned()
}

/// `updated_at`부터 `now`까지 `stale_ms`를 초과해 지났는지 조회한다(전부
/// epoch ms).
#[flutter_rust_bridge::frb(sync)]
#[must_use]
pub fn is_session_stale(now: i64, updated_at: i64, stale_ms: i64) -> bool {
    app_core::dashboard::is_stale(now, updated_at, stale_ms)
}

/// `sessions`를 "alert 우선 → `updated_at` 내림차순"으로 안정 정렬해
/// 돌려준다.
#[flutter_rust_bridge::frb(sync)]
#[must_use]
pub fn sort_session_order(sessions: Vec<SessionOrderKeyDto>) -> Vec<SessionOrderKeyDto> {
    let mut core: Vec<SessionOrderKey> = sessions.into_iter().map(Into::into).collect();
    app_core::dashboard::sort_sessions(&mut core);
    core.into_iter().map(Into::into).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 이벤트_상태_조회가_dto로_옮겨진다() {
        assert_eq!(
            state_for_event(EventSourceDto::ClaudeCode, "SessionStart".to_owned()),
            Some(SessionStateDto::Idle)
        );
        assert_eq!(
            state_for_event(EventSourceDto::Generic, "anything".to_owned()),
            None
        );
    }

    #[test]
    fn 상태_라벨_키가_계약_형태로_돌아온다() {
        assert_eq!(
            state_label_key(SessionStateDto::WaitingInput),
            "state.waiting_input"
        );
    }

    #[test]
    fn stale_판정이_core_규칙과_같다() {
        assert!(!is_session_stale(1_000, 700, 300));
        assert!(is_session_stale(1_001, 700, 300));
    }

    #[test]
    fn 정렬이_alert_우선_updated_at_내림차순으로_dto에도_적용된다() {
        let input = vec![
            SessionOrderKeyDto {
                state: SessionStateDto::Idle,
                updated_at: 100,
            },
            SessionOrderKeyDto {
                state: SessionStateDto::Done,
                updated_at: 50,
            },
        ];
        let sorted = sort_session_order(input);
        let states: Vec<SessionStateDto> = sorted.iter().map(|s| s.state).collect();
        // `Done`은 2026-09-14(Sol 확정)부터 alert이 아니다 - 둘 다 non-alert라
        // updated_at 내림차순만 남고, Idle(100)이 Done(50)보다 앞선다.
        assert_eq!(states, vec![SessionStateDto::Idle, SessionStateDto::Done]);
    }
}
