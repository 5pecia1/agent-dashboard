/// `state/ui_lang_provider.dart`의 [UiLangController]/[parseUiLang]을
/// [ProviderContainer]만으로 닫는다 — `theme_mode_provider_test.dart`와
/// 같은 모양(build 기본값 + setUiLang 반영/구독자 통지)이다.
///
/// [installUiLangSync]는 `WidgetRef`(sealed class — 이 라이브러리 밖에서
/// 흉내 낼 수 없다)를 요구하므로, 그 배선(부팅 seed 순서·sync 응답 반영·
/// "서버 응답을 한 번도 못 받은 동안은 아무것도 하지 않는다" 가드·로컬 캐시
/// 되쓰기)은 실제 `SolApp`을 부팅하는 `widget_tests/app_wiring_test.dart`가
/// 진짜 `_AppHomeState.initState`를 태워 검증한다 — 이 파일은 순수 상태
/// 조각만 본다.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/state/ui_lang_provider.dart';

void main() {
  group('UiLangController', () {
    test('build()의 기본값은 system이다 — sync를 몰라도 죽지 않는다', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(uiLangControllerProvider), 'system');
    });

    test('setUiLang이 state를 그대로 반영하고, 구독자가 다시 그려진다', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final seen = <String>[];
      container.listen(
        uiLangControllerProvider,
        (previous, next) => seen.add(next),
        fireImmediately: true,
      );

      container.read(uiLangControllerProvider.notifier).setUiLang('ko');
      container.read(uiLangControllerProvider.notifier).setUiLang('en');

      expect(seen, ['system', 'ko', 'en']);
      expect(container.read(uiLangControllerProvider), 'en');
    });

    test('알 수 없는 값도 parseUiLang을 거쳐 system으로 접힌다(안전한 폴백)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(uiLangControllerProvider.notifier).setUiLang('ko');
      container.read(uiLangControllerProvider.notifier).setUiLang('fr');
      expect(container.read(uiLangControllerProvider), 'system');
    });
  });

  group('parseUiLang (순수 함수)', () {
    test("'ko'/'en'은 그대로, 그 밖은 전부 'system'", () {
      expect(parseUiLang('ko'), 'ko');
      expect(parseUiLang('en'), 'en');
      expect(parseUiLang('system'), 'system');
      expect(parseUiLang(null), 'system');
      expect(parseUiLang('fr'), 'system');
      expect(parseUiLang(''), 'system');
    });
  });
}
