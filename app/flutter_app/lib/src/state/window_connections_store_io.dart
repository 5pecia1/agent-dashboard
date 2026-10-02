import 'dart:convert';
import 'dart:io';

import 'package:my_dashboard/src/data/window_connection.dart';
import 'package:my_dashboard/src/state/dangling_link_io.dart';

const _schemaVersion = 1;
const _danglingLinkMessage = 'The link target does not exist';
const _stateRelativePath = '.local/state/my-dashboard';
const _rulesFilename = 'window-connections.json';
const _privateDirectoryMode = '700';
const _privateFileMode = '600';

WindowConnectionsFileStore _defaultStore() {
  final home = Platform.environment['HOME'];
  if (home == null || home.trim().isEmpty) {
    throw const FileSystemException('User home directory is unavailable');
  }
  return WindowConnectionsFileStore(
    File('$home/$_stateRelativePath/$_rulesFilename'),
  );
}

Future<List<WindowConnectionRule>> loadWindowConnections() =>
    _defaultStore().load();

Future<void> saveWindowConnections(List<WindowConnectionRule> rules) =>
    _defaultStore().save(rules);

/// 임시 파일과 원본을 같은 파일시스템에 두고 rename으로 교체한다.
/// 손상된 파일은 빈 규칙으로 접지 않아 다음 저장으로 소실되지 않게 한다.
class WindowConnectionsFileStore {
  const WindowConnectionsFileStore(this.file);

  final File file;

  /// 파일이 없을 때(ENOENT)만 빈 목록이다. 존재 여부를 먼저 묻지 않는다 —
  /// `exists()`는 경로가 디렉터리이거나 상위 디렉터리를 검색할 수 없을 때도
  /// false라서, 읽을 수 없는 규칙을 빈 목록으로 보여 주고 다음 저장이
  /// 덮어쓰게 된다. 경로 위의 대상 없는 링크(파일 자신이나 상위 디렉터리)도
  /// 빈 목록이 아니다 — 빈 목록으로 보이면 다음 저장의 rename이 링크를 일반
  /// 파일로 바꾼다(`dangling_link_io.dart`). 그때는 `PathNotFoundException`이
  /// 아닌 [FileSystemException]을 던져 화면이 오류를 보이고 저장하지 않게 한다.
  Future<List<WindowConnectionRule>> load() async {
    final String text;
    try {
      text = await file.readAsString();
    } on PathNotFoundException {
      final link = await danglingLinkOnPath(file.path);
      if (link != null) throw FileSystemException(_danglingLinkMessage, link);
      return const [];
    }
    final Object? decoded = jsonDecode(text);
    if (decoded is! Map<String, Object?> ||
        decoded['version'] != _schemaVersion) {
      throw const FormatException('Unsupported window connections format');
    }
    final rawRules = decoded['rules'];
    if (rawRules is! List<Object?>) {
      throw const FormatException('Invalid window connections list');
    }
    final rules = <WindowConnectionRule>[];
    for (final rawRule in rawRules) {
      if (rawRule is! Map<String, Object?>) {
        throw const FormatException('Invalid window connection entry');
      }
      rules.add(WindowConnectionRule.fromJson(rawRule));
    }
    _validateUniqueKeys(rules);
    return List.unmodifiable(rules);
  }

  Future<void> save(List<WindowConnectionRule> rules) async {
    _validateUniqueKeys(rules);
    final encoded = jsonEncode({
      'version': _schemaVersion,
      'rules': [for (final rule in rules) rule.toJson()],
    });
    await file.parent.create(recursive: true);
    final temporaryDirectory = await file.parent.createTemp(
      '.window-connections-',
    );
    try {
      await _chmod(temporaryDirectory.path, _privateDirectoryMode);
      final temporaryFile = File('${temporaryDirectory.path}/$_rulesFilename');
      await temporaryFile.create();
      await _chmod(temporaryFile.path, _privateFileMode);
      await temporaryFile.writeAsString(encoded, flush: true);
      await temporaryFile.rename(file.path);
    } finally {
      await temporaryDirectory.delete(recursive: true);
    }
  }
}

void _validateUniqueKeys(List<WindowConnectionRule> rules) {
  final keys = <WindowConnectionKey>{};
  for (final rule in rules) {
    if (!keys.add(rule.key)) {
      throw const FormatException('Duplicate window connection key');
    }
  }
}

Future<void> _chmod(String path, String mode) async {
  if (Platform.isWindows) return;
  final result = await Process.run('/bin/chmod', [mode, path]);
  if (result.exitCode != 0) {
    throw const FileSystemException(
      'Unable to restrict window connections permissions',
    );
  }
}
