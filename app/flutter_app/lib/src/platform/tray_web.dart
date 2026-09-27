/// `tray_native.dart`의 웹 거울 — 항상 no-op이다.
///
/// `local_notifications_web.dart`와 같은 자리: 웹에는 메뉴 바/시스템 트레이
/// 자체가 없고, `tray_manager`가 `dart:io`를 무조건 import해서 이 파일이
/// 없으면 조건부 export가 웹 컴파일 그래프에 `dart:io`를 끌고 들어가 빌드가
/// 깨진다.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';

/// [tray_native.dart]와 이름/모양을 맞춘 거울. 웹에서는 항상 false다.
final Provider<bool> traySupportedProvider = Provider<bool>((ref) => false);

/// no-op. 웹에는 트레이 자체가 없으니 부를 대상이 없다.
Future<void> installTray(
  WidgetRef ref, {
  Future<void> Function(SessionViewDto)? onSessionSelected,
}) async {}
