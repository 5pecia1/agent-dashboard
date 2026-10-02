/// `config_provider.dart`의 데스크톱 브리지 — JSON 파일.
///
/// 경로는 hook_contract의 스풀 경로와 같은 상태 디렉터리
/// (`~/.local/state/my-dashboard/`)를 쓴다 — 그
/// 규칙을 그대로 이어받은 잠정 위치다. CLIENT_TOKEN이 평문으로 남으므로
/// 파일 권한을 `600`으로 좁힌다(best-effort — `chmod`가 없는 플랫폼에서는
/// 조용히 넘어간다. 이 템플릿의 데스크톱 대상은 macOS뿐이라 실제로는
/// 항상 성공한다).
///
/// **읽기 계약(`config_provider.dart`의 `ConfigLoadFn`).** 파일이 없을
/// 때(ENOENT)만 빈 값이다. 권한·입출력 오류, 경로에 놓인 디렉터리, 경로
/// 위의 대상 없는 링크(파일 자신이나 상위 디렉터리)는
/// [ConfigReadFailureKind.access], UTF-8 JSON 객체가 아닌 내용은
/// [ConfigReadFailureKind.corrupt]로 던진다. 존재 여부를 먼저 묻지 않고
/// 바로 읽는다 — `exists()`는 상위 디렉터리를 검색할 수 없을 때나 경로가
/// 디렉터리일 때도 false라서, 읽을 수 없는 파일을 "없음"으로 착각한다.
library;

import 'dart:convert';
import 'dart:io';

import 'package:my_dashboard/src/state/config_provider.dart'
    show
        ConfigReadException,
        ConfigReadFailureKind,
        DashboardConfigValues,
        decodeStoredDashboardConfig,
        describeConfigFormatFailure;
import 'package:my_dashboard/src/state/dangling_link_io.dart';

const String _kDanglingLinkDetail = 'the link target does not exist';

Future<DashboardConfigValues> loadDashboardConfig() =>
    loadDashboardConfigFile(File(_configPath()));

Future<void> saveDashboardConfig(DashboardConfigValues values) =>
    saveDashboardConfigFile(File(_configPath()), values);

/// [file]을 `ConfigLoadFn` 계약대로 읽는다. 테스트는 임시 파일을 넘긴다 —
/// 실제 HOME의 설정을 건드리지 않게 경로 계산은 이 함수 밖에 둔다.
Future<DashboardConfigValues> loadDashboardConfigFile(File file) async {
  ConfigReadException failure(ConfigReadFailureKind kind, String detail) =>
      ConfigReadException(kind, location: file.path, detail: detail);

  final List<int> bytes;
  try {
    bytes = await file.readAsBytes();
  } on PathNotFoundException {
    // 파일 자신이나 상위 디렉터리가 대상 없는 링크면 "저장된 것이 없다"가
    // 아니다 — 마운트되지 않은 볼륨을 가리킬 수 있다(`dangling_link_io.dart`).
    final link = await danglingLinkOnPath(file.path);
    if (link != null) {
      throw failure(
        ConfigReadFailureKind.access,
        '$_kDanglingLinkDetail: $link',
      );
    }
    return DashboardConfigValues.empty;
  } on FileSystemException catch (error) {
    throw failure(ConfigReadFailureKind.access, _describeFileFailure(error));
  }
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException catch (error) {
    throw failure(
      ConfigReadFailureKind.corrupt,
      describeConfigFormatFailure(error),
    );
  }
  return decodeStoredDashboardConfig(text, location: file.path);
}

/// OS 메시지만 남긴다. `osError`가 없으면 "Cannot open file: null" 대신
/// 메시지 하나만 쓴다.
String _describeFileFailure(FileSystemException error) {
  final os = error.osError;
  if (os == null) return error.message;
  return '${error.message}: ${os.message} (errno ${os.errorCode})';
}

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
