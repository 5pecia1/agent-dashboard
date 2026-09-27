/// 사용률 패널(TeamClaude·Devin)이 공유하는 게이지와 리셋 시각 위젯.
///
/// i18n 키는 [keyPrefix]로 네임스페이스를 받는다 — `<prefix>.reset_days` 같은
/// 키가 카탈로그에 있어야 한다(지금은 `teamclaude`와 `devin` 둘 다 존재).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';

/// 이 비율 이상이면 게이지를 경고 색으로 바꾼다.
const double kQuotaWarningRatio = 0.9;

/// 사용률 카드의 좌우 바깥 여백 — 나란히 놓인 카드 사이 간격은 이 값의 두 배이다.
const double kUsagePanelHorizontalMargin = 8;

/// 리셋 시각의 날짜를 로케일과 무관하게 `yyyy-MM-dd`로 고정한다.
String formatDashboardDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

class QuotaBar extends StatelessWidget {
  const QuotaBar({super.key, this.ratio});
  final double? ratio;
  @override
  Widget build(BuildContext context) => LinearProgressIndicator(
    value: ratio ?? 0,
    minHeight: 4,
    borderRadius: BorderRadius.circular(2),
    backgroundColor: context.tokens.fg2.withValues(alpha: 0.15),
    color: (ratio ?? 0) >= kQuotaWarningRatio
        ? context.tokens.warn
        : context.tokens.accent,
  );
}

class QuotaResetTime extends ConsumerWidget {
  const QuotaResetTime({super.key, required this.keyPrefix, this.reset});
  final String keyPrefix;
  final DateTime? reset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final at = reset?.toLocal();
    final style = TextStyle(color: context.tokens.fg2, fontSize: 10);
    if (at == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          t(ref, '$keyPrefix.reset_unknown'),
          style: style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    final remaining = at.difference(DateTime.now());
    final String label;
    if (remaining <= Duration.zero) {
      label = t(ref, '$keyPrefix.reset_due');
    } else if (remaining.inDays > 0) {
      label = t(ref, '$keyPrefix.reset_days', {
        'days': '${remaining.inDays}',
        'hours': '${remaining.inHours % Duration.hoursPerDay}',
      });
    } else if (remaining.inHours > 0) {
      label = t(ref, '$keyPrefix.reset_hours', {
        'hours': '${remaining.inHours}',
        'minutes': '${remaining.inMinutes % Duration.minutesPerHour}',
      });
    } else {
      label = t(ref, '$keyPrefix.reset_minutes', {
        'minutes':
            '${(remaining.inMilliseconds / Duration.millisecondsPerMinute).ceil()}',
      });
    }
    final localizations = MaterialLocalizations.of(context);
    final clock = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(at),
      alwaysUse24HourFormat: true,
    );
    final date = formatDashboardDate(at);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Tooltip(
        message: t(ref, '$keyPrefix.reset', {
          'time': '$date $clock ${at.timeZoneName}',
        }),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              t(ref, '$keyPrefix.reset_clock', {'date': date, 'time': clock}),
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
