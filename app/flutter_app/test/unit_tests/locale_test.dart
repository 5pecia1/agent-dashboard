/// `i18n/t.dart`의 [localeDtoForLanguageCode](순수 함수)와 [localeProvider]
/// (그 함수를 [platformLocaleProvider] 위에 얹은 파생값)를 닫는다.
///
/// 검증 지적(high): 이 매핑 함수를 호출·단언하는 테스트가 이전에 하나도
/// 없었다 — `localeProvider`를 다시 `LocaleDto.en` 고정값으로 되돌려도
/// 기존 테스트는 전부 green이었다(위젯 테스트는 `i18nTranslateOverride`로
/// 키를 그대로 돌려받아 로케일 값이 무의미해진다). 아래는 위젯 트리 없이
/// `ProviderContainer` + `platformLocaleProvider` override만으로 "시스템
/// 로케일이 실제로 결과에 반영된다"를 잠근다.
library;

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart' show LocaleDto;
import 'package:my_dashboard/src/state/ui_lang_provider.dart' show uiLangControllerProvider;

void main() {
  group('localeDtoForLanguageCode (순수 매핑)', () {
    test("'ko' -> LocaleDto.ko", () {
      expect(localeDtoForLanguageCode('ko'), LocaleDto.ko);
    });

    test("'en' -> LocaleDto.en", () {
      expect(localeDtoForLanguageCode('en'), LocaleDto.en);
    });

    test('지원하지 않는 코드는 전부 English로 접힌다', () {
      expect(localeDtoForLanguageCode('ja'), LocaleDto.en);
      expect(localeDtoForLanguageCode(''), LocaleDto.en);
      expect(
        localeDtoForLanguageCode('KO'),
        LocaleDto.en,
        reason: '대소문자 구분 — 정확히 lower ko만',
      );
    });
  });

  group('localeProvider (platformLocaleProvider 위 파생값)', () {
    test('platformLocaleProvider가 ko를 돌려주면 localeProvider도 ko다', () {
      final container = ProviderContainer(
        overrides: [
          platformLocaleProvider.overrideWithValue(() => const Locale('ko')),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(localeProvider), LocaleDto.ko);
    });

    test('platformLocaleProvider가 en(혹은 그 밖)을 돌려주면 localeProvider는 en이다', () {
      final container = ProviderContainer(
        overrides: [
          platformLocaleProvider.overrideWithValue(() => const Locale('en')),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(localeProvider), LocaleDto.en);
    });
  });

  group('localeProvider (uiLangControllerProvider 우선순위 — 서버 상태 계약)', () {
    test(
      "uiLangControllerProvider가 'ko'/'en'이면 platformLocaleProvider가 무엇을 "
      '돌려주든 그 값이 이긴다',
      () {
        final container = ProviderContainer(
          overrides: [
            // 플랫폼 로케일을 일부러 반대로 둔다 — 그런데도 uiLang 선택이
            // 이겨야 한다는 게 이 테스트의 요점이다.
            platformLocaleProvider.overrideWithValue(() => const Locale('en')),
          ],
        );
        addTearDown(container.dispose);

        container.read(uiLangControllerProvider.notifier).setUiLang('ko');
        expect(container.read(localeProvider), LocaleDto.ko);

        container.read(uiLangControllerProvider.notifier).setUiLang('en');
        expect(container.read(localeProvider), LocaleDto.en);
      },
    );

    test("uiLangControllerProvider가 기본값('system')이면 platformLocaleProvider로 내려간다", () {
      final container = ProviderContainer(
        overrides: [
          platformLocaleProvider.overrideWithValue(() => const Locale('ko')),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(uiLangControllerProvider),
        'system',
        reason: 'override 없이 기본값 그대로임을 이 테스트가 전제한다',
      );
      expect(container.read(localeProvider), LocaleDto.ko);
    });

    test("'system'을 다시 고르면 즉시 platformLocaleProvider로 되돌아간다", () {
      final container = ProviderContainer(
        overrides: [
          platformLocaleProvider.overrideWithValue(() => const Locale('ko')),
        ],
      );
      addTearDown(container.dispose);

      container.read(uiLangControllerProvider.notifier).setUiLang('en');
      expect(container.read(localeProvider), LocaleDto.en);

      container.read(uiLangControllerProvider.notifier).setUiLang('system');
      expect(container.read(localeProvider), LocaleDto.ko);
    });
  });
}
