import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/saved_prompt.dart';
import 'package:my_dashboard/src/state/saved_prompts_provider.dart';

SavedPrompt _prompt(String id, {String? text, String? sessionKey}) =>
    SavedPrompt(
      id: id,
      title: '제목 $id',
      text: text ?? '문구 $id',
      createdAt: 100,
      updatedAt: 100,
      source: 'claude',
      sessionKey: sessionKey,
    );

ProviderContainer _container(SavedPromptsLoadFn load, SavedPromptsSaveFn save) {
  final container = ProviderContainer(
    overrides: [
      savedPromptsLoadFnProvider.overrideWithValue(load),
      savedPromptsSaveFnProvider.overrideWithValue(save),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('대기 중인 변경부터 마지막 연속 저장 완료까지 새로 읽기를 잠근다', () async {
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final firstAllowed = Completer<void>();
    final secondAllowed = Completer<void>();
    var writes = 0;
    final container = _container(() async => [], (_) async {
      if (++writes == 1) {
        firstStarted.complete();
        await firstAllowed.future;
      } else {
        secondStarted.complete();
        await secondAllowed.future;
      }
    });
    await container.read(savedPromptsProvider.future);
    expect(container.read(savedPromptsBusyProvider), isFalse);
    final controller = container.read(savedPromptsProvider.notifier);
    final first = controller.create(text: '첫 문구');
    final second = controller.create(text: '둘째 문구');
    expect(container.read(savedPromptsBusyProvider), isTrue);
    await firstStarted.future;
    expect(container.read(savedPromptsBusyProvider), isTrue);
    firstAllowed.complete();
    await first;
    await secondStarted.future;
    expect(container.read(savedPromptsBusyProvider), isTrue);
    secondAllowed.complete();
    await second;
    expect(container.read(savedPromptsBusyProvider), isFalse);
    expect(container.read(savedPromptsProvider).requireValue, hasLength(2));
  });

  test('앞선 저장 실패 뒤에도 대기 중인 수정과 삭제가 끝나야 잠금을 푼다', () async {
    final previous = _prompt('old');
    final firstAllowed = Completer<void>();
    final secondStarted = Completer<void>();
    final secondAllowed = Completer<void>();
    final thirdStarted = Completer<void>();
    final thirdAllowed = Completer<void>();
    var writes = 0;
    final container = _container(() async => [previous], (_) async {
      switch (++writes) {
        case 1:
          await firstAllowed.future;
          throw StateError('storage unavailable');
        case 2:
          secondStarted.complete();
          await secondAllowed.future;
        case 3:
          thirdStarted.complete();
          await thirdAllowed.future;
      }
    });
    await container.read(savedPromptsProvider.future);
    final controller = container.read(savedPromptsProvider.notifier);
    final failed = expectLater(controller.create(text: '실패'), throwsStateError);
    final edited = controller.upsert(previous.copyWith(text: '수정한 원문'));
    final removed = controller.remove(previous.id);
    expect(container.read(savedPromptsBusyProvider), isTrue);
    firstAllowed.complete();
    await failed;
    await secondStarted.future;
    expect(container.read(savedPromptsBusyProvider), isTrue);
    secondAllowed.complete();
    await edited;
    await thirdStarted.future;
    expect(container.read(savedPromptsBusyProvider), isTrue);
    thirdAllowed.complete();
    await removed;
    expect(container.read(savedPromptsBusyProvider), isFalse);
    expect(container.read(savedPromptsProvider).requireValue, isEmpty);
  });

  test('저장소 읽기 오류와 입력 검증 오류도 완료 뒤 변경 잠금을 남기지 않는다', () async {
    final container = _container(() async => [], (_) async {});
    await container.read(savedPromptsProvider.future);
    final invalid = container
        .read(savedPromptsProvider.notifier)
        .create(text: ' ');
    expect(container.read(savedPromptsBusyProvider), isTrue);
    await expectLater(invalid, throwsFormatException);
    expect(container.read(savedPromptsBusyProvider), isFalse);

    final damaged = _container(
      () async => throw const FormatException('corrupt storage'),
      (_) async => fail('손상된 저장소에는 쓰지 않는다'),
    );
    await expectLater(
      damaged.read(savedPromptsProvider.future),
      throwsFormatException,
    );
    final failed = damaged.read(savedPromptsProvider.notifier).remove('old');
    expect(damaged.read(savedPromptsBusyProvider), isTrue);
    await expectLater(failed, throwsFormatException);
    expect(damaged.read(savedPromptsBusyProvider), isFalse);
  });

  test('저장 중 컨테이너가 닫혀도 완료 콜백과 다음 대기는 폐기된 상태를 건드리지 않는다', () async {
    final started = Completer<void>();
    final allowed = Completer<void>();
    var writes = 0;
    final container = ProviderContainer(
      overrides: [
        savedPromptsLoadFnProvider.overrideWithValue(() async => []),
        savedPromptsSaveFnProvider.overrideWithValue((_) async {
          writes++;
          started.complete();
          await allowed.future;
        }),
      ],
    );
    var disposed = false;
    addTearDown(() {
      if (!disposed) container.dispose();
    });
    await container.read(savedPromptsProvider.future);
    final controller = container.read(savedPromptsProvider.notifier);
    final first = controller.create(text: '진행 중인 문구');
    final second = controller.create(text: '대기 중인 문구');
    await started.future;
    expect(container.read(savedPromptsBusyProvider), isTrue);
    container.dispose();
    disposed = true;
    allowed.complete();
    await Future.wait([first, second]);
    expect(writes, 1);
  });

  test('브라우저에서도 새 문구 식별자를 생성하고 원문을 저장한다', () async {
    final writes = <List<SavedPrompt>>[];
    final container = _container(
      () async => [],
      (prompts) async => writes.add(prompts),
    );
    await container.read(savedPromptsProvider.future);
    await container.read(savedPromptsProvider.notifier).create(text: ' 원문\n');
    expect(writes.single.single.id, isNotEmpty);
    expect(writes.single.single.text, ' 원문\n');
    expect(container.read(savedPromptsProvider).requireValue, writes.single);
  });

  test('동시에 문구를 추가해도 첫 저장 완료를 기다리고 두 문구를 보존한다', () async {
    final started = Completer<void>();
    final allowed = Completer<void>();
    final writes = <List<SavedPrompt>>[];
    final container = _container(() async => [], (prompts) async {
      writes.add(List.of(prompts));
      if (writes.length == 1) {
        started.complete();
        await allowed.future;
      }
    });
    await container.read(savedPromptsProvider.future);
    final controller = container.read(savedPromptsProvider.notifier);
    final first = controller.create(text: '첫 문구');
    final second = controller.create(text: '두 번째 문구');
    await started.future;
    expect(writes, hasLength(1));
    expect(container.read(savedPromptsProvider).requireValue, isEmpty);
    allowed.complete();
    await Future.wait([first, second]);
    final saved = container.read(savedPromptsProvider).requireValue;
    expect(saved.map((prompt) => prompt.text), ['첫 문구', '두 번째 문구']);
    expect(saved.map((prompt) => prompt.id).toSet(), hasLength(2));
    expect(writes.last, saved);
  });

  test('서로 다른 문구의 동시 수정은 앞선 수정 내용을 보존한다', () async {
    final first = _prompt('first');
    final second = _prompt('second');
    final container = _container(() async => [first, second], (_) async {});
    await container.read(savedPromptsProvider.future);
    final controller = container.read(savedPromptsProvider.notifier);
    final updatedFirst = first.copyWith(text: '첫 수정', updatedAt: 101);
    final updatedSecond = second.copyWith(title: '둘째 제목', updatedAt: 101);
    await Future.wait([
      controller.upsert(updatedFirst),
      controller.upsert(updatedSecond),
    ]);
    expect(container.read(savedPromptsProvider).requireValue, [
      updatedFirst,
      updatedSecond,
    ]);
  });

  test('저장 실패는 이전 목록을 보존하고 뒤에 대기한 저장은 계속한다', () async {
    final previous = _prompt('old');
    var attempts = 0;
    final writes = <List<SavedPrompt>>[];
    final container = _container(() async => [previous], (prompts) async {
      if (++attempts == 1) throw StateError('storage unavailable');
      writes.add(List.of(prompts));
    });
    await container.read(savedPromptsProvider.future);
    final controller = container.read(savedPromptsProvider.notifier);
    final failed = controller.create(text: '실패할 문구');
    final next = controller.create(text: '다음 문구');
    await expectLater(failed, throwsStateError);
    await next;
    final saved = container.read(savedPromptsProvider).requireValue;
    expect(saved.map((prompt) => prompt.text), ['문구 old', '다음 문구']);
    expect(writes, [saved]);
  });

  test('손상된 저장소를 읽지 못하면 추가와 삭제 모두 쓰기를 시도하지 않는다', () async {
    var writes = 0;
    final container = _container(
      () async => throw const FormatException('invalid stored JSON'),
      (_) async => writes++,
    );
    await expectLater(
      container.read(savedPromptsProvider.future),
      throwsFormatException,
    );
    final controller = container.read(savedPromptsProvider.notifier);
    await expectLater(controller.create(text: '새 문구'), throwsFormatException);
    await expectLater(controller.remove('old'), throwsFormatException);
    expect(writes, 0);
    expect(container.read(savedPromptsProvider).hasError, isTrue);
  });

  test('같은 본문만 중복 저장을 합치며 공백이 다른 원문은 별도로 보존한다', () async {
    final previous = _prompt('stable', text: ' 원문\n', sessionKey: 'deleted');
    final container = _container(() async => [previous], (_) async {});
    await container.read(savedPromptsProvider.future);
    final controller = container.read(savedPromptsProvider.notifier);
    await controller.create(text: ' 원문\n', title: '수정한 제목');
    final updated = container.read(savedPromptsProvider).requireValue.single;
    expect(updated.id, previous.id);
    expect(updated.createdAt, previous.createdAt);
    expect(updated.title, '수정한 제목');
    expect(updated.sessionKey, 'deleted');
    await controller.create(text: '원문');
    expect(
      container.read(savedPromptsProvider).requireValue.map((p) => p.text),
      [' 원문\n', '원문'],
    );
  });

  test('같은 삭제된 세션에서 온 문구도 문구 식별자로만 개별 삭제한다', () async {
    final first = _prompt('first', sessionKey: 'deleted-session');
    final second = _prompt('second', sessionKey: 'deleted-session');
    final container = _container(() async => [first, second], (_) async {});
    await container.read(savedPromptsProvider.future);
    await container.read(savedPromptsProvider.notifier).remove(first.id);
    expect(container.read(savedPromptsProvider).requireValue, [second]);
  });

  test('초기 읽기 전에 추가한 문구도 기존 문구를 기다려 보존한다', () async {
    final loaded = Completer<List<SavedPrompt>>();
    final previous = _prompt('old');
    final container = _container(() => loaded.future, (_) async {});
    final pending = container
        .read(savedPromptsProvider.notifier)
        .create(text: '새 문구');
    expect(container.read(savedPromptsBusyProvider), isTrue);
    loaded.complete([previous]);
    await pending;
    expect(container.read(savedPromptsBusyProvider), isFalse);
    expect(container.read(savedPromptsProvider).requireValue.first, previous);
    expect(container.read(savedPromptsProvider).requireValue, hasLength(2));
  });

  test('길이 또는 개수 제한 오류는 원문이나 기존 목록을 잘라 쓰지 않는다', () async {
    final existing = List.generate(
      savedPromptMaxItems,
      (index) => _prompt('$index'),
    );
    var writes = 0;
    final container = _container(() async => existing, (_) async => writes++);
    await container.read(savedPromptsProvider.future);
    final controller = container.read(savedPromptsProvider.notifier);
    await expectLater(controller.create(text: '추가 문구'), throwsFormatException);
    await expectLater(
      controller.create(text: '가' * (savedPromptMaxTextLength + 1)),
      throwsFormatException,
    );
    expect(writes, 0);
    expect(container.read(savedPromptsProvider).requireValue, existing);
    await controller.create(text: existing.first.text);
    expect(writes, 1);
    expect(
      container.read(savedPromptsProvider).requireValue,
      hasLength(savedPromptMaxItems),
    );
  });
}
