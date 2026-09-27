import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/window_connection.dart';
import 'package:my_dashboard/src/state/window_connections_store_io.dart'
    if (dart.library.js_interop) 'package:my_dashboard/src/state/window_connections_store_web.dart'
    as bridge;

typedef WindowConnectionsLoadFn = Future<List<WindowConnectionRule>> Function();
typedef WindowConnectionsSaveFn =
    Future<void> Function(List<WindowConnectionRule> rules);

final windowConnectionsLoadFnProvider = Provider<WindowConnectionsLoadFn>(
  (ref) => bridge.loadWindowConnections,
);
final windowConnectionsSaveFnProvider = Provider<WindowConnectionsSaveFn>(
  (ref) => bridge.saveWindowConnections,
);

final windowConnectionsProvider =
    AsyncNotifierProvider<
      WindowConnectionsController,
      List<WindowConnectionRule>
    >(
      WindowConnectionsController.new,
      // 로컬 파일 오류는 반복 읽기로 고쳐지지 않는다. 즉시 표시한 뒤
      // 사용자가 복구하고 명시적으로 새로 읽을 수 있게 한다.
      retry: (_, _) => null,
    );

class WindowConnectionsController
    extends AsyncNotifier<List<WindowConnectionRule>> {
  Future<void> _tail = Future<void>.value();

  @override
  Future<List<WindowConnectionRule>> build() async =>
      List.unmodifiable(await ref.watch(windowConnectionsLoadFnProvider)());

  Future<void> upsert(WindowConnectionRule rule) => _mutate(
    (rules) => [
      for (final current in rules)
        if (current.key != rule.key) current,
      rule,
    ],
  );

  Future<void> remove(WindowConnectionKey key) =>
      _mutate((rules) => rules.where((rule) => rule.key != key).toList());

  /// 상태는 저장 성공 뒤에만 갱신한다. 다음 호출은 직전 저장까지 기다려
  /// 동시에 다른 프로젝트를 연결해도 먼저 저장한 규칙을 지우지 않는다.
  Future<void> _mutate(
    List<WindowConnectionRule> Function(List<WindowConnectionRule>) change,
  ) {
    final turn = _tail.then((_) async {
      final current = await future;
      if (!ref.mounted) return;
      final next = List<WindowConnectionRule>.unmodifiable(change(current));
      await ref.read(windowConnectionsSaveFnProvider)(next);
      if (ref.mounted) state = AsyncData(next);
    });
    // 각 실패는 해당 호출자에게 돌려주고 이후 저장 큐는 계속 진행한다.
    _tail = turn.catchError((Object _) {});
    return turn;
  }
}
