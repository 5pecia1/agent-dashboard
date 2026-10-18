import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/integrations/data/agy_usage_models.dart';
import 'package:my_dashboard/src/integrations/state/agy_usage_provider.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/quota_widgets.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';

const double kAgyMetricWidth = 104;
const double _metricGap = 12;
const double _warningDotSize = 8;

class AgyQuotaPanel extends ConsumerStatefulWidget {
  const AgyQuotaPanel({super.key});
  @override
  ConsumerState<AgyQuotaPanel> createState() => _AgyQuotaPanelState();
}

class _AgyQuotaPanelState extends ConsumerState<AgyQuotaPanel>
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
      .read(agyUsageControllerProvider.notifier)
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
    final state = ref.watch(agyUsageControllerProvider);
    if (!state.enabled) return const SizedBox.shrink();
    final tokens = context.tokens;
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  t(ref, 'agy.title'),
                  style: TextStyle(
                    color: tokens.fg,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (state.updatedAt != null)
                  Text(
                    t(ref, 'agy.updated', {
                      'time': MaterialLocalizations.of(context).formatTimeOfDay(
                        TimeOfDay.fromDateTime(state.updatedAt!),
                        alwaysUse24HourFormat: true,
                      ),
                    }),
                    style: TextStyle(color: tokens.fg2, fontSize: 11),
                  ),
              ],
            ),
            if (state.reading == null && state.loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(t(ref, 'agy.loading')),
              ),
            if (state.reading == null && state.errorKey != null)
              Text(
                t(ref, state.errorKey!),
                style: TextStyle(color: tokens.warn),
              ),
            if (state.reading != null)
              for (final group in state.reading!.groups)
                _QuotaGroup(group: group, errorKey: state.errorKey),
          ],
        ),
      ),
    );
  }
}

class _QuotaGroup extends ConsumerWidget {
  const _QuotaGroup({required this.group, this.errorKey});
  final AgyQuotaGroup group;
  final String? errorKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            group.labelKey == null ? group.name : t(ref, group.labelKey!),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.tokens.fg,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: _metricGap,
              runSpacing: _metricGap,
              children: [
                for (final bucket in group.buckets)
                  SizedBox(
                    width: math.min(
                      kAgyMetricWidth * scale,
                      constraints.maxWidth,
                    ),
                    child: _QuotaMetric(bucket: bucket, errorKey: errorKey),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuotaMetric extends ConsumerWidget {
  const _QuotaMetric({required this.bucket, this.errorKey});
  final AgyQuotaBucket bucket;
  final String? errorKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final used = bucket.usedPercent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          bucket.labelKey == null ? bucket.name : t(ref, bucket.labelKey!),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: tokens.fg2, fontSize: 12),
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            Flexible(
              child: Text(
                used == null
                    ? t(ref, 'agy.unknown')
                    : t(ref, 'agy.percent', {'value': '${used.round()}'}),
                key: ValueKey('agy-percent-${bucket.id}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: tokens.fg,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (errorKey != null)
              Tooltip(
                message: '${t(ref, errorKey!)}\n${t(ref, 'agy.stale')}',
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: Center(
                      child: Container(
                        key: ValueKey('agy-warning-${bucket.id}'),
                        width: _warningDotSize,
                        height: _warningDotSize,
                        decoration: BoxDecoration(
                          color: tokens.warn,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 5),
        QuotaBar(ratio: used == null ? null : used / kAgyPercentScale),
        QuotaResetTime(keyPrefix: 'agy', reset: bucket.resetsAt),
      ],
    );
  }
}
