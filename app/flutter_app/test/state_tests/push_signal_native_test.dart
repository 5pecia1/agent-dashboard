import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/platform/push_signal.dart';
import 'package:my_dashboard/src/platform/push_signal_native.dart';

PushSignal _click(int transitionId) => PushSignal(
  type: kPushSignalNotificationClick,
  sessionKey: 'codex:session',
  transitionId: transitionId,
);

Future<void> _deliverSignals() => Future<void>.delayed(Duration.zero);

void main() {
  test('구독 전 마지막 클릭만 한 번 전달하고 재구독 때 재생하지 않는다', () async {
    final bus = NativePushSignalBus();
    addTearDown(bus.close);
    bus.emit(_click(1));
    bus.emit(_click(2));
    final received = <PushSignal>[];
    final first = bus.stream.listen(received.add);
    await _deliverSignals();
    expect(received, [_click(2)]);
    await first.cancel();

    final second = bus.stream.listen(received.add);
    await _deliverSignals();
    expect(received, [_click(2)]);
    await second.cancel();
  });

  test('구독자가 다시 없어지면 다음 클릭을 새 구독에 보존한다', () async {
    final bus = NativePushSignalBus();
    addTearDown(bus.close);
    final first = bus.stream.listen((_) {});
    await first.cancel();
    bus.emit(_click(3));
    final received = <PushSignal>[];
    final second = bus.stream.listen(received.add);
    await _deliverSignals();
    expect(received, [_click(3)]);
    await second.cancel();
  });

  test('클릭이 많이 쌓여도 가장 최근 선택 하나만 보존한다', () async {
    final bus = NativePushSignalBus();
    addTearDown(bus.close);
    for (var id = 1; id <= 20; id++) {
      bus.emit(_click(id));
    }
    final received = <PushSignal>[];
    final subscription = bus.stream.listen(received.add);
    await _deliverSignals();
    expect(received, [_click(20)]);
    await subscription.cancel();
  });

  test('일반 재조회 힌트는 보관하지 않고 구독 중에는 전달한다', () async {
    final bus = NativePushSignalBus();
    addTearDown(bus.close);
    const refresh = PushSignal(type: 'refresh');
    bus.emit(refresh);
    bus.emit(_click(4));
    final received = <PushSignal>[];
    final subscription = bus.stream.listen(received.add);
    await _deliverSignals();
    expect(received, [_click(4)]);
    bus.emit(refresh);
    await _deliverSignals();
    expect(received, [_click(4), refresh]);
    await subscription.cancel();
  });

  test('닫힌 수신 통로는 새 클릭을 무시한다', () async {
    final bus = NativePushSignalBus();
    bus.emit(_click(1));
    await bus.close();
    expect(() => bus.emit(_click(2)), returnsNormally);
    expect(await bus.stream.toList(), isEmpty);
  });
}
