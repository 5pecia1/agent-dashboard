//! `AppError` — my_dashboard 코어의 공개, surface 중립 에러 타입.
//!
//! 각 surface는 이 enum을 자신의 네이티브 에러 형태로 사상(mapping)한다 —
//! 예를 들어 CLI surface라면 stderr + 종료 코드로, Flutter는 FRB DTO에 실어
//! Dart의 `Result`/예외로, 훗날 HTTP surface가 생기면 JSON body + status
//! 코드로. [`AppError::message`] / [`AppError::exit_code`]가 그 사상에 필요한
//! 최소 표면이다 — surface마다 `match`를 새로 쓰는 대신 이 두 메서드만
//! 호출하면 된다.

use thiserror::Error;

/// 앱 코어에서 발생할 수 있는 에러.
///
/// 메시지는 완결된 문장으로 쓰고, 가능하면 사용자가 다음에 무엇을 해야
/// 하는지 실행 힌트를 함께 담는다 — "다시 시도하세요" 같은 공허한 문구
/// 대신 구체적인 명령이나 확인할 위치를 안내한다.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum AppError {
    /// 사용자가 알 수 없는 항목 id를 지정했을 때.
    #[error(
        "알 수 없는 항목입니다: `{id}`. 사용 가능한 항목 목록은 `my_dashboard list`로 확인하세요."
    )]
    UnknownItem {
        /// 사용자가 지정한, 존재하지 않는 항목 id.
        id: String,
    },

    /// 입력값이 도메인 제약(형식, 범위 등)을 벗어났을 때.
    #[error("입력값이 올바르지 않습니다: {reason}. 값을 확인한 뒤 다시 입력하세요.")]
    InvalidInput {
        /// 어떤 제약을 왜 위반했는지 설명하는 사람이 읽는 문구.
        reason: String,
    },

    /// 하위 작업(파일 I/O, 외부 프로세스 등)이 실패했을 때 원인 메시지를
    /// 그대로 감싼다.
    #[error("작업을 완료하지 못했습니다: {message}")]
    OperationFailed {
        /// 하위 작업이 반환한 원인 메시지.
        message: String,
    },
}

impl AppError {
    /// 사람이 읽는 최종 메시지. surface가 그대로 stderr/토스트/Dart 예외
    /// 메시지 등에 노출해도 되는 완결된 문장이어야 한다.
    #[must_use]
    pub fn message(&self) -> String {
        self.to_string()
    }

    /// CLI류 surface가 프로세스 종료 코드로 쓸 값.
    ///
    /// 지금은 모든 variant가 같은 값(1)을 반환하지만, variant가 늘어나
    /// variant별로 다른 코드가 필요해지면 여기서만 분기하면 된다 — 호출부가
    /// 각 surface에서 매치 구문을 반복할 필요가 없다.
    #[must_use]
    pub const fn exit_code(&self) -> u8 {
        1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_item_에러_메시지는_안내_명령을_포함한다() {
        let err = AppError::UnknownItem { id: "foo".into() };
        assert!(err.message().contains("my_dashboard list"));
        assert!(err.message().contains("foo"));
    }

    #[test]
    fn invalid_input_에러_메시지는_이유를_포함한다() {
        let err = AppError::InvalidInput {
            reason: "빈 문자열은 허용되지 않습니다".into(),
        };
        assert!(err.message().contains("빈 문자열은 허용되지 않습니다"));
    }

    #[test]
    fn operation_failed_에러_메시지는_원인을_그대로_감싼다() {
        let err = AppError::OperationFailed {
            message: "디스크가 가득 찼습니다".into(),
        };
        assert_eq!(
            err.message(),
            "작업을 완료하지 못했습니다: 디스크가 가득 찼습니다"
        );
    }

    #[test]
    fn 모든_variant의_종료_코드는_1이다() {
        assert_eq!(AppError::UnknownItem { id: "x".into() }.exit_code(), 1);
        assert_eq!(AppError::InvalidInput { reason: "x".into() }.exit_code(), 1);
        assert_eq!(
            AppError::OperationFailed {
                message: "x".into()
            }
            .exit_code(),
            1
        );
    }
}
