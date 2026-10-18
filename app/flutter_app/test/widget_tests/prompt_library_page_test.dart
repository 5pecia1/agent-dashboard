import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/prompt_analytics.dart';
import 'package:my_dashboard/src/data/saved_prompt.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/saved_prompts_provider.dart';
import 'package:my_dashboard/src/state/prompt_history_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/prompt_library_page.dart';

import '../fixtures/prompt_library_fixture.dart';

void main() {
  late List<SavedPrompt> stored;
  late List<String> copied;
  late bool saveConflict;
  late int loads;
  const platform = SystemChannels.platform;
  setUp(() {
    stored = [];
    copied = [];
    saveConflict = false;
    loads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platform, null);
  });

  Future<void> pump(
    WidgetTester tester, {
    bool failure = false,
    ApiResponse Function(ApiRequest)? response,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardApiConfigProvider.overrideWithValue(
            DashboardApiConfig(
              baseUrl: Uri.parse('https://example.test'),
              clientToken: 'fixture',
            ),
          ),
          httpSendProvider.overrideWithValue((request) async {
            if (failure) throw const FormatException('fixture failed');
            return response?.call(request) ?? promptQaResponse(request);
          }),
          savedPromptsLoadFnProvider.overrideWithValue(() async {
            loads++;
            return stored;
          }),
          savedPromptsSaveFnProvider.overrideWithValue((value) async {
            if (saveConflict) throw SavedPromptsConflictException();
            stored = value;
          }),
          i18nTranslateOverride.overrideWithValue((key, _) => key),
          i18nTranslateArgsOverride.overrideWithValue(
            (key, _, keys, values) => '$key ${Map.fromIterables(keys, values)}',
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const PromptLibraryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('반복 문구를 발견하고 원문을 바꾸지 않고 복사한다', (tester) async {
    await pump(tester);
    expect(find.text(promptQaText, findRichText: true), findsOneWidget);
    expect(find.textContaining('submissions: 3'), findsOneWidget);
    expect(find.textContaining('prompt.missing'), findsOneWidget);
    expect(find.textContaining('prompt.truncation'), findsOneWidget);
    expect(
      find.textContaining('prompt.automatic_excluded {count: 2}'),
      findsOneWidget,
    );
    expect(
      find.textContaining(promptQaMachineText, findRichText: true),
      findsNothing,
    );
    await tester.ensureVisible(find.text('prompt.copy').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('prompt.copy').first);
    await tester.pumpAndSettle();
    expect(copied.single, promptQaText);
    expect(
      find.textContaining(promptQaAmbientMachineText, findRichText: true),
      findsNothing,
    );
  });

  testWidgets('문맥에서 저장한 입력은 공백과 줄바꿈이 유지된다', (tester) async {
    await pump(tester);
    await tester.ensureVisible(find.text('prompt.context').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('prompt.context').first);
    await tester.pumpAndSettle();
    expect(find.text(promptQaOriginal, findRichText: true), findsOneWidget);
    await tester.ensureVisible(find.text('prompt.copy_input').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('prompt.copy_input').first);
    await tester.pumpAndSettle();
    expect(copied.single, promptQaOriginal);
    expect(copied.single, isNot(contains('<pasted_content')));
    await tester.ensureVisible(find.text('prompt.copy_input').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('prompt.copy_input').last);
    await tester.pumpAndSettle();
    expect(copied.last, promptQaCodexAnswer);
    expect(copied.last, isNot(contains('questionItemId')));
  });

  testWidgets('새 문구를 저장하고 수정한 뒤 저장 사본만 삭제한다', (tester) async {
    await pump(tester);
    await tester.tap(find.text('prompt.tab.saved'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('prompt.new'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('prompt-editor-title')),
      '검토 규칙',
    );
    await tester.enterText(
      find.byKey(const ValueKey('prompt-editor-text')),
      '  원문을 유지해줘\n테스트해줘  ',
    );
    await tester.tap(find.text('action.save'));
    await tester.pumpAndSettle();
    expect(stored.single.text, '  원문을 유지해줘\n테스트해줘  ');
    await tester.tap(find.text('prompt.edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('prompt-editor-text')),
      '수정한 문구',
    );
    await tester.tap(find.text('action.save'));
    await tester.pumpAndSettle();
    expect(stored.single.text, '수정한 문구');
    await tester.tap(find.text('prompt.delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('prompt.delete').last);
    await tester.pumpAndSettle();
    expect(stored, isEmpty);
    await tester.tap(find.text('prompt.tab.stats'));
    await tester.pumpAndSettle();
    expect(find.text(promptQaText, findRichText: true), findsOneWidget);
  });

  testWidgets('이력 최초 조회 실패를 이전 조회로 오표시하지 않고 문구함은 사용한다', (tester) async {
    await pump(tester, failure: true);
    expect(find.text('prompt.load_failed'), findsOneWidget);
    expect(find.text('prompt.stale'), findsNothing);
    await tester.tap(find.text('prompt.tab.saved'));
    await tester.pumpAndSettle();
    expect(find.text('prompt.new'), findsOneWidget);
  });

  testWidgets('좁은 화면과 큰 글자에서도 필터와 문구 액션이 넘치지 않는다', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pump(tester);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('prompt.tab.saved'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('prompt.tab.saved'));
    await tester.pumpAndSettle();
    expect(find.text('prompt.new'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('검색을 해도 표본 빈도는 유지되고 탭 왕복 뒤 검색어가 보인다', (tester) async {
    await pump(tester);
    await tester.tap(find.text('prompt.terms'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('prompt-search')), 'PR');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('PR', findRichText: true), findsWidgets);
    expect(find.text(promptQaText, findRichText: true), findsNothing);
    expect(find.textContaining('prompts: 4'), findsOneWidget);
    expect(find.text('prompt.search_scope'), findsOneWidget);
    await tester.tap(find.text('prompt.tab.saved'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('prompt.tab.stats'));
    await tester.pumpAndSettle();
    final search = tester.widget<TextField>(
      find.byKey(const ValueKey('prompt-search')),
    );
    expect(search.controller!.text, 'PR');
    expect(find.textContaining('prompts: 4'), findsOneWidget);
  });

  testWidgets('저장 탭 새로고침은 서버 이력이 아니라 로컬 목록을 다시 읽는다', (tester) async {
    await pump(tester);
    await tester.tap(find.text('prompt.tab.saved'));
    await tester.pumpAndSettle();
    final before = loads;
    stored = [
      SavedPrompt(
        id: 'other',
        title: '다른 창',
        text: '외부에서 저장한 문구',
        createdAt: 1,
        updatedAt: 1,
      ),
    ];
    await tester.tap(find.byTooltip('prompt.refresh'));
    await tester.pumpAndSettle();
    expect(loads, greaterThan(before));
    expect(find.text('외부에서 저장한 문구', findRichText: true), findsOneWidget);
  });

  testWidgets('편집 충돌 후 옛 항목을 재저장하지 않고 작성 내용을 구출한다', (tester) async {
    stored = [
      SavedPrompt(
        id: 'same',
        title: '원래',
        text: '옛 본문',
        createdAt: 1,
        updatedAt: 1,
      ),
    ];
    await pump(tester);
    await tester.tap(find.text('prompt.tab.saved'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('prompt.edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('prompt-editor-text')),
      '내 작성 내용',
    );
    stored = [stored.single.copyWith(text: '다른 창의 최신 본문', updatedAt: 2)];
    saveConflict = true;
    await tester.tap(find.text('action.save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('prompt.edit_conflict'), findsOneWidget);
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'action.save'),
    );
    expect(save.onPressed, isNull);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('prompt.copy'),
      ),
    );
    await tester.pumpAndSettle();
    expect(copied.single, '내 작성 내용');
    expect(stored.single.text, '다른 창의 최신 본문');
    await tester.tap(find.text('action.cancel'));
    await tester.pumpAndSettle();
    expect(find.text('다른 창의 최신 본문', findRichText: true), findsOneWidget);
  });

  testWidgets('320픽셀 큰 글자에서 문맥과 편집 대화상자는 부모 폭 안에 놓인다', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pump(tester);
    await tester.scrollUntilVisible(
      find.text('prompt.context'),
      200,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('prompt.context').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(AlertDialog)).width,
      lessThanOrEqualTo(320),
    );
    await tester.tap(find.text('prompt.close'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('prompt.save').first);
    await tester.tap(find.text('prompt.save').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(AlertDialog)).width,
      lessThanOrEqualTo(320),
    );
  });

  testWidgets('보관된 이력이 있어도 화면을 다시 열면 최신 이력을 조회한다', (tester) async {
    var reads = 0;
    final container = ProviderContainer(
      overrides: [
        dashboardApiConfigProvider.overrideWithValue(
          DashboardApiConfig(
            baseUrl: Uri.parse('https://fixture.test'),
            clientToken: 'fixture',
          ),
        ),
        httpSendProvider.overrideWithValue((request) async {
          reads++;
          final response = promptQaResponse(request);
          if (reads == 1) return response;
          final payload = jsonDecode(response.body) as Map<String, dynamic>;
          for (final value in payload['events'] as List<dynamic>) {
            final event = value as Map<String, dynamic>;
            final message = event['message'] as String?;
            if (message != null &&
                message.length < promptPreviewCharacterLimit) {
              event['message'] = '새로 받은 반복 문구';
            }
          }
          return ApiResponse(statusCode: 200, body: jsonEncode(payload));
        }),
        savedPromptsLoadFnProvider.overrideWithValue(() async => stored),
        savedPromptsSaveFnProvider.overrideWithValue(
          (items) async => stored = items,
        ),
        i18nTranslateOverride.overrideWithValue((key, _) => key),
        i18nTranslateArgsOverride.overrideWithValue(
          (key, _, keys, values) => '$key ${Map.fromIterables(keys, values)}',
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(promptHistoryProvider.notifier).refresh();
    final before = reads;
    expect(
      container.read(promptHistoryProvider).requireValue.lastRefreshedAt,
      isNotNull,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const PromptLibraryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(reads, greaterThan(before));
    expect(find.textContaining('prompt.checked'), findsOneWidget);
    expect(find.text('새로 받은 반복 문구', findRichText: true), findsOneWidget);
    expect(find.text(promptQaText, findRichText: true), findsNothing);
  });
  testWidgets('도구 알림 본문으로 검색해도 후보가 없고 제외 수와 사용자 표본은 유지된다', (tester) async {
    await pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('prompt-search')),
      promptQaMachineText,
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('prompt.automatic_excluded {count: 2}'),
      findsOneWidget,
    );
    expect(find.textContaining('prompts: 4'), findsOneWidget);
    expect(find.text('prompt.empty_phrases'), findsOneWidget);
    expect(find.text('<task-notification>', findRichText: true), findsNothing);
  });
  testWidgets('완전히 해석할 수 없는 답변은 제외 수로 안내하고 질문을 결과에 넣지 않는다', (tester) async {
    await pump(
      tester,
      response: (request) {
        final fixture = promptQaResponse(request);
        final payload = jsonDecode(fixture.body) as Map<String, dynamic>;
        final events = payload['events'] as List<dynamic>;
        final partial =
            Map<String, dynamic>.from(events.first as Map<String, dynamic>)
              ..['id'] = 11
              ..['source'] = 'codex'
              ..['session_key'] = 'codex:unreadable-qa'
              ..['message'] =
                  '<send_user_message_question_reply>[{"question":"해석하지 못한 질문 본문';
        events.insert(0, partial);
        return ApiResponse(statusCode: 200, body: jsonEncode(payload));
      },
    );
    expect(
      find.textContaining('prompt.unreadable_excluded {count: 1}'),
      findsOneWidget,
    );
    expect(find.textContaining('prompts: 4'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('prompt-search')),
      '해석하지 못한 질문 본문',
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('prompt.unreadable_excluded {count: 1}'),
      findsOneWidget,
    );
    expect(find.text('prompt.empty_phrases'), findsOneWidget);
  });
}
