import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/rust/api/i18n.dart';
import 'package:my_dashboard/src/rust/frb_generated.dart';
import 'package:my_dashboard/src/state/saved_prompts_provider.dart';
import 'package:my_dashboard/src/state/prompt_history_provider.dart';
import 'package:my_dashboard/src/state/saved_prompts_store_io.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/prompt_library_page.dart';

import '../test/fixtures/prompt_library_fixture.dart';

const _outputPath = String.fromEnvironment(
  'QA_OUTPUT',
  defaultValue: '/tmp/my-dashboard-prompt-native-qa',
);
const _largeScale = 1.8;
final _captureKey = GlobalKey();

Future<void> _capture(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  final boundary =
      _captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2);
  try {
    final bytes = await image.toByteData(format: ImageByteFormat.png);
    await Directory(_outputPath).create(recursive: true);
    await File(
      '$_outputPath/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('실제 macOS 바이너리의 통계와 복사 저장 및 재실행 보존을 검증한다', (tester) async {
    await RustLib.init();
    binding.testTextInput.register();
    final temporary = await Directory.systemTemp.createTemp(
      'prompt-native-storage-',
    );
    final file = File('${temporary.path}/saved-prompts.json');
    final store = SavedPromptsFileStore(file);
    var httpReads = 0;

    Future<void> show(
      LocaleDto locale, {
      bool large = false,
      bool dark = false,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey('${locale.name}-$large-$dark'),
          overrides: [
            localeProvider.overrideWithValue(locale),
            dashboardApiConfigProvider.overrideWithValue(
              DashboardApiConfig(
                baseUrl: Uri.parse('https://fixture.invalid'),
                clientToken: 'fixture-only',
              ),
            ),
            httpSendProvider.overrideWithValue((request) async {
              expectSync(request.method, 'GET');
              expectSync(request.url.path, kEventsPath);
              httpReads++;
              return promptQaResponse(request);
            }),
            savedPromptsLoadFnProvider.overrideWithValue(store.load),
            savedPromptsSaveFnProvider.overrideWithValue(store.save),
          ],
          child: MaterialApp(
            theme: dark ? AppTheme.dark() : AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(large ? _largeScale : 1),
              ),
              child: RepaintBoundary(key: _captureKey, child: child!),
            ),
            home: const PromptLibraryPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PromptLibraryPage)),
      );
      for (var attempt = 0; attempt < 30; attempt++) {
        if (container.read(promptHistoryProvider).value?.refreshing == false) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(container.read(promptHistoryProvider).value?.error, isNull);
      expect(container.read(promptHistoryProvider).value?.refreshing, isFalse);
    }

    await show(LocaleDto.ko);
    expect(find.text('프롬프트'), findsOneWidget);
    expect(find.text('도구가 만든 것으로 식별된 메시지 2개 제외'), findsOneWidget);
    expect(
      find.textContaining(promptQaMachineText, findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining(promptQaAmbientMachineText, findRichText: true),
      findsNothing,
    );
    await _capture(tester, 'ko-initial');
    expect(find.text(promptQaText, findRichText: true), findsOneWidget);
    await _capture(tester, 'ko-stats');
    await Clipboard.setData(
      const ClipboardData(text: 'PROMPT_QA_CLIPBOARD_START'),
    );
    await tester.ensureVisible(find.text('복사').first);
    await tester.tap(find.text('복사').first);
    await tester.pumpAndSettle();
    expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, promptQaText);

    await tester.ensureVisible(find.text('원문 문맥 보기').first);
    await tester.tap(find.text('원문 문맥 보기').first);
    await tester.pumpAndSettle();
    await _capture(tester, 'ko-context');
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장 문구'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('새 문구'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('prompt-editor-title')),
      '기본 검토',
    );
    await tester.enterText(
      find.byKey(const ValueKey('prompt-editor-text')),
      promptQaOriginal,
    );
    await _capture(tester, 'ko-editor');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    for (
      var attempt = 0;
      attempt < 50 &&
          find
              .byKey(const ValueKey('prompt-editor-text'))
              .evaluate()
              .isNotEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('prompt-editor-text')), findsNothing);
    expect((await store.load()).single.text, promptQaOriginal);
    await _capture(tester, 'ko-saved');
    await show(LocaleDto.en, dark: true);
    await _capture(tester, 'en-stats-dark');
    await tester.ensureVisible(find.text('Saved snippets'));
    await tester.tap(find.text('Saved snippets'));
    await tester.pumpAndSettle();
    expect(find.text(promptQaOriginal, findRichText: true), findsOneWidget);
    await _capture(tester, 'en-saved-dark');
    await show(LocaleDto.en, large: true);
    await _capture(tester, 'en-stats-large');
    expect(tester.takeException(), isNull);
    await File('$_outputPath/receipt.txt').writeAsString(
      'Real macOS Profile binary; real Rust translations; clipboard matched; '
      'saved file reloaded exactly; HTTP fixture reads=$httpReads; '
      'personal settings and remote writes were not used.\n'
      'Temporary saved snippets: ${file.path}\n',
    );
  });
}
