import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/window_connection.dart';
import 'package:my_dashboard/src/state/window_connections_provider.dart';

WindowConnectionRule _rule(String project, {String pattern = 'window'}) =>
    WindowConnectionRule(
      key: WindowConnectionKey(host: 'work-mac', project: project),
      bundleId: 'com.microsoft.VSCode',
      titlePattern: pattern,
    );

ProviderContainer _container(
  WindowConnectionsLoadFn load,
  WindowConnectionsSaveFn save,
) {
  final container = ProviderContainer(
    overrides: [
      windowConnectionsLoadFnProvider.overrideWithValue(load),
      windowConnectionsSaveFnProvider.overrideWithValue(save),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('동시에 연결을 저장해도 앞선 프로젝트의 규칙을 보존한다', () async {
    final first = _rule('/work/first');
    final second = _rule('/work/second');
    final firstWriteStarted = Completer<void>();
    final firstWriteAllowed = Completer<void>();
    final writes = <List<WindowConnectionRule>>[];
    final container = _container(() async => [], (rules) async {
      writes.add(List.of(rules));
      if (writes.length == 1) {
        firstWriteStarted.complete();
        await firstWriteAllowed.future;
      }
    });
    await container.read(windowConnectionsProvider.future);
    final controller = container.read(windowConnectionsProvider.notifier);
    final firstSave = controller.upsert(first);
    final secondSave = controller.upsert(second);

    await firstWriteStarted.future;
    expect(writes, [
      [first],
    ]);
    expect(container.read(windowConnectionsProvider).requireValue, isEmpty);
    firstWriteAllowed.complete();
    await Future.wait([firstSave, secondSave]);

    expect(writes, [
      [first],
      [first, second],
    ]);
    expect(container.read(windowConnectionsProvider).requireValue, [
      first,
      second,
    ]);
  });

  test('같은 키의 규칙 교체와 삭제는 다른 프로젝트에 영향을 주지 않는다', () async {
    final old = _rule('/work/first');
    final other = _rule('/work/second');
    final updated = _rule('/work/first', pattern: 'new title');
    final container = _container(() async => [old, other], (_) async {});
    await container.read(windowConnectionsProvider.future);
    final controller = container.read(windowConnectionsProvider.notifier);
    await controller.upsert(updated);
    expect(container.read(windowConnectionsProvider).requireValue, [
      other,
      updated,
    ]);
    await controller.remove(updated.key);
    expect(container.read(windowConnectionsProvider).requireValue, [other]);
  });

  test('저장 실패는 이전 상태를 보존하며 뒤에 대기한 저장을 막지 않는다', () async {
    final old = _rule('/work/old');
    final failed = _rule('/work/failed');
    final next = _rule('/work/next');
    var attempts = 0;
    final writes = <List<WindowConnectionRule>>[];
    final container = _container(() async => [old], (rules) async {
      attempts++;
      if (attempts == 1) throw StateError('disk unavailable');
      writes.add(List.of(rules));
    });
    await container.read(windowConnectionsProvider.future);
    final controller = container.read(windowConnectionsProvider.notifier);
    final failedSave = controller.upsert(failed);
    final pendingSave = controller.upsert(next);
    await expectLater(failedSave, throwsStateError);
    await pendingSave;

    expect(writes, [
      [old, next],
    ]);
    expect(container.read(windowConnectionsProvider).requireValue, [old, next]);
  });

  test('초기 파일이 손상되면 새 규칙을 저장해 기존 파일을 덮어쓰지 않는다', () async {
    var saves = 0;
    final container = _container(
      () async => throw const FormatException('invalid file'),
      (_) async => saves++,
    );
    await expectLater(
      container.read(windowConnectionsProvider.future),
      throwsFormatException,
    );
    await expectLater(
      container
          .read(windowConnectionsProvider.notifier)
          .upsert(_rule('/work/new')),
      throwsFormatException,
    );
    expect(saves, 0);
    expect(container.read(windowConnectionsProvider).hasError, isTrue);
  });

  test('초기 읽기가 끝나기 전에 요청한 저장도 기존 규칙을 기다린다', () async {
    final old = _rule('/work/old');
    final added = _rule('/work/added');
    final loaded = Completer<List<WindowConnectionRule>>();
    final writes = <List<WindowConnectionRule>>[];
    final container = _container(
      () => loaded.future,
      (rules) async => writes.add(rules),
    );
    final pendingSave = container
        .read(windowConnectionsProvider.notifier)
        .upsert(added);
    loaded.complete([old]);
    await pendingSave;
    expect(writes, [
      [old, added],
    ]);
  });
}
