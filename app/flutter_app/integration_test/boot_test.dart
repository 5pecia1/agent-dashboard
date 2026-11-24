import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:my_dashboard/main.dart' as app;
import 'package:my_dashboard/src/ui/setup_page.dart';

import 'isolated_home.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('빈 환경에서 실제 앱이 서버 연결 설정 화면을 연다', (tester) async {
    if (!kIsWeb && Platform.isMacOS) {
      requireFreshDashboardHome(Platform.environment['HOME']);
    }
    await app.main();
    await tester.pumpAndSettle();

    final setup = find.byType(SetupPage);
    expect(setup, findsOneWidget);
    final fields = find.descendant(of: setup, matching: find.byType(TextField));
    expect(fields, findsWidgets);
    expect(tester.widget<TextField>(fields.first).controller?.text, isEmpty);
  });
}
