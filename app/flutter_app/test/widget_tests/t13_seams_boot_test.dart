/// 완료 기준 (a): T13의 시임 5종을 전부 override하면 위젯 트리가 실제
/// 플러그인/네이티브 dylib/wasm을 전혀 건드리지 않고 뜬다는 것을 하나의
/// 위젯으로 증명한다.
///
/// `RustLib.initMock`도 부르지 않는다 — [stateLabelKeyFnProvider] 자체를
/// override해 `dashboard_provider.dart`가 FRB로 내려가는 지점을 이 테스트
/// 시점에서 완전히 끊는다(다른 네 시임도 각각 자신의 `Provider<Fn>`
/// 계층에서 끊는다). `isWasmRuntimeProvider`를 false로 둔 채
/// [pushRegistrarProvider]를 실제로 호출해도 데스크톱 분기라
/// [httpSendProvider]/[webPushTokenFnProvider]까지 갈 필요가 없다 —
/// 그래서 이 파일은 그 둘을 override하지 않고도 안전하다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart' show DashboardApiConfig, dashboardApiConfigProvider;
import 'package:my_dashboard/src/data/dashboard_dto.dart' show TransitionDto;
import 'package:my_dashboard/src/state/capability_provider.dart' show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart';
import 'package:my_dashboard/src/state/notify_provider.dart';
import 'package:my_dashboard/src/state/push_provider.dart' show pushRegistrarProvider;

class _SeamProbe extends ConsumerStatefulWidget {
  const _SeamProbe();

  @override
  ConsumerState<_SeamProbe> createState() => _SeamProbeState();
}

class _SeamProbeState extends ConsumerState<_SeamProbe> {
  String _summary = 'loading';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    // 다섯 시임 전부를 실제로 한 번씩 거친다: config/notify는 값을 읽고,
    // dashboard(FRB 어댑터)는 라벨 함수를 부르고, push는 등록을 시도하고,
    // http는 (호출되지 않더라도) config 조립에 관여한다.
    final config = ref.read(dashboardConfigValuesProvider);
    final labelFn = ref.read(stateLabelKeyFnProvider);
    final pushResult = await ref.read(pushRegistrarProvider)();
    await notifyForAlerts(
      [
        const TransitionDto(
          id: 1,
          sessionKey: 'claude_code:s1',
          toState: 'waiting_input',
        ),
      ],
      dispatch: ref.read(notifyProvider),
      // 상태 라벨은 이 프로브의 관심사가 아니다 — `alertStateLabelProvider`를
      // 읽으면 i18n 카탈로그(FRB)까지 내려가 이 파일이 지키려는 "네이티브
      // dylib을 전혀 건드리지 않는다"가 깨진다. `notifyForAlerts`가 리졸버를
      // 인자로 받기 때문에(그게 이 시임의 존재 이유다) 여기서는 항등 함수를
      // 그대로 넘긴다.
      stateLabel: (String stateCode) => stateCode,
    );

    setState(() {
      _summary = [
        'config:${config.isEmpty}',
        'state:${labelFn(SessionStateDto.idle)}',
        'push:${pushResult.availability}',
      ].join('|');
    });
  }

  @override
  Widget build(BuildContext context) => Text(_summary);
}

void main() {
  testWidgets(
    '완료 기준 (a): 시임 5종을 전부 override하면 위젯 트리가 플러그인/네이티브 dylib/wasm 없이 뜬다',
    (tester) async {
      final sentPayloads = <NotifyPayload>[];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dashboardConfigValuesProvider.overrideWithValue(
              DashboardConfigValues.empty,
            ),
            dashboardApiConfigProvider.overrideWithValue(
              DashboardApiConfig(baseUrl: Uri.parse('https://example.test')),
            ),
            isWasmRuntimeProvider.overrideWithValue(false),
            localNotifyFnProvider.overrideWithValue((payload) async {
              sentPayloads.add(payload);
            }),
            stateLabelKeyFnProvider.overrideWithValue(
              (state) => 'label.${state.name}',
            ),
          ],
          child: const MaterialApp(home: _SeamProbe()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'config:true|state:label.idle|'
          'push:PushAvailability.notApplicable',
        ),
        findsOneWidget,
      );
      // notifyProvider가 실제로 로컬 발신 시임까지 도달했다(가짜로 갈아낀
      // localNotifyFnProvider가 진짜 osascript/OS 알림 대신 받았다) —
      // 데스크톱 분기가 정상 동작함을 boot 레벨에서도 확인한다.
      expect(sentPayloads, hasLength(1));
      expect(sentPayloads.single.sessionKey, 'claude_code:s1');
    },
  );
}
