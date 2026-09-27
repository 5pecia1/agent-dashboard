/// FRB 기능 지원 여부(capability) 시임.
///
/// 목적: 위젯 테스트가 네이티브 dylib(데스크톱)이나 wasm(web/PWA) 링크
/// 없이, override만으로 "이 기능이 이 런타임에서 지원되는가"의 양쪽
/// 분기를 전부 검증할 수 있게 한다.
///
/// 계층은 항상 이 순서로 쌓는다 — capability/i18n 두 시임 모두 동일한
/// 3계층 패턴을 따르는 게 계약이다:
///   1. 함수 타입([CapabilityCheckFn])을 typedef로 먼저 고정한다.
///   2. 그 타입의 `Provider`([capabilityCheckFnProvider])를 열어 테스트가
///      갈아끼울 지점을 만든다.
///   3. 실제 FRB 호출은 최상위 얇은 함수([_capabilityBridge]) 하나에만
///      있다 — 프로덕션 기본 구현이 그 함수를 가리키고, 테스트는
///      Provider만 override하면 된다(아래 사용 예 참고).
///
/// ```dart
/// final container = ProviderContainer(
///   overrides: [
///     isWasmRuntimeProvider.overrideWithValue(true),
///     capabilityCheckFnProvider.overrideWithValue(
///       (id) => const CapabilityDto.unsupported(
///         reason: UnsupportedReasonDto.noWasmHost,
///       ),
///     ),
///   ],
/// );
/// ```
///
/// `capabilityFor`는 동기 FRB 호출이라 위젯 `build` 메서드에서 그대로
/// 불러도 안전하다(별도 FutureProvider/스트림이 필요 없다). 네이티브에서도
/// 플러그인과 실행 경로가 연결되지 않은 기능은 미지원이다. 기능 사용 여부는
/// 런타임 종류가 아니라 이 조회 결과로 판단한다. 테스트에서는 provider를
/// override해 미지원 사유와 UI 처리를 검증한다.
///
/// 이 파일이 참조하는 `capabilityFor`/`CapabilityDto`/`UnsupportedReasonDto`
/// 이름은 app-core가 실제로 어떤 이름으로 capability API를 노출하든 그에
/// 맞춰 바뀔 수 있다 — 고정해야 하는 건 이름이 아니라 이 3계층 구조 자체다.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/rust/api/capability.dart';
import 'package:my_dashboard/src/platform/feature_status.dart';

/// `capabilityFor(capabilityId) -> CapabilityDto` 함수 모양.
typedef CapabilityCheckFn = CapabilityDto Function(String capabilityId);

CapabilityDto _capabilityBridge(
  String capabilityId,
  bool windowReady,
  bool hotkeyReady,
  bool notifyLocalReady,
) => capabilityFor(
  capabilityId: capabilityId,
  windowControlReady: windowReady,
  globalHotkeyReady: hotkeyReady,
  notifyLocalReady: notifyLocalReady,
);

/// FRB capability 어댑터 — 테스트에서는 [ProviderContainer.overrides]나
/// `ProviderScope(overrides: ...)`로 갈아끼운다.
final capabilityCheckFnProvider = Provider<CapabilityCheckFn>((ref) {
  desktopFeatureStatus.addListener(ref.invalidateSelf);
  ref.onDispose(() => desktopFeatureStatus.removeListener(ref.invalidateSelf));
  final windowReady = desktopFeatureStatus.windowControl;
  final hotkeyReady = desktopFeatureStatus.globalHotkey;
  final notifyLocalReady = desktopFeatureStatus.notifyLocal;
  return (id) => _capabilityBridge(id, windowReady, hotkeyReady, notifyLocalReady);
});

/// 현재 프로세스가 wasm32(Flutter web/PWA) 빌드인지 여부.
///
/// 기본값은 `kIsWeb`이며 런타임 설명을 표시할 때 사용한다.
/// 개별 기능의 지원 여부는 [capabilityCheckFnProvider]로 확인한다.
final isWasmRuntimeProvider = Provider<bool>((ref) => kIsWeb);

/// 화면에는 FRB 타입 이름 대신 번역 키만 전달한다.
final capabilityStatusKeyProvider = Provider.family<String, String>((ref, id) {
  final capability = ref.watch(capabilityCheckFnProvider)(id);
  return switch (capability) {
    CapabilityDto_Supported() => 'capability.available',
    CapabilityDto_Unsupported(:final reason) => switch (reason) {
      UnsupportedReasonDto.noWasmHost => 'capability.desktop_only',
      UnsupportedReasonDto.noBrowserHost => 'capability.web_only',
      UnsupportedReasonDto.notConfigured => 'capability.not_configured',
      UnsupportedReasonDto.unknownCapability => 'capability.unknown',
    },
  };
});
