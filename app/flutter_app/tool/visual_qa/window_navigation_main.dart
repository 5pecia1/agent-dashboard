/// 실제 macOS 트레이·AX 조회·창 전환을 검증하는 격리 QA 진입점.
/// 실행: mise exec -- flutter run -t tool/visual_qa/window_navigation_main.dart -d macos
/// 설정·규칙·읽음은 메모리에만 저장하며 HTTP 요청은 전송하지 않는다.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/data/window_connection.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/platform/resident_mode_native.dart';
import 'package:my_dashboard/src/platform/tray_native.dart';
import 'package:my_dashboard/src/platform/window_navigation.dart' as native;
import 'package:my_dashboard/src/routing/app_router.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart';
import 'package:my_dashboard/src/rust/frb_generated.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/state/window_connections_provider.dart';
import 'package:my_dashboard/src/state/window_navigation_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/window_connections_page.dart';
import 'package:my_dashboard/src/ui/window_navigation_actions.dart';
import 'package:tray_manager/tray_manager.dart';

const _project = '/visual-qa/my-dashboard';
const _host = 'window-qa.local';
const _initialCutoff = 10;
const _nextCutoff = 30;
const _raceDelay = Duration(seconds: 5);
const _panelPadding = 24.0;
const _sectionGap = 16.0;
const _buttonGap = 8.0;
const _trayChannel = 'tray_manager';
const _fakeSuccessStatus = 200;
const _demoConfig = DashboardConfigValues(resident: true, uiLang: 'ko');
const _sessionSpecs = <(String, String)>[
  ('claude-code', 'window-qa-claude'),
  ('codex', 'window-qa-codex'),
];

Map<String, SessionViewDto> _sessions(int cutoff) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {
    for (final (source, id) in _sessionSpecs)
      '$source:$id': SessionViewDto(
        key: '$source:$id',
        source: source,
        sessionId: id,
        state: 'waiting_input',
        host: _host,
        project: _project,
        lastMessage: 'Window navigation QA (memory only)',
        lastTransitionId: cutoff,
        updatedAt: now,
        lastOccurredAt: now,
      ),
  };
}

class _QaMemory extends ChangeNotifier {
  DashboardConfigValues config = _demoConfig;
  List<WindowConnectionRule> rules = [];
  final List<String> seen = [];
  int configWrites = 0;
  int ruleWrites = 0;
  int stubbedHttpRequests = 0;
  String activity = 'Ready';
  String focusStatus = 'No focus request';
  String scanStatus = 'No scan request';
  String selectedSession = 'None';

  void report(String value) {
    activity = value;
    notifyListeners();
  }

  Future<WindowScan> scan({String? bundleId}) async {
    scanStatus = 'Scanning ${bundleId ?? 'all apps'}';
    notifyListeners();
    final result = WindowScan.fromMap(
      await native.scanWindows(bundleId: bundleId),
    );
    scanStatus =
        'scope=${bundleId ?? 'all'} trusted=${result.trusted} '
        'complete=${result.complete} windows=${result.windows.length} '
        'applications=${result.applications.length}';
    notifyListeners();
    return result;
  }

  Future<String> focus(String token) async {
    focusStatus = 'Focusing';
    notifyListeners();
    final result = await native.focusWindow(token);
    focusStatus = result;
    notifyListeners();
    return result;
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
    stubbedHttpRequests++;
    notifyListeners();
    // 상세 화면 이력도 실제 요청을 보내지 않는다. 다른 API는 즉시 실패한다.
    if (request.url.path == kEventsPath) {
      return const ApiResponse(
        statusCode: _fakeSuccessStatus,
        body: '{"events":[],"has_more":false,"next_before_id":null}',
      );
    }
    throw StateError('QA blocked an unexpected HTTP request');
  }
}

class _DemoSync extends SyncController {
  _DemoSync(this.memory);
  final _QaMemory memory;

  @override
  SyncControllerState build() => SyncControllerState(
    sync: SyncState(
      sessions: _sessions(_initialCutoff),
      cursor: _initialCutoff,
      seenWatermark: 0,
    ),
  );

  void resetUnread() {
    state = state.copyWith(
      sync: state.sync.copyWith(
        sessions: _sessions(_initialCutoff),
        cursor: _initialCutoff,
        seenTransitionIds: {},
      ),
    );
    memory.seen.clear();
    memory.report('Reset: both sessions unread at cutoff $_initialCutoff');
  }

  void addNextAlert() {
    state = state.copyWith(
      sync: state.sync.copyWith(
        sessions: _sessions(_nextCutoff),
        cursor: _nextCutoff,
      ),
    );
    memory.report('New alert: both sessions at cutoff $_nextCutoff');
  }

  @override
  void triggerNow({bool force = false}) {}

  @override
  void setForeground(bool isForeground) {
    state = state.copyWith(isForeground: isForeground);
  }

  @override
  Future<void> markSeenThrough(String key, int transitionId) async {
    if (!state.sync.sessions.containsKey(key)) return;
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
    memory.report('Marked seen in memory only');
  }

  @override
  Future<void> markSeen(String key) async {
    final cutoff = state.sync.sessions[key]?.lastTransitionId;
    if (cutoff != null) await markSeenThrough(key, cutoff);
  }

  @override
  Future<void> ackSession(String key) async {
    memory.report('QA: acknowledgement suppressed');
  }

  @override
  Future<bool> deleteSession(String key) async {
    memory.report('QA: deletion suppressed');
    return false;
  }
}

void _replayTrayRightClick() {
  ServicesBinding.instance.channelBuffers.push(
    _trayChannel,
    const StandardMethodCodec().encodeMethodCall(
      const MethodCall(kEventOnTrayIconRightMouseDown),
    ),
    (_) {},
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final memory = _QaMemory();
  runApp(
    ProviderScope(
      overrides: [
        localeProvider.overrideWithValue(LocaleDto.ko),
        dashboardConfigValuesProvider.overrideWithValue(_demoConfig),
        configLoadFnProvider.overrideWithValue(() async => memory.config),
        configSaveFnProvider.overrideWithValue(memory.saveConfig),
        dashboardApiConfigProvider.overrideWithValue(
          DashboardApiConfig(
            baseUrl: Uri.parse('https://window-qa.example.test'),
          ),
        ),
        httpSendProvider.overrideWithValue(memory.send),
        syncControllerProvider.overrideWith(() => _DemoSync(memory)),
        windowConnectionsLoadFnProvider.overrideWithValue(
          () async => List.of(memory.rules),
        ),
        windowConnectionsSaveFnProvider.overrideWithValue(memory.saveRules),
        windowScanProvider.overrideWithValue(memory.scan),
        windowFocusProvider.overrideWithValue(memory.focus),
        trayOpenProvider.overrideWithValue(showResidentWindow),
        trayMuteProvider.overrideWithValue(() async => false),
        trayUnmuteProvider.overrideWithValue(() async => false),
        trayUsageRefreshFnProvider.overrideWithValue(() async {}),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        onGenerateRoute: generateAppRoute,
        home: _WindowNavigationQa(memory: memory),
      ),
    ),
  );
}

class _WindowNavigationQa extends ConsumerStatefulWidget {
  const _WindowNavigationQa({required this.memory});
  final _QaMemory memory;
  @override
  ConsumerState<_WindowNavigationQa> createState() =>
      _WindowNavigationQaState();
}

class _WindowNavigationQaState extends ConsumerState<_WindowNavigationQa> {
  Timer? _raceTimer;
  _DemoSync get _sync => ref.read(syncControllerProvider.notifier) as _DemoSync;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_initialize()),
    );
  }

  Future<void> _initialize() async {
    await applyResidentMode(true);
    if (!mounted) return;
    await installTray(ref, onSessionSelected: _selectSession);
    widget.memory.report(
      'Actual tray installed; data and rules are memory only',
    );
  }

  Future<void> _selectSession(SessionViewDto session) async {
    if (!mounted) return;
    widget.memory.selectedSession =
        '${session.key} captured=${session.lastTransitionId}';
    widget.memory.report('Selected tray notification');
    await openSessionWindow(context, ref, session);
  }

  void _scheduleNextAlert() {
    _raceTimer?.cancel();
    _raceTimer = Timer(_raceDelay, () {
      if (mounted) _sync.addNextAlert();
    });
    widget.memory.report(
      'New alert scheduled in ${_raceDelay.inSeconds}s; open the tray now',
    );
  }

  @override
  void dispose() {
    _raceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(syncControllerProvider).sync;
    final rules = ref.watch(windowConnectionsProvider).asData?.value ?? [];
    return Scaffold(
      appBar: AppBar(title: const Text('창 이동 QA · 메모리 전용')),
      body: ListView(
        padding: const EdgeInsets.all(_panelPadding),
        children: [
          const Text(
            'Real native scan/focus and tray. No personal config or production HTTP.\n'
            'Both sessions share $_host + $_project. Save a rule once, then use either tray row.\n'
            'Race: reset unread, schedule the new alert, open the tray/chooser before 5s, '
            'then select a window after the new alert arrives. Seen must stay cutoff=10.',
          ),
          const SizedBox(height: _sectionGap),
          Wrap(
            spacing: _buttonGap,
            runSpacing: _buttonGap,
            children: [
              FilledButton(
                onPressed: () {
                  _raceTimer?.cancel();
                  _sync.resetUnread();
                },
                child: const Text('트레이 재설정(미읽음)'),
              ),
              FilledButton(
                onPressed: _sync.addNextAlert,
                child: const Text('새 알림 (30)'),
              ),
              FilledButton(
                onPressed: _scheduleNextAlert,
                child: const Text('5초 뒤 새 알림'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const WindowConnectionsPage(),
                  ),
                ),
                child: const Text('창 연결 관리'),
              ),
              FilledButton(
                onPressed: hideResidentWindow,
                child: const Text('창 숨기기'),
              ),
              FilledButton(
                onPressed: _replayTrayRightClick,
                child: const Text('트레이 메뉴 열기'),
              ),
            ],
          ),
          const SizedBox(height: _sectionGap),
          for (final session in sync.sessions.values)
            Text(
              '${session.key}: state=${session.state} latest=${session.lastTransitionId} '
              'seen=${sync.seenTransitionIds[session.key] ?? 0} '
              'unread=${sync.isSessionUnseen(session)}',
            ),
          const SizedBox(height: _sectionGap),
          Text('Rules: ${rules.length} (shared host+project)'),
          for (final rule in rules)
            Text(
              '${rule.bundleId} · ${rule.exactTitle ? 'exact' : 'contains'} · ${rule.titlePattern}',
            ),
          const SizedBox(height: _sectionGap),
          ListenableBuilder(
            listenable: widget.memory,
            builder: (context, child) => SelectableText(
              'Activity: ${widget.memory.activity}\n'
              'Selected: ${widget.memory.selectedSession}\n'
              'Native focus: ${widget.memory.focusStatus}\n'
              'Native scan: ${widget.memory.scanStatus}\n'
              'Last seen: ${widget.memory.seen.isEmpty ? 'none' : widget.memory.seen.last}\n'
              'All seen: ${widget.memory.seen.join(', ')}\n'
              'Memory saves: config=${widget.memory.configWrites} rules=${widget.memory.ruleWrites}\n'
              'HTTP stubs=${widget.memory.stubbedHttpRequests}; network sends=0',
            ),
          ),
        ],
      ),
    );
  }
}
