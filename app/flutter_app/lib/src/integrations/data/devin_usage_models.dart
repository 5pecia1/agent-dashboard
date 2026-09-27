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
class DevinQuota {
  const DevinQuota({
    this.accountName,
    this.planName,
    this.billingStrategy,
    this.dailyRemainingPercent,
    this.weeklyRemainingPercent,
    this.dailyResetAt,
    this.weeklyResetAt,
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
  final int? dailyRemainingPercent;
  final int? weeklyRemainingPercent;
  final DateTime? dailyResetAt;
  final DateTime? weeklyResetAt;

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
    return DevinQuota(
      accountName: _string(devinMap['accountDisplayName']),
      planName: _string(infoMap['planName']),
      billingStrategy: _string(infoMap['billingStrategy']),
      dailyRemainingPercent: _int(planMap['dailyQuotaRemainingPercent']),
      weeklyRemainingPercent: _int(planMap['weeklyQuotaRemainingPercent']),
      dailyResetAt: _unixSeconds(planMap['dailyQuotaResetAtUnix']),
      weeklyResetAt: _unixSeconds(planMap['weeklyQuotaResetAtUnix']),
      hideDailyQuota: infoMap['hideDailyQuota'] == true,
      overageBalanceMicros: _int(planMap['overageBalanceMicros']),
      acuConsumed: _double(planMap['acuConsumed']),
      acuLimit: _double(planMap['acuLimit']),
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
