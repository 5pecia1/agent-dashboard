/// 로케일 인지 번역 헬퍼.
///
/// 공통 번역은 Rust(app-core), 사용량 연동 번역은 usage_catalog.dart에 둔다.
/// 이 어댑터가 각 카탈로그를 Riverpod의 활성 로케일에 연결한다.
///
/// `t(ref, key, [args])`/`tRead(ref, key, [args])` 두 개로 나눈 이유:
///
/// - [t]는 `ref.watch(localeProvider)`로 활성 로케일을 **구독**한다.
///   그래서 사용자가 언어 설정을 바꾸는 순간 이 헬퍼를 호출한 위젯이
///   다시 그려진다 — `build` 메서드 안에서 화면에 실제로 남는 문구에는
///   항상 이 변형을 쓴다.
/// - `ref.watch`는 build 단계 전용 API라 콜백(메뉴 탭 핸들러, 다이얼로그
///   오픈, 키 입력 처리 등)에서 호출하면 에러이거나 최소한 의미가 없다.
///   [tRead]는 `ref.read`로 로케일을 딱 한 번만 읽는 변형이다 — 콜백이
///   만든 문자열(스낵바 문구, 메뉴 라벨 등)은 만들어지자마자 위젯 트리를
///   벗어나므로 구독이 없어도 안전하다.
///
/// [i18nTranslateOverride] / [i18nTranslateArgsOverride]는 위젯 테스트가
/// 네이티브 dylib이나 wasm 링크 없이도 돌 수 있도록 실제 FRB 호출을
/// 결정적인 가짜로 바꿔치기하는 시임이다 — capability_provider.dart와
/// 동일한 "`typedef → Provider<Fn> → 얇은 함수`" 3계층을 따른다.
library;

import 'package:flutter/widgets.dart' show Locale, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/rust/api/i18n.dart'
    as frb
    show translate, translateArgs;
import 'package:my_dashboard/src/rust/api/i18n.dart' show LocaleDto;
import 'package:my_dashboard/src/state/ui_lang_provider.dart'
    show uiLangControllerProvider;

/// Optional catalog owned by the application composition entrypoint.
typedef ExtensionTranslation = String? Function(String key, LocaleDto locale);
final extensionTranslationProvider = Provider<ExtensionTranslation>(
  (ref) =>
      (key, locale) => null,
);

/// 순수 `translate(key, locale) -> String` 함수 모양.
typedef I18nTranslate = String Function(String key, LocaleDto locale);

/// `translateArgs` 함수 모양 — 인자는 위치 기반 평행 배열(`argKeys`/
/// `argVals`)이다. FRB 호출 시그니처를 그대로 거울처럼 반영해서, 이
/// 간접 계층에서 `Map`이나 레코드 같은 별도 변환이 생기지 않게 한다.
typedef I18nTranslateArgs =
    String Function(
      String key,
      LocaleDto locale,
      List<String> argKeys,
      List<String> argVals,
    );

/// FRB `translate` 어댑터 — 테스트에서는 [overrideWithValue]로 교체한다.
final i18nTranslateOverride = Provider<I18nTranslate>(
  (ref) =>
      (key, locale) => frb.translate(key: key, locale: locale),
);

/// FRB `translateArgs` 어댑터.
final i18nTranslateArgsOverride = Provider<I18nTranslateArgs>(
  (ref) =>
      (key, locale, argKeys, argVals) => frb.translateArgs(
        key: key,
        locale: locale,
        argKeys: argKeys,
        argVals: argVals,
      ),
);

/// 시스템(OS/브라우저) 로케일을 읽는 함수 모양. [WidgetsBinding.platformDispatcher]
/// 의 `locale`은 데스크톱·모바일뿐 아니라 웹(브라우저 `navigator.language`)
/// 에서도 그대로 동작한다 — 플랫폼별 분기가 필요 없다. 시임으로 뽑은
/// 이유는 이 템플릿의 `typedef -> Provider<Fn> -> 얇은 함수` 3계층 관용
/// (`capability_provider.dart` 등과 같음) 그대로다: 위젯 테스트는 실제
/// OS/브라우저 로케일이 무엇이든 상관없이 [localeProvider] 하나만
/// override해서 en으로 고정한다(아래 문서 참고) — 이 `PlatformLocaleFn`
/// 자체를 override할 필요는 거의 없지만, 특정 시스템 로케일 값을 직접
/// 재현하고 싶은 테스트가 있다면 이 시임을 override하면 된다.
typedef PlatformLocaleFn = Locale Function();

Locale _platformLocale() => WidgetsBinding.instance.platformDispatcher.locale;

/// [PlatformLocaleFn] 어댑터.
final platformLocaleProvider = Provider<PlatformLocaleFn>(
  (ref) => _platformLocale,
);

/// 시스템 로케일의 `languageCode`를 [LocaleDto]로 매핑하는 순수 함수 —
/// 단위 테스트가 'ko'/'en'/그 밖(예: 'ja')의 경계를 위젯 없이 값만으로
/// 재현한다. 지원하는 로케일이 아니면 전부 English로 접는다 — `i18n.rs`의
/// 카탈로그 조회 폴백 체인(빠진 번역은 English로 대체)과 같은 태도다.
LocaleDto localeDtoForLanguageCode(String languageCode) =>
    languageCode == 'ko' ? LocaleDto.ko : LocaleDto.en;

/// 이 앱의 활성 로케일. 우선순위(서버 상태 계약):
///
///   1. [uiLangControllerProvider]가 `'ko'`/`'en'`이면 — 사용자가 직접
///      고른 UI 언어이므로 그 값을 그대로 쓴다. 시스템 로케일과 무관하다.
///   2. 그 값이 `'system'`(기본값, 또는 서버가 아직 정하지 않은 상태 —
///      `state/ui_lang_provider.dart`의 [UiLangController] 문서 참고)이면
///      — 이전과 같은 폴백 경로다: [platformLocaleProvider]가 읽은 시스템
///      로케일을 [localeDtoForLanguageCode]로 매핑한다(이전에는 [LocaleDto.en]
///      고정값이라 완성된 KO 카탈로그가 죽어 있었다 — 결함 수정).
///
/// 위젯 테스트는 대부분 en 문구를 전제로 골든·문자열을 고정해 뒀으므로,
/// 이 provider 자체를 `overrideWithValue(LocaleDto.en)`로 고정해 실행
/// 환경의 시스템 로케일이나 `uiLangControllerProvider` 상태와 무관하게
/// 만든다 — 그게 이 seam(provider 하나로 값을 통째로 갈아 끼우는 지점)의
/// 존재 이유다.
final localeProvider = Provider<LocaleDto>((ref) {
  final uiLang = ref.watch(uiLangControllerProvider);
  switch (uiLang) {
    case 'ko':
      return LocaleDto.ko;
    case 'en':
      return LocaleDto.en;
    default:
      return localeDtoForLanguageCode(
        ref.watch(platformLocaleProvider)().languageCode,
      );
  }
});

/// 활성 로케일로 `key`를 번역한다. `{name}` 같은 자리표시자를 채우려면
/// `args`를 넘긴다.
///
/// 재렌더링 근거: `ref.watch(localeProvider)`가 로케일이 바뀔 때 호출부
/// 위젯을 다시 그리게 만드는 지점이다 — 위 라이브러리 문서의 [t]/[tRead]
/// 구분 참고.
String t(WidgetRef ref, String key, [Map<String, String>? args]) {
  final locale = ref.watch(localeProvider);
  return _translate(ref, locale, key, args);
}

/// [t]의 이벤트 핸들러용 변형. build 단계 밖(콜백)에서는 반드시 이걸
/// 쓴다 — 이유는 위 라이브러리 문서 참고.
String tRead(WidgetRef ref, String key, [Map<String, String>? args]) {
  final locale = ref.read(localeProvider);
  return _translate(ref, locale, key, args);
}

String _translate(
  WidgetRef ref,
  LocaleDto locale,
  String key,
  Map<String, String>? args,
) {
  final extension = ref.read(extensionTranslationProvider)(key, locale);
  if (extension != null) {
    var result = extension;
    for (final entry in (args ?? const <String, String>{}).entries) {
      result = result.replaceAll('{${entry.key}}', entry.value);
    }
    return result;
  }
  if (args == null || args.isEmpty) {
    final translate = ref.read(i18nTranslateOverride);
    return translate(key, locale);
  }
  final translateArgs = ref.read(i18nTranslateArgsOverride);
  return translateArgs(
    key,
    locale,
    args.keys.toList(growable: false),
    args.values.toList(growable: false),
  );
}
