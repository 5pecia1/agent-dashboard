import 'dart:convert';
import 'dart:io';

import 'package:my_dashboard/src/data/window_connection.dart';

const _schemaVersion = 1;
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

  Future<List<WindowConnectionRule>> load() async {
    if (!await file.exists()) return const [];
    final Object? decoded = jsonDecode(await file.readAsString());
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
