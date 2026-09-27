import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart';
import 'package:my_dashboard/src/rust/frb_generated.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/session_detail_page.dart';

const _sessionKey = 'claude-code:demo-history';

final _session = SessionViewDto(
  key: _sessionKey,
  state: 'waiting_input',
  source: 'claude-code',
  sessionId: 'demo-history',
  project: '/workspace/my-dashboard',
  host: 'MacBook',
  lastMessage: '저장 이력 패널 QA용 세션입니다',
  lastTransitionId: 9,
  updatedAt: DateTime.now().millisecondsSinceEpoch,
  lastOccurredAt: DateTime.now().millisecondsSinceEpoch,
);

final _alert = TransitionDto(
  id: 9,
  sessionKey: _sessionKey,
  toState: 'waiting_input',
  fromState: 'working',
  project: _session.project,
  host: _session.host,
  message: '입력이 필요합니다',
  occurredAt: DateTime.now().millisecondsSinceEpoch - 60 * 1000,
  createdAt: DateTime.now().millisecondsSinceEpoch - 60 * 1000,
);

List<Map<String, dynamic>> _fakeEvents() {
  final now = DateTime.now().millisecondsSinceEpoch;
  const specs = <(String, String?)>[
    ('Notification', '작업이 입력을 기다리고 있습니다.'),
    ('UserPromptSubmit', '세션 이력 패널을 화면 아래에 붙여줘'),
    ('PostToolUse', null),
    ('Stop', '턴을 마쳤습니다.'),
    ('UserPromptSubmit', '커서 페이지네이션으로 이전 기록을 더 읽어줘'),
    ('Notification', '권한 확인이 필요합니다.'),
    ('UserPromptSubmit', '오래된 발언도 서버 필터로 찾을 수 있어야 해'),
    ('SessionStart', null),
    ('UserPromptSubmit', '가장 오래된 페이지의 발언입니다'),
    ('Notification', '세션을 시작했습니다.'),
  ];
  return [
    for (var i = 0; i < specs.length; i++)
      <String, dynamic>{
        'id': 40 - i,
        'session_key': _sessionKey,
        'source': 'claude-code',
        'event': specs[i].$1,
        'message': specs[i].$2,
        'received_at': now - (i + 1) * 5 * 60 * 1000,
      },
  ];
}

ApiResponse _historyResponse(ApiRequest request) {
  final all = _fakeEvents();
  final params = request.url.queryParameters;
  var rows = all;
  if (params['kind'] == 'prompts') {
    rows = rows.where((e) => e['event'] == 'UserPromptSubmit').toList();
  }
  final beforeId = int.tryParse(params['before_id'] ?? '');
  if (beforeId != null) {
    rows = rows.where((e) => (e['id'] as int) < beforeId).toList();
  }
  const pageSize = 4;
  final page = rows.take(pageSize).toList();
  final hasMore = rows.length > pageSize;
  return ApiResponse(
    statusCode: 200,
    body: jsonEncode(<String, dynamic>{
      'events': page,
      'has_more': hasMore,
      'next_before_id': hasMore ? page.last['id'] : null,
    }),
  );
}

class _DemoSync extends SyncController {
  @override
  SyncControllerState build() => SyncControllerState(
    sync: SyncState(
      cursor: 1,
      sessions: {_session.key: _session},
      pendingAlerts: [_alert],
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(
    ProviderScope(
      overrides: [
        localeProvider.overrideWithValue(LocaleDto.ko),
        syncControllerProvider.overrideWith(_DemoSync.new),
        dashboardApiConfigProvider.overrideWithValue(
          DashboardApiConfig(baseUrl: Uri.parse('https://dashboard.example.test')),
        ),
        httpSendProvider.overrideWithValue(
          (request) async => request.url.path == kEventsPath
              ? _historyResponse(request)
              : const ApiResponse(statusCode: 200, body: '{}'),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        home: SessionDetailPage(session: _session),
      ),
    ),
  );
}
