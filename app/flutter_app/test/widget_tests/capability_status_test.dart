/// T-wire: capability 데모 화면이 [TemplateDemoPage]로 강등되면서
/// [SolApp]을 통해 도달하려면 `dashboardConfigValuesProvider`/
/// `syncControllerProvider`까지 override해야 하는 무관한 부담이 생긴다 —
/// 이 테스트가 검증하려는 건 그 화면 자체의 capability 문구 표시뿐이므로
/// `narrow_width_test.dart`/`goldens_test.dart`의 다른 하위 화면 테스트와
/// 같은 패턴으로 화면을 직접 펌프한다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/rust/api/capability.dart';
import 'package:my_dashboard/src/state/capability_provider.dart';
import 'package:my_dashboard/src/ui/template_demo_page.dart';

const _messages = {
  'app.title': 'My Dashboard',
  'capability.available': 'Available',
  'capability.desktop_only': 'Not available in this browser',
  'capability.not_configured': 'Not available in this app',
  'capability.unknown': 'Feature unavailable',
};

void main() {
  final cases = [
    (const CapabilityDto.supported(), 'Available'),
    (
      const CapabilityDto.unsupported(reason: UnsupportedReasonDto.noWasmHost),
      'Not available in this browser',
    ),
    (
      const CapabilityDto.unsupported(
        reason: UnsupportedReasonDto.notConfigured,
      ),
      'Not available in this app',
    ),
    (
      const CapabilityDto.unsupported(
        reason: UnsupportedReasonDto.unknownCapability,
      ),
      'Feature unavailable',
    ),
  ];
  for (final isWeb in [false, true]) {
    for (final (capability, expected) in cases) {
      testWidgets('${isWeb ? "웹" : "데스크톱"}에서 기능 상태를 사용자 문구로 표시한다: $expected', (
        tester,
      ) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              i18nTranslateOverride.overrideWithValue(
                (key, locale) => _messages[key] ?? key,
              ),
              isWasmRuntimeProvider.overrideWithValue(isWeb),
              capabilityCheckFnProvider.overrideWithValue((id) => capability),
            ],
            child: const MaterialApp(home: TemplateDemoPage()),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(expected), findsOneWidget);
        expect(find.textContaining('CapabilityDto'), findsNothing);
        expect(find.textContaining('UnsupportedReasonDto'), findsNothing);
      });
    }
  }
}
