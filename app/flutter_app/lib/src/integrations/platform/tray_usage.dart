import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_models.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/integrations/state/devin_usage_provider.dart';
import 'package:my_dashboard/src/integrations/state/teamclaude_provider.dart';

const String _summarySeparator = ' · ';
const int _acuPrecision = 1;

/// 현재 캐시로만 메뉴를 만든다. 조회와 네이티브 메뉴 생애주기는 호출자가 맡는다.
List<String> buildTrayUsageLabels(
  WidgetRef ref, {
  TeamClaudeState teamClaude = const TeamClaudeState(),
  DevinUsageState devin = const DevinUsageState(),
}) {
  if (teamClaude.connection == null && devin.connection == null) return [];
  return [
    tRead(ref, 'tray.usage_title'),
    if (teamClaude.connection != null) ..._teamClaudeLabels(ref, teamClaude),
    if (devin.connection != null) ..._devinLabels(ref, devin),
  ];
}

List<String> _teamClaudeLabels(WidgetRef ref, TeamClaudeState state) {
  final labels = <String>[];
  final snapshot = state.snapshot;
  final source = tRead(ref, 'teamclaude.title');
  if (snapshot == null) {
    labels.add(_emptyLabel(ref, source, state.loading));
  } else {
    final claude = snapshot.forProvider(kTeamClaudeProvider);
    final claudeName = tRead(ref, 'teamclaude.claude');
    labels.add(
      [
        claudeName,
        if (claude.isEmpty)
          tRead(ref, 'teamclaude.no_accounts')
        else
          for (final bucket in kClaudeBuckets)
            // 별도 Fable 값이 보고된 경우에만 표시하며 주간 값을 복제하지 않는다.
            if (bucket != TeamClaudeBucket.fable ||
                claude.any((a) => a.limits[bucket]?.utilization != null))
              _totalLabel(
                ref,
                bucket,
                TeamClaudeTotal(claude, bucket, weighted: true),
              ),
      ].join(_summarySeparator),
    );
    final codex = snapshot.forProvider(kTeamCodexProvider);
    final codexName = tRead(ref, 'teamclaude.codex');
    if (codex.isEmpty) {
      labels.add(
        '$codexName$_summarySeparator${tRead(ref, 'teamclaude.no_accounts')}',
      );
    } else {
      final plans = codex.map((a) => a.plan).toSet().toList()
        ..sort((a, b) => (a ?? '').compareTo(b ?? ''));
      final metrics = <String>[];
      for (final plan in plans) {
        final accounts = codex.where((a) => a.plan == plan).toList();
        final planName = plan ?? tRead(ref, 'teamclaude.unknown_plan');
        // 요금제 미확인은 평균을 만들 근거가 없으므로 값이 있어도 집계하지 않는다.
        final metric = plan == null
            ? '${tRead(ref, TeamClaudeBucket.weekly.labelKey)} '
                  '${tRead(ref, 'tray.usage_no_data')}'
            : _totalLabel(
                ref,
                TeamClaudeBucket.weekly,
                TeamClaudeTotal(
                  accounts,
                  TeamClaudeBucket.weekly,
                  weighted: false,
                ),
              );
        metrics.add('$planName $metric');
      }
      labels.add([codexName, ...metrics].join(_summarySeparator));
    }
  }
  labels.addAll(
    _statusLabels(
      ref,
      source: source,
      errorKey: state.errorKey,
      hasCachedValue: snapshot != null,
    ),
  );
  return labels;
}

String _totalLabel(
  WidgetRef ref,
  TeamClaudeBucket bucket,
  TeamClaudeTotal total,
) {
  final percent = total.usedPercent;
  final value = percent == null
      ? tRead(ref, 'tray.usage_no_data')
      : '$percent%';
  final partial = total.partial
      ? ' (${tRead(ref, 'teamclaude.partial_compact', {'known': '${total.knownAccounts}', 'total': '${total.totalAccounts}'})})'
      : '';
  return '${tRead(ref, bucket.labelKey)} $value$partial';
}

List<String> _devinLabels(WidgetRef ref, DevinUsageState state) {
  final source = tRead(ref, 'devin.title');
  final quota = state.quota;
  final metrics = <String>[];
  if (quota != null) {
    if (quota.weeklyUsedPercent != null) {
      metrics.add('${tRead(ref, 'devin.weekly')} ${quota.weeklyUsedPercent}%');
    }
    if (!quota.hideDailyQuota && quota.dailyUsedPercent != null) {
      metrics.add('${tRead(ref, 'devin.daily')} ${quota.dailyUsedPercent}%');
    }
    if (quota.weeklyUsedPercent == null &&
        quota.dailyUsedPercent == null &&
        quota.acuConsumed != null) {
      metrics.add(
        tRead(ref, 'devin.acu', {
          'used': quota.acuConsumed!.toStringAsFixed(_acuPrecision),
          'limit': quota.acuLimit?.toStringAsFixed(0) ?? '—',
        }),
      );
    }
    if (metrics.isEmpty) metrics.add(tRead(ref, 'tray.usage_no_data'));
  }
  return [
    if (quota == null)
      _emptyLabel(ref, source, state.loading)
    else
      [
        [source, if (quota.planName != null) quota.planName!].join(' '),
        ...metrics,
      ].join(_summarySeparator),
    ..._statusLabels(
      ref,
      source: source,
      errorKey: state.errorKey,
      hasCachedValue: quota != null,
    ),
  ];
}

String _emptyLabel(WidgetRef ref, String source, bool loading) =>
    '$source$_summarySeparator${tRead(ref, loading ? 'tray.usage_loading' : 'tray.usage_no_data')}';

List<String> _statusLabels(
  WidgetRef ref, {
  required String source,
  required String? errorKey,
  required bool hasCachedValue,
}) {
  final status = [
    if (errorKey != null) tRead(ref, 'tray.usage_refresh_failed'),
    if (errorKey != null && hasCachedValue) tRead(ref, 'tray.usage_cached'),
  ];
  return status.isEmpty
      ? []
      : [
          [source, ...status].join(_summarySeparator),
        ];
}
