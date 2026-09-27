import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/data/window_connection.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/state/window_connections_provider.dart';
import 'package:my_dashboard/src/state/window_navigation_provider.dart';
import 'package:my_dashboard/src/ui/widgets/window_connection_dialog.dart';
import 'package:my_dashboard/src/ui/window_connections_page.dart';

const _host = 'work-mac';
const _project = '/work/my-dashboard';
const _target = WindowCandidate(
  token: 'transient-window-token',
  bundleId: 'com.microsoft.VSCode',
  appName: 'Visual Studio Code',
  title: 'README — my-dashboard',
);
final _key = WindowConnectionKey(host: _host, project: _project);
final _readyScan = WindowScan(
  trusted: true,
  complete: true,
  localHost: _host,
  windows: const [_target],
);

class _FixedSyncController extends SyncController {
  _FixedSyncController(this.sessions);
  final List<SessionViewDto> sessions;

  @override
  SyncControllerState build() => SyncControllerState(
    sync: SyncState(
      sessions: {for (final session in sessions) session.key: session},
    ),
  );
}

class _Calls {
  final writes = <List<WindowConnectionRule>>[];
  final scannedBundleIds = <String?>[];
  int focus = 0;
  int settings = 0;
  WindowCandidate? selected;
}

Future<_Calls> _pump(
  WidgetTester tester, {
  bool page = false,
  bool manageOnly = false,
  WindowScan? scan,
  WindowScan? refreshed,
  WindowConnectionRule? rule,
  List<WindowConnectionRule> saved = const [],
  List<SessionViewDto> sessions = const [],
  bool loadFails = false,
  bool saveFails = false,
  bool missingKey = false,
  WindowConnectionKey? connectionKey,
  String? project,
  String? host,
  Size viewport = const Size(1100, 1000),
}) async {
  tester.view.reset();
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final calls = _Calls();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        i18nTranslateOverride.overrideWithValue((key, locale) => key),
        i18nTranslateArgsOverride.overrideWithValue(
          (key, locale, names, values) => '$key ${values.join(' ')}',
        ),
        windowConnectionsLoadFnProvider.overrideWithValue(() async {
          if (loadFails) {
            throw const FormatException('invalid saved connections');
          }
          return saved;
        }),
        windowConnectionsSaveFnProvider.overrideWithValue((rules) async {
          if (saveFails) {
            throw StateError('storage unavailable');
          }
          calls.writes.add(List.of(rules));
        }),
        windowScanProvider.overrideWithValue(({String? bundleId}) async {
          calls.scannedBundleIds.add(bundleId);
          return refreshed ?? scan ?? _readyScan;
        }),
        windowFocusProvider.overrideWithValue((_) async {
          calls.focus++;
          return 'focused';
        }),
        windowAccessibilitySettingsProvider.overrideWithValue(
          () async => calls.settings++,
        ),
        syncControllerProvider.overrideWith(
          () => _FixedSyncController(sessions),
        ),
      ],
      child: MaterialApp(
        home: page
            ? const WindowConnectionsPage()
            : Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async {
                      calls.selected = await showDialog<WindowCandidate>(
                        context: context,
                        builder: (_) => WindowConnectionDialog(
                          connectionKey: missingKey
                              ? null
                              : connectionKey ?? _key,
                          project: project,
                          host: host,
                          scan: scan ?? _readyScan,
                          rule: rule,
                          manageOnly: manageOnly,
                        ),
                      );
                    },
                    child: const Text('show dialog'),
                  ),
                ),
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (!page) {
    await tester.tap(find.text('show dialog'));
    await tester.pumpAndSettle();
  }
  return calls;
}

void main() {
  testWidgets('창 목록과 조건을 스크롤해도 연결 대상 프로젝트가 상단에 남는다', (tester) async {
    await _pump(tester);
    final projectLabel = find.text('window.target_project');
    final initialPosition = tester.getTopLeft(projectLabel);
    expect(find.text('window.connect_project my-dashboard'), findsOneWidget);
    expect(find.text('my-dashboard'), findsOneWidget);
    expect(find.text(_host), findsOneWidget);
    expect(find.text(_project), findsOneWidget);
    expect(find.text('window.scope_note'), findsOneWidget);
    expect(find.text('window.local_windows'), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('window-connection-options')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(projectLabel), initialPosition);
    expect(projectLabel.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('이름이 같은 프로젝트도 전체 경로와 알림 발생 호스트를 표시한다', (tester) async {
    const project = '/work/another-team/my-dashboard';
    const host = 'remote-build-host';
    await _pump(
      tester,
      connectionKey: WindowConnectionKey(host: host, project: project),
    );
    expect(find.text('my-dashboard'), findsOneWidget);
    expect(find.text(project), findsOneWidget);
    expect(find.text(host), findsOneWidget);
    expect(find.text(_project), findsNothing);
    expect(find.text(_host), findsNothing);
  });

  testWidgets('호스트가 없어도 프로젝트를 보여 주며 영구 연결 없이 창을 선택한다', (tester) async {
    final calls = await _pump(tester, missingKey: true, project: _project);
    expect(find.text('window.connect_project my-dashboard'), findsOneWidget);
    expect(find.text(_project), findsOneWidget);
    expect(find.text('window.identity_unknown'), findsOneWidget);
    expect(find.text('window.missing_identity'), findsOneWidget);
    expect(find.text('window.remember'), findsNothing);
    expect(find.text('window.title_pattern'), findsNothing);
    await tester.tap(find.text(_target.title));
    await tester.pump();
    await tester.tap(find.text('window.open'));
    await tester.pumpAndSettle();
    expect(calls.selected, _target);
    expect(calls.writes, isEmpty);
  });

  testWidgets('프로젝트가 없어도 알고 있는 알림 발생 호스트를 표시한다', (tester) async {
    await _pump(tester, missingKey: true, host: _host);
    expect(find.text('window.connect'), findsOneWidget);
    expect(find.text(_host), findsOneWidget);
    expect(find.text('window.identity_unknown'), findsNWidgets(2));
    expect(find.text('window.missing_identity'), findsOneWidget);
  });

  testWidgets('좁고 낮은 창에서도 긴 프로젝트 경로를 줄바꿈하고 넘치지 않는다', (tester) async {
    final longProject =
        '/work/${List.filled(10, 'a-very-long-project-directory').join('/')}/my-dashboard';
    await _pump(
      tester,
      connectionKey: WindowConnectionKey(
        host: 'remote-development-host',
        project: longProject,
      ),
      viewport: const Size(320, 400),
    );
    expect(find.text(longProject), findsOneWidget);
    final pathText = tester.widget<SelectableText>(
      find.byWidgetPredicate(
        (widget) => widget is SelectableText && widget.data == longProject,
      ),
    );
    expect(pathText.maxLines, isNull);
    expect(tester.getSize(find.text(longProject)).width, lessThan(320));
    expect(tester.takeException(), isNull);
    await tester.drag(
      find.byKey(const ValueKey('window-connection-options')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(find.text('window.target_project').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('창을 선택한 뒤 취소하면 연결을 저장하거나 창을 전환하지 않는다', (tester) async {
    final calls = await _pump(tester);
    await tester.tap(find.text(_target.title));
    await tester.pump();
    await tester.tap(find.text('action.cancel'));
    await tester.pumpAndSettle();
    expect(calls.selected, isNull);
    expect(calls.writes, isEmpty);
    expect(calls.focus, 0);
    expect(find.byType(WindowConnectionDialog), findsNothing);
  });

  testWidgets('연결 저장을 끄면 이동 버튼이 바뀌고 저장 없이 선택한 창을 반환한다', (tester) async {
    final calls = await _pump(tester);
    expect(find.text('window.save_and_open'), findsOneWidget);
    await tester.tap(find.text(_target.title));
    await tester.pump();
    await tester.ensureVisible(find.text('window.remember'));
    await tester.tap(find.text('window.remember'));
    await tester.pumpAndSettle();
    expect(find.text('window.save_and_open'), findsNothing);
    expect(find.text('window.open'), findsOneWidget);
    await tester.tap(find.text('window.open'));
    await tester.pumpAndSettle();
    expect(calls.selected, _target);
    expect(calls.writes, isEmpty);
  });

  testWidgets('관리 화면의 저장은 연결만 저장하고 외부 창으로 이동하지 않는다', (tester) async {
    final calls = await _pump(tester, manageOnly: true);
    await tester.tap(find.text(_target.title));
    await tester.pump();
    await tester.tap(find.text('action.save'));
    await tester.pumpAndSettle();
    final saved = calls.writes.single.single;
    expect(saved.key, _key);
    expect(saved.bundleId, _target.bundleId);
    expect(saved.titlePattern, 'my-dashboard');
    expect(calls.selected, isNull);
    expect(calls.focus, 0);
  });

  testWidgets('저장 오류가 나면 선택 화면과 입력값을 남기고 이동하지 않는다', (tester) async {
    final calls = await _pump(tester, saveFails: true);
    await tester.tap(find.text(_target.title));
    await tester.pump();
    await tester.tap(find.text('window.save_and_open'));
    await tester.pumpAndSettle();
    expect(find.text('window.save_failed'), findsOneWidget);
    expect(find.byType(WindowConnectionDialog), findsOneWidget);
    expect(calls.selected, isNull);
    expect(calls.writes, isEmpty);
    expect(calls.focus, 0);
    final pattern = tester.widget<TextField>(find.byType(TextField).last);
    expect(pattern.controller!.text, 'my-dashboard');
  });

  testWidgets('같은 앱의 다른 창으로 연결을 바꾸면 이전 창 제목 조건을 남기지 않는다', (tester) async {
    final other = WindowCandidate(
      token: 'other-window-token',
      bundleId: _target.bundleId,
      appName: _target.appName,
      title: 'README — other-project',
    );
    final saved = WindowConnectionRule(
      key: _key,
      bundleId: _target.bundleId,
      titlePattern: 'my-dashboard',
    );
    final calls = await _pump(
      tester,
      manageOnly: true,
      rule: saved,
      saved: [saved],
      scan: WindowScan(
        trusted: true,
        complete: true,
        localHost: _host,
        windows: [_target, other],
      ),
    );
    await tester.tap(find.text(other.title));
    await tester.pump();
    await tester.tap(find.text('action.save'));
    await tester.pumpAndSettle();
    final updated = calls.writes.single.single;
    expect(updated.matches(other), isTrue);
    expect(updated.matches(_target), isFalse);
    expect(updated.titlePattern, other.title);
    expect(updated.exactTitle, isTrue);
    expect(calls.focus, 0);
  });

  testWidgets('권한 안내에서 설정을 연 뒤 다시 찾으면 허용된 창 목록을 표시한다', (tester) async {
    final calls = await _pump(
      tester,
      scan: WindowScan(
        trusted: false,
        complete: false,
        localHost: _host,
        windows: const [],
      ),
      refreshed: _readyScan,
    );
    expect(find.text('window.permission'), findsOneWidget);
    expect(find.text('window.permission_retry'), findsOneWidget);
    expect(find.text(_target.title), findsNothing);
    await tester.tap(find.text('window.open_settings'));
    await tester.pumpAndSettle();
    expect(calls.settings, 1);
    await tester.tap(find.byTooltip('window.refresh'));
    await tester.pumpAndSettle();
    expect(find.text('window.permission'), findsNothing);
    expect(find.text(_target.title), findsOneWidget);
    expect(calls.writes, isEmpty);
    expect(calls.focus, 0);
  });

  testWidgets('불완전한 조회를 안내하고 후보가 없으면 이동 버튼을 비활성화한다', (tester) async {
    final calls = await _pump(
      tester,
      scan: WindowScan(
        trusted: true,
        complete: false,
        localHost: _host,
        windows: const [],
      ),
    );
    expect(find.text('window.partial'), findsOneWidget);
    expect(find.text('window.none'), findsOneWidget);
    final open = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'window.save_and_open'),
    );
    expect(open.onPressed, isNull);
    expect(calls.focus, 0);
    expect(calls.writes, isEmpty);
  });

  testWidgets('대상 앱을 선택하면 그 앱만 다시 조회하고 기존 선택을 해제한다', (tester) async {
    const applications = [
      WindowApplication(
        bundleId: 'com.microsoft.VSCode',
        appName: 'Visual Studio Code',
      ),
      WindowApplication(bundleId: 'com.apple.Terminal', appName: 'Terminal'),
    ];
    const terminal = WindowCandidate(
      token: 'terminal-window',
      bundleId: 'com.apple.Terminal',
      appName: 'Terminal',
      title: 'unrelated-work — zsh',
    );
    final calls = await _pump(
      tester,
      scan: WindowScan(
        trusted: true,
        complete: false,
        localHost: _host,
        windows: const [terminal],
        applications: applications,
      ),
      refreshed: WindowScan(
        trusted: true,
        complete: true,
        localHost: _host,
        windows: const [_target],
        applications: applications,
      ),
    );
    await tester.tap(find.text(terminal.title));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'window.save_and_open'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Visual Studio Code').last);
    await tester.pumpAndSettle();

    expect(calls.scannedBundleIds, [_target.bundleId]);
    expect(find.text('window.partial'), findsNothing);
    expect(find.widgetWithText(ListTile, terminal.title), findsNothing);
    expect(find.widgetWithText(ListTile, _target.title), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'window.save_and_open'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('window.refresh'));
    await tester.pumpAndSettle();
    expect(calls.scannedBundleIds, [_target.bundleId, _target.bundleId]);
    expect(calls.selected, isNull);
    expect(calls.writes, isEmpty);
    expect(calls.focus, 0);
  });

  testWidgets('관리 목록은 같은 호스트와 전체 경로의 세션을 묶고 다른 경로는 분리한다', (tester) async {
    const first = SessionViewDto(
      key: 'codex:first',
      state: 'working',
      host: _host,
      project: '/work/a/dashboard',
    );
    final sameProject = first.copyWith(key: 'claude:second', source: 'claude');
    final sameName = first.copyWith(
      key: 'codex:third',
      project: '/work/b/dashboard',
    );
    final otherHost = first.copyWith(key: 'devin:fourth', host: 'remote-mac');
    final saved = WindowConnectionRule(
      key: WindowConnectionKey(host: _host, project: '/work/saved-only'),
      bundleId: _target.bundleId,
      titlePattern: 'saved-only',
    );
    await _pump(
      tester,
      page: true,
      saved: [saved],
      sessions: [first, sameProject, sameName, otherHost],
    );
    expect(find.byType(Card), findsNWidgets(4));
    expect(find.text('dashboard · $_host'), findsNWidgets(2));
    expect(find.text('dashboard · remote-mac'), findsOneWidget);
    expect(find.text('saved-only · $_host'), findsOneWidget);
  });

  testWidgets('관리 목록에서 손상 파일 오류를 표시하며 새 저장으로 덮어쓰지 않는다', (tester) async {
    final calls = await _pump(tester, page: true, loadFails: true);
    expect(find.text('window.load_failed'), findsOneWidget);
    expect(find.text('window.refresh'), findsOneWidget);
    expect(find.text('window.add'), findsNothing);
    expect(calls.writes, isEmpty);
    expect(calls.focus, 0);
  });
}
