import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/integrations/data/agy_usage_api.dart';
import 'package:my_dashboard/src/integrations/data/agy_usage_models.dart';
import 'package:my_dashboard/src/integrations/state/agy_usage_provider.dart';

import '../fixtures/agy_usage_fixture.dart';

AgyUsageReading _reading() => agyUsageReadingFromJson(agyUsageFixtureData());

void main() {
  test('미설정과 미지원 환경에서는 프로세스를 조회하지 않는다', () async {
    var calls = 0;
    final container = ProviderContainer(
      overrides: [
        agyUsageSupportedProvider.overrideWithValue(false),
        agyInitialEnabledProvider.overrideWithValue(true),
        agyUsageFetchProvider.overrideWithValue(() async {
          calls++;
          return _reading();
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(agyUsageControllerProvider.notifier);
    controller.configure(true);
    await controller.refresh(userInitiated: true);
    expect(container.read(agyUsageControllerProvider).enabled, isFalse);
    expect(calls, 0);
  });

  test('동시 갱신을 합치며 껐다 켜도 이전 프로세스가 끝난 뒤 새로 조회한다', () async {
    final replies = <Completer<AgyUsageReading>>[];
    final container = ProviderContainer(
      overrides: [
        agyUsageSupportedProvider.overrideWithValue(true),
        agyUsageFetchProvider.overrideWithValue(() {
          final reply = Completer<AgyUsageReading>();
          replies.add(reply);
          return reply.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(agyUsageControllerProvider.notifier)
      ..setActive(false);
    await controller.refresh();
    expect(replies, isEmpty);
    controller.configure(true);
    final original = controller.refresh();
    expect(controller.refresh(), same(original));
    await Future<void>.delayed(Duration.zero);
    expect(replies, hasLength(1));
    controller.configure(false);
    expect(container.read(agyUsageControllerProvider).reading, isNull);
    controller.configure(true);
    final restarted = controller.refresh();
    expect(replies, hasLength(1));
    replies.first.complete(_reading());
    await original;
    await Future<void>.delayed(Duration.zero);
    expect(replies, hasLength(2));
    expect(container.read(agyUsageControllerProvider).reading, isNull);
    final fresh = _reading();
    replies.last.complete(fresh);
    await restarted;
    expect(container.read(agyUsageControllerProvider).reading, same(fresh));
    expect(container.read(agyUsageControllerProvider).loading, isFalse);
  });

  test('실패하면 마지막 성공값과 시각을 보존하고 다시 성공하면 오류를 지운다', () async {
    var failure = false;
    final container = ProviderContainer(
      overrides: [
        agyUsageSupportedProvider.overrideWithValue(true),
        agyUsageFetchProvider.overrideWithValue(() async {
          if (failure) throw const AgyUsageFailure('agy.timeout');
          return _reading();
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(agyUsageControllerProvider.notifier)
      ..setActive(false)
      ..configure(true);
    await controller.refresh();
    final original = container.read(agyUsageControllerProvider);
    failure = true;
    await controller.refresh();
    final failed = container.read(agyUsageControllerProvider);
    expect(failed.reading, same(original.reading));
    expect(failed.updatedAt, original.updatedAt);
    expect(failed.errorKey, 'agy.timeout');
    failure = false;
    await controller.refresh(userInitiated: true);
    expect(container.read(agyUsageControllerProvider).errorKey, isNull);
    controller.configure(false);
    expect(container.read(agyUsageControllerProvider).reading, isNull);
  });

  testWidgets('인증 실패는 정기 재시도를 멈추고 수동 갱신과 활성 화면에서 복구한다', (tester) async {
    var calls = 0;
    var signedIn = false;
    final container = ProviderContainer(
      overrides: [
        agyUsageSupportedProvider.overrideWithValue(true),
        agyUsageFetchProvider.overrideWithValue(() async {
          calls++;
          if (!signedIn) throw const AgyUsageFailure('agy.sign_in_required');
          return _reading();
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(agyUsageControllerProvider.notifier)
      ..configure(true);
    await tester.pump();
    expect(calls, 1);
    await tester.pump(const Duration(minutes: 2));
    expect(calls, 1);
    signedIn = true;
    await controller.refresh(userInitiated: true);
    expect(calls, 2);
    await tester.pump(const Duration(seconds: 59));
    expect(calls, 2);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 3);
    controller.setActive(false);
    await tester.pump(const Duration(minutes: 2));
    expect(calls, 3);
    await controller.refresh(userInitiated: true);
    expect(calls, 4);
    await tester.pump(const Duration(minutes: 2));
    expect(calls, 4, reason: '숨긴 창에서 트레이 갱신은 정기 폴링을 켜지 않는다');
    controller.setActive(true);
    await tester.pump();
    expect(calls, 5);
    controller.setActive(false);
  });

  test('폐기된 컨트롤러의 늦은 결과와 동기 예외가 다음 요청을 막지 않는다', () async {
    final reply = Completer<AgyUsageReading>();
    var calls = 0;
    final container = ProviderContainer(
      overrides: [
        agyUsageSupportedProvider.overrideWithValue(true),
        agyUsageFetchProvider.overrideWithValue(() {
          if (++calls == 1) throw StateError('fixture failure');
          return reply.future;
        }),
      ],
    );
    final controller = container.read(agyUsageControllerProvider.notifier)
      ..setActive(false)
      ..configure(true);
    await controller.refresh();
    expect(
      container.read(agyUsageControllerProvider).errorKey,
      'agy.query_failed',
    );
    final pending = controller.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
    container.dispose();
    reply.complete(_reading());
    await pending;
  });
}
