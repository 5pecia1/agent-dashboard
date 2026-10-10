/// Grok CLI 로그인 파일과 청구 응답에서 화면이 쓰는 값만 고른다.
///
/// 접근 토큰은 조회 요청을 만드는 동안에만 있고, 설정과 로그에는 남기지 않는다.
library;

import 'package:my_dashboard/src/integrations/data/account_period.dart';

const String kGrokAuthIssuer = 'https://auth.x.ai';
const String kGrokDefaultBillingBase = 'https://cli-chat-proxy.grok.com/v1';
const String kGrokClientTokenAuth = 'xai-grok-cli';
const Duration kGrokAuthFreshSkew = Duration(minutes: 5);

enum GrokAuthStatus { ready, missing, expired, invalid, unsupported }

enum GrokUsageWindow { weekly, monthly }

class GrokSession {
  const GrokSession({
    required this.accessToken,
    this.userId,
    this.email,
    this.expiresAt,
  });

  final String accessToken;
  final String? userId;
  final String? email;
  final DateTime? expiresAt;

  String get accountLabel => email ?? userId ?? '';

  @override
  String toString() =>
      'GrokSession(userId: $userId, email: $email, expiresAt: $expiresAt)';
}

class GrokAuthReadResult {
  const GrokAuthReadResult(this.status, {this.session});

  const GrokAuthReadResult.missing() : this(GrokAuthStatus.missing);
  const GrokAuthReadResult.expired() : this(GrokAuthStatus.expired);
  const GrokAuthReadResult.invalid() : this(GrokAuthStatus.invalid);
  const GrokAuthReadResult.unsupported() : this(GrokAuthStatus.unsupported);

  final GrokAuthStatus status;
  final GrokSession? session;

  @override
  String toString() => 'GrokAuthReadResult($status)';
}

class GrokUsageReading {
  const GrokUsageReading({
    required this.usedPercent,
    required this.window,
    this.accountLabel,
    this.plan,
    this.resetsAt,
    this.billingPeriodEndsAt,
  });

  /// 0–100.
  final double usedPercent;
  final GrokUsageWindow window;
  final String? accountLabel;
  final String? plan;
  final DateTime? resetsAt;

  /// Explicit billing period end; independent of the usage window's reset.
  final DateTime? billingPeriodEndsAt;
}

bool grokTokenIsFresh(DateTime? expiresAt, DateTime now) =>
    expiresAt == null || expiresAt.isAfter(now.add(kGrokAuthFreshSkew));

/// `auth.json` 객체에서 쓸 세션을 고른다. `https://auth.x.ai` 항목이 있으면
/// 다른 키로 넘어가지 않는다. 갱신 토큰은 읽지 않는다.
GrokAuthReadResult interpretGrokAuthJson(
  Object? json, {
  required DateTime now,
}) {
  if (json is! Map) return const GrokAuthReadResult.invalid();
  GrokSession? freshOther;
  var sawPreferred = false;
  var preferredExpired = false;
  var otherExpired = false;
  for (final entry in json.entries) {
    final name = entry.key;
    if (name is! String) continue;
    final preferred =
        name == kGrokAuthIssuer || name.startsWith('$kGrokAuthIssuer::');
    final session = _sessionFrom(entry.value);
    if (session == null) {
      if (preferred) sawPreferred = true;
      continue;
    }
    final fresh = grokTokenIsFresh(session.expiresAt, now);
    if (preferred) {
      sawPreferred = true;
      if (fresh) {
        return GrokAuthReadResult(GrokAuthStatus.ready, session: session);
      }
      preferredExpired = true;
      continue;
    }
    if (fresh) {
      freshOther ??= session;
    } else {
      otherExpired = true;
    }
  }
  if (sawPreferred) {
    return preferredExpired
        ? const GrokAuthReadResult.expired()
        : const GrokAuthReadResult.missing();
  }
  if (freshOther != null) {
    return GrokAuthReadResult(GrokAuthStatus.ready, session: freshOther);
  }
  if (otherExpired) return const GrokAuthReadResult.expired();
  return const GrokAuthReadResult.missing();
}

GrokSession? _sessionFrom(Object? value) {
  if (value is! Map) return null;
  final key = value['key'];
  if (key is! String || key.isEmpty || _hasLineBreak(key)) return null;
  final rawExpiry = value['expires_at'];
  return GrokSession(
    accessToken: key,
    userId: _optionalString(value['user_id']),
    email: _optionalString(value['email']),
    expiresAt: rawExpiry is String ? DateTime.tryParse(rawExpiry) : null,
  );
}

String? _optionalString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty || _hasLineBreak(trimmed)) return null;
  return trimmed;
}

bool _hasLineBreak(String value) => RegExp(r'[\r\n]').hasMatch(value);

/// 청구 JSON에서 주간 사용률을 우선하고, 없으면 월간 한도 대비 사용액(센트)을 쓴다.
///
/// proto3 JSON은 기본값 0인 `creditUsagePercent`를 생략한다. 주간 구간이
/// 있는데 그 키가 없으면 새 주의 0%다. `productUsage`에 사용률이 있으면
/// 그 합을 쓰고, 키가 숫자로 있으면 그 값을 그대로 쓴다.
GrokUsageReading? grokUsageReadingFromJson(
  Object? json, {
  String? accountLabel,
}) {
  final config = _billingConfig(json);
  if (config == null) return null;
  final plan = _optionalString(config['subscriptionTier']);
  final resetsAt = _resetAt(config);
  final billingPeriodEndsAt = parseAccountPeriodEnd(config['billingPeriodEnd']);
  final label = _blankToNull(accountLabel);
  GrokUsageReading weeklyReading(double usedPercent) => GrokUsageReading(
    usedPercent: usedPercent.clamp(0, 100).toDouble(),
    window: GrokUsageWindow.weekly,
    accountLabel: label,
    plan: plan,
    resetsAt: resetsAt,
    billingPeriodEndsAt: billingPeriodEndsAt,
  );
  if (config.containsKey('creditUsagePercent')) {
    final weekly = _finite(config['creditUsagePercent']);
    if (weekly != null) return weeklyReading(weekly);
  } else {
    final fromProducts = _sumProductUsagePercent(config);
    if (fromProducts != null) return weeklyReading(fromProducts);
    if (_isWeeklyPeriod(config)) return weeklyReading(0);
  }
  final limit = _money(config['monthlyLimit']);
  final used = _money(config['used']);
  if (limit == null || used == null || limit <= 0) return null;
  return GrokUsageReading(
    usedPercent: (used / limit * 100).clamp(0, 100).toDouble(),
    window: GrokUsageWindow.monthly,
    accountLabel: label,
    plan: plan,
    resetsAt: resetsAt,
    billingPeriodEndsAt: billingPeriodEndsAt,
  );
}

bool _isWeeklyPeriod(Map<String, dynamic> config) {
  final period = config['currentPeriod'];
  if (period is! Map) return false;
  final type = period['type'];
  return type is String && type.toUpperCase().contains('WEEKLY');
}

double? _sumProductUsagePercent(Map<String, dynamic> config) {
  final products = config['productUsage'];
  if (products is! List) return null;
  var sum = 0.0;
  var found = false;
  for (final item in products) {
    if (item is! Map) continue;
    final percent = _finite(item['usagePercent']);
    if (percent == null) continue;
    sum += percent;
    found = true;
  }
  return found ? sum : null;
}

Map<String, dynamic>? _billingConfig(Object? json) {
  if (json is! Map) return null;
  final nested = json['config'];
  if (nested is Map) return Map<String, dynamic>.from(nested);
  const markers = [
    'creditUsagePercent',
    'monthlyLimit',
    'used',
    'currentPeriod',
    'subscriptionTier',
  ];
  if (markers.any(json.containsKey)) {
    return Map<String, dynamic>.from(json);
  }
  return null;
}

double? _finite(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : null;

double? _money(Object? node) {
  if (node is! Map) return null;
  final raw = node['val'];
  if (raw is num && raw.isFinite) return raw.toDouble();
  if (raw is String) return double.tryParse(raw.trim());
  return null;
}

DateTime? _resetAt(Map<String, dynamic> config) {
  final period = config['currentPeriod'];
  final end = period is Map ? period['end'] : null;
  if (end is String) {
    final parsed = DateTime.tryParse(end);
    if (parsed != null) return parsed;
  }
  return null;
}

String? _blankToNull(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}

/// `Uri.resolve`는 `/v1`의 마지막 조각을 바꾸므로 경로를 직접 붙인다.
Uri grokBillingUri(Uri base, {required bool credits}) {
  final root = base.toString().replaceFirst(RegExp(r'/+$'), '');
  final query = credits ? '?format=credits' : '';
  return Uri.parse('$root/billing$query');
}

Uri resolveGrokBillingBaseValue(String? raw) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return Uri.parse(kGrokDefaultBillingBase);
  final stripped = trimmed.replaceFirst(RegExp(r'/+$'), '');
  final uri = Uri.tryParse(stripped);
  if (uri == null ||
      !const ['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty) {
    return Uri.parse(kGrokDefaultBillingBase);
  }
  return uri.replace(query: '', fragment: '');
}
