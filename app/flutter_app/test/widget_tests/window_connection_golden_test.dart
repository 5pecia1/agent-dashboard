/// 플랫폼별 PNG는 해당 OS에서 생성한다. 기본 Ahem 폰트를 사용하는
/// 레이아웃 회귀이며 실제 한글 글리프 검토는 설치 앱 QA에서 수행한다.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/data/window_connection.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart' show LocaleDto;
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/state/window_connections_provider.dart';
import 'package:my_dashboard/src/state/window_navigation_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/widgets/window_connection_dialog.dart';
import 'package:my_dashboard/src/ui/window_connections_page.dart';

const _host = '개발용-MacBook-Pro';
const _project = '/Users/테스트/개발/팀프로젝트/업무-대시보드';
const _bundleId = 'com.microsoft.VSCode';
const _dialogViewport = Size(900, 1000);
const _pageViewport = Size(900, 760);

// 네이티브 번역기를 부르지 않는 고정된 한국어 길이 픽스처다.
// 번역 카탈로그의 정합성은 Rust i18n 테스트가 별도로 확인한다.
const _labels = {
  'window.connect': '창 연결',
  'window.connect_project': '{project}의 작업 창 연결',
  'window.target_project': '연결 대상 프로젝트',
  'window.alert_host': '알림 발생 호스트',
  'window.project': '프로젝트 전체 경로',
  'window.identity_unknown': '확인할 수 없음',
  'window.local_windows': '이 Mac에서 열 앱과 창',
  'window.scope_note': '연결을 저장하면 같은 프로젝트·호스트의 모든 세션에 적용됩니다.',
  'window.manage': '창 연결 관리',
  'window.manage_note':
      '이 Mac에서는 호스트와 프로젝트 전체 경로가 같은 모든 세션이 창 연결을 공유합니다. 에이전트가 달라도 같은 연결을 사용합니다.',
  'window.add': '연결 추가',
  'window.disconnect': '연결 해제',
  'window.unconnected': '연결된 창 없음',
  'window.saved_rule': '저장된 조건: {app} · {title}',
  'window.application': '대상 앱',
  'window.all_apps': '모든 앱',
  'window.search': '앱 또는 창 제목 검색',
  'window.refresh': '다시 찾기',
  'window.show_all': '모든 창 표시',
  'window.remember': '이 호스트·프로젝트의 모든 세션에 사용할 연결 저장',
  'window.title_pattern': '창 제목에 포함된 문구',
  'window.exact': '제목 전체 일치',
  'window.match_count': '일치하는 창: {count}개',
  'window.rule_note':
      '대소문자를 구분하고 입력한 문구 그대로 찾습니다. ‘제목 전체 일치’를 켜면 제목 전체를 비교합니다. 여러 창이 일치하면 직접 선택합니다.',
  'window.open': '창으로 이동',
  'window.save_and_open': '저장하고 창으로 이동',
  'window.show_session': '세션 상세 보기',
  'action.cancel': '취소',
};

String _translate(String key, LocaleDto locale) => _labels[key]!;

String _translateArgs(
  String key,
  LocaleDto locale,
  List<String> names,
  List<String> values,
) {
  var result = _labels[key]!;
  for (var index = 0; index < names.length; index++) {
    result = result.replaceAll('{${names[index]}}', values[index]);
  }
  return result;
}

final _connectionKey = WindowConnectionKey(host: _host, project: _project);
final _savedRule = WindowConnectionRule(
  key: _connectionKey,
  bundleId: _bundleId,
  titlePattern: '업무-대시보드',
);
const _windows = [
  WindowCandidate(
    token: 'golden-window-first',
    bundleId: _bundleId,
    appName: 'Visual Studio Code',
    title: 'window_navigation_provider.dart — 업무-대시보드 — Visual Studio Code',
  ),
  WindowCandidate(
    token: 'golden-window-second',
    bundleId: _bundleId,
    appName: 'Visual Studio Code',
    title: '작업 계획 및 검토 기록.md — 업무-대시보드 — Visual Studio Code',
    minimized: true,
  ),
];
final _scan = WindowScan(
  trusted: true,
  complete: true,
  localHost: _host,
  windows: _windows,
  applications: const [
    WindowApplication(bundleId: _bundleId, appName: 'Visual Studio Code'),
    WindowApplication(bundleId: 'com.apple.Terminal', appName: 'Terminal'),
  ],
);

const _session = SessionViewDto(
  key: 'codex:golden-session',
  state: 'waiting_input',
  source: 'codex',
  project: _project,
  host: _host,
  lastTransitionId: 10,
);

class _FixedSyncController extends SyncController {
  @override
  SyncControllerState build() {
    final sessions = [
      _session,
      _session.copyWith(key: 'claude:golden-session', source: 'claude'),
      _session.copyWith(key: 'codex:other-host', host: '원격-개발서버'),
      _session.copyWith(
        key: 'codex:other-path',
        project: '/Users/테스트/개발/개인프로젝트/업무-대시보드',
      ),
    ];
    return SyncControllerState(
      sync: SyncState(
        sessions: {for (final session in sessions) session.key: session},
      ),
    );
  }
}

void _useViewport(WidgetTester tester, Size logical) {
  final view = tester.view
    ..devicePixelRatio = 1
    ..physicalSize = logical;
  addTearDown(() {
    view
      ..resetDevicePixelRatio()
      ..resetPhysicalSize();
  });
}

Widget _app(Widget home) => ProviderScope(
  overrides: [
    localeProvider.overrideWithValue(LocaleDto.ko),
    i18nTranslateOverride.overrideWithValue(_translate),
    i18nTranslateArgsOverride.overrideWithValue(_translateArgs),
    syncControllerProvider.overrideWith(_FixedSyncController.new),
    windowNavigationSupportedProvider.overrideWithValue(true),
    windowConnectionsLoadFnProvider.overrideWithValue(() async => [_savedRule]),
    windowConnectionsSaveFnProvider.overrideWithValue((_) async {
      throw StateError('Golden rendering must not save connections');
    }),
    windowScanProvider.overrideWithValue(({String? bundleId}) async => _scan),
    windowFocusProvider.overrideWithValue((_) async {
      throw StateError('Golden rendering must not focus external windows');
    }),
    windowAccessibilitySettingsProvider.overrideWithValue(() async {
      throw StateError('Golden rendering must not open system settings');
    }),
  ],
  child: MaterialApp(theme: AppTheme.light(), home: home),
);

void main() {
  testWidgets('저장된 조건에 여러 창이 일치하는 연결 선택 화면 골든', tags: ['golden'], (
    tester,
  ) async {
    _useViewport(tester, _dialogViewport);
    late BuildContext dialogContext;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) {
            dialogContext = context;
            return const Scaffold();
          },
        ),
      ),
    );
    final closed = showDialog<WindowCandidate>(
      context: dialogContext,
      builder: (_) => WindowConnectionDialog(
        connectionKey: _connectionKey,
        scan: _scan,
        rule: _savedRule,
        onShowSession: () {},
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(_windows.first.title));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('일치하는 창: 2개'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(
        '../goldens/window_connection_dialog_${Platform.operatingSystem}.png',
      ),
    );
    Navigator.of(dialogContext).pop();
    await tester.pumpAndSettle();
    await closed;
  });

  testWidgets('호스트와 전체 경로별로 묶인 창 연결 관리 화면 골든', tags: ['golden'], (
    tester,
  ) async {
    _useViewport(tester, _pageViewport);
    await tester.pumpWidget(_app(const WindowConnectionsPage()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Card), findsNWidgets(3));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(
        '../goldens/window_connections_page_${Platform.operatingSystem}.png',
      ),
    );
  });
}
