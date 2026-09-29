import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_models.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/integrations/state/devin_usage_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/quota_widgets.dart';

const double kDevinMetricWidth = 96;

/// Devin 계정 쿼터 카드. TeamClaudePanel과 나란히 놓이지만 데이터 원천은
/// 완전히 다르다 — TeamClaude는 외부 서버의 계정 묶음을, 이 카드는 Devin
/// CLI가 쓰는 GetUserStatus Connect RPC의 단일 계정 쿼터를 읽는다.
class DevinQuotaPanel extends ConsumerStatefulWidget {
  const DevinQuotaPanel({super.key});
  @override
  ConsumerState<DevinQuotaPanel> createState() => _DevinQuotaPanelState();
}

class _DevinQuotaPanelState extends ConsumerState<DevinQuotaPanel>
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
      .read(devinUsageControllerProvider.notifier)
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
    final state = ref.watch(devinUsageControllerProvider);
    if (state.connection == null) return const SizedBox.shrink();
    final quota = state.quota;
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
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        t(ref, 'devin.title'),
                        style: TextStyle(
                          color: tokens.fg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (quota?.planName != null)
                        Text(
                          quota!.planName!,
                          style: TextStyle(color: tokens.fg2, fontSize: 12),
                        ),
                      if (state.updatedAt != null)
                        Text(
                          t(ref, 'devin.updated', {
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
            if (state.loading && quota == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(t(ref, 'devin.loading')),
              ),
            if (state.errorKey != null) ...[
              Text(
                t(ref, state.errorKey!),
                style: TextStyle(color: tokens.warn),
              ),
              if (quota != null)
                Text(
                  t(ref, 'devin.stale'),
                  style: TextStyle(color: tokens.warn),
                ),
              if (kIsWeb && state.errorKey == 'devin.network_error')
                Text(
                  t(ref, 'devin.web_connection_hint'),
                  style: TextStyle(color: tokens.fg2),
                ),
            ],
            if (quota != null) _QuotaBody(quota: quota),
          ],
        ),
      ),
    );
  }
}

class _QuotaBody extends ConsumerWidget {
  const _QuotaBody({required this.quota});
  final DevinQuota quota;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final width = kDevinMetricWidth * scale;
    final showWeekly = quota.weeklyUsedPercent != null;
    final showDaily = !quota.hideDailyQuota && quota.dailyUsedPercent != null;
    final showAcu = quota.weeklyUsedPercent == null &&
        quota.dailyUsedPercent == null &&
        quota.acuConsumed != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (quota.accountName != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              quota.accountName!,
              style: TextStyle(color: tokens.fg2, fontSize: 11),
            ),
          ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            if (showWeekly)
              SizedBox(
                width: width,
                child: _QuotaMetric(
                  label: t(ref, 'devin.weekly'),
                  usedPercent: quota.weeklyUsedPercent,
                  resetAt: quota.weeklyResetAt,
                ),
              ),
            if (showDaily)
              SizedBox(
                width: width,
                child: _QuotaMetric(
                  label: t(ref, 'devin.daily'),
                  usedPercent: quota.dailyUsedPercent,
                  resetAt: quota.dailyResetAt,
                ),
              ),
            // 백분율이 하나도 없으면 ACU 누적/한도로 대체 (두 체계는 공존하지 않음).
            if (showAcu)
              SizedBox(
                width: width * 2,
                child: _AcuMetric(quota: quota),
              ),
            // 지표가 하나도 해석되지 않은 응답은 빈 공간 대신 명시한다.
            if (!showWeekly && !showDaily && !showAcu)
              Text(
                t(ref, 'devin.no_usage'),
                style: TextStyle(color: tokens.fg2, fontSize: 12),
              ),
          ],
        ),
        // 음수는 초과 사용 부채 — 소진 신호라 양수와 같이 표시한다.
        if (quota.overageBalanceMicros != null &&
            quota.overageBalanceMicros! != 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              t(ref, 'devin.overage', {
                'amount': formatDevinOverageUsd(quota.overageBalanceMicros!),
              }),
              style: TextStyle(color: tokens.fg2, fontSize: 11),
            ),
          ),
      ],
    );
  }
}

class _QuotaMetric extends StatelessWidget {
  const _QuotaMetric({
    required this.label,
    required this.usedPercent,
    this.resetAt,
  });
  final String label;
  final int? usedPercent;
  final DateTime? resetAt;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final ratio = usedPercent == null
        ? null
        : usedPercent! / kDevinPercentScale;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: tokens.fg2, fontSize: 12)),
        const SizedBox(height: 3),
        Text(
          usedPercent == null ? '—' : '$usedPercent%',
          style: TextStyle(
            color: tokens.fg,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 5),
        QuotaBar(ratio: ratio),
        QuotaResetTime(keyPrefix: 'devin', reset: resetAt),
      ],
    );
  }
}

/// 잔량 % 대신 ACU 누적치만 오는 과금 계정용 표시 — 한도가 없으면 사용량만.
class _AcuMetric extends ConsumerWidget {
  const _AcuMetric({required this.quota});
  final DevinQuota quota;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final consumed = quota.acuConsumed!;
    final limit = quota.acuLimit;
    final ratio = limit != null && limit > 0 ? consumed / limit : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t(ref, 'devin.acu_label'),
          style: TextStyle(color: tokens.fg2, fontSize: 12),
        ),
        const SizedBox(height: 3),
        Text(
          t(ref, 'devin.acu', {
            'used': consumed.toStringAsFixed(1),
            'limit': limit?.toStringAsFixed(0) ?? '—',
          }),
          style: TextStyle(
            color: tokens.fg,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 5),
        if (ratio != null) QuotaBar(ratio: ratio),
      ],
    );
  }
}
