import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';
import '../test_helpers/session_deletion_harness.dart';

void main() {
  testWidgets(
    '세션 선택 화면 골든',
    (tester) async {
      tester.view.physicalSize = const Size(800, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final harness = SessionDeletionHarness(
        send: (_) async => const ApiResponse(statusCode: 200, body: '{}'),
      );
      addTearDown(harness.container.dispose);
      harness.controller.clearAlerts();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: harness.container,
          child: ProviderScope(
            overrides: [
              i18nTranslateOverride.overrideWithValue(
                (key, locale) => switch (key) {
                  'session.list.title' => 'Sessions',
                  'session.selection.enter' => 'Select sessions',
                  'session.selection.select_all' => 'Select all shown',
                  'session.selection.delete_action' => 'Delete selected',
                  'session.group.unknown_project' => 'Unknown project',
                  'action.cancel' => 'Cancel',
                  _ => key.split('.').last,
                },
              ),
              i18nTranslateArgsOverride.overrideWithValue(
                (key, locale, keys, values) => switch (key) {
                  'session.group.count' => '${values.single} sessions',
                  'session.selection.count' => '${values.single} selected',
                  _ => key.split('.').last,
                },
              ),
            ],
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light(),
              home: const SessionsPage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('session-selection-enter')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('select-session-$deletionOtherKey')),
      );
      await tester.tap(
        find.byKey(const ValueKey('select-session-$deletionFirstKey')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final actualBytes = await tester.runAsync(() async {
        RenderObject renderObject = find
            .byType(MaterialApp)
            .evaluate()
            .single
            .renderObject!;
        while (!renderObject.isRepaintBoundary) {
          renderObject = renderObject.parent!;
        }
        final layer = renderObject.debugLayer! as OffsetLayer;
        final image = await layer.toImage(renderObject.paintBounds);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return bytes!.buffer.asUint8List();
      });
      final encoded = base64Encode(actualBytes!);
      stderr.writeln('GOLDEN_ACTUAL_BEGIN');
      for (var offset = 0; offset < encoded.length; offset += 76) {
        final end = offset + 76 < encoded.length ? offset + 76 : encoded.length;
        stderr.writeln(encoded.substring(offset, end));
      }
      stderr.writeln('GOLDEN_ACTUAL_END');
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          '../goldens/sessions_selection_${Platform.operatingSystem}.png',
        ),
      );
    },
    tags: <String>['golden'],
    skip: !Platform.isMacOS,
  );
}
