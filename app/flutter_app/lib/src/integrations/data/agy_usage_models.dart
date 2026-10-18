import 'package:my_dashboard/src/integrations/data/account_period.dart';

const String kAgyFiveHourWindow = '5h';
const String kAgyWeeklyWindow = 'weekly';
const String kAgyGeminiGroup = 'Gemini Models';
const String kAgyThirdPartyGroup = 'Claude and GPT models';
const double kAgyPercentScale = 100;

class AgyQuotaBucket {
  const AgyQuotaBucket({
    required this.id,
    required this.name,
    this.window,
    this.remainingFraction,
    this.resetsAt,
  });

  final String id;
  final String name;
  final String? window;
  final double? remainingFraction;
  final DateTime? resetsAt;

  double? get usedPercent => remainingFraction == null
      ? null
      : (1 - remainingFraction!) * kAgyPercentScale;

  String? get labelKey => switch (window) {
    kAgyFiveHourWindow => 'agy.five_hour',
    kAgyWeeklyWindow => 'agy.weekly',
    _ => null,
  };
}

class AgyQuotaGroup {
  const AgyQuotaGroup({required this.name, required this.buckets});
  final String name;
  final List<AgyQuotaBucket> buckets;

  String? get labelKey => switch (name) {
    kAgyGeminiGroup => 'agy.gemini',
    kAgyThirdPartyGroup => 'agy.third_party',
    _ => null,
  };
}

class AgyUsageReading {
  const AgyUsageReading({required this.groups});
  final List<AgyQuotaGroup> groups;
}

/// Read account quota from command.data, never the run's top-level token usage.
/// Missing values stay unknown; malformed fractions invalidate the reading.
AgyUsageReading agyUsageReadingFromJson(Object? data) {
  if (data is! Map || data['groups'] is! List) {
    throw const FormatException('Missing quota groups');
  }
  final groups = <AgyQuotaGroup>[];
  final ids = <String>{};
  for (final rawGroup in data['groups'] as List) {
    if (rawGroup is! Map || rawGroup['buckets'] is! List) {
      throw const FormatException('Invalid quota group');
    }
    final name = _requiredText(rawGroup['name']);
    final buckets = <AgyQuotaBucket>[];
    for (final raw in rawGroup['buckets'] as List) {
      if (raw is! Map) throw const FormatException('Invalid quota bucket');
      final id = _requiredText(raw['id']);
      if (!ids.add(id)) throw const FormatException('Duplicate quota bucket');
      final fraction = raw['remaining_fraction'];
      if (fraction != null &&
          (fraction is! num ||
              !fraction.isFinite ||
              fraction < 0 ||
              fraction > 1)) {
        throw const FormatException('Invalid remaining fraction');
      }
      buckets.add(
        AgyQuotaBucket(
          id: id,
          name: raw['name'] == null ? id : _requiredText(raw['name']),
          window: raw['window'] == null ? null : _requiredText(raw['window']),
          remainingFraction: (fraction as num?)?.toDouble(),
          resetsAt: parseAccountPeriodEnd(raw['reset_time']),
        ),
      );
    }
    buckets.sort((a, b) {
      final order = _windowOrder(a.window).compareTo(_windowOrder(b.window));
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
    if (buckets.isNotEmpty) {
      groups.add(
        AgyQuotaGroup(name: name, buckets: List.unmodifiable(buckets)),
      );
    }
  }
  return AgyUsageReading(groups: List.unmodifiable(groups));
}

String _requiredText(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const FormatException('Missing quota label');
  }
  return value.trim();
}

int _windowOrder(String? window) => switch (window) {
  kAgyFiveHourWindow => 0,
  kAgyWeeklyWindow => 1,
  _ => 2,
};
