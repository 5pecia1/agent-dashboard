/// "그동안 있었던 일" 패널 — 커서 이후 아직 확인하지 않은 알림 전이
/// (`SyncState.pendingAlerts`)를 접었다 펼 수 있는 목록으로 보여준다.
///
/// **알려진 한계(공개 문서화):** `sync_reducer.dart`의 `acknowledgeAlerts`/
/// `acknowledgeAllAlerts`가 `SyncController`의 공개 API로 아직 연결되어
/// 있지 않다 — 이 패널은 순수 보기 전용이고, 확인(dismiss) 액션은 이번
/// 범위 밖이다(followup으로 보고).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/widgets/relative_time.dart';
import 'package:my_dashboard/src/ui/widgets/state_chip.dart';
import 'package:my_dashboard/src/util/session_display.dart';

class CatchupPanel extends ConsumerStatefulWidget {
  const CatchupPanel({super.key, required this.pendingAlerts, this.nowMs});

  final List<TransitionDto> pendingAlerts;

  /// 테스트가 시계를 고정하는 지점. null이면 `DateTime.now()`.
  final int? nowMs;

  @override
  ConsumerState<CatchupPanel> createState() => _CatchupPanelState();
}

class _CatchupPanelState extends ConsumerState<CatchupPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final alerts = widget.pendingAlerts;
    if (alerts.isEmpty) {
      return _Shell(
        tokens: tokens,
        header: Text(t(ref, 'catchup.empty'), style: TextStyle(color: tokens.fg2, fontSize: 12)),
      );
    }

    final nowMs = widget.nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final countText = t(ref, 'catchup.count', <String, String>{'count': '${alerts.length}'});
    final toggleLabel = t(
      ref,
      _expanded ? 'catchup.toggle_collapse' : 'catchup.toggle_expand',
    );

    return _Shell(
      tokens: tokens,
      header: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t(ref, 'catchup.title'),
                    style: TextStyle(color: tokens.fg, fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  Text(countText, style: TextStyle(color: tokens.fg2, fontSize: 12)),
                ],
              ),
            ),
            Text(toggleLabel, style: TextStyle(color: tokens.accent, fontSize: 12)),
            Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              color: tokens.accent,
              size: 18,
            ),
          ],
        ),
      ),
      body: _expanded
          ? Column(
              children: [
                const Divider(height: 1),
                for (final alert in alerts.reversed)
                  _AlertRow(alert: alert, nowMs: nowMs, tokens: tokens),
              ],
            )
          : null,
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell({required this.tokens, required this.header, this.body});

  final AppTokens tokens;
  final Widget header;
  final Widget? body;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: tokens.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: tokens.fg2.withValues(alpha: 0.25)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [header, ?body],
    ),
  );
}

class _AlertRow extends ConsumerWidget {
  const _AlertRow({required this.alert, required this.nowMs, required this.tokens});

  final TransitionDto alert;
  final int nowMs;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = sessionStateDtoFromCode(alert.toState);
    final project = (alert.displayTitle?.trim().isNotEmpty ?? false)
        ? sessionDisplayName(
            project: alert.project,
            fallback: alert.sessionIdFromKey,
            displayTitle: alert.displayTitle,
          )
        : ((alert.project?.isNotEmpty ?? false)
            ? alert.project!
            : alert.sessionIdFromKey);
    final timeText = relativeTimeText(ref, nowMs: nowMs, thenMs: alert.occurredAt);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Flexible(child: StateChip(state: state)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              project,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tokens.fg, fontSize: 13),
            ),
          ),
          Text(timeText, style: TextStyle(color: tokens.fg2, fontSize: 11)),
        ],
      ),
    );
  }
}
