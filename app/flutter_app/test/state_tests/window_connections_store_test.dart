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
