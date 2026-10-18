import 'dart:io';

import 'package:my_dashboard/src/data/saved_prompt.dart';
import 'package:my_dashboard/src/state/dangling_link_io.dart';

const _stateRelativePath = '.local/state/my-dashboard';
const _promptsFilename = 'saved-prompts.json';
const _privateDirectoryMode = '700';
const _privateFileMode = '600';
const _danglingLinkMessage = 'The link target does not exist';
const _lockFileSuffix = '.lock';
final _fileLockTails = <String, Future<void>>{};

typedef SavedPromptsStore = SavedPromptsFileStore;

SavedPromptsStore createSavedPromptsStore() => _defaultStore();
final _sharedStore = createSavedPromptsStore();

SavedPromptsFileStore _defaultStore() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.trim().isEmpty) {
    throw const FileSystemException('User home directory is unavailable');
  }
  return SavedPromptsFileStore(
    File('$home/$_stateRelativePath/$_promptsFilename'),
  );
}

Future<List<SavedPrompt>> loadSavedPrompts() => _sharedStore.load();

Future<void> saveSavedPrompts(List<SavedPrompt> prompts) =>
    _sharedStore.save(prompts);

/// 세션 삭제나 서버 연결 변경과 독립적인 개인 문구함이다.
class SavedPromptsFileStore {
  SavedPromptsFileStore(this.file);

  final File file;
  List<SavedPrompt>? _expectedPrevious;

  Future<List<SavedPrompt>> load() async {
    final prompts = await _read();
    _expectedPrevious = prompts;
    return prompts;
  }

  Future<List<SavedPrompt>> _read() async {
    final String text;
    try {
      text = await file.readAsString();
    } on PathNotFoundException {
      final link = await danglingLinkOnPath(file.path);
      if (link != null) throw FileSystemException(_danglingLinkMessage, link);
      return const [];
    }
    return decodeSavedPrompts(text);
  }

  Future<void> save(List<SavedPrompt> prompts) async {
    final next = List<SavedPrompt>.unmodifiable(prompts);
    final encoded = encodeSavedPrompts(next);
    await _withFileLock(() async {
      // 손상이나 다른 앱의 변경을 확인하고 교체할 때까지 잠금을 유지한다.
      final current = await _read();
      validateSavedPromptsSnapshot(_expectedPrevious ?? current, current);
      await _write(encoded);
      _expectedPrevious = next;
    });
  }

  Future<void> _write(String encoded) async {
    await file.parent.create(recursive: true);
    final temporaryDirectory = await file.parent.createTemp('.saved-prompts-');
    try {
      await _chmod(temporaryDirectory.path, _privateDirectoryMode);
      final temporaryFile = File(
        '${temporaryDirectory.path}/$_promptsFilename',
      );
      await temporaryFile.create();
      await _chmod(temporaryFile.path, _privateFileMode);
      await temporaryFile.writeAsString(encoded, flush: true);
      await temporaryFile.rename(file.path);
    } finally {
      await temporaryDirectory.delete(recursive: true);
    }
  }

  Future<void> _withFileLock(Future<void> Function() action) {
    final key = file.absolute.path;
    final previous = _fileLockTails[key] ?? Future<void>.value();
    final turn = previous.then((_) => _withProcessLock(action));
    final tail = turn.catchError((Object _) {});
    _fileLockTails[key] = tail;
    tail.then((_) {
      if (identical(_fileLockTails[key], tail)) _fileLockTails.remove(key);
    });
    return turn;
  }

  Future<void> _withProcessLock(Future<void> Function() action) async {
    // Unix 파일 잠금은 같은 프로세스의 다른 핸들을 막지 않을 수 있으므로
    // 위의 로컬 큐와 프로세스 사이의 OS 잠금을 함께 사용한다.
    final dangling = await danglingLinkOnPath(file.path);
    if (dangling != null) {
      throw FileSystemException(_danglingLinkMessage, dangling);
    }
    await file.parent.create(recursive: true);
    final lockFile = File('${file.path}$_lockFileSuffix');
    if (await FileSystemEntity.type(lockFile.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException(
        'Saved prompts lock must not be a link',
        lockFile.path,
      );
    }
    final lock = await lockFile.open(mode: FileMode.append);
    try {
      await _chmod(lockFile.path, _privateFileMode);
      await lock.lock(FileLock.blockingExclusive);
      try {
        await action();
      } finally {
        await lock.unlock();
      }
    } finally {
      await lock.close();
    }
    // 잠금 파일은 유지한다. 삭제하면 대기 중인 핸들과 새 핸들이 서로 다른
    // inode를 잠가 같은 문구함에 동시에 쓰게 될 수 있다.
  }
}

Future<void> _chmod(String path, String mode) async {
  if (Platform.isWindows) return;
  final result = await Process.run('/bin/chmod', [mode, path]);
  if (result.exitCode != 0) {
    throw FileSystemException(
      'Unable to restrict saved prompts permissions',
      path,
    );
  }
}
