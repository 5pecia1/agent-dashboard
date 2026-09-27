/// `push_signal.dart`의 데스크톱(비-웹) 구현.
///
/// 데스크톱에는 `BroadcastChannel`이 없다. 대신 macOS에서는
/// `apns_push_native.dart`가 `FirebaseMessaging.onMessageOpenedApp`
/// (그리고 냉시작 `getInitialMessage()`)을 이 파일의 [emitPushSignal]로
/// 흘려 넣는다 — 그래서 `app.dart`의 수신자는 웹/맥을 구분하지 않고
/// [watchPushSignals] 하나만 듣는다.
///
/// **이 파일은 firebase를 import하지 않는다.** 통로만 갖고 있고, 그 통로에
/// 무엇이 흘러 들어오는지는 모른다 — macOS가 아닌 데스크톱(linux/windows)
/// 에서는 아무도 [emitPushSignal]을 부르지 않으므로 스트림이 조용할
/// 뿐이다(예외가 아니라 정상 분기다).
library;

import 'dart:async';

import 'package:my_dashboard/src/platform/push_signal.dart';

/// 재조회 힌트와 달리 사용자의 마지막 클릭은 다음 구독까지 한 번 보존한다.
/// UI inbox와 같은 규칙으로, 부팅 중 앞서 선택한 창을 뒤늦게 열지 않는다.
class NativePushSignalBus {
  NativePushSignalBus() {
    _signals = StreamController<PushSignal>.broadcast(onListen: _flushPending);
  }

  PushSignal? _pendingClick;
  late final StreamController<PushSignal> _signals;

  Stream<PushSignal> get stream => _signals.stream;

  void emit(PushSignal signal) {
    if (_signals.isClosed) return;
    if (_signals.hasListener) {
      _signals.add(signal);
      return;
    }
    if (signal.type != kPushSignalNotificationClick) return;
    _pendingClick = signal;
  }

  void _flushPending() {
    final pending = _pendingClick;
    _pendingClick = null;
    if (pending != null) _signals.add(pending);
  }

  Future<void> close() {
    _pendingClick = null;
    return _signals.close();
  }
}

final NativePushSignalBus _signals = NativePushSignalBus();

/// 수신자가 구독하는 지점. `state/push_provider.dart`의
/// `pushSignalWatchProvider`가 이 함수를 기본 구현으로 삼는다.
Stream<PushSignal> watchPushSignals() => _signals.stream;

/// 신호 하나를 흘려 넣는다(`apns_push_native.dart`가 부른다).
void emitPushSignal(PushSignal signal) {
  _signals.emit(signal);
}
