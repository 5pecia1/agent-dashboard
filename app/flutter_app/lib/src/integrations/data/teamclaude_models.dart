/// TeamClaude 상태 응답. 제공자와 한도는 이름에서 추론하지 않는다.
library;

const String kTeamClaudeProvider = 'anthropic';
const String kTeamCodexProvider = 'codex';
const String kTeamClaudeStatusPath = '/teamclaude/status';
const String kTeamClaudeQuotaPath = '/teamclaude/quota';
const int kPercentScale = 100;
const int kMaxEpochMilliseconds = 8640000000000000;

enum TeamClaudeBucket {
  fiveHour('unified5h', 'teamclaude.five_hour'),
  weekly('unified7d', 'teamclaude.weekly'),
  fable('unified7dFable', 'teamclaude.fable');

  const TeamClaudeBucket(this.wireKey, this.labelKey);
  final String wireKey;
  final String labelKey;
}

const kClaudeBuckets = [
  TeamClaudeBucket.fiveHour,
  TeamClaudeBucket.weekly,
  TeamClaudeBucket.fable,
];
const kCodexBuckets = [TeamClaudeBucket.weekly];

class TeamClaudeConnection {
  const TeamClaudeConnection({required this.baseUrl, required this.apiKey});

  final String baseUrl;
  final String apiKey;

  /// 서버 주소 또는 TeamClaude 화면 주소를 같은 API 기준 주소로 정규화한다.
  factory TeamClaudeConnection.parse(String url, String token) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('teamclaude.invalid_url');
    }
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    path = path.replaceFirst(
      RegExp(r'/teamclaude(?:/(?:dashboard|status|quota))?$'),
      '',
    );
    final key = token.trim().replaceFirst(
      RegExp(r'^x-api-key\s*:\s*', caseSensitive: false),
      '',
    );
    if (key.isEmpty || RegExp(r'[\r\n]').hasMatch(key)) {
      throw const FormatException('teamclaude.invalid_key');
    }
    return TeamClaudeConnection(
      baseUrl: uri.replace(path: path).toString(),
      apiKey: key,
    );
  }

  Uri get statusUrl => Uri.parse('$baseUrl$kTeamClaudeStatusPath');
  Uri get quotaUrl => Uri.parse('$baseUrl$kTeamClaudeQuotaPath');

  @override
  bool operator ==(Object other) =>
      other is TeamClaudeConnection &&
      other.baseUrl == baseUrl &&
      other.apiKey == apiKey;
  @override
  int get hashCode => Object.hash(baseUrl, apiKey);
}

class TeamClaudeLimit {
  const TeamClaudeLimit({this.utilization, this.resetAt});
  final double? utilization;
  final DateTime? resetAt;

  factory TeamClaudeLimit.fromValues(Object? usage, Object? reset) {
    final value = usage is num && usage.isFinite && usage >= 0 && usage <= 1
        ? usage.toDouble()
        : null;
    DateTime? at;
    if (reset is num &&
        reset.isFinite &&
        reset.abs() <= kMaxEpochMilliseconds) {
      at = DateTime.fromMillisecondsSinceEpoch(reset.toInt());
    } else if (reset is String) {
      at = DateTime.tryParse(reset);
    }
    return TeamClaudeLimit(utilization: value, resetAt: at);
  }
}

class TeamClaudeAccount {
  const TeamClaudeAccount({
    required this.name,
    required this.provider,
    required this.limits,
    this.disabled = false,
    this.plan,
    this.capacityWeight,
  });
  final String name;
  final String provider;
  final bool disabled;
  final String? plan;
  final double? capacityWeight;
  final Map<TeamClaudeBucket, TeamClaudeLimit> limits;

  factory TeamClaudeAccount.fromJson(
    Map<String, dynamic> json, {
    Map<String, dynamic>? summary,
  }) {
    if (json['name'] is! String || json['provider'] is! String) {
      throw const FormatException('teamclaude.invalid_response');
    }
    final quota = json['quota'] is Map<String, dynamic>
        ? json['quota'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final scoped = quota['scopedWeekly'];
    final fable = scoped is Map ? scoped['fable'] : null;
    final scopedFable = fable is Map
        ? TeamClaudeLimit.fromValues(fable['utilization'], fable['resetAt'])
        : null;
    final tier = summary?['tier'];
    final weight = tier is Map ? tier['weight'] : null;
    final rateTier = tier is Map ? tier['rateLimitTier'] : null;
    final seatTier = tier is Map ? tier['seatTier'] : null;
    final plan = json['provider'] == kTeamCodexProvider
        ? quota['planType']
        : (seatTier ?? rateTier);
    return TeamClaudeAccount(
      name: json['name'] as String,
      provider: json['provider'] as String,
      disabled: json['disabled'] == true,
      plan: plan is String && plan.isNotEmpty ? plan : null,
      capacityWeight:
          json['provider'] == kTeamClaudeProvider &&
              weight is num &&
              weight.isFinite &&
              weight > 0
          ? weight.toDouble()
          : null,
      limits: Map.unmodifiable({
        for (final bucket in TeamClaudeBucket.values)
          bucket:
              bucket == TeamClaudeBucket.fable &&
                  scopedFable?.utilization != null
              ? scopedFable!
              : TeamClaudeLimit.fromValues(
                  quota[bucket.wireKey],
                  quota['${bucket.wireKey}Reset'],
                ),
      }),
    );
  }
}

class TeamClaudeSnapshot {
  const TeamClaudeSnapshot({required this.accounts});
  final List<TeamClaudeAccount> accounts;

  factory TeamClaudeSnapshot.fromJson(
    Map<String, dynamic> json, {
    Map<String, dynamic>? quota,
  }) {
    final rows = json['accounts'];
    if (rows is! List || rows.any((row) => row is! Map<String, dynamic>)) {
      throw const FormatException('teamclaude.invalid_response');
    }
    final summaries = quota?['accounts'];
    final byName = <String, List<Map<String, dynamic>>>{};
    if (summaries is List) {
      for (final row in summaries.whereType<Map<String, dynamic>>()) {
        if (row['name'] is String) {
          byName.putIfAbsent(row['name'] as String, () => []).add(row);
        }
      }
    }
    // quota에는 provider/ID가 없으므로 양쪽에서 이름이 유일할 때만 결합한다.
    // 제공자 분류 자체는 항상 status.provider를 사용한다.
    final counts = <Object?, int>{};
    for (final row in rows.cast<Map<String, dynamic>>()) {
      counts.update(row['name'], (n) => n + 1, ifAbsent: () => 1);
    }
    return TeamClaudeSnapshot(
      accounts: List.unmodifiable([
        for (final row in rows.cast<Map<String, dynamic>>())
          TeamClaudeAccount.fromJson(
            row,
            summary:
                counts[row['name']] == 1 && byName[row['name']]?.length == 1
                ? byName[row['name']]!.single
                : null,
          ),
      ]),
    );
  }

  List<TeamClaudeAccount> forProvider(String provider) => accounts
      .where((account) => account.provider == provider)
      .toList(growable: false);
}

/// Claude는 서버가 제공한 용량으로 가중하고, Codex는 동일 요금제끼리 평균한다.
/// 미관측 값과 알 수 없는 용량은 제외하고 부분 집계로 표시한다.
class TeamClaudeTotal {
  TeamClaudeTotal(
    List<TeamClaudeAccount> accounts,
    TeamClaudeBucket bucket, {
    required bool weighted,
    DateTime? now,
  }) : totalAccounts = accounts.length {
    final referenceTime = now ?? DateTime.now();
    for (final account in accounts) {
      final reset = account.limits[bucket]?.resetAt;
      if (reset != null &&
          reset.isAfter(referenceTime) &&
          (nextResetAt == null || reset.isBefore(nextResetAt!))) {
        nextResetAt = reset;
      }
    }
    if (!weighted &&
        (accounts.any(
              (a) => a.provider != kTeamCodexProvider || a.plan == null,
            ) ||
            accounts.map((a) => a.plan).toSet().length > 1)) {
      throw ArgumentError('Codex averages require one known plan');
    }
    // 상대 가중치로 정규화해 유효한 큰 수를 합할 때도 overflow가 나지 않게 한다.
    final weightScale = weighted
        ? accounts
              .where((a) => a.limits[bucket]?.utilization != null)
              .map((a) => a.capacityWeight)
              .nonNulls
              .fold(
                1.0,
                (largest, weight) => weight > largest ? weight : largest,
              )
        : 1.0;
    for (final account in accounts) {
      final value = account.limits[bucket]?.utilization;
      final weight = weighted ? account.capacityWeight : 1.0;
      if (value == null || weight == null) continue;
      knownAccounts++;
      used += value * (weight / weightScale);
      capacity += weight / weightScale;
    }
  }

  final int totalAccounts;
  DateTime? nextResetAt;
  int knownAccounts = 0;
  double used = 0;
  double capacity = 0;
  double? get ratio => knownAccounts == 0 ? null : used / capacity;
  int? get usedPercent =>
      ratio == null ? null : (ratio! * kPercentScale).round();
  bool get partial => knownAccounts < totalAccounts;
}
