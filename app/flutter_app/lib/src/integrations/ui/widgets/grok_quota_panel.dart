import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/integrations/data/grok_usage_models.dart';
import 'package:my_dashboard/src/integrations/state/grok_usage_provider.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/devin_quota_panel.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/quota_widgets.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';

class GrokQuotaPanel extends ConsumerStatefulWidget {
  const GrokQuotaPanel({super.key});
  @override
  ConsumerState<GrokQuotaPanel> createState() => _GrokQuotaPanelState();
}

class _GrokQuotaPanelState extends ConsumerState<GrokQuotaPanel>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _setActivity(WidgetsBinding.instance.lifecycleState);
    });
  }

  void _setActivity(AppLifecycleState? value) => ref
      .read(grokUsageControllerProvider.notifier)
      .setActive(
        value == null ||
            value == AppLifecycleState.resumed ||
            value == AppLifecycleState.inactive,
      );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _setActivity(state);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(grokUsageControllerProvider);
    if (!state.enabled) return const SizedBox.shrink();
    final reading = state.cliEnabled ? state.reading : null;
    final botReading = state.botEnabled ? state.botReading : null;
    final tokens = context.tokens;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final hasMetric = reading != null || botReading != null;
    return Card(
      margin: const EdgeInsets.fromLTRB(
        kUsagePanelHorizontalMargin,
        12,
        kUsagePanelHorizontalMargin,
        4,
      ),
      color: tokens.surface,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        t(ref, 'grok.title'),
                        style: TextStyle(
                          color: tokens.fg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (reading?.plan != null)
                        Text(
                          reading!.plan!,
                          style: TextStyle(color: tokens.fg2, fontSize: 12),
                        ),
                      if (state.updatedAt != null)
                        Text(
                          t(ref, 'grok.updated', {
                            'time': MaterialLocalizations.of(context)
                                .formatTimeOfDay(
                                  TimeOfDay.fromDateTime(state.updatedAt!),
                                  alwaysUse24HourFormat: true,
                                ),
                          }),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: tokens.fg2, fontSize: 11),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (state.loading && !hasMetric)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(t(ref, 'grok.loading')),
              ),
            // 마지막 숫자가 있으면 경고 문장은 그 숫자 옆 점의 툴팁으로만 둔다.
            // 숫자가 없을 때는 문장 자체가 내용이라 카드에 남긴다.
            if (state.cliEnabled && state.errorKey != null && reading == null)
              Text(
                t(ref, state.errorKey!),
                style: TextStyle(color: tokens.warn),
              ),
            if (state.botEnabled &&
                state.botErrorKey != null &&
                botReading == null)
              Text(
                t(ref, state.botErrorKey!),
                style: TextStyle(color: tokens.warn),
              ),
            if (state.cliEnabled && state.noticeKey != null)
              Text(
                t(ref, state.noticeKey!),
                style: TextStyle(color: tokens.fg2),
              ),
            if (state.botEnabled && state.botNoticeKey != null)
              Text(
                t(ref, state.botNoticeKey!),
                style: TextStyle(color: tokens.fg2),
              ),
            if (reading?.accountLabel != null)
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                child: Text(
                  reading!.accountLabel!,
                  style: TextStyle(color: tokens.fg2, fontSize: 11),
                ),
              ),
            if (hasMetric)
              Row(
                children: [
                  if (reading != null)
                    SizedBox(
                      width: kDevinMetricWidth * scale,
                      child: _GrokMetric(
                        labelKey: reading.window == GrokUsageWindow.weekly
                            ? 'grok.weekly'
                            : 'grok.monthly',
                        reading: reading,
                        warning: _staleReadingWarning(ref, state.errorKey),
                        warningKey: const ValueKey('grok-cli-reading-warning'),
                      ),
                    ),
                  if (reading != null && botReading != null)
                    const SizedBox(width: 8),
                  if (botReading != null)
                    SizedBox(
                      width: kDevinMetricWidth * scale,
                      child: _GrokMetric(
                        labelKey: 'grok.bot_metric',
                        reading: botReading,
                        showPlan: true,
                        warning: _staleReadingWarning(ref, state.botErrorKey),
                        warningKey: const ValueKey('grok-bot-reading-warning'),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

String? _staleReadingWarning(WidgetRef ref, String? errorKey) {
  if (errorKey == null) return null;
  return '${t(ref, errorKey)}\n${t(ref, 'grok.stale')}';
}

class _GrokMetric extends ConsumerWidget {
  const _GrokMetric({
    required this.labelKey,
    required this.reading,
    this.showPlan = false,
    this.warning,
    this.warningKey,
  });

  final String labelKey;
  final GrokUsageReading reading;
  final bool showPlan;
  final String? warning;
  final Key? warningKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final shown = reading.usedPercent.round();
    final percent = Text(
      t(ref, 'grok.percent', {'value': '$shown'}),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: tokens.fg,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t(ref, labelKey),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: tokens.fg2, fontSize: 12),
        ),
        if (showPlan && reading.plan != null)
          Text(
            reading.plan!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: tokens.fg2, fontSize: 11),
          ),
        const SizedBox(height: 3),
        if (warning == null)
          percent
        else
          Row(
            children: [
              Flexible(child: percent),
              _ReadingWarningDot(
                key: warningKey,
                message: warning!,
                color: tokens.warn,
              ),
            ],
          ),
        const SizedBox(height: 5),
        QuotaBar(ratio: (reading.usedPercent / 100).clamp(0, 1).toDouble()),
        QuotaResetTime(keyPrefix: 'grok', reset: reading.resetsAt),
      ],
    );
  }
}

class _ReadingWarningDot extends StatelessWidget {
  const _ReadingWarningDot({
    super.key,
    required this.message,
    required this.color,
  });

  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      child: Padding(
        padding: const EdgeInsets.only(left: 6),
        child: SizedBox(
          width: 16,
          height: 16,
          child: Center(
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
        ),
      ),
    );
  }
}
