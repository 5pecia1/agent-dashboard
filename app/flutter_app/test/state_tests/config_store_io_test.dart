/// `config_store_io.dart`의 읽기 계약: 파일이 없을 때만 빈 값이고, 읽지 못한
/// 저장소는 [ConfigReadException]이다.
///
/// 모든 테스트는 임시 디렉터리의 파일을 [loadDashboardConfigFile]/
/// [saveDashboardConfigFile]에 직접 넘긴다 — 기본 경로를 계산하는
/// `loadDashboardConfig`/`saveDashboardConfig`는 실제 HOME의 설정을 읽고
/// 쓰므로 여기서 절대 부르지 않는다.
///
/// 권한(chmod 000) 테스트는 권한 검사를 우회하는 계정(root, CI 컨테이너)
/// 에서는 읽기가 성공하므로 건너뛴다. 그 환경에서도 디렉터리·손상 내용
/// 테스트가 같은 회귀를 지킨다.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/config_store_io.dart';

const String _fixtureToken = 'fixture-client-token-7f3a';
const String _noAccessMode = '000';
const String _ownerDirectoryMode = '700';
const String _ownerFileMode = '600';
const String _rootSkipReason = '권한 검사를 우회하는 계정(root)에서는 확인할 수 없다';

/// 서버 자격증명과 세 연동 설정을 모두 가진, 이미 쓰던 사용자의 설정.
final Map<String, Object?> _storedJson = <String, Object?>{
  'server_url': 'https://dash.example.test',
  'client_token': _fixtureToken,
  'cursor': 41,
  'theme_mode': 'dark',
  'teamclaude': <String, Object?>{
    'url': 'https://tc.example.test',
    'api_key': 'fixture-teamclaude-key',
  },
  'devin': <String, Object?>{
    'url': 'https://devin.example.test',
    'api_key': 'fixture-devin-key',
  },
  'grok': <String, Object?>{'enabled': true, 'bot': true},
};

Future<void> _chmod(String path, String mode) async {
  final result = await Process.run('chmod', <String>[mode, path]);
  expect(result.exitCode, 0, reason: 'chmod $mode $path');
}

/// 이 계정이 chmod 000을 지키는가. 검사 대상 로더가 아니라 `dart:io`로
/// 직접 확인한다 — 로더가 오류를 빈 값으로 접는 결함이 있어도 테스트가
/// 건너뛰지 않고 실패하게 한다.
Future<bool> _permissionsEnforced(File file) async {
  try {
    await file.readAsBytes();
    return false;
  } on FileSystemException {
    return true;
  }
}

/// 읽기 결과 또는 던진 예외 하나를 돌려준다.
Future<Object?> _attemptLoad(File file) async {
  try {
    return await loadDashboardConfigFile(file);
  } on Object catch (error) {
    return error;
  }
}

Matcher _readFailure(ConfigReadFailureKind kind, File file) =>
    isA<ConfigReadException>()
        .having((error) => error.kind, 'kind', kind)
        .having((error) => error.location, 'location', file.path);

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('config-store-io-');
    addTearDown(() => directory.delete(recursive: true));
    file = File('${directory.path}/state/config.json');
  });

  group('읽기 계약', () {
    test('파일이나 상위 디렉터리가 없으면 첫 실행이라 빈 값이다', () async {
      expect(await loadDashboardConfigFile(file), DashboardConfigValues.empty);
      final deep = File('${directory.path}/a/b/c/config.json');
      expect(await loadDashboardConfigFile(deep), DashboardConfigValues.empty);
    });

    test('저장된 서버 주소, 토큰, 커서, 테마와 연동 설정을 그대로 읽는다', () async {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(_storedJson));

      final loaded = await loadDashboardConfigFile(file);

      expect(loaded, DashboardConfigValues.fromJson(_storedJson));
      expect(loaded.serverUrl, 'https://dash.example.test');
      expect(loaded.clientToken, _fixtureToken);
      expect(loaded.cursor, 41);
      expect(loaded.themeMode, 'dark');
      expect(
        loaded.extra.keys,
        containsAll(<String>['teamclaude', 'devin', 'grok']),
      );
    });

    test('잘린 JSON은 손상으로 알리고 파일을 그대로 두며 토큰을 드러내지 않는다', () async {
      await file.parent.create(recursive: true);
      final full = jsonEncode(_storedJson);
      // 토큰 바로 뒤에서 자른다 — 파서가 토큰을 읽은 뒤 실패하게 한다.
      final cut = full.indexOf(_fixtureToken) + _fixtureToken.length + 2;
      final truncated = full.substring(0, cut);
      expect(
        truncated,
        contains(_fixtureToken),
        reason: '토큰이 잘린 원문 안에 있어야 의미가 있다',
      );
      await file.writeAsString(truncated);

      final outcome = await _attemptLoad(file);

      expect(outcome, _readFailure(ConfigReadFailureKind.corrupt, file));
      final error = outcome! as ConfigReadException;
      expect(error.toString(), isNot(contains(_fixtureToken)));
      expect(error.detail, isNot(contains(_fixtureToken)));
      expect(await file.readAsString(), truncated);
    });

    test('JSON 객체가 아닌 내용, 빈 파일, UTF-8이 아닌 바이트는 손상이다', () async {
      await file.parent.create(recursive: true);
      for (final content in <List<int>>[
        utf8.encode('[]'),
        utf8.encode('null'),
        utf8.encode('"x"'),
        utf8.encode('42'),
        <int>[],
        utf8.encode('  \n'),
        <int>[0x7b, 0xff, 0xfe, 0x7d],
      ]) {
        await file.writeAsBytes(content);
        expect(
          await _attemptLoad(file),
          _readFailure(ConfigReadFailureKind.corrupt, file),
          reason: 'content=$content',
        );
        expect(await file.readAsBytes(), content);
      }
    });

    test('서버 주소나 토큰이 문자열이 아니면 손상이다 — null로 접으면 다음 저장이 지운다', () async {
      await file.parent.create(recursive: true);
      for (final broken in <Map<String, Object?>>[
        {..._storedJson, 'client_token': 12345},
        {..._storedJson, 'server_url': <String, Object?>{}},
      ]) {
        await file.writeAsString(jsonEncode(broken));
        expect(
          await _attemptLoad(file),
          _readFailure(ConfigReadFailureKind.corrupt, file),
        );
      }
    });

    test('유한하지 않은 커서와 워터마크는 그 필드만 null로 접고 자격증명은 읽는다', () async {
      await file.parent.create(recursive: true);
      final text =
          jsonEncode({..._storedJson, 'cursor': 0, 'seen_watermark': 0})
              .replaceFirst('"cursor":0', '"cursor":1e999')
              .replaceFirst('"seen_watermark":0', '"seen_watermark":-1e999');
      await file.writeAsString(text);

      final loaded = await loadDashboardConfigFile(file);

      expect(loaded.cursor, isNull);
      expect(loaded.seenWatermark, isNull);
      expect(loaded.clientToken, _fixtureToken);
    });

    test('설정 경로에 디렉터리가 있으면 접근 오류다', () async {
      await Directory(file.path).create(recursive: true);

      expect(
        await _attemptLoad(file),
        _readFailure(ConfigReadFailureKind.access, file),
      );
    });

    test('대상이 없는 링크는 첫 실행이 아니라 접근 오류다', () async {
      await file.parent.create(recursive: true);
      await Link(file.path).create('${directory.path}/unmounted/config.json');

      expect(
        await _attemptLoad(file),
        _readFailure(ConfigReadFailureKind.access, file),
      );
      expect(await FileSystemEntity.isLink(file.path), isTrue);
    });

    test('상위 디렉터리가 대상 없는 링크여도 첫 실행이 아니라 접근 오류이고 그 링크를 알린다', () async {
      // 예: `~/.local/state/my-dashboard`가 마운트되지 않은 볼륨을 가리킨다.
      final stateLink = Link(file.parent.path);
      await stateLink.create('${directory.path}/unmounted/state');

      final outcome = await _attemptLoad(file);

      expect(outcome, _readFailure(ConfigReadFailureKind.access, file));
      expect(
        (outcome! as ConfigReadException).detail,
        contains(stateLink.path),
      );
      expect(await FileSystemEntity.isLink(stateLink.path), isTrue);
    });

    test('상위 디렉터리 링크의 대상이 있고 파일만 없으면 첫 실행이다', () async {
      final target = Directory('${directory.path}/volume/state');
      await target.create(recursive: true);
      await Link(file.parent.path).create(target.path);

      expect(await loadDashboardConfigFile(file), DashboardConfigValues.empty);
    });

    test('상위 디렉터리를 검색할 수 없으면 빈 값이 아니라 접근 오류다', () async {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(_storedJson));
      await _chmod(file.parent.path, _noAccessMode);
      addTearDown(() => _chmod(file.parent.path, _ownerDirectoryMode));
      if (!await _permissionsEnforced(file)) {
        markTestSkipped(_rootSkipReason);
        return;
      }

      expect(
        await _attemptLoad(file),
        _readFailure(ConfigReadFailureKind.access, file),
      );
    });

    test('읽기 권한이 없는 파일은 접근 오류다', () async {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(_storedJson));
      await _chmod(file.path, _noAccessMode);
      addTearDown(() => _chmod(file.path, _ownerFileMode));
      if (!await _permissionsEnforced(file)) {
        markTestSkipped(_rootSkipReason);
        return;
      }

      expect(
        await _attemptLoad(file),
        _readFailure(ConfigReadFailureKind.access, file),
      );
    });
  });

  group('패치 큐와 실제 파일 (자격증명 소거 회귀)', () {
    late ProviderContainer container;
    late File backup;
    late List<int> originalBytes;
    late List<int> backupBytes;

    setUp(() async {
      container = ProviderContainer(
        overrides: [
          configLoadFnProvider.overrideWithValue(
            () => loadDashboardConfigFile(file),
          ),
          configSaveFnProvider.overrideWithValue(
            (values) => saveDashboardConfigFile(file, values),
          ),
        ],
      );
      addTearDown(container.dispose);
      backup = File('${file.path}.before-extensions');
      // 기존 사용자의 파일이 있고, 앱이 한 번 저장해 백업도 만들어 둔 상태.
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(_storedJson));
      await saveDashboardConfigFile(
        file,
        DashboardConfigValues.fromJson(_storedJson),
      );
      originalBytes = await file.readAsBytes();
      backupBytes = await backup.readAsBytes();
    });

    Future<void> patchCursor() => container.read(configPatchFnProvider)(
      (current) => current.copyWith(cursor: 99),
    );

    Future<void> expectNothingWritten() async {
      expect(await file.readAsBytes(), originalBytes);
      expect(await backup.readAsBytes(), backupBytes);
      expect(await File('${file.path}.tmp').exists(), isFalse);
    }

    test('손상된 설정 위에 커서를 저장하려 하면 아무것도 쓰지 않는다', () async {
      await file.writeAsString('{"client_token":"$_fixtureToken",');
      originalBytes = await file.readAsBytes();

      await expectLater(patchCursor(), throwsA(isA<ConfigReadException>()));

      await expectNothingWritten();
    });

    test('읽기 권한이 없는 설정 위에 커서를 저장하려 하면 아무것도 쓰지 않는다', () async {
      await _chmod(file.path, _noAccessMode);
      addTearDown(() => _chmod(file.path, _ownerFileMode));
      if (!await _permissionsEnforced(file)) {
        markTestSkipped(_rootSkipReason);
        return;
      }

      await expectLater(patchCursor(), throwsA(isA<ConfigReadException>()));

      await _chmod(file.path, _ownerFileMode);
      await expectNothingWritten();
    });

    test('읽을 수 있게 되면 같은 패치가 자격증명과 연동 설정을 보존한 채 저장된다', () async {
      final saved = List<int>.of(originalBytes);
      await file.writeAsString('{"client_token":');
      await expectLater(patchCursor(), throwsA(isA<ConfigReadException>()));

      await file.writeAsBytes(saved);
      await patchCursor();

      final reloaded = await loadDashboardConfigFile(file);
      expect(
        reloaded,
        DashboardConfigValues.fromJson(_storedJson).copyWith(cursor: 99),
      );
      expect(reloaded.clientToken, _fixtureToken);
      expect(await backup.readAsBytes(), backupBytes);
    });
  });
}
