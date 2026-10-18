import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/saved_prompt.dart';
import 'package:my_dashboard/src/state/saved_prompts_store_io.dart'
    if (dart.library.js_interop) 'package:my_dashboard/src/state/saved_prompts_store_web.dart'
    as bridge;

typedef SavedPromptsLoadFn = Future<List<SavedPrompt>> Function();
typedef SavedPromptsSaveFn = Future<void> Function(List<SavedPrompt> prompts);

final savedPromptsLoadFnProvider = Provider<SavedPromptsLoadFn>(
  (ref) => ref.watch(_savedPromptsStoreProvider).load,
);
final savedPromptsSaveFnProvider = Provider<SavedPromptsSaveFn>(
  (ref) => ref.watch(_savedPromptsStoreProvider).save,
);
final _savedPromptsPendingCountProvider =
    NotifierProvider<_SavedPromptsMutationCounter, int>(
      _SavedPromptsMutationCounter.new,
    );

/// 실행 중인 저장뿐 아니라 큐에서 기다리는 변경도 새로 읽기와 경합하지 않는다.
final savedPromptsBusyProvider = Provider<bool>(
  (ref) => ref.watch(_savedPromptsPendingCountProvider) > 0,
);

class _SavedPromptsMutationCounter extends Notifier<int> {
  @override
  int build() => 0;

  void begin() => state++;

  void end() {
    // 닫힌 컨테이너에서 완료된 저장은 이미 폐기된 상태에 접근하지 않는다.
    if (!ref.mounted) return;
    state--;
  }
}

// 각 앱/탭이 실제로 읽은 목록을 별도로 기억해 다른 창의 저장을 덮지 않는다.
final _savedPromptsStoreProvider = Provider<bridge.SavedPromptsStore>(
  (ref) => bridge.createSavedPromptsStore(),
);
final savedPromptsProvider =
    AsyncNotifierProvider<SavedPromptsController, List<SavedPrompt>>(
      SavedPromptsController.new,
      // 파일 오류는 자동 재시도로 해결되지 않으므로 복구 후 명시적으로 읽는다.
      retry: (_, _) => null,
    );

class SavedPromptsController extends AsyncNotifier<List<SavedPrompt>> {
  Future<void> _tail = Future<void>.value();
  final _random = Random.secure();
  static const _idRandomParts = 4;
  static const _idRandomRadix = 16;
  // Dart 웹 컴파일에서 `1 << 32`가 0이 되어 난수 상한을 리터럴로 보존한다.
  static const _idRandomBound = 0x100000000;

  @override
  Future<List<SavedPrompt>> build() async {
    final prompts = await ref.watch(savedPromptsLoadFnProvider)();
    validateSavedPrompts(prompts);
    return List.unmodifiable(prompts);
  }

  Future<void> create({
    required String text,
    String title = '',
    String? source,
    String? sessionKey,
  }) => _mutate((prompts) {
    SavedPrompt? previous;
    for (final prompt in prompts) {
      if (prompt.text == text) {
        previous = prompt;
        break;
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final updatedAt = previous == null ? now : max(now, previous.updatedAt);
    final id = previous?.id ?? _newId(prompts, now);
    final next = SavedPrompt(
      id: id,
      title: title.trim().isEmpty ? previous?.title ?? '' : title,
      text: text,
      createdAt: previous?.createdAt ?? now,
      updatedAt: updatedAt,
      source: source ?? previous?.source,
      sessionKey: sessionKey ?? previous?.sessionKey,
    );
    return [
      for (final prompt in prompts)
        if (prompt.id != id) prompt,
      next,
    ];
  });

  Future<void> upsert(SavedPrompt prompt) => _mutate(
    (prompts) => [
      for (final current in prompts)
        if (current.id != prompt.id) current,
      prompt,
    ],
  );

  Future<void> remove(String id) =>
      _mutate((prompts) => prompts.where((prompt) => prompt.id != id).toList());

  String _newId(List<SavedPrompt> prompts, int now) {
    final ids = {for (final prompt in prompts) prompt.id};
    String id;
    do {
      final suffix = List.generate(
        _idRandomParts,
        (_) => _random.nextInt(_idRandomBound).toRadixString(_idRandomRadix),
      ).join('-');
      id = '$now-$suffix';
    } while (ids.contains(id));
    return id;
  }

  /// 저장 성공 뒤에 상태를 갱신하고 실패한 호출 뒤에도 저장 큐를 계속한다.
  Future<void> _mutate(List<SavedPrompt> Function(List<SavedPrompt>) change) {
    final counter = ref.read(_savedPromptsPendingCountProvider.notifier);
    counter.begin();
    final turn = _tail
        .then((_) async {
          if (!ref.mounted) return;
          final current = await future;
          if (!ref.mounted) return;
          final next = List<SavedPrompt>.unmodifiable(change(current));
          validateSavedPrompts(next);
          await ref.read(savedPromptsSaveFnProvider)(next);
          if (ref.mounted) state = AsyncData(next);
        })
        .whenComplete(counter.end);
    _tail = turn.catchError((Object _) {});
    return turn;
  }
}
