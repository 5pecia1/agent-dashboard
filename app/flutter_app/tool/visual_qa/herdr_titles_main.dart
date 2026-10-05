import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart';
import 'package:my_dashboard/src/rust/frb_generated.dart';
import 'package:my_dashboard/src/state/notify_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/session_detail_page.dart';
import 'package:my_dashboard/src/ui/widgets/catchup_panel.dart';
import 'package:my_dashboard/src/ui/widgets/session_card.dart';

const _project = '/visual-qa/my-dashboard';
const _host = 'title-qa.local';
const _gap = 16.0;

final _now = DateTime.now().millisecondsSinceEpoch;

final _sessions = [
  SessionViewDto(
    key: 'claude-code:title-qa-a',
    source: 'claude-code',
    sessionId: 'title-qa-a',
    state: 'waiting_input',
    project: _project,
    host: _host,
    displayTitle: '로그인 화면 수정',
    lastMessage: '변경 내용을 확인할까요?',
    updatedAt: _now,
    lastOccurredAt: _now,
    lastProgressAt: _now,
  ),
  SessionViewDto(
    key: 'codex:title-qa-b',
    source: 'codex',
    sessionId: 'title-qa-b',
    state: 'working',
    project: _project,
    host: _host,
    displayTitle: '결제 테스트 보완',
    lastMessage: '테스트를 실행하고 있습니다.',
    updatedAt: _now,
    lastOccurredAt: _now,
    lastProgressAt: _now,
  ),
];

final _alert = TransitionDto(
  id: 1,
  sessionKey: _sessions.first.key,
  source: _sessions.first.source,
  toState: 'waiting_input',
  project: _project,
  host: _host,
  displayTitle: _sessions.first.displayTitle,
  message: _sessions.first.lastMessage,
  occurredAt: _now,
  createdAt: _now,
);

class _QaSync extends SyncController {
  @override
  SyncControllerState build() => SyncControllerState(
    sync: SyncState(
      cursor: 1,
      serverTime: _now,
      sessions: {for (final session in _sessions) session.key: session},
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
        syncControllerProvider.overrideWith(_QaSync.new),
        dashboardApiConfigProvider.overrideWithValue(
          DashboardApiConfig(
            baseUrl: Uri.parse('https://title-qa.example.test'),
          ),
        ),
        httpSendProvider.overrideWithValue(
          (request) async => ApiResponse(
            statusCode: 200,
            body: jsonEncode(<String, dynamic>{
              'events': [
                <String, dynamic>{
                  'id': 1,
                  'session_key': request.url.queryParameters['session_key'],
                  'source': 'claude-code',
                  'event': 'Notification',
                  'message': '변경 내용을 확인할까요?',
                  'display_title': '이벤트 당시 작업명',
                  'received_at': _now,
                },
              ],
              'has_more': false,
              'next_before_id': null,
            }),
          ),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: const _QaHome(),
      ),
    ),
  );
}

class _QaHome extends StatelessWidget {
  const _QaHome();

  @override
  Widget build(BuildContext context) {
    final banner = payloadForAlert(_alert, stateLabel: (_) => '질문·승인 대기');
    return Scaffold(
      appBar: AppBar(title: const Text('Herdr 작업명 QA')),
      body: ListView(
        padding: const EdgeInsets.all(_gap),
        children: [
          for (final session in _sessions)
            SessionCard(
              session: session,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SessionDetailPage(session: session),
                ),
              ),
            ),
          const SizedBox(height: _gap),
          CatchupPanel(pendingAlerts: [_alert], nowMs: _now),
          const SizedBox(height: _gap),
          Text(banner.title),
          Text(banner.body),
        ],
      ),
    );
  }
}
