import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_models.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/integrations/state/teamclaude_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/quota_widgets.dart';

const double kQuotaMetricWidth = 96;
const double kAccountMetricWidth = 136;
const double kQuotaDesktopWidth = 680;
const double kQuotaCompactDesktopWidth = 440;
const double kQuotaMetricCompactWidth = 60;

class TeamClaudePanel extends ConsumerStatefulWidget {
  const TeamClaudePanel({super.key});
  @override
  ConsumerState<TeamClaudePanel> createState() => _TeamClaudePanelState();
}

class _TeamClaudePanelState extends ConsumerState<TeamClaudePanel>
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
      .read(teamClaudeControllerProvider.notifier)
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
    final state = ref.watch(teamClaudeControllerProvider);
    if (state.connection == null) return const SizedBox.shrink();
    final snapshot = state.snapshot;
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height:
                  MediaQuery.sizeOf(context).width > 600 &&
                      MediaQuery.textScalerOf(context).scale(1) <= 1.2
                  ? 32
                  : null,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      t(ref, 'teamclaude.title'),
                      style: TextStyle(
                        color: tokens.fg,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (state.updatedAt != null)
                    Flexible(
                      child: Text(
                        t(ref, 'teamclaude.updated', {
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
                    ),
                ],
              ),
            ),
            if (state.loading && snapshot == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(t(ref, 'teamclaude.loading')),
              ),
            if (state.errorKey != null) ...[
              Text(
                t(ref, state.errorKey!),
                style: TextStyle(color: tokens.warn),
              ),
              if (snapshot != null)
                Text(
                  t(ref, 'teamclaude.stale'),
                  style: TextStyle(color: tokens.warn),
                ),
              if (kIsWeb && state.errorKey == 'teamclaude.network_error')
                Text(
                  t(ref, 'teamclaude.web_connection_hint'),
                  style: TextStyle(color: tokens.fg2),
                ),
            ],
            if (snapshot != null)
              LayoutBuilder(
                builder: (context, constraints) {
                  final horizontal =
                      constraints.maxWidth >= kQuotaCompactDesktopWidth &&
                      MediaQuery.textScalerOf(context).scale(1) <= 1.2;
                  final compactMetrics =
                      constraints.maxWidth < kQuotaDesktopWidth;
                  final providers = [
                    _ProviderQuota(
                      provider: kTeamClaudeProvider,
                      accounts: snapshot.forProvider(kTeamClaudeProvider),
                      compactMetrics: compactMetrics,
                    ),
                    _ProviderQuota(
                      provider: kTeamCodexProvider,
                      accounts: snapshot.forProvider(kTeamCodexProvider),
                      compactMetrics: compactMetrics,
                    ),
                  ];
                  if (horizontal) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: providers.first),
                        const SizedBox(width: 16),
                        Expanded(child: providers.last),
                      ],
                    );
                  }
                  return Column(children: providers);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _ProviderQuota extends ConsumerWidget {
  const _ProviderQuota({
    required this.provider,
    required this.accounts,
    required this.compactMetrics,
  });
  final String provider;
  final List<TeamClaudeAccount> accounts;
  final bool compactMetrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final claude = provider == kTeamClaudeProvider;
    final plans = accounts.map((a) => a.plan).toSet().toList()
      ..sort((a, b) => (a ?? '').compareTo(b ?? ''));
    final buckets = claude ? kClaudeBuckets : kCodexBuckets;
    return ExpansionTile(
      key: PageStorageKey('teamclaude-$provider'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 12),
      title: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            t(ref, claude ? 'teamclaude.claude' : 'teamclaude.codex'),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          Tooltip(
            message: t(
              ref,
              claude ? 'teamclaude.weighted' : 'teamclaude.plan_average',
            ),
            child: Text(
              t(
                ref,
                claude
                    ? 'teamclaude.weighted_short'
                    : 'teamclaude.average_short',
              ),
              style: TextStyle(color: context.tokens.fg2, fontSize: 11),
            ),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (accounts.isEmpty) Text(t(ref, 'teamclaude.no_accounts')),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (claude && accounts.isNotEmpty)
                  for (final bucket in buckets)
                    if (accounts.any(
                      (a) => a.limits[bucket]?.utilization != null,
                    ))
                      _TotalMetric(
                        label: t(ref, bucket.labelKey),
                        total: TeamClaudeTotal(
                          accounts,
                          bucket,
                          weighted: true,
                        ),
                        compact: compactMetrics,
                      ),
                if (!claude)
                  for (final plan in plans)
                    _TotalMetric(
                      label: plan ?? t(ref, 'teamclaude.unknown_plan'),
                      total: TeamClaudeTotal(
                        accounts.where((a) => a.plan == plan).toList(),
                        TeamClaudeBucket.weekly,
                        weighted: plan == null,
                      ),
                      compact: compactMetrics,
                    ),
              ],
            ),
          ],
        ),
      ),
      children: [
        for (final account in accounts)
          _AccountQuota(account: account, buckets: buckets),
      ],
    );
  }
}

class _TotalMetric extends ConsumerWidget {
  const _TotalMetric({
    required this.label,
    required this.total,
    required this.compact,
  });
  final String label;
  final TeamClaudeTotal total;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metricWidth =
        (compact ? kQuotaMetricCompactWidth : kQuotaMetricWidth) *
        MediaQuery.textScalerOf(context).scale(1);
    final partialMessage = total.partial
        ? t(ref, 'teamclaude.partial', {
            'known': '${total.knownAccounts}',
            'total': '${total.totalAccounts}',
          })
        : null;
    return SizedBox(
      width: metricWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(color: context.tokens.fg2, fontSize: 12),
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: metricWidth),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    total.usedPercent == null ? '—' : '${total.usedPercent}%',
                    style: TextStyle(
                      color: context.tokens.fg,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (partialMessage != null)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Tooltip(
                      message: partialMessage,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          t(ref, 'teamclaude.partial_compact', {
                            'known': '${total.knownAccounts}',
                            'total': '${total.totalAccounts}',
                          }),
                          style: TextStyle(
                            color: context.tokens.warn,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          QuotaBar(ratio: total.ratio),
          QuotaResetTime(keyPrefix: 'teamclaude', reset: total.nextResetAt),
        ],
      ),
    );
  }
}

class _AccountQuota extends ConsumerWidget {
  const _AccountQuota({required this.account, required this.buckets});
  final TeamClaudeAccount account;
  final List<TeamClaudeBucket> buckets;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(vertical: 12),
    decoration: BoxDecoration(
      border: Border(
        top: BorderSide(color: context.tokens.fg2.withValues(alpha: 0.15)),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(account.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        Text(
          [
            account.plan ?? t(ref, 'teamclaude.unknown_plan'),
            if (account.capacityWeight != null)
              t(ref, 'teamclaude.weight', {
                'weight': '${account.capacityWeight!.round()}',
              }),
            if (account.disabled) t(ref, 'teamclaude.disabled'),
          ].join(' · '),
          style: TextStyle(color: context.tokens.fg2, fontSize: 11),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final bucket in buckets)
              if (account.limits[bucket]?.utilization != null)
                SizedBox(
                  width:
                      kAccountMetricWidth *
                      MediaQuery.textScalerOf(context).scale(1),
                  child: _AccountMetric(account: account, bucket: bucket),
                ),
          ],
        ),
      ],
    ),
  );
}

class _AccountMetric extends ConsumerWidget {
  const _AccountMetric({required this.account, required this.bucket});
  final TeamClaudeAccount account;
  final TeamClaudeBucket bucket;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final limit = account.limits[bucket];
    final value = limit?.utilization;
    final reset = limit?.resetAt?.toLocal();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t(ref, 'teamclaude.limit_value', {
            'label': t(ref, bucket.labelKey),
            'value': value == null
                ? '—'
                : '${(value * kPercentScale).round()}%',
          }),
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 5),
        QuotaBar(ratio: value),
        QuotaResetTime(keyPrefix: 'teamclaude', reset: reset),
      ],
    );
  }
}
