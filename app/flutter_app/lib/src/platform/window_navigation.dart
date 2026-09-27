/// macOS 접근성 창 조회·전환 채널. 웹에서는 채널을 호출하지 않는다.
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

/// macos/Runner/WindowNavigation.swift와 같은 채널 계약이다.
const kWindowNavigationChannelName = 'app/window_navigation';
const kWindowScanMethod = 'scan';
const kWindowFocusMethod = 'focus';
const kWindowOpenSettingsMethod = 'openSettings';
const kWindowTokenArgument = 'token';
const kWindowBundleIdArgument = 'bundleId';
const kWindowFocusUnconfirmed = 'unconfirmed';

const _channel = MethodChannel(kWindowNavigationChannelName);
const _failedScan = <String, Object?>{
  'trusted': false,
  'complete': false,
  'localHost': '',
  'windows': <Object?>[],
};

bool get supportsWindowNavigation =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// [bundleId]가 있으면 해당 앱만 조회한다. complete는 요청한 범위에 적용된다.
Future<Map<String, Object?>> scanWindows({String? bundleId}) async {
  if (!supportsWindowNavigation) return _failedScan;
  final targetBundleId = bundleId?.trim();
  try {
    return await _channel.invokeMapMethod<String, Object?>(
          kWindowScanMethod,
          targetBundleId == null || targetBundleId.isEmpty
              ? null
              : <String, Object?>{kWindowBundleIdArgument: targetBundleId},
        ) ??
        _failedScan;
  } on MissingPluginException {
    return _failedScan;
  } on PlatformException {
    return _failedScan;
  }
}

Future<String> focusWindow(String token) async {
  if (!supportsWindowNavigation || token.isEmpty) {
    return kWindowFocusUnconfirmed;
  }
  try {
    return await _channel.invokeMethod<String>(
          kWindowFocusMethod,
          <String, Object?>{kWindowTokenArgument: token},
        ) ??
        kWindowFocusUnconfirmed;
  } on MissingPluginException {
    return kWindowFocusUnconfirmed;
  } on PlatformException {
    return kWindowFocusUnconfirmed;
  }
}

Future<void> openWindowAccessibilitySettings() async {
  if (!supportsWindowNavigation) return;
  try {
    await _channel.invokeMethod<void>(kWindowOpenSettingsMethod);
  } on MissingPluginException {
    // 지원하지 않는 셸에서 설정 화면을 열 수 없다.
  } on PlatformException {
    // 설정 진입 실패가 알림 흐름을 중단하지 않게 한다.
  }
}
