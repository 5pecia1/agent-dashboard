/// Grok Bot 앱이 이 Mac에 남겨 둔 로그인에서 화면이 쓰는 값만 고른다.
///
/// 접근 토큰과 키체인 암호는 조회 요청을 만드는 동안에만 있고, 설정과 로그에는
/// 남기지 않는다.
library;

import 'dart:convert';

import 'package:my_dashboard/src/integrations/data/grok_usage_models.dart';

const String kGrokBotUsageEndpoint =
    'https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus';
const String kGrokBotKeychainService = 'Grok Bot Safe Storage';
const String kGrokBotKeychainAccount = 'Grok Bot Key';

enum GrokBotAuthStatus {
  ready,
  missing,
  unreadable,
  keychainDenied,
  unsupported,
}

enum GrokBotKeychainStatus { ready, denied, unavailable }

class GrokBotPreview {
  const GrokBotPreview(this.status, {this.ciphertext});

  const GrokBotPreview.missing() : this(GrokBotAuthStatus.missing);
  const GrokBotPreview.unreadable() : this(GrokBotAuthStatus.unreadable);
  const GrokBotPreview.unsupported() : this(GrokBotAuthStatus.unsupported);

  final GrokBotAuthStatus status;

  /// `safeStorage` 암호문. 로그에 찍히지 않게 [toString]에서는 뺀다.
  final String? ciphertext;

  int? get ciphertextHash => ciphertext?.hashCode;

  @override
  String toString() => 'GrokBotPreview($status)';
}

class GrokBotAuthReadResult {
  const GrokBotAuthReadResult(
    this.status, {
    this.accessToken,
    this.ciphertextHash,
  });

  const GrokBotAuthReadResult.missing() : this(GrokBotAuthStatus.missing);
  const GrokBotAuthReadResult.unreadable() : this(GrokBotAuthStatus.unreadable);
  const GrokBotAuthReadResult.keychainDenied()
    : this(GrokBotAuthStatus.keychainDenied);
  const GrokBotAuthReadResult.unsupported()
    : this(GrokBotAuthStatus.unsupported);

  final GrokBotAuthStatus status;
  final String? accessToken;
  final int? ciphertextHash;

  @override
  String toString() => 'GrokBotAuthReadResult($status)';
}

class GrokBotKeychainRead {
  const GrokBotKeychainRead(this.status, {this.password});

  const GrokBotKeychainRead.denied() : this(GrokBotKeychainStatus.denied);
  const GrokBotKeychainRead.unavailable()
    : this(GrokBotKeychainStatus.unavailable);

  final GrokBotKeychainStatus status;
  final String? password;

  @override
  String toString() => 'GrokBotKeychainRead($status)';
}

/// `sand-secrets.json`에서 활성 계정의 접근 토큰 암호문만 고른다.
/// 갱신 토큰은 읽지 않는다. `cursor-accounts` 문자열이 깨지면 [FormatException].
GrokBotPreview grokBotPreviewFromSecrets(Object? json) {
  if (json is! Map) return const GrokBotPreview.unreadable();
  final rawAccounts = json['cursor-accounts'];
  final Object? accounts;
  if (rawAccounts is String) {
    if (rawAccounts.trim().isEmpty) return const GrokBotPreview.missing();
    accounts = jsonDecode(rawAccounts);
  } else if (rawAccounts is Map) {
    accounts = rawAccounts;
  } else {
    return const GrokBotPreview.missing();
  }
  if (accounts is! Map) return const GrokBotPreview.unreadable();
  final active = accounts['active'];
  final stored = accounts['accounts'];
  if (active is! String || active.isEmpty || stored is! Map) {
    return const GrokBotPreview.missing();
  }
  final account = stored[active];
  if (account is! Map) return const GrokBotPreview.missing();
  final ciphertext = account['cursor-access-token'];
  if (ciphertext is! String ||
      ciphertext.isEmpty ||
      _hasLineBreak(ciphertext)) {
    return const GrokBotPreview.missing();
  }
  return GrokBotPreview(GrokBotAuthStatus.ready, ciphertext: ciphertext);
}

/// `security` 종료 코드로 키체인 암호를 고른다. 암호는 [toString]에 넣지 않는다.
GrokBotKeychainRead interpretGrokBotKeychain({
  required int exitCode,
  required String stdout,
  required String stderr,
}) {
  if (exitCode == 0) {
    final password = _stripTrailingNewline(stdout);
    if (password.isNotEmpty) {
      return GrokBotKeychainRead(
        GrokBotKeychainStatus.ready,
        password: password,
      );
    }
  }
  final detail = stderr.toLowerCase();
  if (detail.contains('cancel') ||
      detail.contains('not allowed') ||
      detail.contains('denied')) {
    return const GrokBotKeychainRead.denied();
  }
  return const GrokBotKeychainRead.unavailable();
}

/// `GetSandUsageStatus` JSON에서 주간 사용률과 리셋 시각만 고른다.
/// 계정 식별자와 대시보드 주소는 담지 않는다.
GrokUsageReading? grokBotReadingFromJson(Object? json) {
  if (json is! Map) return null;
  final percent = json['usagePercent'];
  if (percent is! num || !percent.isFinite) return null;
  final reset = json['nextResetTimestampUtc'];
  return GrokUsageReading(
    usedPercent: percent.toDouble().clamp(0, 100).toDouble(),
    window: GrokUsageWindow.weekly,
    plan: _optionalString(json['grokPlanLabel']),
    resetsAt: reset is String ? DateTime.tryParse(reset) : null,
  );
}

String _stripTrailingNewline(String value) {
  if (value.endsWith('\n')) {
    value = value.substring(0, value.length - 1);
    if (value.endsWith('\r')) value = value.substring(0, value.length - 1);
  }
  return value;
}

String? _optionalString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty || _hasLineBreak(trimmed)) return null;
  return trimmed;
}

bool _hasLineBreak(String value) => RegExp(r'[\r\n]').hasMatch(value);
