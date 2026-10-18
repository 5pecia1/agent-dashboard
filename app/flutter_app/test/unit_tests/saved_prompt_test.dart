import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/saved_prompt.dart';

SavedPrompt _prompt({
  String id = 'saved-1',
  String text = '  한글 원문\r\n\t끝  ',
}) => SavedPrompt(
  id: id,
  title: '  제목  ',
  text: text,
  createdAt: 100,
  updatedAt: 101,
  source: 'claude',
  sessionKey: 'session-1',
);

void main() {
  test('제목만 다듬고 원문 공백과 줄바꿈은 JSON 왕복 후에도 그대로 유지한다', () {
    final prompt = _prompt();
    expect(prompt.title, '제목');
    expect(SavedPrompt.fromJson(prompt.toJson()), prompt);
    expect(decodeSavedPrompts(encodeSavedPrompts([prompt])), [prompt]);
    expect(prompt.toJson().keys, isNot(contains('serverToken')));
    expect(
      () => decodeSavedPrompts(encodeSavedPrompts([prompt])).add(prompt),
      throwsUnsupportedError,
    );
  });

  test('제목과 본문을 수정해도 식별자와 원문 출처는 그대로 유지한다', () {
    final previous = _prompt();
    final next = previous.copyWith(title: '', text: '수정한 원문', updatedAt: 102);
    expect(next.id, previous.id);
    expect(next.createdAt, previous.createdAt);
    expect(next.source, previous.source);
    expect(next.sessionKey, previous.sessionKey);
    expect(next.title, isEmpty);
    expect(previous.text, '  한글 원문\r\n\t끝  ');
  });

  test('빈 식별자나 본문과 잘못된 필드 타입은 거부한다', () {
    final valid = _prompt().toJson();
    for (final entry in <Map<String, Object?>>[
      {...valid, 'id': '  '},
      {...valid, 'text': '\t\n'},
      {...valid, 'title': null},
      {...valid, 'createdAt': 100.0},
      {...valid, 'updatedAt': '101'},
      {...valid, 'updatedAt': 99},
      {...valid, 'createdAt': -1},
      {...valid, 'source': 1},
      {...valid, 'sessionKey': false},
    ]) {
      expect(() => SavedPrompt.fromJson(entry), throwsFormatException);
    }
  });

  test('최대 길이의 본문은 보존하고 초과 입력은 잘라 저장하지 않는다', () {
    final maximum = '가' * savedPromptMaxTextLength;
    expect(_prompt(text: maximum).text, maximum);
    expect(
      () => _prompt(text: '가' * (savedPromptMaxTextLength + 1)),
      throwsFormatException,
    );
    expect(
      () => _prompt().copyWith(title: '가' * (savedPromptMaxTitleLength + 1)),
      throwsFormatException,
    );
  });

  test('손상된 JSON과 잘못된 버전과 중복 식별자는 거부한다', () {
    final prompt = _prompt();
    for (final text in [
      '{broken',
      '[]',
      '{"version":1.0,"prompts":[]}',
      '{"version":2,"prompts":[]}',
      '{"version":1,"prompts":{}}',
      '{"version":1,"prompts":[null]}',
      jsonEncode({
        'version': 1,
        'prompts': [prompt.toJson(), prompt.toJson()],
      }),
    ]) {
      expect(() => decodeSavedPrompts(text), throwsFormatException);
    }
    expect(() => encodeSavedPrompts([prompt, prompt]), throwsFormatException);
  });

  test('문구함 최대 개수를 초과하면 저장과 읽기를 모두 거부한다', () {
    final prompts = List.generate(
      savedPromptMaxItems + 1,
      (index) => _prompt(id: '$index'),
    );
    expect(() => encodeSavedPrompts(prompts), throwsFormatException);
    expect(
      () => decodeSavedPrompts(
        jsonEncode({
          'version': 1,
          'prompts': [for (final prompt in prompts) prompt.toJson()],
        }),
      ),
      throwsFormatException,
    );
  });
}
