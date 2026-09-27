import 'package:flutter/foundation.dart' show immutable;

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/util/project_path.dart';

/// 세션과 에이전트 종류가 달라도 같은 호스트·전체 경로는 연결을 공유한다.
@immutable
class WindowConnectionKey {
  factory WindowConnectionKey({required String host, required String project}) =>
      WindowConnectionKey._(_nonBlank(host, 'host').trim(), _nonBlank(project, 'project'));

  const WindowConnectionKey._(this.host, this.project);

  final String host;
  final String project;

  static WindowConnectionKey? fromSession(SessionViewDto session) {
    final host = session.host?.trim();
    if (host == null || host.isEmpty || session.project.trim().isEmpty) {
      return null;
    }
    return WindowConnectionKey(host: host, project: session.project);
  }

  factory WindowConnectionKey.fromJson(Map<Object?, Object?> json) => WindowConnectionKey(
    host: _nonBlank(json['host'], 'host'),
    project: _nonBlank(json['project'], 'project'),
  );

  Map<String, Object?> toJson() => {'host': host, 'project': project};

  @override
  bool operator ==(Object other) =>
      other is WindowConnectionKey && host == other.host && project == other.project;

  @override
  int get hashCode => Object.hash(host, project);
}

/// 창 제목은 정규식이 아닌 대소문자를 구분하는 리터럴 조건이다.
/// 창 토큰은 네이티브 조회 수명에만 유효하므로 저장하지 않는다.
@immutable
class WindowConnectionRule {
  factory WindowConnectionRule({
    required WindowConnectionKey key,
    required String bundleId,
    required String titlePattern,
    bool exactTitle = false,
  }) => WindowConnectionRule._(
    key,
    _nonBlank(bundleId, 'bundleId').trim(),
    _nonBlank(titlePattern, 'titlePattern'),
    exactTitle,
  );

  const WindowConnectionRule._(this.key, this.bundleId, this.titlePattern, this.exactTitle);

  final WindowConnectionKey key;
  final String bundleId;
  final String titlePattern;
  final bool exactTitle;

  bool matches(WindowCandidate candidate) =>
      candidate.bundleId == bundleId &&
      (exactTitle ? candidate.title == titlePattern : candidate.title.contains(titlePattern));

  factory WindowConnectionRule.fromJson(Map<Object?, Object?> json) {
    final key = json['key'];
    final exactTitle = json['exactTitle'] ?? false;
    if (key is! Map<Object?, Object?> || exactTitle is! bool) {
      throw const FormatException('Invalid window connection rule');
    }
    return WindowConnectionRule(
      key: WindowConnectionKey.fromJson(key),
      bundleId: _nonBlank(json['bundleId'], 'bundleId'),
      titlePattern: _nonBlank(json['titlePattern'], 'titlePattern'),
      exactTitle: exactTitle,
    );
  }

  Map<String, Object?> toJson() => {
    'key': key.toJson(),
    'bundleId': bundleId,
    'titlePattern': titlePattern,
    'exactTitle': exactTitle,
  };

  @override
  bool operator ==(Object other) =>
      other is WindowConnectionRule &&
      key == other.key &&
      bundleId == other.bundleId &&
      titlePattern == other.titlePattern &&
      exactTitle == other.exactTitle;

  @override
  int get hashCode => Object.hash(key, bundleId, titlePattern, exactTitle);
}

@immutable
class WindowCandidate {
  const WindowCandidate({
    required this.token,
    required this.bundleId,
    required this.appName,
    required this.title,
    this.minimized = false,
  });

  final String token;
  final String bundleId;
  final String appName;
  final String title;
  final bool minimized;

  factory WindowCandidate.fromMap(Map<Object?, Object?> map) {
    final minimized = map['minimized'] ?? false;
    final title = map['title'];
    if (minimized is! bool || title is! String) {
      throw const FormatException('Invalid window candidate');
    }
    return WindowCandidate(
      token: _nonBlank(map['token'], 'token'),
      bundleId: _nonBlank(map['bundleId'], 'bundleId'),
      appName: _nonBlank(map['appName'], 'appName'),
      title: title,
      minimized: minimized,
    );
  }
}

@immutable
class WindowApplication {
  const WindowApplication({required this.bundleId, required this.appName});
  final String bundleId;
  final String appName;

  factory WindowApplication.fromMap(Map<Object?, Object?> map) => WindowApplication(
    bundleId: _nonBlank(map['bundleId'], 'bundleId'),
    appName: _nonBlank(map['appName'], 'appName'),
  );
}

@immutable
class WindowScan {
  WindowScan({
    required this.trusted,
    required this.complete,
    required this.localHost,
    required List<WindowCandidate> windows,
    List<WindowApplication> applications = const [],
  }) : windows = List.unmodifiable(windows),
       applications = List.unmodifiable(applications);

  final bool trusted;
  final bool complete;
  final String localHost;
  final List<WindowCandidate> windows;
  final List<WindowApplication> applications;

  factory WindowScan.fromMap(Map<Object?, Object?> map) {
    final trusted = map['trusted'];
    final complete = map['complete'];
    final windows = map['windows'];
    final localHost = map['localHost'];
    if (trusted is! bool ||
        complete is! bool ||
        windows is! List<Object?> ||
        localHost is! String) {
      throw const FormatException('Invalid window scan');
    }
    return WindowScan(
      trusted: trusted,
      complete: complete,
      localHost: localHost,
      applications: [
        for (final app in (map['applications'] as List<Object?>? ?? const []))
          if (app is Map<Object?, Object?>) WindowApplication.fromMap(app),
      ],
      windows: [
        for (final window in windows)
          if (window is Map<Object?, Object?>)
            WindowCandidate.fromMap(window)
          else
            throw const FormatException('Invalid window scan entry'),
      ],
    );
  }
}

/// 선택 화면의 추천만 정한다. 제목 일치는 자동 전환의 근거가 아니다.
List<WindowCandidate> windowSuggestionsFor(
  WindowConnectionKey key,
  Iterable<WindowCandidate> windows,
) {
  final name = projectBasename(key.project);
  if (name.isEmpty || name == '/' || name == r'\') return const [];
  final pattern = RegExp(
    '(^|[^\\p{L}\\p{N}_.-])${RegExp.escape(name)}(?=\$|[^\\p{L}\\p{N}_.-])',
    unicode: true,
  );
  return List.unmodifiable(windows.where((window) => pattern.hasMatch(window.title)));
}

String _nonBlank(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Invalid window connection field: $field');
  }
  return value;
}
