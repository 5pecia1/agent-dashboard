/// Devin 계정 쿼터 모델.
///
/// 데이터 원천은 Devin CLI가 `/usage`·`/session-stats`를 채우기 위해 쓰는
/// 것과 같은 Connect RPC(`SeatManagementService/GetUserStatus`)다 — 공개
/// 문서가 없는 비공식 엔드포인트라 응답 필드는 모두 선택으로 접고, CLI 버전
/// 갱신 시 계약이 달라졌는지 함께 확인한다. 인증은 요청 본문의
/// `metadata.api_key`(`~/.local/share/devin/credentials.toml`의
/// `windsurf_api_key`와 같은 값)다 — HTTP 헤더가 아니라 Codeium 계열
/// 프로토콜 관용대로 본문 메타데이터에 실린다.
library;

import 'package:my_dashboard/src/integrations/data/account_period.dart';

/// 배포 배포판(devin/windsurf)마다 `api_server_url`이 다를 수 있으므로
/// 설정값으로 받되, 비우면 표준 서버로 접는다.
const String kDevinDefaultApiServer = 'https://server.codeium.com';

const String kDevinUserStatusPath =
    '/exa.seat_management_pb.SeatManagementService/GetUserStatus';

/// 서버는 `metadata`에 비어 있지 않은 IDE/확장 이름과 버전을 요구한다
/// (누락·빈 문자열 모두 400 invalid_argument, 실측 확인). 이 엔드포인트가
/// CLI 계약이라 클라이언트 정체는 CLI의 것을 그대로 보낸다 — 버전은 계약을
/// 확인한 CLI 버전으로 고정한다.
const String kDevinClientName = 'devin-cli';
const String kDevinClientVersion = '3000.10.27';

/// 백분율 스케일(0-100). `teamclaude_models.dart`의 kPercentScale과 같은 값을
/// 이 모듈이 별도로 들고 있는 이유: 두 데이터 원천이 서로를 모르게 두기 위해.
const int kDevinPercentScale = 100;

/// `planInfo.billingStrategy`가 이 값이면 계정이 일간/주간 잔량 % 쿼터로
/// 과금된다. ACU 계정은 대신 `acuConsumed`/`acuLimit`을 보낸다.
const String kDevinBillingStrategyQuota = 'BILLING_STRATEGY_QUOTA';

/// USD micros → 달러 환산 분모 (`overageBalanceMicros`).
const int kDevinMicrosPerUsd = 1000000;

class DevinConnection {
  const DevinConnection({required this.baseUrl, required this.apiKey});

  /// Connect RPC 서버 루트(예: `https://server.codeium.com`).
  final String baseUrl;

  /// `metadata.api_key`로 들어가는 계정 키.
  final String apiKey;

  /// 서버 주소를 비우면 표준 서버로 접는다 — 개인 계정은 전부 같은 서버를
  /// 가리키므로 설정 화면에서 주소를 굳이 고치지 않아도 되게 한다.
  factory DevinConnection.parse(String url, String key) {
    final trimmed = url.trim();
    final uri = Uri.tryParse(
      trimmed.isEmpty ? kDevinDefaultApiServer : trimmed,
    );
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('devin.invalid_url');
    }
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    // RPC 경로까지 붙여 넣은 경우 루트로 정규화한다.
    if (path.endsWith(kDevinUserStatusPath)) {
      path = path.substring(0, path.length - kDevinUserStatusPath.length);
    }
    final apiKey = key.trim();
    if (apiKey.isEmpty || RegExp(r'[\r\n]').hasMatch(apiKey)) {
      throw const FormatException('devin.invalid_key');
    }
    return DevinConnection(
      baseUrl: uri.replace(path: path).toString(),
      apiKey: apiKey,
    );
  }

  Uri get userStatusUrl => Uri.parse('$baseUrl$kDevinUserStatusPath');

  @override
  bool operator ==(Object other) =>
      other is DevinConnection &&
      other.baseUrl == baseUrl &&
      other.apiKey == apiKey;
  @override
  int get hashCode => Object.hash(baseUrl, apiKey);
}

/// `GetUserStatus` 응답에서 화면이 쓰는 부분만 펼친 스냅샷.
///
/// `userStatus.planStatus` 아래 쿼터 필드는 과금 방식(`billingStrategy`)마다
/// 채워지는 칸이 다르다 — QUOTA 계정은 일간/주간 잔량 %를, ACU 계정은
/// `acuConsumed`/`acuLimit`을 보낸다. 없는 칸은 null로 두고 화면이 건너뛴다.
///
/// 단 Connect/proto3 JSON은 기본값(0)인 필드를 직렬화에서 생략한다 — 잔량이
/// 정확히 0%(소진)이면 키 자체가 응답에서 사라진다. `fromUserStatus`는
/// 리셋 시각처럼 "윈도우가 존재한다"는 양의 증거가 있는데 값만 없는 경우를
/// 0으로 복원해 "해당 없음"과 구별한다 (2026-09-28 실측: 주간 소진 계정은
/// `weeklyQuotaResetAtUnix`만 남고 `weeklyQuotaRemainingPercent`가 사라져
/// 카드가 빈 화면이 됐다).
class DevinQuota {
  const DevinQuota({
    this.accountName,
    this.planName,
    this.billingStrategy,
    this.dailyRemainingPercent,
    this.weeklyRemainingPercent,
    this.dailyResetAt,
    this.weeklyResetAt,
    this.planEndsAt,
    this.hideDailyQuota = false,
    this.overageBalanceMicros,
    this.acuConsumed,
    this.acuLimit,
  });

  /// `planInfo.devinInfo.accountDisplayName`.
  final String? accountName;

  /// `planInfo.planName`(예: `Max`).
  final String? planName;

  /// `planInfo.billingStrategy`(예: `BILLING_STRATEGY_QUOTA`).
  final String? billingStrategy;

  /// 잔량 백분율(0-100). 서버는 남은 양을 내므로 화면의 사용률은
  /// [dailyUsedPercent]/[weeklyUsedPercent]처럼 `100 - 잔량`으로 환산한다.
  /// QUOTA 계정에서 윈도우(리셋 시각)가 있는데 키가 생략된 0은 파서가
  /// 복원해 둔 값이므로 여기서도 0이다.
  final int? dailyRemainingPercent;
  final int? weeklyRemainingPercent;
  final DateTime? dailyResetAt;
  final DateTime? weeklyResetAt;

  /// `planStatus.planEnd`: end of the reported plan period, not a promised charge.
  final DateTime? planEndsAt;

  /// 플랜이 일간 쿼터를 감추라고 명시한 경우(Max 등). 이 때
  /// [dailyRemainingPercent]가 와도 화면은 일간 칸을 그리지 않는다.
  final bool hideDailyQuota;

  /// 추가 결제(on-demand) 잔액, USD micros. proto int64라 JSON 문자열로 온다.
  final int? overageBalanceMicros;

  /// ACU 과금 계정의 누적 사용량/한도. QUOTA 계정에는 없다.
  final double? acuConsumed;
  final double? acuLimit;

  int? get dailyUsedPercent => dailyRemainingPercent == null
      ? null
      : kDevinPercentScale - dailyRemainingPercent!;
  int? get weeklyUsedPercent => weeklyRemainingPercent == null
      ? null
      : kDevinPercentScale - weeklyRemainingPercent!;

  factory DevinQuota.fromUserStatus(Map<String, dynamic> json) {
    final status = json['userStatus'];
    if (status is! Map<String, dynamic>) {
      throw const FormatException('devin.invalid_response');
    }
    final plan = status['planStatus'];
    final planMap = plan is Map<String, dynamic>
        ? plan
        : const <String, dynamic>{};
    final info = planMap['planInfo'];
    final infoMap = info is Map<String, dynamic>
        ? info
        : const <String, dynamic>{};
    final devinInfo = infoMap['devinInfo'];
    final devinMap = devinInfo is Map<String, dynamic>
        ? devinInfo
        : const <String, dynamic>{};
    final billingStrategy = _string(infoMap['billingStrategy']);
    var dailyRemaining = _int(planMap['dailyQuotaRemainingPercent']);
    var weeklyRemaining = _int(planMap['weeklyQuotaRemainingPercent']);
    final dailyResetAt = _unixSeconds(planMap['dailyQuotaResetAtUnix']);
    final weeklyResetAt = _unixSeconds(planMap['weeklyQuotaResetAtUnix']);
    var acuConsumed = _double(planMap['acuConsumed']);
    final acuLimit = _double(planMap['acuLimit']);
    // proto3 JSON은 기본값(0) 필드를 생략한다 — 리셋 시각은 있는데 잔량 키가
    // 없으면 잔량이 실제 0%(소진)이다. 리셋 시각도 없으면 그 윈도우가 없는
    // 것이므로 null을 유지해 "없는 쿼터를 소진으로 착각"하지 않는다.
    if (billingStrategy == kDevinBillingStrategyQuota) {
      dailyRemaining ??= dailyResetAt != null ? 0 : null;
      weeklyRemaining ??= weeklyResetAt != null ? 0 : null;
    }
    // ACU 계정도 같은 생략 규칙 — 한도는 있는데 누적치 키가 없으면 0이다.
    acuConsumed ??= acuLimit != null ? 0.0 : null;
    return DevinQuota(
      accountName: _string(devinMap['accountDisplayName']),
      planName: _string(infoMap['planName']),
      billingStrategy: billingStrategy,
      dailyRemainingPercent: dailyRemaining,
      weeklyRemainingPercent: weeklyRemaining,
      dailyResetAt: dailyResetAt,
      weeklyResetAt: weeklyResetAt,
      planEndsAt: parseAccountPeriodEnd(planMap['planEnd']),
      hideDailyQuota: infoMap['hideDailyQuota'] == true,
      overageBalanceMicros: _int(planMap['overageBalanceMicros']),
      acuConsumed: acuConsumed,
      acuLimit: acuLimit,
    );
  }

  static String? _string(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  /// proto int64/uint64는 Connect JSON에서 문자열로 올 수 있어 둘 다 받는다.
  static int? _int(Object? value) {
    if (value is num && value.isFinite) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static double? _double(Object? value) {
    if (value is num && value.isFinite) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static DateTime? _unixSeconds(Object? value) {
    final seconds = _int(value);
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      seconds * Duration.millisecondsPerSecond,
    );
  }
}

/// USD micros를 `$7.46`/`-$1.71` 형식으로 — 부호가 달러 기호 밖에 오게 한다.
/// 음수는 초과 사용 부채(잔액 소진 뒤 추가 결제분)라 양수만큼 표시 가치가 있다.
String formatDevinOverageUsd(int micros) =>
    '${micros < 0 ? '-' : ''}\$${(micros.abs() / kDevinMicrosPerUsd).toStringAsFixed(2)}';
