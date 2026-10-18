@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'package:my_dashboard/src/data/saved_prompt.dart';
import 'package:my_dashboard/src/state/saved_prompts_store_web.dart';

void main() {
  String? previous;
  setUp(() async {
    previous = web.window.localStorage.getItem(savedPromptsStorageKey);
    web.window.localStorage.removeItem(savedPromptsStorageKey);
    await loadSavedPrompts();
  });
  tearDown(() {
    if (previous == null) {
      web.window.localStorage.removeItem(savedPromptsStorageKey);
    } else {
      web.window.localStorage.setItem(savedPromptsStorageKey, previous!);
    }
  });

  test('브라우저 저장소의 원문은 새 읽기에서도 공백과 줄바꿈까지 복원된다', () async {
    expect(await loadSavedPrompts(), isEmpty);
    final prompt = SavedPrompt(
      id: 'browser-id',
      title: '',
      text: '  한글\r\n\t문구  ',
      createdAt: 100,
      updatedAt: 101,
    );
    await saveSavedPrompts([prompt]);
    expect(await loadSavedPrompts(), [prompt]);
    expect(
      web.window.localStorage.getItem(savedPromptsStorageKey),
      encodeSavedPrompts([prompt]),
    );
    await saveSavedPrompts([]);
    expect(await loadSavedPrompts(), isEmpty);
  });

  test('손상된 브라우저 JSON은 빈 목록으로 바꾸거나 다음 저장으로 덮지 않는다', () async {
    for (final invalid in ['{broken', '{"version":2,"prompts":[]}']) {
      web.window.localStorage.setItem(savedPromptsStorageKey, invalid);
      await expectLater(loadSavedPrompts(), throwsFormatException);
      await expectLater(saveSavedPrompts([]), throwsFormatException);
      expect(web.window.localStorage.getItem(savedPromptsStorageKey), invalid);
    }
  });

  test('실제 브라우저 할당량을 초과한 저장은 오류를 전파하고 기존 문구를 보존한다', () async {
    final previousPrompt = SavedPrompt(
      id: 'preserved',
      title: '',
      text: '남아 있어야 하는 원문',
      createdAt: 100,
      updatedAt: 100,
    );
    await saveSavedPrompts([previousPrompt]);
    final maximumText = '가' * savedPromptMaxTextLength;
    final largeLibrary = List.generate(
      savedPromptMaxItems,
      (index) => SavedPrompt(
        id: 'quota-$index',
        title: '',
        text: maximumText,
        createdAt: 100,
        updatedAt: 100,
      ),
    );
    await expectLater(
      saveSavedPrompts(largeLibrary),
      throwsA(
        predicate<Object>((error) => '$error'.contains('QuotaExceededError')),
      ),
    );
    expect(await loadSavedPrompts(), [previousPrompt]);
  });

  test('다른 탭의 저장 뒤에는 낡은 목록 쓰기를 거부하고 재조회 후 복구한다', () async {
    final firstStore = SavedPromptsWebStore();
    final secondStore = SavedPromptsWebStore();
    await Future.wait([firstStore.load(), secondStore.load()]);
    final prompt = SavedPrompt(
      id: 'new-tab',
      title: '',
      text: '다른 탭의 원문',
      createdAt: 100,
      updatedAt: 100,
    );
    await firstStore.save([prompt]);
    await expectLater(
      secondStore.save([]),
      throwsA(isA<SavedPromptsConflictException>()),
    );
    expect(await firstStore.load(), [prompt]);
    await secondStore.load();
    await secondStore.save([]);
    expect(await firstStore.load(), isEmpty);
  });

  test('Web Locks에서 같은 기준으로 동시에 저장하면 하나만 성공한다', () async {
    final firstStore = SavedPromptsWebStore();
    final secondStore = SavedPromptsWebStore();
    await Future.wait([firstStore.load(), secondStore.load()]);
    SavedPrompt prompt(String id) => SavedPrompt(
      id: id,
      title: '',
      text: id,
      createdAt: 100,
      updatedAt: 100,
    );
    final firstWrite = firstStore.save([prompt('first')]);
    final secondWrite = secondStore.save([prompt('second')]);
    await expectLater(
      secondWrite,
      throwsA(isA<SavedPromptsConflictException>()),
    );
    await firstWrite;
    expect(await firstStore.load(), [prompt('first')]);
  });
}
