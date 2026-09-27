/// 진단 화면 — `GET /dashboard/diagnostics` 스냅샷을 그대로 보여준다
/// ("왜 알림이 안 왔나"에 답하는 화면).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/template_demo_page.dart';
import 'package:my_dashboard/src/ui/widgets/relative_time.dart';

class DiagnosticsPage extends ConsumerStatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  ConsumerState<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends ConsumerState<DiagnosticsPage> {
  bool _loading = true;
  bool _hasError = false;
  DiagnosticsDto? _diagnostics;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _hasError = false;
    });
    try {
      final result = await ref.read(dashboardApiProvider).diagnostics();
      if (!mounted) return;
      setState(() {
        _diagnostics = result;
        _loading = false;
      });
    } on DashboardApiException {
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        title: Text(t(ref, 'diagnostics.title')),
        actions: [
          // T-wire: 삭제 대신 강등한 템플릿 인사말/capability 데모 화면
          // 진입점(`template_demo_page.dart` 문서 참고). 전용 i18n 키를
          // 새로 만들지 않는다 — 이 화면 범위에서 그 화면 자체가 이미
          // 쓰는 `app.title`을 툴팁으로 재사용한다(app-core 카탈로그를
          // 건드리지 않고도 `i18n_check.py`를 통과한다).
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: t(ref, 'app.title'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const TemplateDemoPage()),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 64),
                    child: Column(
                      children: [
                        CircularProgressIndicator(color: tokens.accent),
                        const SizedBox(height: 12),
                        Text(t(ref, 'diagnostics.loading'), style: TextStyle(color: tokens.fg2)),
                      ],
                    ),
                  ),
                ],
              )
            : _hasError
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
                    child: Column(
                      children: [
                        Icon(Icons.error_outline, color: tokens.warn, size: 40),
                        const SizedBox(height: 12),
                        Text(
                          t(ref, 'diagnostics.error'),
                          style: TextStyle(color: tokens.fg),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _load,
                          child: Text(t(ref, 'action.retry')),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : _DiagnosticsBody(diagnostics: _diagnostics!, tokens: tokens),
      ),
    );
  }
}

class _DiagnosticsBody extends ConsumerWidget {
  const _DiagnosticsBody({required this.diagnostics, required this.tokens});

  final DiagnosticsDto diagnostics;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final none = t(ref, 'diagnostics.none_value');
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lastEventAt = diagnostics.lastEventAt;
    final lastEventText = lastEventAt == null
        ? none
        : relativeTimeText(ref, nowMs: nowMs, thenMs: lastEventAt);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        _Row(tokens: tokens, label: t(ref, 'diagnostics.last_event_label'), value: lastEventText),
        _Row(
          tokens: tokens,
          label: t(ref, 'diagnostics.max_transition_label'),
          value: '${diagnostics.maxTransitionId}',
        ),
        _Row(
          tokens: tokens,
          label: t(ref, 'diagnostics.pruned_below_label'),
          value: '${diagnostics.prunedBelowId}',
        ),
        _Row(
          tokens: tokens,
          label: t(ref, 'diagnostics.device_failures_label'),
          value: '${diagnostics.deviceFailureCount}',
        ),
        _Row(
          tokens: tokens,
          label: t(ref, 'diagnostics.subscription_failures_label'),
          value: '${diagnostics.subscriptionFailureCount}',
        ),
        const SizedBox(height: 20),
        Text(
          t(ref, 'diagnostics.channels_title'),
          style: TextStyle(color: tokens.fg, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        if (diagnostics.channels.isEmpty)
          Text(none, style: TextStyle(color: tokens.fg2, fontSize: 12))
        else
          for (final entry in diagnostics.channels.entries)
            _Row(
              tokens: tokens,
              label: entry.key,
              value: t(ref, entry.value ? 'diagnostics.channel_ready' : 'diagnostics.channel_not_ready'),
            ),
        const SizedBox(height: 20),
        Text(
          t(ref, 'diagnostics.table_counts_title'),
          style: TextStyle(color: tokens.fg, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        if (diagnostics.tableCounts.isEmpty)
          Text(none, style: TextStyle(color: tokens.fg2, fontSize: 12))
        else
          for (final entry in diagnostics.tableCounts.entries)
            _Row(tokens: tokens, label: entry.key, value: '${entry.value}'),
        const SizedBox(height: 20),
        Text(
          t(ref, 'diagnostics.last_push_title'),
          style: TextStyle(color: tokens.fg, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        _LastPushView(entry: diagnostics.lastPush, tokens: tokens, nowMs: nowMs),
      ],
    );
  }
}

class _LastPushView extends ConsumerWidget {
  const _LastPushView({required this.entry, required this.tokens, required this.nowMs});

  final PushLogEntryDto? entry;
  final AppTokens tokens;
  final int nowMs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final push = entry;
    if (push == null) {
      return Text(t(ref, 'diagnostics.last_push_none'), style: TextStyle(color: tokens.fg2, fontSize: 12));
    }
    // transport/target/result는 서버가 주는 원문(전송 채널·대상·결과 코드)
    // 이라 번역하지 않는다 — 변수로 옮겨서 `Text()`에 리터럴이 아닌 값을
    // 넘긴다.
    final summary = '${push.transport} -> ${push.target}: ${push.result}';
    final timeText = relativeTimeText(ref, nowMs: nowMs, thenMs: push.createdAt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(summary, style: TextStyle(color: tokens.fg, fontSize: 13)),
        const SizedBox(height: 2),
        Text(timeText, style: TextStyle(color: tokens.fg2, fontSize: 11)),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.tokens, required this.label, required this.value});

  final AppTokens tokens;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: tokens.fg2, fontSize: 12),
          ),
        ),
        const SizedBox(width: 8),
        // 채널 이름·카운터는 서버가 주는 원문이라 길이를 보장할 수 없다 —
        // 라벨과 달리 값 쪽에 더 많은 폭을 주되(flex 2), 그래도 넘치면
        // 잘라낸다(좁은 폭 완료 기준 e).
        Flexible(
          flex: 2,
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: TextStyle(color: tokens.fg, fontSize: 13),
          ),
        ),
      ],
    ),
  );
}
