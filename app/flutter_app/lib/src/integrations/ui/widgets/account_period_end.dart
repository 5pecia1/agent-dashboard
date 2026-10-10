import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/quota_widgets.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';

/// Show the reported period boundary without predicting renewal or payment.
class AccountPeriodEnd extends ConsumerWidget {
  const AccountPeriodEnd({super.key, required this.labelKey, this.endsAt});

  final String labelKey;
  final DateTime? endsAt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final at = endsAt?.toLocal();
    if (at == null) return const SizedBox.shrink();
    final clock = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(at), alwaysUse24HourFormat: true);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Text(
        t(ref, labelKey, {
          'time': '${formatDashboardDate(at)} $clock ${at.timeZoneName}',
        }),
        style: TextStyle(color: context.tokens.fg2, fontSize: 11),
      ),
    );
  }
}
