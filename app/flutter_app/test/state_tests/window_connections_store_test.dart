import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/window_connection.dart';
import 'package:my_dashboard/src/state/window_connections_store_io.dart';

WindowConnectionRule _rule(String project) => WindowConnectionRule(
  key: WindowConnectionKey(host: 'work-mac', project: project),
  bundleId: 'com.microsoft.VSCode',
  titlePattern: 'README — $project',
  exactTitle: true,
);

void main() {
  late Directory directory;
  late File file;
  late WindowConnectionsFileStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'window-connections-test-',
    );
    file = File('${directory.path}/state/window-connections.json');
    store = WindowConnectionsFileStore(file);
  });
  tearDown(() => directory.delete(recursive: true));

  test('첫 실행에는 빈 목록이고 저장 후 전체 경로와 제목 조건을 복원한다', () async {
    expect(await store.load(), isEmpty);
    final rules = [_rule('/work/a/dashboard'), _rule('/work/b/dashboard')];
    await store.save(rules);
    expect(await store.load(), rules);
    expect((await file.parent.list().toList()).map((entry) => entry.path), [
      file.path,
    ]);
    if (!Platform.isWindows) {
      const permissionMask = 0x1ff;
      const ownerReadWrite = 0x180;
      expect((await file.stat()).mode & permissionMask, ownerReadWrite);
    }
  });

  test('기존 파일을 교체해도 읽을 수 있는 JSON과 제한된 권한을 유지한다', () async {
    await store.save([_rule('/work/old')]);
    final updated = [_rule('/work/new')];
    await store.save(updated);
    expect(await store.load(), updated);
    final Object? decoded = jsonDecode(await file.readAsString());
    expect(decoded, isA<Map<String, Object?>>());
  });

  test('손상된 파일이나 알 수 없는 버전은 빈 목록으로 숨기지 않는다', () async {
    await file.parent.create(recursive: true);
    for (final invalid in [
      '{broken',
      '{"version":2,"rules":[]}',
      '{"version":1,"rules":[null]}',
    ]) {
      await file.writeAsString(invalid);
      await expectLater(store.load(), throwsFormatException);
      expect(await file.readAsString(), invalid);
    }
  });

  test('규칙 경로에 디렉터리가 있으면 빈 목록이 아니라 읽기 오류다', () async {
    await Directory(file.path).create(recursive: true);

    await expectLater(
      store.load(),
      throwsA(
        isA<FileSystemException>().having(
          (error) => error is PathNotFoundException,
          '파일 없음으로 분류됐는가',
          isFalse,
        ),
      ),
    );
  });

  test('대상 없는 링크는 빈 목록이 아니라 읽기 오류이고 링크를 그대로 둔다', () async {
    // 빈 목록으로 보이면 다음 저장의 rename이 링크를 일반 파일로 바꿔 원래
    // 규칙과의 연결을 끊는다. 화면은 읽기 오류일 때 저장하지 않는다
    // (`window_connections_provider_test.dart`).
    await file.parent.create(recursive: true);
    final link = Link(file.path);
    await link.create('${directory.path}/unmounted/window-connections.json');

    await expectLater(
      store.load(),
      throwsA(
        isA<FileSystemException>()
            .having(
              (error) => error is PathNotFoundException,
              '파일 없음으로 분류됐는가',
              isFalse,
            )
            .having((error) => error.path, 'path', link.path),
      ),
    );
    expect(await FileSystemEntity.isLink(link.path), isTrue);
  });

  test('상위 디렉터리가 대상 없는 링크여도 빈 목록이 아니라 읽기 오류다', () async {
    final stateLink = Link(file.parent.path);
    await stateLink.create('${directory.path}/unmounted/state');

    await expectLater(
      store.load(),
      throwsA(
        isA<FileSystemException>()
            .having(
              (error) => error is PathNotFoundException,
              '파일 없음으로 분류됐는가',
              isFalse,
            )
            .having((error) => error.path, 'path', stateLink.path),
      ),
    );
  });

  test('상위 디렉터리를 검색할 수 없으면 빈 목록이 아니라 읽기 오류다', () async {
    await store.save([_rule('/work/locked')]);
    final locked = file.parent.path;
    Future<void> chmod(String mode) async {
      final result = await Process.run('chmod', [mode, locked]);
      expect(result.exitCode, 0);
    }

    await chmod('000');
    addTearDown(() => chmod('700'));
    // 권한이 지켜지는지는 검사 대상이 아니라 dart:io로 직접 본다 — 빈
    // 목록으로 접는 결함이 있어도 건너뛰지 않고 실패하게 한다.
    try {
      await file.readAsString();
      markTestSkipped('권한 검사를 우회하는 계정(root)에서는 확인할 수 없다');
      return;
    } on FileSystemException {
      // 이 계정은 chmod 000을 지킨다.
    }

    await expectLater(
      store.load(),
      throwsA(
        isA<FileSystemException>().having(
          (error) => error is PathNotFoundException,
          '파일 없음으로 분류됐는가',
          isFalse,
        ),
      ),
    );
  });

  test('중복 키는 읽기와 쓰기에서 거부하고 기존 파일을 보존한다', () async {
    final rule = _rule('/work/project');
    await store.save([rule]);
    final original = await file.readAsString();
    await expectLater(store.save([rule, rule]), throwsFormatException);
    expect(await file.readAsString(), original);

    await file.writeAsString(
      jsonEncode({
        'version': 1,
        'rules': [rule.toJson(), rule.toJson()],
      }),
    );
    await expectLater(store.load(), throwsFormatException);
  });
}
