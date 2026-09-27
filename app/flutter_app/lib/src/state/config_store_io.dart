/// `config_provider.dart`의 데스크톱 브리지 — JSON 파일.
///
/// 경로는 hook_contract의 스풀 경로와 같은 상태 디렉터리
/// (`~/.local/state/my-dashboard/`)를 쓴다 — 그
/// 규칙을 그대로 이어받은 잠정 위치다. CLIENT_TOKEN이 평문으로 남으므로
/// 파일 권한을 `600`으로 좁힌다(best-effort — `chmod`가 없는 플랫폼에서는
/// 조용히 넘어간다. 이 템플릿의 데스크톱 대상은 macOS뿐이라 실제로는
/// 항상 성공한다).
library;

import 'dart:convert';
import 'dart:io';

import 'package:my_dashboard/src/state/config_provider.dart'
    show DashboardConfigValues;

Future<DashboardConfigValues> loadDashboardConfig() async {
  try {
    final file = File(_configPath());
    if (!file.existsSync()) return DashboardConfigValues.empty;
    final text = await file.readAsString();
    final Object? decoded = jsonDecode(text) as Object?;
    if (decoded is! Map<String, Object?>) return DashboardConfigValues.empty;
    return DashboardConfigValues.fromJson(decoded);
  } on FileSystemException {
    return DashboardConfigValues.empty;
  } on FormatException {
    return DashboardConfigValues.empty;
  }
}

Future<void> saveDashboardConfig(DashboardConfigValues values) =>
    saveDashboardConfigFile(File(_configPath()), values);

/// Preserve the pre-extraction bytes once before the first update. Keeping the
/// backup next to the config makes migration idempotent and rollback explicit.
/// The caller supplies a file in tests so no personal settings are accessed.
Future<void> saveDashboardConfigFile(
  File file,
  DashboardConfigValues values,
) async {
  await file.parent.create(recursive: true);
  final backup = File('${file.path}.before-extensions');
  if (await file.exists() && !await backup.exists()) {
    final snapshot = File('${backup.path}.tmp');
    await snapshot.create();
    await _restrictConfigPermissions(snapshot);
    await snapshot.writeAsBytes(await file.readAsBytes(), flush: true);
    await snapshot.rename(backup.path);
  }
  final staged = File('${file.path}.tmp');
  try {
    await staged.create();
    await _restrictConfigPermissions(staged);
    await staged.writeAsString(jsonEncode(values.toJson()), flush: true);
    await staged.rename(file.path);
  } finally {
    if (await staged.exists()) await staged.delete();
  }
}

Future<void> _restrictConfigPermissions(File file) async {
  if (Platform.isWindows) return;
  final result = await Process.run('chmod', <String>['600', file.path]);
  if (result.exitCode != 0) {
    throw FileSystemException(
      'Could not restrict configuration permissions',
      file.path,
    );
  }
}

String _stateDir() {
  final home = Platform.environment['HOME'] ?? Directory.current.path;
  return '$home/.local/state/my-dashboard';
}

String _configPath() => '${_stateDir()}/config.json';
