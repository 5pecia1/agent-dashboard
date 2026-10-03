/// `debugPrint`로 나간 줄을 모은다.
///
/// 앱이 화면에 보이지 않는 원문을 남기는 자리가 `debugPrint`다
/// (`sync_controller.dart`의 `SyncErrorInfo.fromError`, `platform/tray_native.
/// dart`). 테스트가 그 줄을 확인하고, 그 줄이 테스트 출력에 섞이지 않게 한다.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

/// [body]가 도는 동안 `debugPrint`로 나간 줄을 모아 돌려준다. 끝나면(던져도)
/// 원래 `debugPrint`를 되돌린다.
Future<List<String>> captureDebugPrint(FutureOr<void> Function() body) async {
  final logged = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) => logged.add(message ?? '');
  try {
    await body();
  } finally {
    debugPrint = original;
  }
  return logged;
}
