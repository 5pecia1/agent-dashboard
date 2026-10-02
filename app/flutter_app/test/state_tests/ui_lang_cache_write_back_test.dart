/// `installUiLangSync`(`state/ui_lang_provider.dart`)의 언어 캐시 되쓰기가
/// 백그라운드 쓰기 규칙(`config_provider.dart`의 `backgroundConfigPatch`)을
/// 따르는지 닫는다: 저장된 설정으로 부팅한 뒤 설정 파일이 사라졌으면 새
/// 파일을 만들지 않는다.
///
/// 실제 패치 큐(`configPatchFnProvider`)에 메모리 읽기·쓰기만 갈아 끼운다.
/// 이 함수는 `WidgetRef`를 받으므로 최소한의 위젯 하나가 부팅 배선
/// (`app.dart`)처럼 부른다.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/sync_reducer.dart' show SyncState;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/state/ui_lang_provider.dart';

const DashboardConfigValues _stored = DashboardConfigValues(
  serverUrl: 'https://dash.example.test',
  clientToken: 'stored-client-token',
);

/// 서버 응답이 `ui_lang`을 실어 오는 순간만 흉내 내는 컨트롤러 —
/// `sync_controller.dart`의 `_afterSuccess`처럼 `lastSuccessAtMs`를 같이
/// 올린다(`syncUiLangListenable`이 "응답을 받았다"로 읽는 필드).
class _ServerUiLangController extends SyncController {
  static _ServerUiLangController? last;
  int _clock = 0;

  @override
  SyncControllerState build() {
    last = this;
    return const SyncControllerState(sync: SyncState(cursor: 0));
  }

  void deliver(String uiLang) {
    state = state.copyWith(
      sync: state.sync.copyWith(uiLang: uiLang),
      lastSuccessAtMs: ++_clock,
    );
  }
}

class _UiLangSyncHost extends ConsumerStatefulWidget {
  const _UiLangSyncHost();

  @override
  ConsumerState<_UiLangSyncHost> createState() => _UiLangSyncHostState();
}

class _UiLangSyncHostState extends ConsumerState<_UiLangSyncHost> {
  @override
  void initState() {
    super.initState();
    installUiLangSync(ref);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  late DashboardConfigValues onDisk;
  late List<DashboardConfigValues> saves;

  setUp(() {
    saves = <DashboardConfigValues>[];
    _ServerUiLangController.last = null;
  });

  Future<void> boot(WidgetTester tester, {required bool storedAtBoot}) =>
      tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncControllerProvider.overrideWith(_ServerUiLangController.new),
            storedConfigAtBootProvider.overrideWithValue(storedAtBoot),
            configLoadFnProvider.overrideWithValue(() async => onDisk),
            configSaveFnProvider.overrideWithValue((values) async {
              onDisk = values;
              saves.add(values);
            }),
          ],
          child: const _UiLangSyncHost(),
        ),
      );

  testWidgets('저장된 설정으로 부팅한 뒤 설정 파일이 사라졌으면 언어 캐시를 새 파일에 쓰지 않는다', (
    tester,
  ) async {
    onDisk = _stored;
    await boot(tester, storedAtBoot: true);
    onDisk = DashboardConfigValues.empty;

    _ServerUiLangController.last!.deliver('ko');
    await tester.pump();

    expect(saves, isEmpty);
    expect(
      tester.container().read(uiLangControllerProvider),
      'ko',
      reason: '화면 언어는 서버 값을 그대로 따른다 — 막는 것은 디스크 쓰기뿐이다',
    );
  });

  testWidgets('설정 파일이 있으면 언어 캐시를 그 파일에 되쓰고 다른 값은 그대로 둔다', (tester) async {
    onDisk = _stored;
    await boot(tester, storedAtBoot: true);

    _ServerUiLangController.last!.deliver('ko');
    await tester.pump();

    expect(saves, <DashboardConfigValues>[_stored.copyWith(uiLang: 'ko')]);
  });

  testWidgets('저장된 설정 없이 부팅한 세션은 빈 저장소에도 언어 캐시를 쓴다', (tester) async {
    onDisk = DashboardConfigValues.empty;
    await boot(tester, storedAtBoot: false);

    _ServerUiLangController.last!.deliver('en');
    await tester.pump();

    expect(saves, <DashboardConfigValues>[
      const DashboardConfigValues(uiLang: 'en'),
    ]);
  });
}
