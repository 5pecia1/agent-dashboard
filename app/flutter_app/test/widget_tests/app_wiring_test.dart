/// T-wire: 앱 셸 배선(홈 분기, 세션 상세 공유 라우트, `syncController`
/// 부팅) 자체를 검증한다. 개별 화면(`sessions_page_test.dart` 등)이 이미
/// 다루는 화면 내부 렌더링은 여기서 다시 다루지 않는다 — 이 파일이 보는
/// 건 오직 "배선이 맞물리는가"뿐이다.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/app.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart'
    show SessionViewDto, TransitionDto;
import 'package:my_dashboard/src/data/sync_reducer.dart' show SyncState;
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/routing/app_router.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart' show LocaleDto;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show isSessionStaleFnProvider, stateLabelKeyFnProvider;
import 'package:my_dashboard/src/state/notify_provider.dart'
    show NotifyPayload, localNotifyFnProvider;
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/state/ui_lang_provider.dart' show uiLangControllerProvider;
import 'package:my_dashboard/src/ui/session_detail_page.dart' show SessionDeepLinkPage;
import 'package:my_dashboard/src/ui/setup_page.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';

const _messages = {'app.title': 'My Dashboard'};

String _translate(String key, LocaleDto locale) => _messages[key] ?? key;

String _translateArgs(
  String key,
  LocaleDto locale,
  List<String> argKeys,
  List<String> argVals,
) => _messages[key] ?? key;

/// `build()`가 실제로 실행됐는지를 밖에서 관찰할 수 있게 플래그를 남기는
/// 가짜 컨트롤러 — "부팅 시점에 syncController를 읽어 깨운다"(완료 기준
/// 2)를 `ref.read`가 실제로 일어났는지로 직접 증명한다. Riverpod의
/// `NotifierProvider`는 지연 평가라 아무도 읽지 않으면 이 `build()` 자체가
/// 절대 돌지 않는다 — 이 테스트가 실패하면 그 지연 평가를 누가 뚫어주는
/// 배선이 빠졌다는 뜻이다.
///
/// `cursor: 0`을 준다 — 기본값(`cursor: null`)은 `SyncState.isFirstBoot`를
/// `true`로 남겨 `sessions_page.dart`가 `SessionsScreenPhase.loading`(무한
/// 회전 `CircularProgressIndicator`)으로 접힌다. 그 스피너는 절대 멈추지
/// 않는 애니메이션이라 `pumpAndSettle()`이 세션 목록 화면에 도달하는 모든
/// 테스트에서 타임아웃으로 죽는다 — 이 배선 테스트가 보려는 건 화면 내부
/// 렌더링이 아니라 라우팅/부팅 배선이므로, "첫 동기화는 이미 끝났고 활성
/// 세션은 없다"(empty, 정적 화면)로 고정해 그 문제를 피한다.
class _BootProbeController extends SyncController {
  static bool builtAtLeastOnce = false;

  /// 마지막으로 만들어진 인스턴스. TASK A-impl (4)(d)는 부팅된 앱 트리에
  /// 리스너가 실제로 붙었는지를 "여기로 sync 결과를 밀어 넣으면 알림 시임이
  /// 불리는가"로 증명한다 — 구독이 없으면 아무 일도 일어나지 않는다.
  static _BootProbeController? last;

  @override
  SyncControllerState build() {
    builtAtLeastOnce = true;
    last = this;
    return const SyncControllerState(sync: SyncState(cursor: 0));
  }

  /// sync 한 사이클이 알림 대상 전이를 물고 끝난 것과 같은 상태 전이.
  /// 리듀서 자체는 `unit_tests/sync_reducer_test.dart`가 닫으므로 여기서는
  /// 이미 계산된 큐를 그대로 얹는다.
  void emitPendingAlerts(List<TransitionDto> alerts) {
    state = state.copyWith(
      sync: state.sync.copyWith(
        cursor: alerts.isEmpty ? 0 : alerts.last.id,
        pendingAlerts: List<TransitionDto>.unmodifiable(alerts),
      ),
    );
  }
}

/// [installUiLangSync](`state/ui_lang_provider.dart`) 전용 컨트롤러.
/// `WidgetRef`는 sealed class라 그 함수를 `ProviderContainer` 레벨에서
/// 직접 흉내 낼 수 없으므로(`state_tests/ui_lang_provider_test.dart`
/// 문서 참고), 실제 `SolApp`을 부팅해 `_AppHomeState.initState`가 진짜
/// `WidgetRef`로 그 함수를 부르게 한 뒤 결과를
/// `tester.container().read(uiLangControllerProvider)`로 읽어 검증한다
/// (`flutter_riverpod`이 공개하는 `RiverpodWidgetTesterX.container()` 테스트
/// 헬퍼 — `provider_scope.dart` 참고).
///
/// `_BootProbeController`를 재사용하지 않는 이유: 그쪽은 다른 다수 테스트가
/// "`uiLang`은 항상 null로 시작한다"에 암묵적으로 기대는 공유 정적 상태라,
/// 여기서 생성 시점 초기값을 다르게 만드는 파라미터를 얹으면 그 테스트들과
/// 뒤섞인다 — 이 그룹만 쓰는 별도 클래스로 완전히 분리한다.
class _UiLangSyncController extends SyncController {
  _UiLangSyncController([this._initialUiLang, this._initialSynced = false]);

  /// 리스너가 붙기 *전에* 이미 서버가 값을 정해 둔 경합(부팅 스냅샷 자체에
  /// `ui_lang`이 실려 있는 경우)을 재현한다. 기본 null은
  /// `_BootProbeController`와 같은 "아직 아무 응답도 못 받았다" 모양이다.
  final String? _initialUiLang;

  /// "이 스냅샷은 이미 서버 응답 한 번을 반영한 것인가" — 부팅 스냅샷에
  /// `ui_lang`이 실려 있다는 말은 그 응답을 이미 받았다는 뜻이므로
  /// `lastSuccessAtMs`도 함께 서 있어야 한다(`sync_controller.dart`의
  /// `_afterSuccess`가 둘을 같은 쓰기에서 갱신한다).
  final bool _initialSynced;

  /// 마지막으로 만들어진 인스턴스 — `_BootProbeController.last`와 같은
  /// 자리·같은 이유(부팅 이후 sync 응답 도착을 흉내내려면 이미 만들어진
  /// 인스턴스에 상태를 밀어 넣어야 한다).
  static _UiLangSyncController? last;

  int _clock = 0;

  @override
  SyncControllerState build() {
    last = this;
    return SyncControllerState(
      sync: SyncState(cursor: 0, uiLang: _initialUiLang),
      lastSuccessAtMs: _initialSynced ? ++_clock : null,
    );
  }

  /// 서버 sync 응답이 `ui_lang`을 새로 실어 온 것과 같은 상태 전이 —
  /// `sync_reducer.dart`의 절대값 대입(`mute_until`/`hookSkew`와 같은
  /// 관용)을 그대로 흉내낸다. `lastSuccessAtMs`를 함께 올리는 것까지가
  /// `_afterSuccess`의 모양이다 — 그래야 "서버가 null이라고 답했다"가
  /// "아직 응답이 없다"와 구분된다(`ui_lang_provider.dart`의
  /// `syncUiLangListenable` 문서 참고).
  void setServerUiLang(String? value) {
    state = state.copyWith(
      sync: state.sync.copyWith(uiLang: value),
      lastSuccessAtMs: ++_clock,
    );
  }
}

/// [installUiLangSync]가 sync 확정값을 로컬 캐시에 되쓰는 걸 받아 적는 시임.
/// 기본 [configPatchFnProvider]는 Rust 브리지(`bridge.loadDashboardConfig`)를
/// 그대로 타므로 위젯 테스트에서는 쓸 수 없다.
class _ConfigPatchRecorder {
  _ConfigPatchRecorder([this.values = DashboardConfigValues.empty]);

  DashboardConfigValues values;
  final List<DashboardConfigValues> patches = <DashboardConfigValues>[];

  Future<void> call(
    DashboardConfigValues Function(DashboardConfigValues current) mutate,
  ) async {
    values = mutate(values);
    patches.add(values);
  }
}

/// 디스크 저장 실패(권한 등)를 흉내내는 예외 — `ConfigSaveFn` 계약의
/// "저장 실패는 예외"가 [configPatchFnProvider] 밖으로 나오는 모양 그대로다.
class _ConfigPatchFailure implements Exception {
  const _ConfigPatchFailure();
}

/// TASK ESC-nav 전용 고정 컨트롤러 — [_BootProbeController]와 달리 세션
/// 하나를 들고 있어야 세션 상세 라우트/삭제 다이얼로그를 실제로 띄울 수
/// 있다(순수 라우팅 배선만 보는 [_BootProbeController]를 오염시키지 않게
/// 따로 둔다).
class _EscNavController extends SyncController {
  _EscNavController(this._state);

  final SyncControllerState _state;

  @override
  SyncControllerState build() => _state;
}

const _escSession = SessionViewDto(
  key: 'claude-code:esc1',
  state: 'working',
  source: 'claude-code',
  sessionId: 'esc1',
  project: 'my-dashboard',
  host: 'dev-mac',
  updatedAt: 1000,
);

/// 이 그룹의 모든 테스트가 공유하는 override 목록 — 함수가 아니라 top-level
/// `final` 변수로 둔다. `Override`는 `flutter_riverpod`의 barrel export
/// 목록에 없고(정본은 `package:riverpod/misc.dart`), 그 이름을 여기 함수
/// 반환 타입으로 직접 적으면 `riverpod`을 (전이 의존성인데) 이 패키지의
/// 직접 의존성으로 추가하라는 `depend_on_referenced_packages` info가 뜬다
/// (`config_provider.dart` 문서에도 같은 이유가 적혀 있다). top-level
/// 변수는 초기화식에서 타입을 그대로 끌어와(상향 추론) `strict-inference`도
/// 만족하면서 그 타입 이름을 소스에 직접 적을 필요가 없다.
final _commonOverrides = [
  i18nTranslateOverride.overrideWithValue(_translate),
  i18nTranslateArgsOverride.overrideWithValue(_translateArgs),
  stateLabelKeyFnProvider.overrideWithValue((s) => 'label.${s.name}'),
  isSessionStaleFnProvider.overrideWithValue(
    ({required int now, required int updatedAt, required int staleMs}) => false,
  ),
  dashboardApiConfigProvider.overrideWithValue(
    DashboardApiConfig(baseUrl: Uri.parse('https://example.test')),
  ),
  httpSendProvider.overrideWithValue(
    (request) async => request.url.path == kEventsPath
        ? const ApiResponse(
            statusCode: 200,
            body: '{"events":[],"has_more":false,"next_before_id":null}',
          )
        : const ApiResponse(statusCode: 200, body: '{}'),
  ),
];

void main() {
  group('_AppHome 분기', () {
    testWidgets('서버 주소가 없으면 설정 화면으로 유도한다', (tester) async {
      _BootProbeController.builtAtLeastOnce = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._commonOverrides,
            dashboardConfigValuesProvider.overrideWithValue(
              DashboardConfigValues.empty,
            ),
            configLoadFnProvider.overrideWithValue(
              () async => DashboardConfigValues.empty,
            ),
            syncControllerProvider.overrideWith(_BootProbeController.new),
          ],
          child: const SolApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SetupPage), findsOneWidget);
      expect(find.byType(SessionsPage), findsNothing);
    });

    testWidgets('서버 주소가 이미 있으면 세션 목록으로 바로 간다', (tester) async {
      _BootProbeController.builtAtLeastOnce = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._commonOverrides,
            dashboardConfigValuesProvider.overrideWithValue(
              const DashboardConfigValues(serverUrl: 'https://example.test'),
            ),
            syncControllerProvider.overrideWith(_BootProbeController.new),
          ],
          child: const SolApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SessionsPage), findsOneWidget);
      expect(find.byType(SetupPage), findsNothing);
    });

    testWidgets('설정을 저장하면 재시작 없이도 세션 목록으로 넘어간다 (완료 기준 2)', (tester) async {
      _BootProbeController.builtAtLeastOnce = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._commonOverrides,
            dashboardConfigValuesProvider.overrideWithValue(
              DashboardConfigValues.empty,
            ),
            configLoadFnProvider.overrideWithValue(
              () async => DashboardConfigValues.empty,
            ),
            configSaveFnProvider.overrideWithValue((_) async {}),
            syncControllerProvider.overrideWith(_BootProbeController.new),
          ],
          child: const SolApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SetupPage), findsOneWidget);

      await tester.enterText(
        find.byType(TextField).first,
        'https://api.example.workers.dev',
      );
      await tester.tap(find.byType(FilledButton).first);
      await tester.pumpAndSettle();

      expect(find.byType(SessionsPage), findsOneWidget);
      expect(find.byType(SetupPage), findsNothing);
    });

    testWidgets('두 분기 모두 syncController를 부팅 시점에 읽어 깨운다 (완료 기준 2)', (
      tester,
    ) async {
      _BootProbeController.builtAtLeastOnce = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._commonOverrides,
            dashboardConfigValuesProvider.overrideWithValue(
              DashboardConfigValues.empty,
            ),
            configLoadFnProvider.overrideWithValue(
              () async => DashboardConfigValues.empty,
            ),
            syncControllerProvider.overrideWith(_BootProbeController.new),
          ],
          child: const SolApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Riverpod은 지연 평가다 — 이 값이 true라는 것 자체가 `_AppHomeState.
      // initState`가 `ref.read(syncControllerProvider)`로 build()를 실제로
      // 한 번 돌렸다는 증거다(설정 화면이 보이고 있어도 그렇다).
      expect(_BootProbeController.builtAtLeastOnce, isTrue);
    });

    testWidgets(
      'TASK A-impl (4)(d): 앱 트리를 부팅하면 alert 전이 -> 알림 리스너가 '
      '실제로 구독된다',
      (tester) async {
        _BootProbeController.builtAtLeastOnce = false;
        _BootProbeController.last = null;
        final sent = <NotifyPayload>[];

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ..._commonOverrides,
              dashboardConfigValuesProvider.overrideWithValue(
                const DashboardConfigValues(serverUrl: 'https://example.test'),
              ),
              syncControllerProvider.overrideWith(_BootProbeController.new),
              // 실제 OS 알림 대신 기록만 한다. `notifyProvider`의 나머지
              // 규칙(웹 no-op / APNs 소유권)은 override하지 않는다 — VM
              // 테스트에서 `isWasmRuntimeProvider`는 false,
              // `apnsRegisteredProvider`는 등록 전이라 false가 기본값이고,
              // 그게 곧 "이 앱이 배너의 주인"인 프로덕션 폴백 경로다.
              localNotifyFnProvider.overrideWithValue((
                NotifyPayload payload,
              ) async {
                sent.add(payload);
              }),
            ],
            child: const SolApp(),
          ),
        );
        await tester.pumpAndSettle();

        expect(sent, isEmpty, reason: '부팅만으로는 알릴 것이 없다');

        // 부팅 배선이 없으면 이 상태 전이는 아무 부작용도 내지 않는다 —
        // 이 테스트가 실패하면 `app.dart`에서 `installAlertNotifier` 호출이
        // 빠졌다는 뜻이다(이번 작업이 고친 그 결함 그대로).
        _BootProbeController.last!.emitPendingAlerts(<TransitionDto>[
          const TransitionDto(
            id: 1,
            sessionKey: 'claude_code:s1',
            toState: 'waiting_input',
            message: '입력을 기다립니다',
          ),
          const TransitionDto(
            id: 2,
            sessionKey: 'codex:s2',
            toState: 'done',
            message: '작업을 마쳤습니다',
          ),
        ]);
        await tester.pumpAndSettle();

        expect(sent, hasLength(2), reason: '전이당 정확히 한 번');
        expect(sent.map((NotifyPayload p) => p.sessionKey), <String>[
          'claude_code:s1',
          'codex:s2',
        ]);

        // 같은 큐가 다시 도착해도(폴링) 다시 알리지 않는다 — 워터마크는
        // 위젯이 아니라 Provider 그래프가 들고 있다.
        _BootProbeController.last!.emitPendingAlerts(<TransitionDto>[
          const TransitionDto(
            id: 1,
            sessionKey: 'claude_code:s1',
            toState: 'waiting_input',
            message: '입력을 기다립니다',
          ),
          const TransitionDto(
            id: 2,
            sessionKey: 'codex:s2',
            toState: 'done',
            message: '작업을 마쳤습니다',
          ),
        ]);
        await tester.pumpAndSettle();

        expect(sent, hasLength(2));
      },
    );
  });

  group('installUiLangSync 배선 (state/ui_lang_provider.dart)', () {
    testWidgets('첫 sync 응답이 아직 없는 동안은 로컬 seed값이 그대로 살아 있다', (tester) async {
      final patches = _ConfigPatchRecorder();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._commonOverrides,
            configPatchFnProvider.overrideWithValue(patches.call),
            dashboardConfigValuesProvider.overrideWithValue(
              const DashboardConfigValues(
                serverUrl: 'https://example.test',
                uiLang: 'ko',
              ),
            ),
            syncControllerProvider.overrideWith(_UiLangSyncController.new),
          ],
          child: const SolApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.container().read(uiLangControllerProvider),
        'ko',
        reason:
            'SyncState.uiLang은 디스크에 없어 부팅 직후엔 늘 null이고 '
            'lastSuccessAtMs도 아직 null이다 — 그 구간을 걸러내지 못하면 방금 '
            "seed한 값이 곧바로 'system'으로 덮인다",
      );
      expect(
        patches.patches,
        isEmpty,
        reason: '아직 서버가 아무 말도 안 했으니 캐시에 되쓸 것도 없다',
      );
    });

    testWidgets(
      '서버가 첫 응답에서 null(미설정)을 주면 부팅 seed(ko)가 system으로 수렴한다',
      (tester) async {
        // 리뷰 지적 high 회귀 가드: `uiLang`만 select하던 시절엔 null -> null이
        // 전이가 아니라 리스너가 아예 깨어나지 않았고, needsSetup 단계에서 고른
        // 로컬 'ko'가 서버 연결 이후에도 영구히 이겼다. [모델] 지시는 서버 null이면
        // 각 기기가 자기 플랫폼 로케일을 쓰라고 못 박는다.
        _UiLangSyncController.last = null;
        final patches = _ConfigPatchRecorder(
          const DashboardConfigValues(
            serverUrl: 'https://example.test',
            uiLang: 'ko',
          ),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ..._commonOverrides,
              configPatchFnProvider.overrideWithValue(patches.call),
              dashboardConfigValuesProvider.overrideWithValue(
                const DashboardConfigValues(
                  serverUrl: 'https://example.test',
                  uiLang: 'ko',
                ),
              ),
              syncControllerProvider.overrideWith(_UiLangSyncController.new),
            ],
            child: const SolApp(),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.container().read(uiLangControllerProvider), 'ko');

        // 서버 확정값이 null인 첫 응답 도착 — uiLang은 null -> null이지만
        // lastSuccessAtMs가 서므로 리스너가 깨어나야 한다.
        _UiLangSyncController.last!.setServerUiLang(null);
        await tester.pumpAndSettle();

        expect(
          tester.container().read(uiLangControllerProvider),
          'system',
          reason: '서버 null은 "서버가 규범을 갖지 않는다"는 확정이지 무응답이 아니다',
        );
        expect(
          patches.values.uiLang,
          'system',
          reason: '로컬 캐시도 같은 값으로 되쓰여야 다음 부팅에서 ko가 되살아나지 않는다',
        );
      },
    );

    testWidgets('리스너가 붙는 시점에 서버가 이미 값을 정해 두었으면 즉시 반영된다', (tester) async {
      final patches = _ConfigPatchRecorder();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._commonOverrides,
            configPatchFnProvider.overrideWithValue(patches.call),
            dashboardConfigValuesProvider.overrideWithValue(
              const DashboardConfigValues(serverUrl: 'https://example.test'),
            ),
            syncControllerProvider.overrideWith(
              () => _UiLangSyncController('en', true),
            ),
          ],
          child: const SolApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.container().read(uiLangControllerProvider), 'en');
    });

    testWidgets('부팅 이후 서버 응답이 바뀌면 컨트롤러도, 로컬 캐시도 따라간다', (tester) async {
      _UiLangSyncController.last = null;
      final patches = _ConfigPatchRecorder(
        const DashboardConfigValues(serverUrl: 'https://example.test'),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._commonOverrides,
            configPatchFnProvider.overrideWithValue(patches.call),
            dashboardConfigValuesProvider.overrideWithValue(
              const DashboardConfigValues(serverUrl: 'https://example.test'),
            ),
            syncControllerProvider.overrideWith(_UiLangSyncController.new),
          ],
          child: const SolApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.container().read(uiLangControllerProvider), 'system');

      _UiLangSyncController.last!.setServerUiLang('ko');
      await tester.pumpAndSettle();

      expect(tester.container().read(uiLangControllerProvider), 'ko');
      expect(
        patches.values.uiLang,
        'ko',
        reason:
            '리뷰 지적 medium 수정: 이 되쓰기가 없으면 이 기기에서 직접 고른 적이 '
            '없는(= 웹/다른 기기에서 바뀐) 언어는 매 부팅마다 플랫폼 로케일로 '
            '그려졌다가 첫 sync에 튄다 — 캐시가 존재 이유를 못 한다',
      );
    });

    testWidgets('서버가 값을 진짜로 지우면(non-null -> null) system으로 되돌아간다', (
      tester,
    ) async {
      _UiLangSyncController.last = null;
      final patches = _ConfigPatchRecorder();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._commonOverrides,
            configPatchFnProvider.overrideWithValue(patches.call),
            dashboardConfigValuesProvider.overrideWithValue(
              const DashboardConfigValues(serverUrl: 'https://example.test'),
            ),
            syncControllerProvider.overrideWith(
              () => _UiLangSyncController('en', true),
            ),
          ],
          child: const SolApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.container().read(uiLangControllerProvider), 'en');

      _UiLangSyncController.last!.setServerUiLang(null);
      await tester.pumpAndSettle();

      expect(
        tester.container().read(uiLangControllerProvider),
        'system',
        reason: '서버가 이미 응답한 뒤라 null도 그대로 반영된다',
      );
    });

    testWidgets(
      'POST 확정 뒤 도착한 비행 중이던 옛 sync 응답은 확정값을 되돌리지 않는다',
      (tester) async {
        // 리뷰 지적 medium에 대한 판정을 코드로 고정한다. 이 리스너가 보는 건
        // 컨트롤러가 아니라 `SyncState.uiLang`이다 — POST 경로는 `SyncState`를
        // 건드리지 않으므로, POST 이전에 발사돼 뒤늦게 도착한 응답이 실어 오는
        // 값은 `SyncState`가 이미 들고 있던 그 값과 같다. 즉 전이가 아니고,
        // select가 리스너를 깨우지 않는다. `lastSuccessAtMs`를 raw 타임스탬프가
        // 아니라 bool(everSynced)로 접어 투영하는 이유가 정확히 이것이다 —
        // 매 폴링이 리스너를 깨우면 그 창이 실제로 열린다.
        _UiLangSyncController.last = null;
        final patches = _ConfigPatchRecorder();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ..._commonOverrides,
              configPatchFnProvider.overrideWithValue(patches.call),
              dashboardConfigValuesProvider.overrideWithValue(
                const DashboardConfigValues(serverUrl: 'https://example.test'),
              ),
              syncControllerProvider.overrideWith(
                () => _UiLangSyncController('ko', true),
              ),
            ],
            child: const SolApp(),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.container().read(uiLangControllerProvider), 'ko');

        // 사용자가 English를 골라 서버가 'en'을 확정해 준 직후
        // (`setup_page.dart._setUiLang`이 하는 그대로 — 서버 확정값만 반영).
        tester
            .container()
            .read(uiLangControllerProvider.notifier)
            .setUiLang('en');
        await tester.pumpAndSettle();
        expect(tester.container().read(uiLangControllerProvider), 'en');

        // POST 이전에 발사돼 이제야 도착한 응답 — 서버가 그때 알던 값은 'ko'다.
        _UiLangSyncController.last!.setServerUiLang('ko');
        await tester.pumpAndSettle();

        expect(
          tester.container().read(uiLangControllerProvider),
          'en',
          reason:
              'SyncState.uiLang은 ko -> ko라 전이가 없다 — 리스너가 깨어나지 않으므로 '
              '방금 확정된 en이 되돌아가지 않는다',
        );
      },
    );

    testWidgets('캐시 되쓰기가 실패해도 화면 반영은 그대로다(정본은 서버다)', (tester) async {
      _UiLangSyncController.last = null;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._commonOverrides,
            configPatchFnProvider.overrideWithValue(
              (_) async => throw const _ConfigPatchFailure(),
            ),
            dashboardConfigValuesProvider.overrideWithValue(
              const DashboardConfigValues(serverUrl: 'https://example.test'),
            ),
            syncControllerProvider.overrideWith(_UiLangSyncController.new),
          ],
          child: const SolApp(),
        ),
      );
      await tester.pumpAndSettle();

      _UiLangSyncController.last!.setServerUiLang('ko');
      await tester.pumpAndSettle();

      expect(
        tester.container().read(uiLangControllerProvider),
        'ko',
        reason: '캐시는 다음 부팅 깜빡임만 막는 보조 수단 — 실패가 배선을 멈춰선 안 된다',
      );
    });
  });

  group('didChangeLocales (WidgetsBindingObserver, app.dart)', () {
    testWidgets(
      'OS 로케일이 바뀌면 platformLocaleProvider가 무효화되어 localeProvider가 새 로케일을 '
      '반영한다',
      (tester) async {
        // `i18n/t.dart`의 `platformLocaleProvider`(기본 구현)는
        // `WidgetsBinding.instance.platformDispatcher.locale`을 그대로
        // 읽는다 — 이 시임을 override하지 않고 실제 테스트 바인딩의 로케일
        // 값 자체를 바꿔서(`WidgetTester.platformDispatcher.localeTestValue`)
        // 프로덕션 관찰 경로(`_AppHomeState`가 `WidgetsBindingObserver`로
        // 받는 `didChangeLocales` 콜백)를 그대로 태운다.
        tester.platformDispatcher.localeTestValue = const Locale('ko');
        addTearDown(tester.platformDispatcher.clearLocaleTestValue);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ..._commonOverrides,
              dashboardConfigValuesProvider.overrideWithValue(
                const DashboardConfigValues(serverUrl: 'https://example.test'),
              ),
              syncControllerProvider.overrideWith(_BootProbeController.new),
            ],
            child: const SolApp(),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          tester.container().read(localeProvider),
          LocaleDto.ko,
          reason: 'uiLangControllerProvider는 기본값 system이라 부팅 시점 플랫폼 로케일을 '
              '그대로 따라간다',
        );

        tester.platformDispatcher.localeTestValue = const Locale('en');
        await tester.pump();

        expect(
          tester.container().read(localeProvider),
          LocaleDto.en,
          reason:
              '_AppHomeState.didChangeLocales가 platformLocaleProvider를 '
              'invalidate하지 않으면 localeProvider는 부팅 시점 ko로 캐시된 채 '
              '남는다 — en으로 바뀌는 것 자체가 이 배선이 동작한다는 증거다',
        );
      },
    );

    testWidgets("uiLangControllerProvider가 'ko'/'en'으로 고정돼 있으면 OS 로케일 변화를 무시한다", (
      tester,
    ) async {
      tester.platformDispatcher.localeTestValue = const Locale('en');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._commonOverrides,
            dashboardConfigValuesProvider.overrideWithValue(
              const DashboardConfigValues(
                serverUrl: 'https://example.test',
                uiLang: 'ko',
              ),
            ),
            syncControllerProvider.overrideWith(_BootProbeController.new),
          ],
          child: const SolApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.container().read(localeProvider), LocaleDto.ko);

      tester.platformDispatcher.localeTestValue = const Locale('ja');
      await tester.pump();

      expect(
        tester.container().read(localeProvider),
        LocaleDto.ko,
        reason: '사용자가 직접 고른 언어는 [모델] 지시대로 OS 로케일보다 우선한다',
      );
    });
  });

  group('세션 상세 공유 라우트', () {
    testWidgets(
      'pushNamed(sessionDetailRouteName(...))이 SessionDeepLinkPage로 간다 '
      '(macOS 알림 클릭 딥링크가 타는 것과 같은 경로)',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ..._commonOverrides,
              dashboardConfigValuesProvider.overrideWithValue(
                const DashboardConfigValues(serverUrl: 'https://example.test'),
              ),
              syncControllerProvider.overrideWith(_BootProbeController.new),
            ],
            child: const SolApp(),
          ),
        );
        await tester.pumpAndSettle();

        rootNavigatorKey.currentState!.pushNamed(
          sessionDetailRouteName('claude_code:s1'),
        );
        await tester.pumpAndSettle();

        expect(find.byType(SessionDeepLinkPage), findsOneWidget);
      },
    );

    testWidgets(
      '웹 해시로 들어오는 initialRoute도(예: `#/session/<key>`) 같은 '
      'onGenerateRoute를 타 SessionDeepLinkPage로 간다',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ..._commonOverrides,
              dashboardConfigValuesProvider.overrideWithValue(
                const DashboardConfigValues(serverUrl: 'https://example.test'),
              ),
              syncControllerProvider.overrideWith(_BootProbeController.new),
            ],
            // `SolApp`은 `home:`을 쓰지 않으므로 `initialRoute`가 그대로
            // `onGenerateRoute`(`app_router.dart`)를 탄다 — 웹 빌드에서
            // 이 이름은 `WidgetsBinding.instance.platformDispatcher.
            // defaultRouteName`(URL 해시 프래그먼트)에서 온다
            // (`app_router.dart` 문서 참고). 위젯 테스트에서는 그 바인딩
            // 값을 직접 흉내낼 수 없으니 `initialRoute:` 파라미터로 같은
            // 진입 경로(`onGenerateRoute`가 첫 라우트부터 처리)를 재현한다.
            //
            // 폴백은 `SolApp()`을 다시 쓰지 않는다 — `Navigator.
            // defaultGenerateInitialRoutes`는 `/session/<key>` 같은
            // 다세그먼트 초기 라우트를 받으면 전체 경로보다 *먼저* `/`와
            // `/session`(중간 접두사) 각각에 대해서도 `onGenerateRoute`를
            // 부르고 그 결과를 전부 초기 히스토리에 쌓는다(Flutter
            // 프레임워크 자체 동작, `navigator.dart`의
            // `defaultGenerateInitialRoutes` 참고) — 그 두 접두사는
            // `generateAppRoute`가 null을 돌려주므로 폴백이 두 번 더
            // 불린다. 폴백이 `SolApp()`(자기 안에 또 `MaterialApp
            // (navigatorKey: rootNavigatorKey)`를 갖는)이면, 바깥
            // `MaterialApp`이 이미 같은 [rootNavigatorKey]를 쥔 채로 그
            // 안에 같은 키를 쥔 `MaterialApp`이 최소 두 개 더 얹혀 프레임
            // 안에서 같은 `GlobalKey`가 동시에 여러 엘리먼트에 붙는
            // 프레임워크 단정(`'child == _child'`) 충돌을 낸다 — 실제
            // 앱(`app.dart`)의 폴백은 `MaterialApp`이 아니라 평범한
            // `_AppHome` 위젯이라 이 키 충돌이 없다. 이 테스트가 보려는
            // 건 라우팅 팩토리 하나뿐이므로 그 폴백 모양(키 없는 평범한
            // 위젯)만 흉내낸다.
            child: MaterialApp(
              navigatorKey: rootNavigatorKey,
              initialRoute: sessionDetailRouteName('claude_code:s1'),
              onGenerateRoute: (settings) =>
                  generateAppRoute(settings) ??
                  MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(SessionDeepLinkPage), findsOneWidget);
      },
    );
  });

  group('sessionDetailRouteName / sessionKeyFromRouteName', () {
    test('왕복 변환이 원래 세션 키를 그대로 돌려준다', () {
      const key = 'claude_code:s1';
      expect(sessionKeyFromRouteName(sessionDetailRouteName(key)), key);
    });

    test('콜론이 있는 키도 URL 세그먼트로 안전하게 인코딩된다', () {
      const key = 'codex:abc:def';
      final routeName = sessionDetailRouteName(key);
      expect(routeName.contains(':'), isFalse);
      expect(sessionKeyFromRouteName(routeName), key);
    });

    test('세션 라우트 모양이 아니면 null', () {
      expect(sessionKeyFromRouteName('/'), isNull);
      expect(sessionKeyFromRouteName('/settings'), isNull);
      expect(sessionKeyFromRouteName(null), isNull);
    });

    test('세션 키 세그먼트가 비어 있으면 null', () {
      expect(sessionKeyFromRouteName('/session/'), isNull);
    });
  });

  group('ESC 뒤로가기 (TASK ESC-nav)', () {
    testWidgets('세션 상세 화면에서 ESC를 누르면 목록으로 돌아간다', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._commonOverrides,
            dashboardConfigValuesProvider.overrideWithValue(
              const DashboardConfigValues(serverUrl: 'https://example.test'),
            ),
            syncControllerProvider.overrideWith(
              () => _EscNavController(
                const SyncControllerState(
                  sync: SyncState(
                    cursor: 0,
                    sessions: {'claude-code:esc1': _escSession},
                  ),
                ),
              ),
            ),
          ],
          child: const SolApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SessionsPage), findsOneWidget);

      rootNavigatorKey.currentState!.pushNamed(
        sessionDetailRouteName('claude-code:esc1'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SessionDeepLinkPage), findsOneWidget);
      expect(find.byType(SessionsPage), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(SessionDeepLinkPage), findsNothing);
      expect(find.byType(SessionsPage), findsOneWidget);
    });

    testWidgets('루트(세션 목록)에서 ESC는 아무 일도 하지 않는다', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._commonOverrides,
            dashboardConfigValuesProvider.overrideWithValue(
              const DashboardConfigValues(serverUrl: 'https://example.test'),
            ),
            syncControllerProvider.overrideWith(_BootProbeController.new),
          ],
          child: const SolApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SessionsPage), findsOneWidget);

      // 뒤로 갈 라우트가 없다 — `Navigator.maybePop()`이 조용히 아무 일도
      // 하지 않아야 한다(canPop == false).
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(SessionsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('다이얼로그가 떠 있으면 ESC는 다이얼로그만 닫고 화면은 그대로 남는다', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._commonOverrides,
            dashboardConfigValuesProvider.overrideWithValue(
              const DashboardConfigValues(serverUrl: 'https://example.test'),
            ),
            syncControllerProvider.overrideWith(
              () => _EscNavController(
                const SyncControllerState(
                  sync: SyncState(
                    cursor: 0,
                    sessions: {'claude-code:esc1': _escSession},
                  ),
                ),
              ),
            ),
          ],
          child: const SolApp(),
        ),
      );
      await tester.pumpAndSettle();

      rootNavigatorKey.currentState!.pushNamed(
        sessionDetailRouteName('claude-code:esc1'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SessionDeepLinkPage), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(find.text('session.delete.dialog_title'), findsOneWidget);

      // 다이얼로그의 자체 `ModalRoute`(barrierDismissible 기본 true)가
      // 이 화면(barrierDismissible이 아닌 일반 `MaterialPageRoute`)이나
      // `app.dart`의 [CallbackShortcuts]보다 포커스에 더 가까워 먼저 ESC를
      // 잡는다 — Flutter 기본 동작, 이 앱 코드가 새로 만든 게 아니다.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(
        find.text('session.delete.dialog_title'),
        findsNothing,
        reason: '다이얼로그만 닫힌다',
      );
      expect(
        find.byType(SessionDeepLinkPage),
        findsOneWidget,
        reason: '화면 자체는 pop되지 않는다(취소와 같은 취급)',
      );
    });
  });
}
