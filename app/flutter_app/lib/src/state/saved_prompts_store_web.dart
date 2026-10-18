import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'package:my_dashboard/src/data/saved_prompt.dart';

const savedPromptsStorageKey = 'my-dashboard.saved-prompts.v1';
const _storageLockName = '$savedPromptsStorageKey.write';

typedef SavedPromptsStore = SavedPromptsWebStore;

SavedPromptsStore createSavedPromptsStore() => SavedPromptsWebStore();
final _sharedStore = createSavedPromptsStore();

Future<List<SavedPrompt>> loadSavedPrompts() => _sharedStore.load();

Future<void> saveSavedPrompts(List<SavedPrompt> prompts) =>
    _sharedStore.save(prompts);

class SavedPromptsWebStore {
  List<SavedPrompt>? _expectedPrevious;

  List<SavedPrompt> _read() {
    // SecurityError는 빈 문구함으로 숨기지 않는다.
    final raw = web.window.localStorage.getItem(savedPromptsStorageKey);
    return raw == null ? const [] : decodeSavedPrompts(raw);
  }

  Future<List<SavedPrompt>> load() async {
    final prompts = _read();
    _expectedPrevious = prompts;
    return prompts;
  }

  Future<void> save(List<SavedPrompt> prompts) async {
    final next = List<SavedPrompt>.unmodifiable(prompts);
    final encoded = encodeSavedPrompts(next);
    void commit() {
      final current = _read();
      validateSavedPromptsSnapshot(_expectedPrevious ?? current, current);
      // setItem이 실패하면 기준 목록도 갱신하지 않는다.
      web.window.localStorage.setItem(savedPromptsStorageKey, encoded);
      _expectedPrevious = next;
    }

    final navigator = web.window.navigator;
    if (navigator.getProperty<JSAny?>('locks'.toJS) == null) {
      // Web Locks가 없는 브라우저도 비동기 틈 없이 stale 목록을 검사한다.
      commit();
      return;
    }
    Object? failure;
    StackTrace? failureStack;
    await navigator.locks
        .request(
          _storageLockName,
          ((JSAny? _) {
            try {
              commit();
            } catch (error, stack) {
              failure = error;
              failureStack = stack;
            }
            return null;
          }).toJS,
        )
        .toDart;
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  }
}
