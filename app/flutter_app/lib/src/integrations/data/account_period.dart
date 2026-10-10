/// Parse provider period boundaries without normalizing invalid calendar dates.
library;

final _timestamp = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})'
  r'(?:\.\d{1,9})?(?:Z|([+-])(\d{2}):(\d{2}))$',
);

DateTime? parseAccountPeriodEnd(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  final match = _timestamp.firstMatch(text);
  if (match == null) return null;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final calendar = DateTime.utc(year, month, day);
  if (calendar.year != year ||
      calendar.month != month ||
      calendar.day != day ||
      int.parse(match[4]!) >= Duration.hoursPerDay ||
      int.parse(match[5]!) >= Duration.minutesPerHour ||
      int.parse(match[6]!) >= Duration.secondsPerMinute) {
    return null;
  }
  if (match[7] != null &&
      (int.parse(match[8]!) >= Duration.hoursPerDay ||
          int.parse(match[9]!) >= Duration.minutesPerHour)) {
    return null;
  }
  return DateTime.tryParse(text);
}
