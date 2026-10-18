import 'dart:convert';

import 'package:my_dashboard/src/data/dashboard_api.dart';

const promptQaText = '기존 동작을 보존하고 테스트를 실행해줘';
const promptQaOriginal = '  기존 동작을 보존하고 테스트를 실행해줘\n결과를 한국어로 설명해줘  ';
const promptQaCodexAnswer = '$promptQaText\nUI 와 PR 을 확인해줘';
const promptQaMachineText = '도구 알림의 고유한 반복 본문';
const promptQaAmbientMachineText = '자동 추천 정책의 고유한 본문';
const promptQaAmbientAutomatic =
    'You are an expert at upholding safety and compliance standards for Codex ambient suggestions.\n\n'
    'I will present you with two categories of content:\n$promptQaAmbientMachineText';
const promptQaAutomatic =
    '<task-notification>\n<task-id>qa</task-id>\n'
    '<status>completed</status>\n<summary>$promptQaMachineText</summary>\n'
    '</task-notification>';

ApiResponse promptQaResponse(ApiRequest request, {bool older = false}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  Map<String, Object?> event(int id, String source, String? text) => {
    'id': id,
    'session_key': '$source:qa-${id % 2}',
    'source': source,
    'event': 'UserPromptSubmit',
    'message': text,
    'display_title': 'Prompt QA',
    'received_at': now - (10 - id) * 1000,
  };
  return ApiResponse(
    statusCode: 200,
    body: jsonEncode({
      'events': [
        event(10, 'codex', promptQaAmbientAutomatic),
        event(9, 'claude-code', promptQaAutomatic),
        event(
          8,
          'claude-code',
          '<pasted_content id="a9f8">$promptQaOriginal</pasted_content>',
        ),
        event(7, 'devin', '$promptQaText\n변경 내용을 먼저 알려줘'),
        event(
          6,
          'codex',
          '<send_user_message_question_reply>${jsonEncode([
            {'answer': promptQaCodexAnswer, 'question': '에이전트 질문의 고유 문구', 'questionItemId': 'qa'},
          ])}</send_user_message_question_reply>',
        ),
        event(5, 'antigravity', null),
        event(4, 'grok', null),
        event(3, 'claude-code', List.filled(300, '가').join()),
      ],
      'has_more': false,
      'next_before_id': null,
    }),
  );
}
