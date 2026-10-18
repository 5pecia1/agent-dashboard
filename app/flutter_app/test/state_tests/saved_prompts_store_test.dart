import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/saved_prompt.dart';
import 'package:my_dashboard/src/state/saved_prompts_store_io.dart';

SavedPrompt _prompt(String id) => SavedPrompt(
  id: id,
  title: '제목 $id',
  text: '  원문 $id\r\n\t끝  ',
  createdAt: 100,
  updatedAt: 101,
  source: 'claude',
  sessionKey: 'session-removed',
);

void main() {
  late Directory directory;
  late File file;
  late SavedPromptsFileStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('saved-prompts-test-');
    file = File('${directory.path}/state/saved-prompts.json');
    store = SavedPromptsFileStore(file);
  });
  tearDown(() => directory.delete(recursive: true));

  test('파일이 없을 때만 빈 목록이고 저장 후 원문과 출처를 정확히 복원한다', () async {
    expect(await store.load(), isEmpty);
    final prompts = [_prompt('first'), _prompt('second')];
    await store.save(prompts);
    expect(await SavedPromptsFileStore(file).load(), prompts);
    expect(
      (await file.parent.list().toList()).map((entry) => entry.path).toSet(),
      {file.path, '${file.path}.lock'},
    );
    if (!Platform.isWindows) {
      const permissionMask = 0x1ff;
      const ownerReadWrite = 0x180;
      expect((await file.stat()).mode & permissionMask, ownerReadWrite);
    }
  });

  test('파일 교체 후에도 제한된 권한과 원문을 유지한다', () async {
    await store.save([_prompt('old')]);
    final updated = [_prompt('new')];
    await store.save(updated);
    expect(await store.load(), updated);
    expect(await file.readAsString(), encodeSavedPrompts(updated));
  });

  test('손상된 파일과 알 수 없는 버전은 읽기와 다음 쓰기에서 거부한다', () async {
    await file.parent.create(recursive: true);
    for (final invalid in [
      '{broken',
      '{"version":2,"prompts":[]}',
      '{"version":1,"prompts":[null]}',
      '{"version":1,"prompts":[{"id":"missing-fields"}]}',
    ]) {
      await file.writeAsString(invalid);
      await expectLater(store.load(), throwsFormatException);
      await expectLater(store.save([_prompt('new')]), throwsFormatException);
      expect(await file.readAsString(), invalid);
    }
  });

  test('처음 읽은 뒤 손상된 파일도 저장 시점에 보존한다', () async {
    await store.save([_prompt('old')]);
    await store.load();
    const damaged = '{later-corruption';
    await file.writeAsString(damaged);
    await expectLater(store.save([_prompt('new')]), throwsFormatException);
    expect(await file.readAsString(), damaged);
  });

  test('파일 경로가 디렉터리면 읽기 오류를 보여 주고 교체하지 않는다', () async {
    await Directory(file.path).create(recursive: true);
    await expectLater(store.load(), throwsA(isA<FileSystemException>()));
    await expectLater(
      store.save([_prompt('new')]),
      throwsA(isA<FileSystemException>()),
    );
    expect(await Directory(file.path).exists(), isTrue);
  });

  test('대상 없는 파일 링크는 읽기와 저장에서 거부하고 링크를 보존한다', () async {
    await file.parent.create(recursive: true);
    final link = Link(file.path);
    await link.create('${directory.path}/unmounted/saved-prompts.json');
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
    await expectLater(
      store.save([_prompt('new')]),
      throwsA(isA<FileSystemException>()),
    );
    expect(await FileSystemEntity.isLink(file.path), isTrue);
  }, skip: Platform.isWindows);

  test('상위 디렉터리의 대상 없는 링크도 빈 목록으로 접지 않는다', () async {
    final link = Link(file.parent.path);
    await link.create('${directory.path}/unmounted/state');
    await expectLater(
      store.load(),
      throwsA(
        isA<FileSystemException>().having(
          (error) => error.path,
          'path',
          link.path,
        ),
      ),
    );
    await expectLater(
      store.save([_prompt('new')]),
      throwsA(isA<FileSystemException>()),
    );
    expect(await FileSystemEntity.isLink(link.path), isTrue);
  }, skip: Platform.isWindows);

  test('중복 식별자나 초과 목록 저장은 기존 파일과 원문을 보존한다', () async {
    final prompt = _prompt('old');
    await store.save([prompt]);
    final original = await file.readAsString();
    await expectLater(store.save([prompt, prompt]), throwsFormatException);
    final oversized = List.generate(
      savedPromptMaxItems + 1,
      (index) => _prompt('$index'),
    );
    await expectLater(store.save(oversized), throwsFormatException);
    expect(await file.readAsString(), original);
  });

  test('문구 삭제는 저장한 문구함만 바꾸며 세션 출처는 조회하지 않는다', () async {
    final first = _prompt('first');
    final second = _prompt('second');
    await store.save([first, second]);
    await store.save([second]);
    expect(await SavedPromptsFileStore(file).load(), [second]);
    expect(
      (await file.parent.list().toList()).map((entry) => entry.path).toSet(),
      {file.path, '${file.path}.lock'},
    );
  });

  test('다른 앱이 저장한 뒤 낡은 목록으로 쓰면 원본을 보존하고 재조회 후 복구한다', () async {
    final first = _prompt('first');
    final second = _prompt('second');
    await store.save([first]);
    final other = SavedPromptsFileStore(file);
    await other.load();
    await store.save([first, second]);
    await expectLater(
      other.save([first]),
      throwsA(isA<SavedPromptsConflictException>()),
    );
    expect(await store.load(), [first, second]);
    await other.load();
    await other.save([second]);
    expect(await SavedPromptsFileStore(file).load(), [second]);
  });

  test('같은 기준 목록으로 동시에 쓰는 두 저장소는 하나만 성공한다', () async {
    final firstStore = SavedPromptsFileStore(file);
    final secondStore = SavedPromptsFileStore(file);
    await Future.wait([firstStore.load(), secondStore.load()]);
    final firstWrite = firstStore.save([_prompt('first')]);
    final secondWrite = secondStore.save([_prompt('second')]);
    await expectLater(
      secondWrite,
      throwsA(isA<SavedPromptsConflictException>()),
    );
    await firstWrite;
    expect(await SavedPromptsFileStore(file).load(), [_prompt('first')]);
  });

  test('다른 프로세스의 OS 잠금이 풀린 뒤 현재 원본을 비교한다', () async {
    await store.load();
    final helper = File('${directory.path}/hold-lock.dart');
    await helper.writeAsString('''
import 'dart:io';

Future<void> main(List<String> args) async {
  final lockFile = File(args[0]);
  await lockFile.parent.create(recursive: true);
  final lock = await lockFile.open(mode: FileMode.append);
  await lock.lock(FileLock.blockingExclusive);
  await File(args[1]).writeAsString(args[2], flush: true);
  stdout.writeln('locked');
  await stdin.first;
  await lock.unlock();
  await lock.close();
}
''');
    final other = _prompt('other-process');
    final child = await Process.start('dart', [
      helper.path,
      '${file.path}.lock',
      file.path,
      encodeSavedPrompts([other]),
    ]);
    addTearDown(() => child.kill());
    final childErrors = child.stderr.transform(utf8.decoder).join();
    expect(
      await child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first,
      'locked',
    );
    var finished = false;
    final write = store.save([_prompt('local')]);
    final checked = expectLater(
      write,
      throwsA(isA<SavedPromptsConflictException>()),
    ).whenComplete(() => finished = true);
    const observationWindow = Duration(milliseconds: 100);
    await Future<void>.delayed(observationWindow);
    expect(finished, isFalse);
    child.stdin.writeln('release');
    await child.stdin.close();
    await checked;
    expect(await child.exitCode, 0, reason: await childErrors);
    expect(await SavedPromptsFileStore(file).load(), [other]);
  });

  test('잠금 파일이 링크이면 대상 권한을 바꾸거나 문구를 저장하지 않는다', () async {
    await file.parent.create(recursive: true);
    final target = File('${directory.path}/unrelated');
    await target.writeAsString('보존');
    final link = Link('${file.path}.lock');
    await link.create(target.path);
    await expectLater(
      store.save([_prompt('new')]),
      throwsA(isA<FileSystemException>()),
    );
    expect(await target.readAsString(), '보존');
    expect(await file.exists(), isFalse);
  }, skip: Platform.isWindows);
}
