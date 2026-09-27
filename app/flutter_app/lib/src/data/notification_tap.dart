import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;

/// 알림이 발신될 때의 대상과 읽음 경계를 보존한다. OS 알림 id는 잘릴 수
/// 있으므로 원본 전이 id는 반드시 이 payload에서만 읽는다.
@immutable
class NotificationTap {
  const NotificationTap({
    this.sessionKey,
    this.project,
    this.host,
    this.transitionId,
    this.serverUrl,
    this.legacy = false,
  });

  static const int _version = 1;
  static final RegExp _legacySessionKey = RegExp(r'^[A-Za-z0-9_-]+:[^\s{}\[\]"]+$');

  final String? sessionKey;
  final String? project;
  final String? host;
  final int? transitionId;
  final String? serverUrl;

  /// 이미 알림 센터에 전달된 구버전의 단순 세션 키만 허용한다. 이 값에는
  /// 원본 전이 id와 서버가 없으므로 대상 조회에는 쓰되 읽음 처리하지 않는다.
  final bool legacy;

  String encode() => jsonEncode(<String, Object?>{
    'version': _version,
    if (sessionKey != null) 'session_key': sessionKey,
    if (project != null) 'project': project,
    if (host != null) 'host': host,
    if (transitionId != null) 'transition_id': transitionId,
    if (safeServerUrl(serverUrl) case final String value) 'server_url': value,
  });

  static NotificationTap? decode(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    if (_legacySessionKey.hasMatch(payload)) {
      return NotificationTap(sessionKey: payload, legacy: true);
    }
    try {
      final value = jsonDecode(payload);
      if (value is! Map<String, dynamic> ||
          value['version'] is! int ||
          value['version'] != _version) {
        return null;
      }
      for (final key in const ['session_key', 'project', 'host', 'server_url']) {
        if (value[key] != null && value[key] is! String) return null;
      }
      final transitionId = value['transition_id'];
      if (transitionId != null && (transitionId is! int || transitionId <= 0)) return null;
      return NotificationTap(
        sessionKey: value['session_key'] as String?,
        project: value['project'] as String?,
        host: value['host'] as String?,
        transitionId: transitionId as int?,
        serverUrl: safeServerUrl(value['server_url'] as String?),
      );
    } on FormatException {
      return null;
    }
  }

  /// 서버 구분에는 주소만 필요하다. 인증정보·쿼리·fragment를 OS에 저장하지 않는다.
  static String? safeServerUrl(String? value) {
    final uri = value == null ? null : Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority || !const ['http', 'https'].contains(uri.scheme)) {
      return null;
    }
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
  }
}

typedef NotificationTapHandler = void Function(NotificationTap tap);
