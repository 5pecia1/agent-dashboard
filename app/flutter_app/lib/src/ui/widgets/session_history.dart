import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_history.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/widgets/relative_time.dart';

class SessionHistory extends ConsumerStatefulWidget {
  const SessionHistory({required this.sessionKey, super.key});

  final String sessionKey;

  @override
  ConsumerState<SessionHistory> createState() => _SessionHistoryState();
}

class _SessionHistoryState extends ConsumerState<SessionHistory> {
  List<DashboardHistoryEvent> _events = [];
  bool _loading = false;
  bool _hasError = false;
  bool _promptsOnly = false;
  bool _hasMore = false;
  int? _beforeId;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void didUpdateWidget(SessionHistory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionKey != widget.sessionKey) {
      _load(reset: true);
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading && !reset) return;
    final generation = reset ? ++_generation : _generation;
    final beforeId = reset ? null : _beforeId;
    final promptsOnly = _promptsOnly;
    setState(() {
      _loading = true;
      _hasError = false;
      if (reset) {
        _events = [];
        _beforeId = null;
        _hasMore = false;
      }
    });
    try {
      final page = await ref.read(dashboardApiProvider).history(
        sessionKey: widget.sessionKey,
        promptsOnly: promptsOnly,
        beforeId: beforeId,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _events = [..._events, ...page.events];
        _hasMore = page.hasMore;
        _beforeId = page.nextBeforeId;
        _loading = false;
        _hasError = false;
      });
    } on Object {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _hasError = true;
      });
    }
  }

  void _setPromptsOnly(bool value) {
    if (_promptsOnly == value) return;
    _promptsOnly = value;
    _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardApiConfigProvider, (previous, next) {
      _generation++;
      Future.microtask(() {
        if (mounted) _load(reset: true);
      });
    });

    final tokens = context.tokens;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                t(ref, 'session.history.title'),
                style: TextStyle(color: tokens.fg, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: t(ref, 'session.history.refresh'),
              onPressed: () => _load(reset: true),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: Text(t(ref, 'session.history.all')),
              selected: !_promptsOnly,
              onSelected: (_) => _setPromptsOnly(false),
            ),
            ChoiceChip(
              label: Text(t(ref, 'session.history.prompts')),
              selected: _promptsOnly,
              onSelected: (_) => _setPromptsOnly(true),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ..._body(tokens, nowMs),
      ],
    );
  }

  List<Widget> _body(AppTokens tokens, int nowMs) {
    if (_events.isEmpty && _loading) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: LinearProgressIndicator(),
        ),
      ];
    }
    if (_events.isEmpty && _hasError) {
      return [_ErrorRetry(tokens: tokens, onRetry: () => _load())];
    }
    if (_events.isEmpty) {
      return [
        Text(
          t(ref, 'session.history.empty'),
          style: TextStyle(color: tokens.fg2, fontSize: 12),
        ),
      ];
    }
    return [
      for (final event in _events)
        _HistoryRow(event: event, tokens: tokens, nowMs: nowMs),
      if (_hasError) _ErrorRetry(tokens: tokens, onRetry: () => _load()),
      if (_loading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: LinearProgressIndicator(),
        ),
      if (_hasMore)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _loading ? null : () => _load(),
            child: Text(t(ref, 'session.history.older')),
          ),
        ),
    ];
  }
}

class _ErrorRetry extends ConsumerWidget {
  const _ErrorRetry({required this.tokens, required this.onRetry});

  final AppTokens tokens;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          t(ref, 'session.history.error'),
          style: TextStyle(color: tokens.warn, fontSize: 12),
        ),
        TextButton(
          onPressed: onRetry,
          child: Text(t(ref, 'action.retry')),
        ),
      ],
    ),
  );
}

class _HistoryRow extends ConsumerWidget {
  const _HistoryRow({
    required this.event,
    required this.tokens,
    required this.nowMs,
  });

  final DashboardHistoryEvent event;
  final AppTokens tokens;
  final int nowMs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = event.isUserPrompt
        ? t(ref, 'session.history.user_prompt')
        : event.event;
    final timeText = relativeTimeText(
      ref,
      nowMs: nowMs,
      thenMs: event.receivedAt,
    );
    final message = event.message;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: tokens.fg2, fontSize: 11),
                ),
              ),
              Text(
                timeText,
                style: TextStyle(color: tokens.fg2, fontSize: 11),
              ),
            ],
          ),
          if (message != null && message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: SelectableText(
                message,
                style: TextStyle(color: tokens.fg, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
