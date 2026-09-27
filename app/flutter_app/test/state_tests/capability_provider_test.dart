import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/rust/api/capability.dart';
import 'package:my_dashboard/src/state/capability_provider.dart';
import 'package:my_dashboard/src/platform/feature_status.dart';
import 'package:my_dashboard/src/rust/frb_generated.dart';

class _CapabilityApi extends RustLibApi {
  @override
  CapabilityDto crateApiCapabilityCapabilityFor({
    required String capabilityId,
    required bool windowControlReady,
    required bool globalHotkeyReady,
    required bool notifyLocalReady,
  }) {
    final ready = switch (capabilityId) {
      'desktop.global_hotkey' => globalHotkeyReady,
      'notify.local' => notifyLocalReady,
      _ => windowControlReady,
    };
    return ready
        ? const CapabilityDto.supported()
        : const CapabilityDto.unsupported(
            reason: UnsupportedReasonDto.notConfigured,
          );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('실행_준비_상태의_변경이_실제_Provider_구독자에게_전달된다', () async {
    RustLib.initMock(api: _CapabilityApi());
    addTearDown(RustLib.dispose);
    desktopFeatureStatus.windowChanged(false);
    desktopFeatureStatus.hotkeyChanged(false);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final observed = <String>[];
    final provider = capabilityStatusKeyProvider('desktop.global_hotkey');
    container.listen(provider, (_, value) {
      observed.add(value);
    }, fireImmediately: true);
    desktopFeatureStatus.hotkeyChanged(true);
    await container.pump();
    desktopFeatureStatus.hotkeyChanged(false);
    await container.pump();
    expect(observed, [
      'capability.not_configured',
      'capability.available',
      'capability.not_configured',
    ]);
  });

  test('T16 완료 기준 (a): notifyLocal 프로브 결과 전이가 capability 결과에 반영된다', () async {
    RustLib.initMock(api: _CapabilityApi());
    addTearDown(RustLib.dispose);
    // 프로브가 아직 끝나지 않은 초기 상태로 되돌린다.
    desktopFeatureStatus.notifyLocalChanged(false);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final observed = <String>[];
    final provider = capabilityStatusKeyProvider('notify.local');
    container.listen(provider, (_, value) {
      observed.add(value);
    }, fireImmediately: true);

    // 프로브가 성공(flutter_local_notifications 또는 osascript 폴백 중 하나가
    // 실제로 동작함을 확인)하면 readiness가 true로 넘어간다.
    desktopFeatureStatus.notifyLocalChanged(true);
    await container.pump();
    // 반대로 프로브가 실패로 판정되면 다시 미구성으로 접힌다.
    desktopFeatureStatus.notifyLocalChanged(false);
    await container.pump();

    expect(observed, [
      'capability.not_configured',
      'capability.available',
      'capability.not_configured',
    ]);
  });

  test('capability override로 네이티브 링크 없이 wasm 미지원 분기를 확인한다', () {
    const unsupported = CapabilityDto.unsupported(
      reason: UnsupportedReasonDto.noWasmHost,
    );
    final container = ProviderContainer(
      overrides: [
        // 실제 wasm 빌드가 아니어도 이 provider 하나만 override하면
        // "미지원" 분기를 네이티브 테스트 호스트에서 그대로 태울 수
        // 있다 — capability_provider.dart 라이브러리 문서 참고.
        isWasmRuntimeProvider.overrideWithValue(true),
        capabilityCheckFnProvider.overrideWithValue(
          (capabilityId) => unsupported,
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(isWasmRuntimeProvider), isTrue);
    final capability = container.read(capabilityCheckFnProvider)(
      'sample.feature',
    );
    expect(capability, unsupported);
  });

  test('capability override 기본값은 supported를 돌려준다', () {
    final container = ProviderContainer(
      overrides: [
        capabilityCheckFnProvider.overrideWithValue(
          (capabilityId) => const CapabilityDto.supported(),
        ),
      ],
    );
    addTearDown(container.dispose);

    final capability = container.read(capabilityCheckFnProvider)(
      'sample.feature',
    );
    expect(capability, const CapabilityDto.supported());
  });
}
