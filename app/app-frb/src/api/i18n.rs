//! 번역 조회의 FFI 표면.
//!
//! codegen이 이 모듈에서 `flutter_app/lib/src/rust/api/i18n.dart`를 만들고,
//! Flutter 쪽 `lib/src/i18n/t.dart`가 그 파일의 [`translate`]/[`translate_args`]/
//! [`LocaleDto`]를 감싼다 — 여기 이름이나 인자 순서를 바꾸면 그 어댑터의
//! typedef도 함께 고쳐야 한다.
//!
//! 카탈로그 자체는 이 크레이트에 없다. [`app_core::i18n`]이 단일 소스이고
//! 여기서는 로케일 표현만 브리지 타입으로 옮긴다.

use app_core::i18n::{self, Locale};

/// [`app_core::i18n::Locale`]의 브리지 표현.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocaleDto {
    /// English.
    En,
    /// 한국어.
    Ko,
}

impl From<LocaleDto> for Locale {
    fn from(locale: LocaleDto) -> Self {
        match locale {
            LocaleDto::En => Self::En,
            LocaleDto::Ko => Self::Ko,
        }
    }
}

/// `key`를 `locale`로 번역한다.
///
/// 카탈로그에 없는 키는 예외를 던지지 않고 눈에 띄는 표식(`???`)으로
/// 돌아온다 — 폴백 규칙은 [`app_core::i18n::t`] 문서 참고.
#[flutter_rust_bridge::frb(sync)]
#[must_use]
pub fn translate(key: String, locale: LocaleDto) -> String {
    i18n::t(locale.into(), &key).to_owned()
}

/// `key`를 번역한 뒤 `{name}` 자리표시자를 채운다.
///
/// 인자를 `Map` 대신 평행한 두 리스트(`arg_keys`/`arg_vals`)로 받는 이유:
/// 브리지 경계에서 맵 타입을 주고받으면 Dart↔Rust 양쪽에 변환 코드가
/// 생기는데, 이 호출의 인자 수는 한 자릿수라 그 비용이 이득보다 크다.
/// Dart 쪽 어댑터(`t.dart`)가 호출부의 `Map`을 이 두 리스트로 편다.
///
/// 길이가 다르면 짧은 쪽까지만 짝지어 쓴다 — 남는 항목은 무시되고, 채우지
/// 못한 자리표시자는 `{name}` 그대로 화면에 남아 누락이 드러난다.
#[flutter_rust_bridge::frb(sync)]
#[must_use]
pub fn translate_args(
    key: String,
    locale: LocaleDto,
    arg_keys: Vec<String>,
    arg_vals: Vec<String>,
) -> String {
    let args: Vec<(&str, &str)> = arg_keys
        .iter()
        .zip(arg_vals.iter())
        .map(|(name, value)| (name.as_str(), value.as_str()))
        .collect();
    i18n::t_args(locale.into(), &key, &args)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 로케일별로_다른_번역이_돌아온다() {
        assert_eq!(translate("action.save".to_owned(), LocaleDto::En), "Save");
        assert_eq!(translate("action.save".to_owned(), LocaleDto::Ko), "저장");
    }

    #[test]
    fn 없는_키는_표식으로_돌아온다() {
        assert_eq!(translate("no.such.key".to_owned(), LocaleDto::En), "???");
    }

    #[test]
    fn 평행_리스트_인자가_자리표시자를_채운다() {
        assert_eq!(
            translate_args(
                "error.unknown_item".to_owned(),
                LocaleDto::En,
                vec!["id".to_owned()],
                vec!["42".to_owned()],
            ),
            "Unknown item: 42"
        );
    }

    #[test]
    fn 인자_리스트_길이가_다르면_짧은_쪽까지만_짝짓는다() {
        // 값이 비어 있으니 어떤 자리표시자도 채우지 못하고 그대로 남는다.
        assert_eq!(
            translate_args(
                "error.unknown_item".to_owned(),
                LocaleDto::En,
                vec!["id".to_owned()],
                vec![],
            ),
            "Unknown item: {id}"
        );
    }
}
