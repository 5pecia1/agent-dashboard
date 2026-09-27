/// 설정 화면의 UI 표시 언어 선택(시스템/한국어/English) 계약.
///
/// `setup_theme_mode_test.dart`와 같은 시임 override 관용을 따르되, 핵심
/// 갈림길 하나가 다르다 — 서버 동기화 계약: **낙관적 갱신이
/// 없다**(`dashboard_api.dart`의 `mute()` 전례). 그래서:
///
/// - 서버가 아직 없거나(`unconfigured`) `needsSetup`(401/403으로 멈춤)이면
///   `dashboardApiProvider`를 아예 건드리지 않고 로컬(설정 캐시·
///   `uiLangControllerProvider`)에만 곧바로 반영한다 — 이 예외가 없으면
///   언어를 잘못 골라 이 화면 자체를 못 읽게 된 사용자가 못 빠져나온다.
/// - 서버가 연결돼 있으면 선택은 곧장 화면에 반영되지 않는다 — POST 응답이
///   돌려준 **확인된 값**만 화면·컨트롤러·로컬 캐시에 반영된다. 실패하면
///   (되돌릴 낙관 상태가 애초에 없으므로) 값은 그대로 두고 에러만 보여준다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart' show LocaleDto;
import 'package:my_dashboard/src/state/capability_provider.dart' show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/resident_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/state/ui_lang_provider.dart' show uiLangControllerProvider;
import 'package:my_dashboard/src/ui/setup_page.dart';
// ignore: depend_on_referenced_packages
import 'package:riverpod/misc.dart' show Override;

String _translate(String key, LocaleDto locale) => key;

String _translateArgs(
  String key,
  LocaleDto locale,
  List<String> argKeys,
  List<String> argVals,
) => key;

void _useTallViewport(WidgetTester tester) {
  final view = tester.view
    ..devicePixelRatio = 1.0
    ..physicalSize = const Size(500, 2000);
  addTearDown(() {
    view
      ..resetDevicePixelRatio()
      ..resetPhysicalSize();
  });
}

class _MemoryConfigStore {
  _MemoryConfigStore([this.values = DashboardConfigValues.empty]);

  DashboardConfigValues values;
  final List<DashboardConfigValues> saves = <DashboardConfigValues>[];

  Future<DashboardConfigValues> load() async => values;

  Future<void> save(DashboardConfigValues next) async {
    values = next;
    saves.add(next);
  }
}

/// `phase: idle`(기본) — `needsSetup`은 항상 false다.
class _NoopSyncController extends SyncController {
  @override
  SyncControllerState build() => const SyncControllerState();
}

/// 401/403으로 멈춘 상태 — `needsSetup`이 true다. 서버 주소는 있어도(이미
/// 연결을 시도해 봤으니) 로그인이 막혀 POST를 쓸 수 없는 경우를 흉내낸다.
class _StoppedSyncController extends SyncController {
  @override
  SyncControllerState build() => const SyncControllerState(phase: SyncPhase.stopped);
}

class FileSystemExceptionStub implements Exception {
  const FileSystemExceptionStub();
}

// syncControllerProvider는 base가 아니라 매 테스트의 `extra`가 직접
// 넣는다 — `ProviderContainer`는 같은 provider를 두 번 override하면
// (base에서 한 번, needsSetup 테스트가 다시 한 번) 디버그 assert로 곧바로
// 죽는다(생성 시점 override는 마지막이 이긴다는 보장이 없다 — hot-reload용
// `updateOverrides`와 다르다). 그래서 이 helper는 `syncControllerProvider`를
// 기본값으로 깔지 않고, 호출자가 매번 `extra`에 정확히 하나만 넣는다.
Widget _setupPage({required List<Override> extra}) => ProviderScope(
  overrides: [
    i18nTranslateOverride.overrideWithValue(_translate),
    i18nTranslateArgsOverride.overrideWithValue(_translateArgs),
    isWasmRuntimeProvider.overrideWithValue(false),
    residentToggleSupportedProvider.overrideWithValue(false),
    ...extra,
  ],
  child: const MaterialApp(home: SetupPage()),
);

void main() {
  group('초기 표시', () {
    testWidgets('저장된 값이 없으면 시스템이 선택된 채로 열린다', (tester) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore();
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
            syncControllerProvider.overrideWith(_NoopSyncController.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('setup.section.language'), findsOneWidget);
      final segmented = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(segmented.selected, {'system'});
      // i18n-exempt 라벨(각 언어를 그 언어로 표기)이 그대로 문자열로 뜬다 —
      // 번역기를 거치지 않는다는 걸 이 두 텍스트의 존재로 확인한다.
      expect(find.text('한국어'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
    });

    testWidgets('저장된 값이 있으면 그 값으로 열린다', (tester) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore(const DashboardConfigValues(uiLang: 'ko'));
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
            syncControllerProvider.overrideWith(_NoopSyncController.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final segmented = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(segmented.selected, {'ko'});
    });
  });

  group('needsSetup/unconfigured — 로컬에만 반영(서버 동기화 계약 예외)', () {
    testWidgets('서버 주소가 아직 없으면(unconfigured) API 없이 즉시 로컬에 반영된다', (tester) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore(
        DashboardConfigValues.empty, // serverUrl == null
      );
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
            dashboardConfigValuesProvider.overrideWithValue(DashboardConfigValues.empty),
            syncControllerProvider.overrideWith(_NoopSyncController.new),
            // dashboardApiConfigProvider/httpSendProvider를 일부러
            // override하지 않는다 — unconfigured 분기는 `dashboardApiProvider`를
            // 절대 읽으면 안 되고(읽으면 override 없는 provider라 곧바로
            // StateError로 죽는다), 이 테스트가 초록이면 그 자체로 "API를
            // 안 건드렸다"는 증거다.
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('한국어'));
      await tester.pumpAndSettle();

      expect(store.saves, hasLength(1));
      expect(store.saves.single.uiLang, 'ko');
      final segmented = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(segmented.selected, {'ko'});
      expect(
        tester.container().read(uiLangControllerProvider),
        'ko',
        reason: 'uiLangControllerProvider도 같은 값으로 즉시 따라간다',
      );
    });

    testWidgets('서버 주소는 있어도 needsSetup(401/403으로 멈춤)이면 역시 로컬에만 반영된다', (tester) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore(
        const DashboardConfigValues(serverUrl: 'https://a.test'),
      );
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
            dashboardConfigValuesProvider.overrideWithValue(
              const DashboardConfigValues(serverUrl: 'https://a.test'),
            ),
            syncControllerProvider.overrideWith(_StoppedSyncController.new),
            // 여기서도 dashboardApiConfigProvider/httpSendProvider는
            // override하지 않는다 — needsSetup이면 서버 주소가 있어도 POST를
            // 시도해선 안 된다.
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();

      expect(store.saves, hasLength(1));
      expect(store.saves.single.uiLang, 'en');
      final segmented = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(segmented.selected, {'en'});
    });

    testWidgets('로컬 저장 자체가 실패해도 선택은 그대로 두고 에러만 보여준다(되돌릴 낙관 상태가 없다)', (
      tester,
    ) async {
      _useTallViewport(tester);
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(() async => DashboardConfigValues.empty),
            configSaveFnProvider.overrideWithValue(
              (_) async => throw const FileSystemExceptionStub(),
            ),
            dashboardConfigValuesProvider.overrideWithValue(DashboardConfigValues.empty),
            syncControllerProvider.overrideWith(_NoopSyncController.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('한국어'));
      await tester.pumpAndSettle();

      final segmented = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(
        segmented.selected,
        {'ko'},
        reason:
            '테마 모드와 달리 되돌리지 않는다 — 이 경로는 애초에 낙관적 갱신이 '
            '아니라 로컬이 정본인 값을 곧바로 쓴 것이다',
      );
      expect(find.text('setup.ui_lang_error'), findsOneWidget);
    });
  });

  group('서버가 연결된 상태 — 확인된 값만 반영(낙관적 갱신 없음, mute() 전례)', () {
    testWidgets(
      '선택은 곧장 반영되지 않고, 서버가 돌려준 확인된 값(요청과 달라도)이 화면·캐시·컨트롤러에 반영된다',
      (tester) async {
        _useTallViewport(tester);
        final store = _MemoryConfigStore(
          const DashboardConfigValues(serverUrl: 'https://a.test', uiLang: 'en'),
        );
        final seenRequests = <ApiRequest>[];
        await tester.pumpWidget(
          _setupPage(
            extra: [
              configLoadFnProvider.overrideWithValue(store.load),
              configSaveFnProvider.overrideWithValue(store.save),
              dashboardConfigValuesProvider.overrideWithValue(
                const DashboardConfigValues(serverUrl: 'https://a.test', uiLang: 'en'),
              ),
              syncControllerProvider.overrideWith(_NoopSyncController.new),
              dashboardApiConfigProvider.overrideWithValue(
                DashboardApiConfig(baseUrl: Uri.parse('https://a.test')),
              ),
              httpSendProvider.overrideWithValue((request) async {
                seenRequests.add(request);
                // 서버는 사용자가 고른 'system'(→ null)이 아니라 'ko'를
                // 확인값으로 돌려준다 — 낙관적으로 'system'을 먼저 그려선
                // 안 되고, 최종 결과는 이 확인값이어야 한다는 게 이 테스트의
                // 요점이다.
                return const ApiResponse(statusCode: 200, body: '{"ui_lang":"ko"}');
              }),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('setup.ui_lang_system'));
        await tester.pumpAndSettle();

        expect(seenRequests, hasLength(1));
        expect(seenRequests.single.method, 'POST');
        expect(seenRequests.single.url.path, kUiLangPath);
        expect(
          seenRequests.single.body,
          '{"lang":null}',
          reason:
              "'system' 선택은 로컬 기기 사실이라 서버로는 null(지움)로 옮겨 적힌다. "
              '요청 키는 계약대로 lang이다 — ui_lang으로 보내면 서버가 키 부재 400으로 거절한다',
        );

        final segmented = tester.widget<SegmentedButton<String>>(
          find.byType(SegmentedButton<String>),
        );
        expect(segmented.selected, {'ko'}, reason: '확인된 값(ko)이 최종 상태다');
        expect(store.saves, hasLength(1));
        expect(store.saves.single.uiLang, 'ko');
        expect(tester.container().read(uiLangControllerProvider), 'ko');
      },
    );

    testWidgets(
      '서버는 확정했는데 로컬 캐시 저장이 실패해도 화면이 잠기지 않는다 '
      '(_busy가 풀리고, 확정값은 그대로 남는다)',
      (tester) async {
        // 리뷰 지적 high 회귀 가드: 이 분기가 `on DashboardApiException`만
        // 좁게 잡던 시절엔 `configPatchFn`의 디스크 예외가 새어 나가
        // `_busy`가 영원히 true로 굳었다 — `_busy`는 이 화면의 모든 버튼이
        // 공유하는 잠금이라 설정 화면 전체가 비활성이 됐다.
        _useTallViewport(tester);
        await tester.pumpWidget(
          _setupPage(
            extra: [
              configLoadFnProvider.overrideWithValue(
                () async => const DashboardConfigValues(serverUrl: 'https://a.test'),
              ),
              configSaveFnProvider.overrideWithValue(
                (_) async => throw const FileSystemExceptionStub(),
              ),
              dashboardConfigValuesProvider.overrideWithValue(
                const DashboardConfigValues(serverUrl: 'https://a.test'),
              ),
              syncControllerProvider.overrideWith(_NoopSyncController.new),
              dashboardApiConfigProvider.overrideWithValue(
                DashboardApiConfig(baseUrl: Uri.parse('https://a.test')),
              ),
              httpSendProvider.overrideWithValue(
                (request) async =>
                    const ApiResponse(statusCode: 200, body: '{"ui_lang":"ko"}'),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('한국어'));
        await tester.pumpAndSettle();

        final segmented = tester.widget<SegmentedButton<String>>(
          find.byType(SegmentedButton<String>),
        );
        expect(
          segmented.selected,
          {'ko'},
          reason: '서버가 확정한 값이라 캐시 저장이 실패해도 되돌리지 않는다',
        );
        expect(
          tester.container().read(uiLangControllerProvider),
          'ko',
          reason: '컨트롤러 반영은 디스크 쓰기보다 앞이라 캐시 실패와 무관하다',
        );
        expect(
          segmented.onSelectionChanged,
          isNotNull,
          reason: '_busy가 풀려야 세그먼트가 다시 눌린다 — 굳으면 화면 전체가 잠긴다',
        );
        expect(find.text('setup.ui_lang_error'), findsOneWidget);
      },
    );

    testWidgets('요청이 실패하면 선택은 그대로 남고 에러만 보여준다', (tester) async {
      _useTallViewport(tester);
      final store = _MemoryConfigStore(
        const DashboardConfigValues(serverUrl: 'https://a.test'),
      );
      var callCount = 0;
      await tester.pumpWidget(
        _setupPage(
          extra: [
            configLoadFnProvider.overrideWithValue(store.load),
            configSaveFnProvider.overrideWithValue(store.save),
            dashboardConfigValuesProvider.overrideWithValue(
              const DashboardConfigValues(serverUrl: 'https://a.test'),
            ),
            syncControllerProvider.overrideWith(_NoopSyncController.new),
            dashboardApiConfigProvider.overrideWithValue(
              DashboardApiConfig(baseUrl: Uri.parse('https://a.test')),
            ),
            httpSendProvider.overrideWithValue((request) async {
              callCount += 1;
              return const ApiResponse(statusCode: 500, body: '{"error":"boom"}');
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('한국어'));
      await tester.pumpAndSettle();

      expect(callCount, 1, reason: '실패해도 재시도 없이 정확히 1회만 부른다');
      final segmented = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(segmented.selected, {'system'}, reason: '낙관적으로 바뀐 적이 없으니 되돌릴 것도 없다 — 원래 값 그대로');
      expect(store.saves, isEmpty, reason: '로컬 캐시도 확인된 값이 없으면 손대지 않는다');
      expect(find.text('setup.ui_lang_error'), findsOneWidget);
    });
  });
}
