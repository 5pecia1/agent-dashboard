/// App Nap 방지·wake 신호의 데스크톱 구현 (TASK P-impl (1)(3)).
///
/// **왜 새 채널이 아니라 기존 상주 채널인가.** `resident_mode_native.dart`가
/// 이미 `MethodChannel("app/resident")`를 열어 뒀다 — 상주 여부와 "창이
/// 숨겨진 동안 타이머를 얼마나 빡빡하게 유지할까"는 같은 생명주기 얘기다.
/// 그래서 이 파일은 그 채널 이름([kResidentChannelName])을 그대로 재사용해
/// 메서드만 둘 더한다: `setBackgroundActivity`(Dart -> Native, App Nap 방지
/// on/off)와 `onWake`(Native -> Dart, 맥이 깨어났다는 신호). 채널을 남발하지
/// 않는다는 제약을 그대로 지킨다.
///
/// **던지지 않는다.** `resident_mode_native.dart`와 같은 관용 — 채널
/// 반대편이 없어도(macOS가 아닌 데스크톱, 플러그인 미등록) 조용한 no-op이다.
/// App Nap 방지는 "안 되면 그만"인 최적화이지 정확성 요구사항이 아니다 —
/// 못 걸어도 다음 포그라운드 복귀나 다음 wake가 다시 따라잡는다.
library;

import 'dart:async';

import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, MissingPluginException, PlatformException;

import 'package:my_dashboard/src/platform/resident_mode_native.dart'
    show hasResidentToggleHost, kResidentChannelName;

/// [kResidentChannelName] 위에서 App Nap 방지를 켜고 끄는 메서드. 인자는
/// `{'active': bool}`.
const String kBackgroundActivitySetMethod = 'setBackgroundActivity';

/// [kBackgroundActivitySetMethod]의 인자 키.
const String kBackgroundActivityActiveArg = 'active';

/// [kResidentChannelName] 위에서 네이티브가 Dart로 보내는, 맥이 잠에서
/// 깨어났다는 신호. 인자는 없다 — 발생했다는 사실 자체가 정보다.
const String kBackgroundActivityWakeMethod = 'onWake';

const MethodChannel _channel = MethodChannel(kResidentChannelName);

/// 네이티브 쪽에 App Nap 방지를 켜거나 끈다. [BackgroundActivityController]가
/// "상주 모드 && 창 숨김"을 판정할 때마다 부른다 — 실제
/// `ProcessInfo.beginActivity`/`endActivity` 호출은 `AppDelegate.swift`가
/// 갖고 있다(Dart에는 그 API가 없다).
Future<void> applyBackgroundActivity(bool active) async {
  if (!hasResidentToggleHost) return;
  try {
    await _channel.invokeMethod<void>(kBackgroundActivitySetMethod, <String, Object?>{
      kBackgroundActivityActiveArg: active,
    });
  } on MissingPluginException {
    // 채널 반대편이 아직/영영 없다 — 조용히 접는다.
  } on PlatformException {
    // 네이티브가 거절했다. 다음 전환(창 복귀/재숨김)이 다시 시도한다.
  }
}

/// [kResidentChannelName] 위에서 [kBackgroundActivityWakeMethod] 호출을
/// 받아 스트림으로 흘린다. `resident_mode_native.dart`는 이 채널에
/// `setMethodCallHandler`를 걸지 않으므로(그 파일은 내보내기만 한다) 여기서
/// 핸들러를 거는 것과 충돌하지 않는다.
Stream<void> watchWakeSignals() {
  if (!hasResidentToggleHost) return const Stream<void>.empty();
  late final StreamController<void> controller;
  controller = StreamController<void>.broadcast(
    onListen: () {
      _channel.setMethodCallHandler((MethodCall call) async {
        if (call.method == kBackgroundActivityWakeMethod) {
          controller.add(null);
        }
        return null;
      });
    },
    onCancel: () {
      _channel.setMethodCallHandler(null);
    },
  );
  return controller.stream;
}
