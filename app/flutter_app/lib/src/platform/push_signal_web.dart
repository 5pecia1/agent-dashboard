/// `push_signal.dart`의 웹 구현 — `BroadcastChannel('dashboard')` 수신자.
///
/// `web/push_sw.js`의 `notificationclick` 핸들러가 열려 있는 창을 찾으면
/// 새 창을 열지 않고 이 채널로 신호만 던진다("이 세션을 열어라"까지만
/// 말한다 — 라우팅과 재동기화는 페이지가 한다). 그 신호를 실제로 듣는
/// 쪽이 지금까지 없어서 클릭이 창 포커스까지만 되고 화면은 그대로였다
/// (직전 게이트가 발견한 미배선 2건 중 하나) — 이 파일이 그 구멍을 막는다.
///
/// **던지지 않는다.** `BroadcastChannel`이 없는 브라우저(또는 이 API를
/// 막아 둔 컨텍스트)에서는 빈 스트림을 돌려준다 — push 수신 배선이 없어도
/// 폴링은 그대로 돌고, 정합성은 그쪽이 담보한다(정본 `push` 절).
///
/// `flutter test`(VM 타깃)는 이 파일을 절대 실행하지 않는다. 실제 검증은
/// `app/scripts/web_push_smoke.py`가 헤드리스 브라우저에서 하고, 값 변환
/// 규칙([pushSignalFromMap])은 호스트 없이 단위 테스트로 닫는다.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'package:my_dashboard/src/platform/push_signal.dart';

/// `push_sw.js`가 던지는 신호를 [PushSignal]로 옮겨 흘려보낸다.
///
/// 채널은 **구독이 생길 때 열고 취소될 때 닫는다** — 페이지가 살아 있는
/// 동안 열린 채로 두면 hot restart마다 채널이 쌓인다.
Stream<PushSignal> watchPushSignals() {
  if (!globalContext.has('BroadcastChannel')) {
    return const Stream<PushSignal>.empty();
  }

  web.BroadcastChannel? channel;
  late final StreamController<PushSignal> controller;

  void handleMessage(web.MessageEvent event) {
    final signal = _signalFromMessage(event.data);
    if (signal == null) return;
    controller.add(signal);
  }

  final listener = handleMessage.toJS;

  controller = StreamController<PushSignal>.broadcast(
    onListen: () {
      try {
        channel = web.BroadcastChannel(kPushSignalChannelName)
          ..addEventListener('message', listener);
      } on Object {
        // 채널을 못 열어도 스트림은 그대로 조용히 남는다.
        channel = null;
      }
    },
    onCancel: () {
      final open = channel;
      channel = null;
      if (open == null) return;
      try {
        open
          ..removeEventListener('message', listener)
          ..close();
      } on Object {
        // 닫기 실패는 무시한다 — 페이지가 사라지면 채널도 사라진다.
      }
    },
  );
  return controller.stream;
}

/// `MessageEvent.data`(구조화 복제된 JS 객체)에서 우리가 아는 키만 꺼낸다.
/// 객체가 아니거나 읽는 데 실패하면 null — 그 메시지는 무시한다.
PushSignal? _signalFromMessage(JSAny? data) {
  if (data == null) return null;
  if (!data.isA<JSObject>()) return null;
  final object = data as JSObject;

  String? stringOf(String key) {
    try {
      return object.getProperty<JSString?>(key.toJS)?.toDart;
    } on Object {
      return null;
    }
  }

  bool? boolOf(String key) {
    try {
      return object.getProperty<JSBoolean?>(key.toJS)?.toDart;
    } on Object {
      return null;
    }
  }

  Object? transitionIdOf() {
    try {
      final value = object.getProperty<JSAny?>(kPushSignalTransitionIdField.toJS);
      if (value == null) return null;
      if (value.isA<JSString>()) return (value as JSString).toDart;
      if (value.isA<JSNumber>()) {
        final number = (value as JSNumber).toDartDouble;
        if (number.isFinite && number == number.truncateToDouble()) {
          return number.toInt();
        }
      }
    } on Object {
      // 잘못된 전이는 클릭 시점의 읽음 경계로 사용할 수 없다.
    }
    return null;
  }

  return pushSignalFromMap(<String, Object?>{
    kPushSignalTypeField: stringOf(kPushSignalTypeField),
    kPushSignalSessionKeyField: stringOf(kPushSignalSessionKeyField),
    kPushSignalLinkField: stringOf(kPushSignalLinkField),
    kPushSignalRefreshField: boolOf(kPushSignalRefreshField),
    kPushSignalTransitionIdField: transitionIdOf(),
    kPushSignalProjectField: stringOf(kPushSignalProjectField),
    kPushSignalHostField: stringOf(kPushSignalHostField),
  });
}
