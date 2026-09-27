/// macOS 실제 트레이와 사용량 컨트롤러를 확인하는 수동 QA 진입점.
/// 실행: flutter run -t tool/visual_qa/tray_usage_main.dart -d macos
/// 개인 설정은 읽지 않으며 HTTP 응답만 고정 데이터로 대체한다.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_models.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_models.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/platform/resident_mode_native.dart';
import 'package:my_dashboard/src/platform/tray_native.dart';
import 'package:my_dashboard/src/integrations/platform/tray_usage.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart';
import 'package:my_dashboard/src/rust/frb_generated.dart';
import 'package:my_dashboard/src/integrations/state/devin_usage_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/integrations/state/teamclaude_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:tray_manager/tray_manager.dart';

const _trayChannel = 'tray_manager';
const _responseDelay = Duration(seconds: 1);
const _successStatus = 200;
const _failureStatus = 503;
const _initialRequest = 1;
const _claudeInitialUsage = 0.30;
const _claudeRefreshedUsage = 0.40;
const _codexInitialUsage = 0.34;
const _codexRefreshedUsage = 0.44;
const _devinInitialRemaining = 48;
const _devinRefreshedRemaining = 38;
const _panelPadding = 24.0;
const _sectionGap = 16.0;
const _teamConnection = TeamClaudeConnection(
  baseUrl: 'https://teamclaude.example.test',
  apiKey: 'demo-only',
);
const _devinConnection = DevinConnection(
  baseUrl: 'https://devin.example.test',
  apiKey: 'demo-only',
);
const _quota = {
  'accounts': [
    {
      'name': 'QA Claude',
      'tier': {'weight': 20, 'rateLimitTier': 'default_claude_max_20x'},
    },
  ],
};

class _DemoTransport extends ChangeNotifier {
  _DemoTransport({required this.onDelayedResponse});

  final VoidCallback onDelayedResponse;
  final _requests = <String, int>{};
  bool failUsage = false;
  int successfulResponses = 0;

  int get requestCount => _requests.values.fold(0, (sum, count) => sum + count);

  void setFailure(bool fail) {
    failUsage = fail;
    notifyListeners();
  }

  Future<ApiResponse> send(ApiRequest request) async {
    final path = request.url.path;
    final count = (_requests[path] ?? 0) + 1;
    _requests[path] = count;
    final fail = failUsage;
    notifyListeners();
    // 초기 캐시는 즉시 채우고 이후 조회만 늦춰 메뉴의 즉시 열림을 확인한다.
    final delayed = count > _initialRequest && path != kTeamClaudeQuotaPath;
    if (delayed) {
      await Future<void>.delayed(_responseDelay);
    }
    if (fail) {
      if (delayed) onDelayedResponse();
      return const ApiResponse(statusCode: _failureStatus);
    }
    final initial = count == _initialRequest;
    final Map<String, Object> body;
    switch (path) {
      case kTeamClaudeStatusPath:
        body = {
          'accounts': [
            {
              'name': 'QA Claude',
              'provider': kTeamClaudeProvider,
              'quota': {
                'unified5h': initial
                    ? _claudeInitialUsage
                    : _claudeRefreshedUsage,
                'unified7d': initial
                    ? _claudeInitialUsage
                    : _claudeRefreshedUsage,
              },
            },
            {
              'name': 'QA Codex',
              'provider': kTeamCodexProvider,
              'quota': {
                'planType': 'pro',
                'unified7d': initial
                    ? _codexInitialUsage
                    : _codexRefreshedUsage,
              },
            },
          ],
        };
      case kTeamClaudeQuotaPath:
        body = _quota;
      case kDevinUserStatusPath:
        body = {
          'userStatus': {
            'planStatus': {
              'planInfo': {
                'planName': 'Max',
                'billingStrategy': 'BILLING_STRATEGY_QUOTA',
                'hideDailyQuota': true,
              },
              'weeklyQuotaRemainingPercent': initial
                  ? _devinInitialRemaining
                  : _devinRefreshedRemaining,
            },
          },
        };
      default:
        throw StateError('Unexpected QA request: $path');
    }
    successfulResponses++;
    notifyListeners();
    if (delayed) onDelayedResponse();
    return ApiResponse(statusCode: _successStatus, body: jsonEncode(body));
  }
}

class _DemoSync extends SyncController {
  @override
  SyncControllerState build() => const SyncControllerState();

  @override
  void triggerNow({bool force = false}) {}
}

class _PopupProbe extends ChangeNotifier {
  int opened = 0;
  int completed = 0;
  int responsesWhileOpen = 0;
  int openCommands = 0;

  bool get pending => opened > completed;

  void observeDelayedResponse() {
    if (!pending) return;
    responsesWhileOpen++;
    notifyListeners();
  }

  Future<void> openWindow() async {
    openCommands++;
    notifyListeners();
    await showResidentWindow();
  }

  Future<void> show() async {
    opened++;
    notifyListeners();
    try {
      await trayManager.popUpContextMenu();
    } finally {
      completed++;
      notifyListeners();
    }
  }
}

// QA 버튼도 설치된 TrayManager 리스너로 들어간다. 별도 TrayMenu를 만들지 않는다.
void _replayTrayRightClick() {
  ServicesBinding.instance.channelBuffers.push(
    _trayChannel,
    const StandardMethodCodec().encodeMethodCall(
      const MethodCall(kEventOnTrayIconRightMouseDown),
    ),
    (_) {},
  );
}

Future<void> _hideAndReplayTrayRightClick() async {
  await hideResidentWindow();
  _replayTrayRightClick();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final popup = _PopupProbe();
  final transport = _DemoTransport(
    onDelayedResponse: popup.observeDelayedResponse,
  );
  runApp(
    ProviderScope(
      overrides: [
        localeProvider.overrideWithValue(LocaleDto.ko),
        teamClaudeInitialConnectionProvider.overrideWithValue(_teamConnection),
        devinInitialConnectionProvider.overrideWithValue(_devinConnection),
        httpSendProvider.overrideWithValue(transport.send),
        syncControllerProvider.overrideWith(_DemoSync.new),
        trayOpenProvider.overrideWithValue(popup.openWindow),
        trayMuteProvider.overrideWithValue(() async => false),
        trayUnmuteProvider.overrideWithValue(() async => false),
        trayMenuPopupFnProvider.overrideWithValue(popup.show),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        home: _TrayUsageQa(transport: transport, popup: popup),
      ),
    ),
  );
}

class _TrayUsageQa extends ConsumerStatefulWidget {
  const _TrayUsageQa({required this.transport, required this.popup});

  final _DemoTransport transport;
  final _PopupProbe popup;

  @override
  ConsumerState<_TrayUsageQa> createState() => _TrayUsageQaState();
}

class _TrayUsageQaState extends ConsumerState<_TrayUsageQa> {
  @override
  void initState() {
    super.initState();
    // 초기 Timer.zero를 취소한다. 창 숨김 상태와 같은 수동 조회만 허용한다.
    ref.read(teamClaudeControllerProvider.notifier).setActive(false);
    ref.read(devinUsageControllerProvider.notifier).setActive(false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_initialize());
    });
  }

  Future<void> _initialize() async {
    await applyResidentMode(true);
    if (!mounted) return;
    await installTray(ref);
    if (!mounted) return;
    await ref.read(trayUsageRefreshFnProvider)();
  }

  @override
  Widget build(BuildContext context) {
    final teamClaude = ref.watch(teamClaudeControllerProvider);
    final devin = ref.watch(devinUsageControllerProvider);
    final labels = buildTrayUsageLabels(
      ref,
      teamClaude: teamClaude,
      devin: devin,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('트레이 사용량 QA')),
      body: ListView(
        padding: const EdgeInsets.all(_panelPadding),
        children: [
          const Text(
            '정기 조회 없음 · 실제 네트워크 없음\n'
            '1. 창을 숨기고 보라색 트레이 아이콘을 우클릭하세요.\n'
            '2. 처음 열린 메뉴: Claude 30% / Codex 34% / Devin 52%\n'
            '3. 1초 뒤 닫고 다시 열기: Claude 40% / Codex 44% / Devin 62%\n'
            '4. 실패를 켠 뒤 반복하면 마지막 성공값과 실패 안내가 남습니다.',
          ),
          const SizedBox(height: _sectionGap),
          FilledButton(
            onPressed: hideResidentWindow,
            child: const Text('창 숨기기 / Hide window'),
          ),
          FilledButton(
            onPressed: _replayTrayRightClick,
            child: const Text('트레이 메뉴 열기 / Open tray menu'),
          ),
          FilledButton(
            onPressed: _hideAndReplayTrayRightClick,
            child: const Text('숨기고 트레이 열기'),
          ),
          const Text('QA 전용: 플랫폼의 트레이 우클릭 이벤트를 재생합니다.'),
          ListenableBuilder(
            listenable: widget.popup,
            builder: (context, child) => Text(
              '메뉴 open ${widget.popup.opened} / closed '
              '${widget.popup.completed} / pending ${widget.popup.pending}\n'
              '열린 중 응답 ${widget.popup.responsesWhileOpen}회 / '
              '열기 명령 ${widget.popup.openCommands}회',
            ),
          ),
          ListenableBuilder(
            listenable: widget.transport,
            builder: (context, child) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('다음 사용량 조회부터 실패 (HTTP 503)'),
                  value: widget.transport.failUsage,
                  onChanged: widget.transport.setFailure,
                ),
                Text(
                  '요청 ${widget.transport.requestCount}회 · '
                  '성공 응답 ${widget.transport.successfulResponses}회',
                ),
              ],
            ),
          ),
          const SizedBox(height: _sectionGap),
          Text('조회 중: ${teamClaude.loading || devin.loading}'),
          SelectableText(labels.join('\n')),
        ],
      ),
    );
  }
}
