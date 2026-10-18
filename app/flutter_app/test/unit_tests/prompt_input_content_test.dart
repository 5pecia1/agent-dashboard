import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_history.dart';
import 'package:my_dashboard/src/data/prompt_input_content.dart';

const String _taskNotification =
    '<task-notification>\n'
    '<task-id>worker-1</task-id>\n'
    '<tool-use-id>tool-1</tool-use-id>\n'
    '<output-file>/tmp/worker-1.output</output-file>\n'
    '<status>completed</status>\n'
    '<summary>검사를 실행해줘 자동 작업 요약</summary>\n'
    '</task-notification>';
const String _pasteOpen = '<pasted_content id="c0de">';
const String _pasteClose = '</pasted_content>';
const String _replyOpen = '<send_user_message_question_reply>';
const String _replyClose = '</send_user_message_question_reply>';
const List<String> _ambientHeads = <String>[
  'You are an expert at upholding safety and compliance standards for Codex ambient suggestions.\n\n'
      'I will present you with two categories of content:',
  '# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what '
      'this user can do with Codex in this Projectless task\n\n',
  '# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what '
      'this user can do with Codex in this local project: my-dashboard\n\n',
];

DashboardHistoryEvent _event(
  String? message, {
  String source = 'claude-code',
}) => DashboardHistoryEvent(
  id: 1,
  sessionKey: '$source:project/session',
  source: source,
  event: 'UserPromptSubmit',
  message: message,
  receivedAt: 1,
);

PromptInputContent _inspect(String? message, {String source = 'claude-code'}) =>
    inspectPromptInput(_event(message, source: source));

String _reply(List<Map<String, String>> answers) =>
    '$_replyOpen${jsonEncode(answers)}$_replyClose';

void main() {
  test('Codex의 확인된 자동 제안 시작 문구는 뒤 본문까지 통째로 제외한다', () {
    for (final head in _ambientHeads) {
      final raw = '$head\n\nthe user 자동 제안 본문';
      final event = _event(raw, source: 'codex');
      final content = inspectPromptInput(event);

      expect(content.text, isNull, reason: head);
      expect(content.automatic, isTrue, reason: head);
      expect(content.unreadable, isFalse);
      expect(content.mayBeClipped, isFalse);
      expect(event.message, raw);
      expect(_inspect(' \n\t$raw', source: 'codex').automatic, isTrue);
    }
  });

  test('다른 출처와 인용 코드 블록 및 문장 속 자동 제안 템플릿은 보존한다', () {
    for (final head in _ambientHeads) {
      for (final source in ['claude-code', 'devin', 'grok', 'unknown']) {
        final content = _inspect(head, source: source);
        expect(content.text, head, reason: source);
        expect(content.automatic, isFalse);
      }
      for (final raw in [
        '```text\n$head\n```',
        '> $head',
        '"$head"',
        '`$head`',
        'Review this prompt:\n$head',
        jsonEncode({'suggestions': head}),
      ]) {
        final content = _inspect(raw, source: 'codex');
        expect(content.text, raw, reason: raw);
        expect(content.automatic, isFalse);
        expect(content.unreadable, isFalse);
      }
    }
  });

  test('일반 영어 요청과 템플릿의 일부만 같은 문구는 자동 입력으로 보지 않는다', () {
    for (final raw in [
      'Explain how the user can update their settings.',
      'You are an expert reviewer. Review this code for the user.',
      'Generate 0 to 3 suggestions for the user.',
      '{"suggestions":[{"title":"Help the user review code"}]}',
      'You are an expert at upholding safety and compliance standards for Codex ambient suggestions.',
      '# Overview\n\nGenerate 0 to 3 personalized suggestions for this user.',
      _ambientHeads.first.replaceFirst('\n\n', ' '),
    ]) {
      final content = _inspect(raw, source: 'codex');
      expect(content.text, raw, reason: raw);
      expect(content.automatic, isFalse);
    }
  });

  test('사용자가 붙여넣거나 질문에 답한 자동 제안 문구는 다시 제외하지 않는다', () {
    for (final head in _ambientHeads) {
      final reply = _reply([
        {'answer': head, 'question': '질문', 'questionItemId': 'first'},
      ]);
      final answer = _inspect(reply, source: 'codex');
      expect(answer.text, head);
      expect(answer.automatic, isFalse);
      final paste = _inspect('$_pasteOpen$head$_pasteClose');
      expect(paste.text, head);
      expect(paste.automatic, isFalse);
    }
  });

  test('일반 입력은 공백 줄바꿈과 UTF16 문자열을 그대로 보존한다', () {
    for (final text in ['  검사를\t실행해줘\n', '<article>🙂 설명</article>', '']) {
      final content = _inspect(text);

      expect(content.text, text);
      expect(content.automatic, isFalse);
      expect(content.unreadable, isFalse);
      expect(content.mayBeClipped, isFalse);
    }
    expect(_inspect(null).text, isNull);
    expect(_inspect(null).unreadable, isFalse);
  });

  test('Claude의 확인된 작업 알림 구조와 명시적 시스템 알림을 제외한다', () {
    final longTask = _taskNotification.replaceFirst(
      '자동 작업 요약',
      '자동 작업 요약 ${'가' * promptPreviewCharacterLimit}',
    );
    for (final text in [
      _taskNotification,
      ' \n$_taskNotification\n ',
      longTask.substring(0, promptPreviewCharacterLimit),
      '<task-notification><task-id>worker-2</task-id>'
          '<summary>검사를 실행해줘</summary></task-notification>',
      '[SYSTEM NOTIFICATION - NOT USER INPUT] 백그라운드 작업 완료',
    ]) {
      final content = _inspect(text);

      expect(content.text, isNull, reason: text);
      expect(content.automatic, isTrue, reason: text);
      expect(content.unreadable, isFalse);
      expect(content.mayBeClipped, isFalse);
    }
  });

  test('Claude 자동 알림 규칙은 다른 출처의 같은 문자열에 적용하지 않는다', () {
    for (final source in ['codex', 'devin', 'grok', 'unknown']) {
      for (final text in [
        _taskNotification,
        '[SYSTEM NOTIFICATION - NOT USER INPUT] 사용자 예시',
      ]) {
        expect(_inspect(text, source: source).text, text, reason: source);
        expect(_inspect(text, source: source).automatic, isFalse);
      }
    }
  });

  test('태그 언급과 임의 XML 및 인용한 작업 알림은 사용자 입력으로 보존한다', () {
    for (final text in [
      '<task-notification> 설명해줘',
      '<task-notification><summary>직접 만든 XML</summary></task-notification>',
      '<task-notification><task-id>example</task-id> 설명해줘',
      '<task-notification><task-id>example</task-id>'
          '<custom>내 데이터</custom></task-notification>',
      '이 알림을 설명해줘\n$_taskNotification',
      '```xml\n$_taskNotification\n```',
      '> $_taskNotification',
      '"$_taskNotification"',
      '`$_taskNotification`',
    ]) {
      final content = _inspect(text);

      expect(content.text, text, reason: text);
      expect(content.automatic, isFalse, reason: text);
    }
  });

  test('닫힌 작업 알림 뒤에 사용자 설명이 있으면 전체 원문을 보존한다', () {
    const text = '$_taskNotification\n이 결과를 설명해줘';
    final content = _inspect(text);

    expect(content.text, text);
    expect(content.automatic, isFalse);
    expect(_inspect('$_taskNotification\n  ').automatic, isTrue);
  });

  test('확인된 붙여넣기 감싸기만 제거하고 본문과 뒤의 사용자 문장은 보존한다', () {
    const body = '\n  검사를\t실행해줘\n\n';
    const tail = '\n위 내용을 정리해줘  ';
    const raw = ' \n$_pasteOpen$body$_pasteClose$tail';
    final event = _event(raw);
    final content = inspectPromptInput(event);

    expect(content.text, '$body$tail');
    expect(content.automatic, isFalse);
    expect(content.unreadable, isFalse);
    expect(event.message, raw);
    expect(_inspect('$_pasteOpen$body$_pasteClose').text, body);
    expect(_inspect('$_pasteOpen$body$_pasteClose').text, body);
  });

  test('사용자가 붙여넣은 작업 알림 예시는 다시 자동 입력으로 분류하지 않는다', () {
    for (final body in [
      _taskNotification,
      '[SYSTEM NOTIFICATION - NOT USER INPUT] 내가 붙인 예시',
    ]) {
      final content = _inspect('$_pasteOpen$body$_pasteClose');

      expect(content.text, body);
      expect(content.automatic, isFalse);
    }
  });

  test('붙여넣기 안에 같은 닫는 태그 예시가 있어도 바깥 포장만 제거한다', () {
    const body = '문자열 $_pasteClose 예시를 설명해줘';
    const tail = '\n내가 쓴 조건';

    expect(_inspect('$_pasteOpen$body$_pasteClose').text, body);
    expect(_inspect('$_pasteOpen$body$_pasteClose$tail').text, '$body$tail');
  });

  test('붙여넣기 태그라도 출처와 확인된 ID 구조가 다르면 원문으로 남긴다', () {
    for (final text in [
      '<pasted_content>태그 예시</pasted_content>',
      '<pasted_content id="example">태그 예시</pasted_content>',
      '<pasted_content id="c0de" custom="yes">태그 예시</pasted_content>',
      '```xml\n$_pasteOpen태그 예시$_pasteClose\n```',
    ]) {
      expect(_inspect(text).text, text);
    }
    const text = '$_pasteOpen직접 작성한 XML$_pasteClose';
    for (final source in ['codex', 'devin', 'grok']) {
      expect(_inspect(text, source: source).text, text);
    }
  });

  test('붙여넣기 본문이 저장 끝에 닿을 때만 UTF16 한도 경고를 남긴다', () {
    const emoji = '🙂';
    final emojiBody =
        emoji *
        ((promptPreviewCharacterLimit - _pasteOpen.length) ~/ emoji.length);
    final raw = '$_pasteOpen$emojiBody';
    final padding = '가' * (promptPreviewCharacterLimit - raw.length);
    final content = _inspect('$raw$padding');

    expect('$raw$padding'.length, promptPreviewCharacterLimit);
    expect(content.text, '$emojiBody$padding');
    expect(content.mayBeClipped, isTrue);
    expect(_inspect('$_pasteOpen${'가' * 10}').mayBeClipped, isFalse);
  });

  test('닫힌 붙여넣기 본문은 감싸기가 한도에 닿아도 잘림으로 표시하지 않는다', () {
    final body =
        '가' *
        (promptPreviewCharacterLimit - _pasteOpen.length - _pasteClose.length);
    final raw = '$_pasteOpen$body$_pasteClose';
    final content = _inspect(raw);

    expect(raw.length, promptPreviewCharacterLimit);
    expect(content.text, body);
    expect(content.mayBeClipped, isFalse);
    expect(_inspect('$raw   ').mayBeClipped, isFalse);
    final withTail = _inspect('$raw\n직접 쓴 조건');
    expect(withTail.text, '$body\n직접 쓴 조건');
    expect(withTail.mayBeClipped, isTrue);
  });

  test('한도에서 잘린 붙여넣기 닫는 태그 조각은 복사 본문에 섞지 않는다', () {
    const fragment = '</pasted_con';
    final body =
        '가' *
        (promptPreviewCharacterLimit - _pasteOpen.length - fragment.length);
    final raw = '$_pasteOpen$body$fragment';
    final content = _inspect(raw);

    expect(raw.length, promptPreviewCharacterLimit);
    expect(content.text, body);
    expect(content.mayBeClipped, isTrue);
    expect(_inspect('$_pasteOpen태그 예시 $fragment').text, '태그 예시 $fragment');
    const literal = '값이 <';
    final literalBody =
        '가' *
        (promptPreviewCharacterLimit - _pasteOpen.length - literal.length);
    expect(
      _inspect('$_pasteOpen$literalBody$literal').text,
      '$literalBody$literal',
    );
  });

  test('바깥 붙여넣기 닫는 태그가 잘려도 본문 속 닫는 태그 예시는 보존한다', () {
    const inner = '$_pasteClose 태그 예시\n';
    const fragment = '</pasted_con';
    final padding =
        '가' *
        (promptPreviewCharacterLimit -
            _pasteOpen.length -
            inner.length -
            fragment.length);
    final body = '$inner$padding';
    final raw = '$_pasteOpen$body$fragment';
    final content = _inspect(raw);

    expect(raw.length, promptPreviewCharacterLimit);
    expect(content.text, body);
    expect(content.mayBeClipped, isTrue);
  });

  test('Codex 질문 답변 배열에서는 검증된 답변 문자열만 정확히 복원한다', () {
    const raw =
        '<send_user_message_question_reply>'
        r'[{"answer":"  A\nB\t\"인용\" ","question":"기계 질문",'
        '"questionItemId":"item-1"}]'
        '</send_user_message_question_reply>';
    final content = _inspect(raw, source: 'codex');

    expect(content.text, '  A\nB\t"인용" ');
    expect(content.automatic, isFalse);
    expect(content.unreadable, isFalse);
    expect(content.mayBeClipped, isFalse);
  });

  test('Codex의 여러 답변은 배열 순서와 원래 공백을 유지하며 한 줄로 연결한다', () {
    final raw = _reply([
      {'question': '선택 질문', 'answer': ' 첫 답변 ', 'questionItemId': 'first'},
      {'answer': '\n둘째 답변\n', 'questionItemId': 'second', 'question': '다음 질문'},
    ]);
    final content = _inspect(raw, source: 'codex');

    expect(content.text, ' 첫 답변 \n\n둘째 답변\n');
    expect(content.unreadable, isFalse);
  });

  test('Codex 답변 문자열 안의 닫는 태그는 포장 경계로 해석하지 않는다', () {
    const answer = '"$_replyClose" 태그를 고쳐줘';
    final raw = _reply([
      {'answer': answer, 'question': '기계 질문', 'questionItemId': 'first'},
    ]);

    expect(_inspect(raw, source: 'codex').text, answer);
    final withoutOuterClose = raw.substring(0, raw.length - _replyClose.length);
    expect(_inspect(withoutOuterClose, source: 'codex').text, answer);
    expect(
      _inspect('$raw\n사용자 조건 $_replyClose', source: 'codex').text,
      '$raw\n사용자 조건 $_replyClose',
    );
    final question = '가' * promptPreviewCharacterLimit;
    final atLimit = _reply([
      {'answer': answer, 'question': question, 'questionItemId': 'first'},
    ]);
    final fullArrayWithLiteral = atLimit.substring(
      0,
      atLimit.length - _replyClose.length,
    );
    expect(_inspect(fullArrayWithLiteral, source: 'codex').text, answer);
    expect(
      _inspect(fullArrayWithLiteral, source: 'codex').mayBeClipped,
      isFalse,
    );
    const fragment = '</send_user_';
    final emptyQuestion = _reply([
      {'answer': answer, 'question': '', 'questionItemId': 'first'},
    ]);
    final arrayLength = emptyQuestion.length - _replyClose.length;
    final exactQuestion =
        '가' * (promptPreviewCharacterLimit - arrayLength - fragment.length);
    final clippedOuterClose = _reply([
      {'answer': answer, 'question': exactQuestion, 'questionItemId': 'first'},
    ]).substring(0, promptPreviewCharacterLimit);
    expect(clippedOuterClose, endsWith(fragment));
    expect(_inspect(clippedOuterClose, source: 'codex').text, answer);
    expect(_inspect(clippedOuterClose, source: 'codex').mayBeClipped, isFalse);
  });

  test('완전한 답변 배열은 감싸기의 닫는 태그만 잘려도 답변 잘림으로 세지 않는다', () {
    const answer = '검사를 실행해줘';
    final question =
        '가' *
        (promptPreviewCharacterLimit -
            _replyOpen.length -
            jsonEncode([
              {'answer': answer, 'question': '', 'questionItemId': 'first'},
            ]).length);
    final array = jsonEncode([
      {'answer': answer, 'question': question, 'questionItemId': 'first'},
    ]);
    final raw = '$_replyOpen$array';
    final content = _inspect(raw, source: 'codex');

    expect(raw.length, promptPreviewCharacterLimit);
    expect(content.text, answer);
    expect(content.mayBeClipped, isFalse);
    expect(_inspect('$raw</send', source: 'codex').text, answer);
    expect(_inspect('$raw</send', source: 'codex').mayBeClipped, isFalse);
  });

  test('완전한 첫 답변 뒤에서 잘린 다중 질문 배열은 일부 답변을 추정하지 않는다', () {
    final full = _reply([
      {'answer': '첫 답변은 완전함', 'question': '질문 1', 'questionItemId': 'first'},
      {
        'answer': '가' * promptPreviewCharacterLimit,
        'question': '질문 2',
        'questionItemId': 'second',
      },
    ]);
    final raw = full.substring(0, promptPreviewCharacterLimit);
    final content = _inspect(raw, source: 'codex');

    expect(raw, contains('첫 답변은 완전함'));
    expect(raw, contains('"answer":"가'));
    expect(raw, isNot(contains('"questionItemId":"second"')));
    expect(content.text, isNull);
    expect(content.unreadable, isTrue);
    expect(content.automatic, isFalse);
    expect(content.mayBeClipped, isFalse);
  });

  test('잘린 질문 안의 answer 유사 문자열은 사용자 답변으로 복원하지 않는다', () {
    final full = _reply([
      {
        'answer': '가' * promptPreviewCharacterLimit,
        'question': '{"answer":"기계 질문 안의 가짜 답변"}',
        'questionItemId': 'first',
      },
    ]);
    final content = _inspect(
      full.substring(0, promptPreviewCharacterLimit),
      source: 'codex',
    );

    expect(content.text, isNull);
    expect(content.unreadable, isTrue);
  });

  test('질문이나 ID가 첫 필드인 알려진 답변 배열도 잘리면 미해독으로 분리한다', () {
    for (final firstKey in ['question', 'questionItemId']) {
      final full = _reply([
        {
          firstKey:
              '${r'{"answer":"기계 질문 안의 가짜 답변"}'}${'가' * promptPreviewCharacterLimit}',
          'answer': '실제 답변',
          if (firstKey == 'question')
            'questionItemId': 'first'
          else
            'question': '질문',
        },
      ]);
      final raw = full.substring(0, promptPreviewCharacterLimit);
      final content = _inspect(raw, source: 'codex');

      expect(raw, startsWith('$_replyOpen[{"$firstKey":'));
      expect(content.text, isNull, reason: firstKey);
      expect(content.unreadable, isTrue, reason: firstKey);
      expect(content.automatic, isFalse);
      expect(content.mayBeClipped, isFalse);
    }
  });

  test('알려진 답변 배열이 잘못된 형식이면 미해독으로 알리고 일반 XML은 보존한다', () {
    for (final payload in ['[{"answer":"미완성', '[{"answer":"답변"}, invalid]']) {
      final content = _inspect(
        '$_replyOpen$payload$_replyClose',
        source: 'codex',
      );

      expect(content.text, isNull, reason: payload);
      expect(content.unreadable, isTrue, reason: payload);
      expect(content.automatic, isFalse);
    }
    for (final payload in [
      '설명해줘',
      '[]',
      '{"answer":"직접 쓴 예시"}',
      '[{"custom":"내 데이터"}]',
      '[{"answer":"답변","question":"질문"}]',
      '[{"answer":false,"question":"질문","questionItemId":"first"}]',
      '[{"answer":"답변","question":[],"questionItemId":"first"}]',
      '[{"answer":"답변","question":"질문","questionItemId":"first","extra":1}]',
      '[{"answer":"x","other":"literalXML"}]',
      '[{"question":"직접 쓴 예시","custom":"내 데이터"}]',
      '[{"questionItemId":"직접 쓴 예시","custom":"내 데이터"}]',
    ]) {
      final raw = '$_replyOpen$payload$_replyClose';
      expect(_inspect(raw, source: 'codex').text, raw);
      expect(_inspect(raw, source: 'codex').unreadable, isFalse);
    }
  });

  test('Codex 감싸기라도 다른 출처나 인용과 사용자 꼬리는 원문으로 보존한다', () {
    final raw = _reply([
      {'answer': '검사를 실행해줘', 'question': '질문', 'questionItemId': 'first'},
    ]);
    for (final source in ['claude-code', 'devin', 'grok']) {
      expect(_inspect(raw, source: source).text, raw);
    }
    for (final quoted in ['```xml\n$raw\n```', '> $raw', '$raw\n내가 쓴 설명']) {
      expect(_inspect(quoted, source: 'codex').text, quoted);
      expect(_inspect(quoted, source: 'codex').unreadable, isFalse);
    }
  });
}
