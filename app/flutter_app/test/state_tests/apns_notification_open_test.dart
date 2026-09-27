import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/platform/apns_push_native.dart';
import 'package:my_dashboard/src/platform/push_signal.dart';

const _initialMessage = RemoteMessage(
  data: {
    'session_key': 'codex:initial',
    'transition_id': '42',
    'project': '/work/dashboard',
    'host': 'work-mac',
  },
);

void main() {
  test('APNs 배너의 클릭 시점과 창 연결 정보를 보존한다', () {
    final signal = pushSignalFromRemoteMessage(_initialMessage);
    expect(signal.type, kPushSignalNotificationClick);
    expect(signal.sessionKey, 'codex:initial');
    expect(signal.transitionId, 42);
    expect(signal.project, '/work/dashboard');
    expect(signal.host, 'work-mac');
  });

  test('클릭 콜백은 payload type과 무관하게 클릭 신호로 전달한다', () {
    final signal = pushSignalFromRemoteMessage(
      const RemoteMessage(data: {'type': 'refresh', 'transition_id': '42'}),
    );
    expect(signal.type, kPushSignalNotificationClick);
    expect(signal.transitionId, 42);
  });

  test('등록을 동시에 재시도해도 초기 클릭과 열린 배너 구독은 하나다', () async {
    final messages = StreamController<RemoteMessage>.broadcast();
    addTearDown(messages.close);
    final initial = Completer<RemoteMessage?>();
    final signals = <PushSignal>[];
    final handler = ApnsNotificationOpenHandler(onSignal: signals.add);
    addTearDown(handler.dispose);
    var reads = 0;
    Future<RemoteMessage?> getInitialMessage() {
      reads++;
      return initial.future;
    }

    final first = handler.start(
      openedMessages: messages.stream,
      getInitialMessage: getInitialMessage,
    );
    final second = handler.start(
      openedMessages: messages.stream,
      getInitialMessage: getInitialMessage,
    );
    expect(reads, 1);
    initial.complete(_initialMessage);
    await Future.wait([first, second]);
    expect(signals, [pushSignalFromRemoteMessage(_initialMessage)]);

    await handler.start(openedMessages: messages.stream, getInitialMessage: getInitialMessage);
    expect(reads, 1);
    messages.add(
      const RemoteMessage(data: {'session_key': 'claude_code:live', 'transition_id': '43'}),
    );
    await Future<void>.delayed(Duration.zero);
    expect(signals.length, 2);
    expect(signals.last.sessionKey, 'claude_code:live');
    expect(signals.last.transitionId, 43);
  });

  test('초기 클릭 조회 실패는 등록에 전파하지 않고 이후 클릭은 수신한다', () async {
    final messages = StreamController<RemoteMessage>.broadcast();
    addTearDown(messages.close);
    final signals = <PushSignal>[];
    final handler = ApnsNotificationOpenHandler(onSignal: signals.add);
    addTearDown(handler.dispose);
    var reads = 0;
    Future<RemoteMessage?> getInitialMessage() async {
      reads++;
      throw StateError('initial message unavailable');
    }

    await handler.start(openedMessages: messages.stream, getInitialMessage: getInitialMessage);
    await handler.start(openedMessages: messages.stream, getInitialMessage: getInitialMessage);
    expect(reads, 1);
    messages.addError(StateError('stream unavailable'));
    messages.add(_initialMessage);
    await Future<void>.delayed(Duration.zero);
    expect(signals, [pushSignalFromRemoteMessage(_initialMessage)]);
  });

  test('초기 클릭이 없는 일반 시작도 초기 조회를 반복하지 않는다', () async {
    final handler = ApnsNotificationOpenHandler(onSignal: (_) => fail('클릭 없음'));
    addTearDown(handler.dispose);
    var reads = 0;
    Future<RemoteMessage?> getInitialMessage() async {
      reads++;
      return null;
    }

    for (var attempt = 0; attempt < 3; attempt++) {
      await handler.start(
        openedMessages: const Stream<RemoteMessage>.empty(),
        getInitialMessage: getInitialMessage,
      );
    }
    expect(reads, 1);
  });
}
