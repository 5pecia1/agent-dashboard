/// [HookSkewBanner] 단독 위젯 테스트 — host(+project basename) 목록이 실제로
/// 문구에 섞여 그려지는지, 그리고 복사 아이콘(`_CopyUpdateCommandButton`)의
/// 표시 조건·복사 동작·피드백을 본다. 배너 표시/비표시 조건과 다른 배너와의
/// 동시 표시는 `sessions_page_test.dart`가 화면 조립 수준에서 이미 덮는다.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart' show LocaleDto;
import 'package:my_dashboard/src/state/config_provider.dart'
    show
        DashboardConfigValues,
        dashboardApiConfigControllerProvider,
        dashboardConfigValuesProvider;
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/widgets/alert_banner.dart';

/// 실제 카탈로그의 `{hosts}` 치환을 흉내 내는 결정적 가짜 — 진짜
/// 템플릿 문자열 없이도(카탈로그는 Rust 쪽에 있다) 인자 값이 문구 안에
/// 실제로 섞여 드는지를 `key: 값1, 값2` 모양으로 확인한다.
/// `sessions_page_test.dart`의 기본 override(키를 그대로 돌려주고 인자를
/// 무시함)와 다른 지점이 이거다.
String _echoArgsTranslate(
  String key,
  LocaleDto locale,
  List<String> argKeys,
  List<String> argVals,
) => argVals.isEmpty ? key : '$key: ${argVals.join(', ')}';

/// 복사 아이콘 표시/비표시를 가르는 `dashboardConfigValuesProvider.
/// serverUrl` — 대부분의 테스트는 값이 있든 없든 상관하지 않으므로
/// 기본값을 하나 채워 둔다(가려면 명시적으로 `serverUrl:`을 넘긴다).
const _defaultServerUrl = 'https://dashboard.example';

Future<void> _pumpBanner(
  WidgetTester tester,
  List<HookSkewDto> hookSkew, {
  String? serverUrl = _defaultServerUrl,
}) => tester.pumpWidget(
  ProviderScope(
    overrides: [
      i18nTranslateOverride.overrideWithValue((key, locale) => key),
      i18nTranslateArgsOverride.overrideWithValue(_echoArgsTranslate),
      dashboardConfigValuesProvider.overrideWithValue(
        DashboardConfigValues(serverUrl: serverUrl),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: HookSkewBanner(hookSkew: hookSkew)),
    ),
  ),
);

void main() {
  testWidgets('host 목록이 쉼표로 이어져 본문에 그대로 렌더된다(project 없음)', (tester) async {
    await _pumpBanner(tester, const <HookSkewDto>[
      HookSkewDto(host: 'dev-mac'),
      HookSkewDto(host: 'sol-linux'),
    ]);

    expect(find.text('alert.banner.hook_skew.title'), findsOneWidget);
    expect(
      find.text('alert.banner.hook_skew.body: dev-mac, sol-linux'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  group('좁은 화면(narrow_width_test.dart 관례)', () {
    // `narrow_width_test.dart`와 같은 360x800 고정 — 모바일 1열 레이아웃.
    const narrowViewport = Size(360, 800);

    void useNarrowViewport(WidgetTester tester) {
      final view = tester.view
        ..devicePixelRatio = 1.0
        ..physicalSize = narrowViewport;
      addTearDown(() {
        view
          ..resetDevicePixelRatio()
          ..resetPhysicalSize();
      });
    }

    testWidgets('제목이 길어 복사 아이콘과 한 줄에 못 들어가도 오버플로 없이 말줄임된다', (
      tester,
    ) async {
      useNarrowViewport(tester);

      // 제목 키만 실제 문구보다도 긴 문자열로 바꿔치기해 `Flexible` +
      // ellipsis가 실제로 동작하는지 스트레스를 준다 — 나머지 키는 평소처럼
      // 그대로 돌려준다(echo).
      const longTitle =
          '이 제목은 360px 폭에서 복사 아이콘과 한 줄에 절대 못 들어갈 만큼 '
          '의도적으로 아주 길게 늘여 쓴 문구입니다';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            i18nTranslateOverride.overrideWithValue(
              (key, locale) =>
                  key == 'alert.banner.hook_skew.title' ? longTitle : key,
            ),
            i18nTranslateArgsOverride.overrideWithValue(_echoArgsTranslate),
            dashboardConfigValuesProvider.overrideWithValue(
              const DashboardConfigValues(serverUrl: _defaultServerUrl),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: HookSkewBanner(
                hookSkew: const <HookSkewDto>[HookSkewDto(host: 'dev-mac')],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('host가 하나뿐이어도 그대로 렌더된다', (tester) async {
    await _pumpBanner(tester, const <HookSkewDto>[
      HookSkewDto(host: 'dev-mac'),
    ]);

    expect(find.text('alert.banner.hook_skew.body: dev-mac'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('project가 있으면 "host (basename)" 형태로 병기된다', (tester) async {
    await _pumpBanner(tester, const <HookSkewDto>[
      HookSkewDto(
        host: '235f7d6e85ff',
        rev: 'a1b2c3d4',
        project: '/workspaces/trim.page',
      ),
    ]);

    expect(
      find.text('alert.banner.hook_skew.body: 235f7d6e85ff (trim.page)'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('project가 null인 항목과 있는 항목이 섞이면 각각 폴백/병기된다', (tester) async {
    await _pumpBanner(tester, const <HookSkewDto>[
      HookSkewDto(host: '235f7d6e85ff', project: '/workspaces/trim.page'),
      HookSkewDto(host: 'sol-linux'),
    ]);

    expect(
      find.text(
        'alert.banner.hook_skew.body: 235f7d6e85ff (trim.page), sol-linux',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  group('hookSkewUpdateCommand (순수 함수)', () {
    test('QUICKSTART.md의 한 줄과 글자 하나까지 같다', () {
      expect(
        hookSkewUpdateCommand('https://dashboard.example'),
        'curl -fsSL https://dashboard.example/setup.sh | bash',
      );
    });

    test('끝 슬래시는 벗겨내 //setup.sh가 되지 않는다', () {
      expect(
        hookSkewUpdateCommand('https://dashboard.example/'),
        'curl -fsSL https://dashboard.example/setup.sh | bash',
      );
    });
  });

  group('복사 아이콘', () {
    const serverUrl = 'https://dashboard.example';

    tearDown(() {
      // 다음 테스트로 mock handler가 새지 않게 매번 지운다.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets('serverUrl이 있으면 복사 아이콘이 보인다', (tester) async {
      await _pumpBanner(tester, const <HookSkewDto>[
        HookSkewDto(host: 'dev-mac'),
      ], serverUrl: serverUrl);

      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('serverUrl이 null이면 아이콘이 없다', (tester) async {
      await _pumpBanner(tester, const <HookSkewDto>[
        HookSkewDto(host: 'dev-mac'),
      ], serverUrl: null);

      expect(find.byIcon(Icons.copy_outlined), findsNothing);
      expect(find.byIcon(Icons.check_outlined), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('serverUrl이 빈 문자열이어도 아이콘이 없다', (tester) async {
      await _pumpBanner(tester, const <HookSkewDto>[
        HookSkewDto(host: 'dev-mac'),
      ], serverUrl: '');

      expect(find.byIcon(Icons.copy_outlined), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('아이콘을 누르면 정확한 명령 문자열이 클립보드에 담긴다', (tester) async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            calls.add(call);
            return null;
          });

      await _pumpBanner(tester, const <HookSkewDto>[
        HookSkewDto(host: 'dev-mac'),
      ], serverUrl: serverUrl);
      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pump();

      final setDataCall = calls.singleWhere(
        (call) => call.method == 'Clipboard.setData',
      );
      expect(
        (setDataCall.arguments as Map)['text'],
        'curl -fsSL $serverUrl/setup.sh | bash',
      );
      expect(tester.takeException(), isNull);

      // 체크 표시로 되돌리는 타이머가 남은 채로 테스트가 끝나면
      // "Timer가 still pending"으로 실패한다 — 끝까지 흘려보낸다.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('이 세션에서 주소를 바꿔 저장했다면 복사하는 명령은 바꾼 서버를 가리킨다', (tester) async {
      // 배너는 지금 동기화하는 서버가 준 `hook_skew`를 그린다. 부팅 스냅샷의
      // 옛 주소를 쓰면 복사한 명령이 옛 서버의 setup.sh를 받는다.
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            calls.add(call);
            return null;
          });
      await _pumpBanner(tester, const <HookSkewDto>[
        HookSkewDto(host: 'dev-mac'),
      ], serverUrl: serverUrl);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HookSkewBanner)),
      );

      container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: 'https://moved.example', clientToken: 'token');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pump();

      final setDataCall = calls.singleWhere(
        (call) => call.method == 'Clipboard.setData',
      );
      expect(
        (setDataCall.arguments as Map)['text'],
        'curl -fsSL https://moved.example/setup.sh | bash',
      );
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('첫 실행에서 주소를 저장하면 복사 아이콘이 나타난다', (tester) async {
      await _pumpBanner(tester, const <HookSkewDto>[
        HookSkewDto(host: 'dev-mac'),
      ], serverUrl: null);
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HookSkewBanner)),
      );

      container
          .read(dashboardApiConfigControllerProvider.notifier)
          .apply(serverUrl: serverUrl, clientToken: 'token');
      await tester.pump();

      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('복사 후 체크 아이콘으로 잠깐 바뀌었다가 되돌아온다', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async => null,
          );

      await _pumpBanner(tester, const <HookSkewDto>[
        HookSkewDto(host: 'dev-mac'),
      ], serverUrl: serverUrl);
      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pump();

      expect(find.byIcon(Icons.check_outlined), findsOneWidget);
      expect(find.byIcon(Icons.copy_outlined), findsNothing);

      await tester.pump(const Duration(seconds: 2));

      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
      expect(find.byIcon(Icons.check_outlined), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
