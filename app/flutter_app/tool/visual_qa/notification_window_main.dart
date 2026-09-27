/// 실제 macOS 배너 클릭·냉시작·창 전환을 확인하는 격리 QA 진입점.
/// 실행: mise exec -- flutter run -t tool/visual_qa/notification_window_main.dart -d macos
/// 개인 설정·토큰은 읽지 않으며 설정·읽음·규칙은 메모리에만 보관한다.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/notification_tap.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/data/window_connection.dart';
import 'package:my_dashboard/src/data/window_navigation_target.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/platform/local_notifications_native.dart' as local;
import 'package:my_dashboard/src/platform/resident_mode_native.dart';
import 'package:my_dashboard/src/platform/window_navigation.dart' as native;
import 'package:my_dashboard/src/routing/app_router.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart';
import 'package:my_dashboard/src/rust/frb_generated.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/notification_click_inbox.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/state/window_connections_provider.dart';
import 'package:my_dashboard/src/state/window_navigation_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/notification_click_actions.dart';
import 'package:my_dashboard/src/ui/window_navigation_actions.dart';

const _project = '/visual-qa/my-dashboard';
const _host = 'notification-qa.local';
const _sessionKey = 'codex:notification-window-qa';
const _serverUrl = 'https://notification-qa.example.test';
const _windowApp = String.fromEnvironment(
  'QA_WINDOW_APP',
  defaultValue: 'com.microsoft.VSCode',
);
const _windowTitle = String.fromEnvironment(
  'QA_WINDOW_TITLE',
  defaultValue: 'Dashboard',
);
const _initialCutoff = 2000000010;
const _nextCutoff = 2000000030;
const _panelPadding = 24.0;
const _sectionGap = 16.0;
const _buttonGap = 8.0;
const _config = DashboardConfigValues(resident: true, uiLang: 'ko');
const _target = WindowNavigationTarget(
  sessionKey: _sessionKey,
  project: _project,
  host: _host,
  transitionId: _initialCutoff,
);

WindowConnectionRule _defaultRule() => WindowConnectionRule(
  key: WindowConnectionKey(host: _host, project: _project),
  bundleId: _windowApp,
  titlePattern: _windowTitle,
  exactTitle: true,
);

class _QaMemory extends ChangeNotifier {
  DashboardConfigValues config = _config;
  List<WindowConnectionRule> rules = [_defaultRule()];
  final List<String> seen = [];
  String activity = '준비 중';
  String lastTap = '없음';
  String focusStatus = '아직 전환하지 않음';
  String scanStatus = '아직 조회하지 않음';
  int blockedHttpRequests = 0;
  int configWrites = 0;
  int ruleWrites = 0;

  void report(String value) {
    activity = value;
    notifyListeners();
  }

  Future<WindowScan> scan({String? bundleId}) async {
    final result = WindowScan.fromMap(await native.scanWindows(bundleId: bundleId));
    scanStatus =
        'trusted=${result.trusted} complete=${result.complete} '
        'windows=${result.windows.length}';
    notifyListeners();
    return result;
  }

  Future<String> focus(String token) async {
    focusStatus = await native.focusWindow(token);
    notifyListeners();
    return focusStatus;
  }

  Future<void> saveConfig(DashboardConfigValues value) async {
    config = value;
    configWrites++;
    notifyListeners();
  }

  Future<void> saveRules(List<WindowConnectionRule> value) async {
    rules = List.of(value);
    ruleWrites++;
    notifyListeners();
  }

  Future<ApiResponse> send(ApiRequest request) async {
    blockedHttpRequests++;
    notifyListeners();
    throw StateError('Notification QA does not send HTTP requests');
  }
}

class _QaSync extends SyncController {
  _QaSync(this.memory);
  final _QaMemory memory;
  bool hasSession = false;
  int latest = _initialCutoff;

  Map<String, SessionViewDto> get _sessions => !hasSession
      ? {}
      : {
          _sessionKey: SessionViewDto(
            key: _sessionKey,
            source: 'codex',
            sessionId: 'notification-window-qa',
            state: 'waiting_input',
            project: _project,
            host: _host,
            lastTransitionId: latest,
          ),
        };

  @override
  SyncControllerState build() =>
      const SyncControllerState(sync: SyncState(cursor: _initialCutoff, seenWatermark: 0));

  void setHasSession(bool value) {
    hasSession = value;
    _update();
  }

  void addNextAlert() {
    latest = _nextCutoff;
    _update();
    memory.report('새 전이 $_nextCutoff 도착. 이전 배너를 누르면 $_initialCutoff까지만 읽어야 함');
  }

  void resetUnread() {
    latest = _initialCutoff;
    memory.seen.clear();
    state = state.copyWith(
      sync: state.sync.copyWith(sessions: _sessions, cursor: latest, seenTransitionIds: {}),
    );
    memory.report('읽음 기록과 최신 전이를 초기화함');
  }

  void _update() {
    state = state.copyWith(
      sync: state.sync.copyWith(sessions: _sessions, cursor: latest),
    );
  }

  @override
  void triggerNow({bool force = false}) {}

  @override
  void setForeground(bool value) {
    state = state.copyWith(isForeground: value);
  }

  @override
  Future<void> markSeenThrough(String key, int transitionId) async {
    final previous = state.sync.seenTransitionIds[key] ?? 0;
    state = state.copyWith(
      sync: state.sync.copyWith(
        seenTransitionIds: {
          ...state.sync.seenTransitionIds,
          key: previous > transitionId ? previous : transitionId,
        },
      ),
    );
    memory.seen.add('$key cutoff=$transitionId');
    memory.report('원본 배너 전이까지 메모리에서 읽음 처리함');
  }

  @override
  Future<void> markSeen(String key) async => memory.report('QA: 전체 세션 읽음 요청은 억제함');

  @override
  Future<void> ackSession(String key) async => memory.report('QA: 세션 확인 요청은 억제함');

  @override
  Future<bool> deleteSession(String key) async => false;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // UI를 만들기 전에 등록·프로브한다. 냉시작 클릭은 실제 앱과 같은 inbox가
  // 첫 프레임의 consumer 등록까지 보존한다.
  local.registerNotificationTapHandler(notificationClickInbox.add);
  await local.probeNotificationSupport();
  await RustLib.init();
  final memory = _QaMemory();
  runApp(
    ProviderScope(
      overrides: [
        localeProvider.overrideWithValue(LocaleDto.ko),
        dashboardConfigValuesProvider.overrideWithValue(_config),
        configLoadFnProvider.overrideWithValue(() async => memory.config),
        configSaveFnProvider.overrideWithValue(memory.saveConfig),
        dashboardApiConfigProvider.overrideWithValue(
          DashboardApiConfig(baseUrl: Uri.parse(_serverUrl)),
        ),
        httpSendProvider.overrideWithValue(memory.send),
        syncControllerProvider.overrideWith(() => _QaSync(memory)),
        windowConnectionsLoadFnProvider.overrideWithValue(() async => List.of(memory.rules)),
        windowConnectionsSaveFnProvider.overrideWithValue(memory.saveRules),
        windowScanProvider.overrideWithValue(memory.scan),
        windowFocusProvider.overrideWithValue(memory.focus),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        onGenerateRoute: generateAppRoute,
        home: _NotificationQa(memory: memory),
      ),
    ),
  );
}

class _NotificationQa extends ConsumerStatefulWidget {
  const _NotificationQa({required this.memory});
  final _QaMemory memory;

  @override
  ConsumerState<_NotificationQa> createState() => _NotificationQaState();
}

class _NotificationQaState extends ConsumerState<_NotificationQa> {
  void Function()? _unbind;
  _QaSync get _sync => ref.read(syncControllerProvider.notifier) as _QaSync;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_initialize()));
  }

  Future<void> _initialize() async {
    await applyResidentMode(true);
    if (!mounted) return;
    widget.memory.report('실제 OS 배너 준비됨. 서버 요청·디스크 저장 없음');
    _unbind = ref.read(notificationClickInboxProvider).bind((NotificationTap tap) async {
      widget.memory.lastTap =
          'session=${tap.sessionKey} project=${tap.project} '
          'host=${tap.host} cutoff=${tap.transitionId} legacy=${tap.legacy}';
      widget.memory.report('실제 알림 클릭을 공통 창 이동 경로로 전달함');
      if (mounted) await openNotificationWindow(context, ref, tap);
    });
  }

  Future<void> _sendBanner({bool coldLaunch = false}) async {
    // QA 배너만 지운 뒤 재전송해 같은 id를 재사용해도 매번 배너가 나타난다.
    await FlutterLocalNotificationsPlugin().cancel(id: _initialCutoff);
    await local.showNotification(
      title: '[QA] my-dashboard · 창 이동 테스트',
      body: coldLaunch ? 'Cmd+Q로 앱을 종료한 뒤 이 배너를 클릭하세요.' : '$_host · 연결된 작업 창으로 이동',
      sessionKey: _sessionKey,
      project: _project,
      host: _host,
      id: _initialCutoff,
      serverUrl: _serverUrl,
    );
    if (!mounted) return;
    widget.memory.report(
      coldLaunch
          ? '배너 발신. Cmd+Q로 종료 후 알림 센터에서 QA 배너 클릭'
          : '배너 발신. 새 전이 버튼을 누른 뒤 이전 배너로 읽음 경계를 확인할 수 있음',
    );
  }

  @override
  void dispose() {
    _unbind?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(syncControllerProvider).sync;
    final rules = ref.watch(windowConnectionsProvider).asData?.value ?? [];
    final seen = sync.seenTransitionIds[_sessionKey] ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('알림 → 작업 창 QA · 메모리 전용')),
      body: ListView(
        padding: const EdgeInsets.all(_panelPadding),
        children: [
          const Text(
            '실제 OS 배너와 창 조회·전환을 사용합니다. 개인 설정과 운영 서버는 사용하지 않습니다.\n'
            '대상: my-dashboard · $_host · $_project\n'
            '기본 연결: $_windowApp · 정확한 제목 $_windowTitle. '
            '수동으로 변경한 규칙은 앱 종료 시 초기화됩니다.\n'
            '기본값은 세션 목록 없음입니다. 배너 자체의 대상과 전이로 이동·읽음이 되어야 합니다.',
          ),
          const SizedBox(height: _sectionGap),
          Wrap(
            spacing: _buttonGap,
            runSpacing: _buttonGap,
            children: [
              FilledButton(onPressed: _sendBanner, child: const Text('배너 보내기 (전이 10)')),
              FilledButton(onPressed: _sync.addNextAlert, child: const Text('새 전이 30')),
              FilledButton(onPressed: _sync.resetUnread, child: const Text('읽음 초기화')),
              FilledButton(
                onPressed: () => _sendBanner(coldLaunch: true),
                child: const Text('배너 보내기 → Cmd+Q 종료'),
              ),
              FilledButton(
                onPressed: () =>
                    openWindowTarget(context, ref, _target, configure: true, markRead: false),
                child: const Text('연결 대상 확인·변경'),
              ),
              FilledButton(onPressed: hideResidentWindow, child: const Text('대시보드 숨기기')),
            ],
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('가짜 동기화 목록에 세션 포함'),
            value: _sync.hasSession,
            onChanged: (value) => _sync.setHasSession(value ?? false),
          ),
          Text(
            'latest=${_sync.latest} seen=$seen unread=${seen < _sync.latest} '
            'cachedSessions=${sync.sessions.length}',
          ),
          Text('알림 백엔드: ${local.currentNotificationBackend.name}'),
          Text('창 규칙: ${rules.length}개'),
          for (final rule in rules)
            Text(
              '${rule.bundleId} · ${rule.exactTitle ? 'exact' : 'contains'} · ${rule.titlePattern}',
            ),
          const SizedBox(height: _sectionGap),
          ListenableBuilder(
            listenable: widget.memory,
            builder: (_, _) => SelectableText(
              'Activity: ${widget.memory.activity}\n'
              'Last tap: ${widget.memory.lastTap}\n'
              'Native focus: ${widget.memory.focusStatus}\n'
              'Native scan: ${widget.memory.scanStatus}\n'
              'Seen: ${widget.memory.seen.join(', ')}\n'
              'Memory saves: config=${widget.memory.configWrites} rules=${widget.memory.ruleWrites}\n'
              'Blocked HTTP requests=${widget.memory.blockedHttpRequests}; network sends=0',
            ),
          ),
        ],
      ),
    );
  }
}
