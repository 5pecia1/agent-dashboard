import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_history.dart';
import 'package:my_dashboard/src/data/prompt_analytics.dart';

DashboardHistoryEvent _prompt(
  int id,
  String? message, {
  String source = 'claude-code',
  String session = 'claude-code:project/session',
  String event = 'UserPromptSubmit',
  int? at,
}) => DashboardHistoryEvent(
  id: id,
  sessionKey: session,
  source: source,
  event: event,
  message: message,
  receivedAt: at ?? id,
);

void main() {
  test('Codex 자동 제안 템플릿의 본문은 모든 분석 보기와 검색 및 표본에서 제외한다', () {
    const heads = <String>[
      'You are an expert at upholding safety and compliance standards for Codex ambient suggestions.\n\n'
          'I will present you with two categories of content:',
      '# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this Projectless task\n\n',
      '# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project: my-dashboard\n\n',
    ];
    const human = 'Review the deployment.';
    final automatic = <DashboardHistoryEvent>[
      for (var index = 0; index < heads.length; index++)
        _prompt(
          index + 3,
          '${heads[index]}\n\nthe user bot-only-needle ${'filler ' * 60}'
              .substring(0, promptPreviewCharacterLimit),
          source: 'codex',
          at: 150,
        ),
    ];
    final events = <DashboardHistoryEvent>[
      _prompt(1, human, source: 'codex', at: 120),
      _prompt(2, human, source: 'codex', at: 150),
      ...automatic,
      automatic.first,
    ];
    final analysis = analyzePrompts(
      events,
      source: 'codex',
      since: 100,
      until: 200,
    );

    expect(analysis.prompts.map((event) => event.id), [2, 1]);
    expect(analysis.observedEventsCount, 5);
    expect(analysis.automaticMessageCount, 3);
    expect(analysis.unreadableInputCount, 0);
    expect(analysis.missingContentCount, 0);
    expect(analysis.possibleTruncationCount, 0);
    expect(analysis.fullPrompts.single.text, human);
    expect(analysis.fullPrompts.single.submissionCount, 2);
    expect(analysis.phrases.single.submissionCount, 2);
    for (final query in [
      'the user',
      'bot-only-needle',
      'ambient',
      'hyperpersonalized',
    ]) {
      final searched = analyzePrompts(
        events,
        source: 'codex',
        since: 100,
        until: 200,
        query: query,
      );
      expect(searched.terms, isEmpty, reason: query);
      expect(searched.phrases, isEmpty, reason: query);
      expect(searched.fullPrompts, isEmpty, reason: query);
      expect(searched.prompts, analysis.prompts);
      expect(searched.automaticMessageCount, 3);
      expect(searched.possibleTruncationCount, 0);
    }
    expect(
      automatic.every((event) => event.message!.contains('bot-only-needle')),
      isTrue,
    );
    expect(analyzePrompts(events, since: 151).automaticMessageCount, 0);
    expect(
      analyzePrompts(events, source: 'claude-code').automaticMessageCount,
      0,
    );
  });

  test('Claude 작업 알림의 자동 본문은 사용자 반복 표현으로 세지 않는다', () {
    const phrase = '검사를 실행해줘';
    const notification =
        '<task-notification>\n'
        '<task-id>worker-1</task-id>\n'
        '<tool-use-id>tool-1</tool-use-id>\n'
        '<status>completed</status>\n'
        '<summary>$phrase 자동 작업 요약</summary>\n'
        '</task-notification>';
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, phrase),
      _prompt(2, notification),
      _prompt(3, notification),
    ]);

    expect(analysis.prompts.map((event) => event.id), [1]);
    expect(analysis.automaticMessageCount, 2);
    expect(analysis.unreadableInputCount, 0);
    expect(analysis.observedEventsCount, 3);
    expect(analysis.phrases, isEmpty);
    expect(analysis.fullPrompts.single.text, phrase);
    expect(
      analysis.terms.any((pattern) => pattern.text.contains('summary')),
      isFalse,
    );
  });

  test('CLI 뒤 한글과 영문 혼합 요청어미는 동사 목록 없이 마침표 변형을 묶는다', () {
    for (final body in [
      'flutter test 실행해줘',
      'git diff 커밋해줘',
      'flutter test 알려줘',
      'git diff 알려주세요',
      'git diff commit해줘',
      'flutter test PR확인해주세요',
    ]) {
      final analysis = analyzePrompts(<DashboardHistoryEvent>[
        _prompt(1, '$body.'),
        _prompt(2, body),
      ]);

      expect(analysis.phrases.single.normalizedKey, body, reason: body);
      expect(analysis.phrases.single.submissionCount, 2, reason: body);
      expect(analysis.phrases.single.variants, containsAll(['$body.', body]));
    }
  });

  test('요청어미가 있어도 실제 출력 명령과 quoted option path 인자는 보존한다', () {
    const originals = <String>[
      'echo 실행해줘.',
      'echo 실행해줘',
      'printf 알려주세요.',
      'printf 알려주세요',
      'flutter test "실행해줘."',
      "flutter test '커밋해줘.'",
      'flutter test `알려줘.`',
      'flutter test --실행해줘.',
      'flutter test --target=실행해줘.',
      'flutter test ./실행해줘.',
    ];
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      for (var index = 0; index < originals.length; index++)
        for (var submission = 0; submission < 2; submission++)
          _prompt(index * 2 + submission + 1, originals[index]),
    ]);

    expect(
      analysis.phrases.map((pattern) => pattern.normalizedKey),
      containsAll(originals),
    );
    for (final original in originals) {
      expect(
        analysis.phrases
            .firstWhere((pattern) => pattern.normalizedKey == original)
            .submissionCount,
        2,
      );
    }
    expect(
      analysis.terms.map((pattern) => pattern.normalizedKey),
      containsAll([
        '실행해줘.',
        '실행해줘',
        '알려주세요.',
        '알려주세요',
        '"실행해줘."',
        "'커밋해줘.'",
        '`알려줘.`',
        '--실행해줘.',
        '--target=실행해줘.',
        './실행해줘.',
      ]),
    );
  });

  test('파일명과 자연어가 섞인 요청은 마지막 마침표만 달라도 한 구문으로 묶는다', () {
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, 'main.dart 고쳐줘.'),
      _prompt(2, 'main.dart 고쳐줘'),
    ]);

    expect(analysis.phrases.single.normalizedKey, 'main.dart 고쳐줘');
    expect(analysis.phrases.single.submissionCount, 2);
    expect(
      analysis.phrases.single.variants,
      containsAll(['main.dart 고쳐줘.', 'main.dart 고쳐줘']),
    );
    expect(
      analysis.terms
          .firstWhere((pattern) => pattern.normalizedKey == 'main.dart')
          .submissionCount,
      2,
    );
  });

  test('CLI 이름 뒤 자연어 요청 동사가 있으면 마침표 표기만 다른 구문을 묶는다', () {
    for (final body in ['flutter test 돌려줘', 'npm test 확인해줘', 'git diff 고쳐줘']) {
      final analysis = analyzePrompts(<DashboardHistoryEvent>[
        _prompt(1, '$body.'),
        _prompt(2, body),
      ]);

      expect(analysis.phrases.single.normalizedKey, body);
      expect(analysis.phrases.single.submissionCount, 2);
      expect(analysis.phrases.single.variants, containsAll(['$body.', body]));
    }
  });

  test('한 줄의 실제 CLI 명령이 다른 자연어 줄의 용어 정규화에 영향을 주지 않는다', () {
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, 'git status\n고쳐줘.'),
      _prompt(2, 'flutter test\n고쳐줘'),
    ]);

    final word = analysis.terms.firstWhere(
      (pattern) => pattern.normalizedKey == '고쳐줘',
    );
    expect(word.submissionCount, 2);
    expect(word.variants, containsAll(['고쳐줘.', '고쳐줘']));
  });

  test('실제 CLI 인자와 기술 토큰의 마침표 및 질문 감탄 부호를 보존한다', () {
    const originals = [
      'echo hello.',
      'npm run test.',
      'README.md.',
      'v1.2.0.',
      'npm?',
      '확인해줘?',
      '확인해줘!',
    ];
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      for (var index = 0; index < originals.length; index++)
        for (var submission = 0; submission < 2; submission++)
          _prompt(index * 2 + submission + 1, originals[index]),
    ]);

    expect(
      analysis.phrases.map((pattern) => pattern.normalizedKey),
      containsAll(originals),
    );
    expect(
      analysis.terms.map((pattern) => pattern.normalizedKey),
      containsAll([
        'hello.',
        'test.',
        'README.md.',
        'v1.2.0.',
        'npm?',
        '확인해줘?',
        '확인해줘!',
      ]),
    );
  });

  test('천 개 표본에서 반복 구문과 용어를 집계하고 표시 목록은 상한을 지킨다', () {
    const recurring = '기존 동작을 보존하고 테스트를 실행해줘';
    final prompts = List<DashboardHistoryEvent>.generate(1000, (index) {
      final words = List<String>.generate(
        20,
        (word) => '항목${index}_$word',
      ).join(' ');
      return _prompt(index + 1, '$recurring\n$words');
    });
    final analysis = analyzePrompts(prompts);

    expect(analysis.prompts, hasLength(1000));
    expect(analysis.terms.length, lessThanOrEqualTo(kPromptPatternLimit));
    expect(analysis.fullPrompts, hasLength(kPromptPatternLimit));
    expect(
      analysis.phrases
          .firstWhere((item) => item.text == recurring)
          .submissionCount,
      1000,
    );
  });

  test('한국어 반복 문장에서 제출 수와 원문 문맥을 함께 제공한다', () {
    const phrase = '기존 동작을 보존하고 테스트를 실행해줘';
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, '$phrase\n로그인 화면을 수정해줘'),
      _prompt(2, '$phrase\n검색 화면을 수정해줘', session: 'codex:another'),
      _prompt(3, '다른 요청'),
    ]);

    final result = analysis.phrases.firstWhere((item) => item.text == phrase);
    expect(result.submissionCount, 2);
    expect(result.sessionCount, 2);
    expect(result.lastUsedAt, 2);
    expect(result.examples.first.message, contains('검색 화면을 수정해줘'));
    expect(analysis.phrases.any((item) => item.text == '동작을 보존하고'), isFalse);
  });

  test('영어 약어 AI UI PR은 짧아도 용어로 남고 단독 입력도 볼 수 있다', () {
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, 'AI UI PR review'),
    ]);

    expect(
      analysis.terms.map((item) => item.text),
      containsAll(['AI', 'UI', 'PR']),
    );
    expect(analysis.phrases, isEmpty);
    expect(analysis.fullPrompts.single.text, 'AI UI PR review');
    expect(analysis.fullPrompts.single.submissionCount, 1);
  });

  test('같은 프롬프트 재제출은 세고 같은 행 ID의 재시도만 제거한다', () {
    final first = _prompt(1, '테스트를 실행해줘');
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      first,
      first,
      _prompt(2, '테스트를 실행해줘'),
    ]);

    expect(analysis.prompts, hasLength(2));
    expect(analysis.observedEventsCount, 2);
    expect(analysis.fullPrompts.single.submissionCount, 2);
    expect(analysis.fullPrompts.single.sessionCount, 1);
  });

  test('한 입력에서 세 번 나온 문장은 제출 한 번과 출현 세 번으로 구분한다', () {
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, '검사를 실행해줘. 검사를 실행해줘. 검사를 실행해줘.'),
      _prompt(2, '검사를 실행해줘.'),
    ]);

    final phrase = analysis.phrases.firstWhere(
      (item) => item.text == '검사를 실행해줘.',
    );
    expect(phrase.submissionCount, 2);
    expect(phrase.occurrenceCount, 4);
    final term = analysis.terms.firstWhere((item) => item.text == '검사를');
    expect(term.submissionCount, 2);
    expect(term.occurrenceCount, 4);
  });

  test('opencode 입력은 플러그인이 넘긴 본문 그대로 지원 출처로 집계되고 미지원 목록에 들어가지 않는다', () {
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, '테스트 하나 추가해 줘', source: 'opencode'),
      _prompt(2, null, source: 'opencode'),
    ]);

    expect(analysis.prompts.map((event) => event.id), [1]);
    expect(analysis.observedEventsCount, 2);
    expect(analysis.missingContentCount, 1);
    expect(analysis.unsupportedSources, isEmpty);
    expect(analysis.terms.any((item) => item.text == '테스트'), isTrue);
  });

  test('합성 agy와 미지원 출처 및 assistant 이벤트는 본문이 있어도 집계하지 않는다', () {
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, '실제 입력', source: 'codex'),
      _prompt(2, null, source: 'antigravity'),
      _prompt(3, '합성 입력', source: 'antigravity'),
      _prompt(4, '미확인 입력', source: 'unknown'),
      _prompt(5, '완료 응답', event: 'Stop'),
      _prompt(6, null, source: 'devin'),
      _prompt(7, '  ', source: 'grok'),
    ]);

    expect(analysis.prompts.map((event) => event.id), [1]);
    expect(analysis.observedEventsCount, 6);
    expect(analysis.missingContentCount, 2);
    expect(analysis.terms.any((item) => item.text == '합성'), isFalse);
  });

  test('기간과 출처는 표본을 고르고 검색은 표본 수를 유지하며 저장 입력 후보만 좁힌다', () {
    final analysis = analyzePrompts(
      <DashboardHistoryEvent>[
        _prompt(1, 'PR review', source: 'codex', at: 99),
        _prompt(2, 'PR Review', source: 'codex', at: 100),
        _prompt(3, '다른 요청', source: 'codex', at: 150),
        _prompt(4, 'PR review', source: 'devin', at: 150),
        _prompt(5, 'PR review', source: 'codex', at: 200),
      ],
      source: 'codex',
      since: 100,
      until: 200,
      query: 'review',
    );

    expect(analysis.prompts.map((event) => event.id), [3, 2]);
    expect(analysis.observedEventsCount, 2);
    expect(analysis.fullPrompts.single.text, 'PR Review');
    expect(analysis.terms.single.normalizedKey, 'Review');
  });

  test('공백 정규화로 묶어도 복사할 표현은 실제 원문 span을 보존한다', () {
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, '이전 요청\n코드를\t확인해줘\n추가 조건'),
      _prompt(2, '최근 요청\n코드를  확인해줘\n다른 조건'),
    ]);

    final phrase = analysis.phrases.firstWhere(
      (item) => item.normalizedKey == '코드를 확인해줘',
    );
    expect(phrase.text, '코드를  확인해줘');
    expect(phrase.variants, containsAll(['코드를  확인해줘', '코드를\t확인해줘']));
    expect(
      phrase.examples.every(
        (event) =>
            event.message!.contains(phrase.variants.first) ||
            event.message!.contains(phrase.variants.last),
      ),
      isTrue,
    );
  });

  test('URL 파일명 버전과 명령은 내부 마침표에서 문장으로 나누지 않는다', () {
    const prompt = 'README.md v1.2.3 https://example.dev/a --check를 확인해줘';
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, prompt),
      _prompt(2, prompt),
    ]);

    expect(analysis.phrases.single.text, prompt);
    expect(
      analysis.terms.map((item) => item.text),
      containsAll(['README.md', 'v1.2.3', 'https://example.dev/a', '--check를']),
    );
  });

  test('같은 접두사라도 저장된 꼬리가 다르면 전체 입력을 합치지 않는다', () {
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, '같은 접두사 작업 A'),
      _prompt(2, '같은 접두사 작업 B'),
    ]);

    expect(analysis.fullPrompts, hasLength(2));
    expect(
      analysis.fullPrompts.every((item) => item.submissionCount == 1),
      isTrue,
    );
  });

  test('300 경계는 UTF16 코드 유닛으로 계산하며 실제 절단을 확정하지 않는다', () {
    final below = '가' * (promptPreviewCharacterLimit - 1);
    final boundary = '🙂' * (promptPreviewCharacterLimit ~/ 2);
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, below),
      _prompt(2, boundary),
      _prompt(3, '$below가나'),
    ]);

    expect(boundary.length, promptPreviewCharacterLimit);
    expect(analysis.possibleTruncationCount, 2);
  });

  test('검색해도 빈도와 표본 상태는 유지하며 용어와 구문 자체에 검색을 적용한다', () {
    final events = <DashboardHistoryEvent>[
      _prompt(1, '테스트를 실행해줘\n로그인'),
      _prompt(2, '테스트를 실행해줘\n검색'),
      _prompt(3, null, source: 'codex'),
      _prompt(4, null, source: 'antigravity'),
    ];
    final full = analyzePrompts(events);
    final searched = analyzePrompts(events, query: '로그인');

    expect(searched.prompts, full.prompts);
    expect(searched.observedEventsCount, full.observedEventsCount);
    expect(searched.missingContentCount, full.missingContentCount);
    expect(searched.possibleTruncationCount, full.possibleTruncationCount);
    expect(searched.unsupportedSources, full.unsupportedSources);
    expect(searched.terms.single.normalizedKey, '로그인');
    expect(searched.phrases, isEmpty);
    expect(searched.fullPrompts.single.text, contains('로그인'));

    final repeated = analyzePrompts(events, query: '테스트를');
    expect(repeated.terms.single.submissionCount, 2);
    expect(repeated.phrases.single.submissionCount, 2);
  });

  test('상위 백 개 밖의 드문 표현도 검색은 후보 상한 전에 찾아낸다', () {
    final events = <DashboardHistoryEvent>[
      for (var index = 0; index < kPromptPatternLimit + 10; index++)
        _prompt(index + 1, '아주길고흔한고유용어$index 긴 표현을 반복해줘'),
      _prompt(1000, 'needle'),
    ];
    final full = analyzePrompts(events);
    expect(full.terms.any((pattern) => pattern.text == 'needle'), isFalse);
    expect(
      full.fullPrompts.any((pattern) => pattern.text == 'needle'),
      isFalse,
    );

    final searched = analyzePrompts(events, query: 'NEEDLE');
    expect(searched.prompts.length, events.length);
    expect(searched.terms.single.text, 'needle');
    expect(searched.fullPrompts.single.text, 'needle');
  });

  test('마침표와 번호 및 목록 표기만 다른 표현은 묶고 원문 변형을 남긴다', () {
    const originals = ['리뷰해줘', '리뷰해줘.', '1. 리뷰해줘', '- 리뷰해줘'];
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      for (var index = 0; index < originals.length; index++)
        _prompt(index + 1, originals[index]),
    ]);

    final phrase = analysis.phrases.single;
    expect(phrase.normalizedKey, '리뷰해줘');
    expect(phrase.submissionCount, 4);
    expect(phrase.occurrenceCount, 4);
    expect(phrase.variants, containsAll(originals));
    expect(phrase.text, '- 리뷰해줘');
    expect(analysis.terms.single.normalizedKey, '리뷰해줘');
    expect(analysis.terms.single.submissionCount, 4);
    expect(analysis.fullPrompts, hasLength(4));
  });

  test('목록 prefix와 본문을 겹쳐 추출해도 같은 출현을 두 번 세지 않는다', () {
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, '1. 코드를 확인해줘.'),
      _prompt(2, '• 코드를 확인해줘'),
    ]);

    final phrase = analysis.phrases.single;
    expect(phrase.normalizedKey, '코드를 확인해줘');
    expect(phrase.submissionCount, 2);
    expect(phrase.occurrenceCount, 2);
    expect(phrase.variants, containsAll(['1. 코드를 확인해줘.', '• 코드를 확인해줘']));
    expect(
      analysis.terms.any((pattern) => pattern.normalizedKey == '1'),
      isFalse,
    );
  });

  test('경로 버전 URL과 명령에 속한 마침표는 표현 key에서도 보존한다', () {
    const originals = <String>[
      'README.md.',
      'README.md',
      '.env',
      '../src/',
      'https://example.dev/a',
      'v1.2.3',
      '--check',
      'npm run test.',
    ];
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      for (var index = 0; index < originals.length; index++)
        for (var submission = 0; submission < 2; submission++)
          _prompt(index * 2 + submission + 1, originals[index]),
    ]);

    expect(
      analysis.phrases.map((pattern) => pattern.normalizedKey),
      containsAll(originals),
    );
    expect(
      analysis.terms.map((pattern) => pattern.normalizedKey),
      containsAll([
        'README.md.',
        'README.md',
        '.env',
        '../src/',
        'https://example.dev/a',
        'v1.2.3',
        '--check',
        'test.',
      ]),
    );
  });

  test('같은 표본에 긴 단어가 있어도 토큰이 다른 짧은 표현은 억제하지 않는다', () {
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, '정리\n정리해줘 세션'),
      _prompt(2, '정리\n정리해줘 세션'),
    ]);

    expect(
      analysis.phrases.map((pattern) => pattern.normalizedKey),
      containsAll(['정리', '정리해줘 세션']),
    );
    expect(
      analysis.phrases.every((pattern) => pattern.submissionCount == 2),
      isTrue,
    );
  });

  test('최근 예시에 없는 기록도 끝 경계에 닿으면 표현의 잘림 가능성을 표시한다', () {
    const repeated = '반복 문구';
    final padding = '가' * (promptPreviewCharacterLimit - repeated.length - 1);
    final clipped = '$padding\n$repeated';
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, clipped),
      _prompt(2, '$repeated\n다른 요청 A'),
      _prompt(3, '$repeated\n다른 요청 B'),
      _prompt(4, '$repeated\n다른 요청 C'),
    ]);

    expect(clipped.length, promptPreviewCharacterLimit);
    final phrase = analysis.phrases.firstWhere(
      (pattern) => pattern.normalizedKey == repeated,
    );
    expect(phrase.examples.map((event) => event.id), [4, 3, 2]);
    expect(phrase.mayBeClipped, isTrue);
    expect(
      analysis.terms
          .firstWhere((pattern) => pattern.normalizedKey == '문구')
          .mayBeClipped,
      isTrue,
    );
    expect(
      analysis.fullPrompts
          .firstWhere((pattern) => pattern.text == clipped)
          .mayBeClipped,
      isTrue,
    );
    expect(
      analysis.phrases
          .firstWhere((pattern) => pattern.normalizedKey == '다른 요청')
          .mayBeClipped,
      isFalse,
    );
  });

  test('한도 길이의 입력에서도 끝에 닿지 않은 표현은 잘림 표시를 하지 않는다', () {
    const prefix = '앞 문구';
    final body =
        '$prefix\n${'가' * (promptPreviewCharacterLimit - prefix.length - 1)}';
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, body),
      _prompt(2, '$prefix\n다른 내용'),
    ]);

    expect(body.length, promptPreviewCharacterLimit);
    expect(
      analysis.phrases
          .firstWhere((pattern) => pattern.normalizedKey == prefix)
          .mayBeClipped,
      isFalse,
    );
    expect(
      analysis.fullPrompts
          .firstWhere((pattern) => pattern.text == body)
          .mayBeClipped,
      isTrue,
    );
  });

  test('지원하지 않는 출처 수는 검색과 무관하며 기간 출처 및 ID 중복 경계를 따른다', () {
    final unsupported = _prompt(1, null, source: 'antigravity', at: 100);
    final events = <DashboardHistoryEvent>[
      unsupported,
      unsupported,
      _prompt(2, '합성', source: 'antigravity', at: 150),
      _prompt(3, '미확인', source: 'unknown', at: 150),
      _prompt(4, null, source: 'unknown', at: 200),
      _prompt(5, 'assistant', source: 'unknown', event: 'Stop', at: 150),
    ];
    final analysis = analyzePrompts(
      events,
      since: 100,
      until: 200,
      query: '일치 없음',
    );

    expect(analysis.unsupportedSources, {'antigravity': 2, 'unknown': 1});
    expect(analysis.observedEventsCount, 3);
    expect(analysis.prompts, isEmpty);
    expect(analysis.missingContentCount, 0);
    expect(
      () => analysis.unsupportedSources['unknown'] = 0,
      throwsUnsupportedError,
    );
    expect(
      analyzePrompts(
        events,
        source: 'unknown',
        since: 100,
        until: 200,
      ).unsupportedSources,
      {'unknown': 1},
    );
  });

  test('최근 여덟 변형 밖의 원문 표기에서도 검색 후보를 찾고 전체 빈도를 유지한다', () {
    final events = <DashboardHistoryEvent>[
      _prompt(1, '99. 리뷰해줘'),
      for (var index = 2; index <= kPromptPatternVariants + 3; index++)
        _prompt(index, '$index. 리뷰해줘'),
    ];
    final analysis = analyzePrompts(events, query: '99.');

    expect(analysis.phrases.single.submissionCount, events.length);
    expect(analysis.phrases.single.normalizedKey, '리뷰해줘');
    expect(analysis.phrases.single.variants, hasLength(kPromptPatternVariants));
    expect(analysis.phrases.single.variants, isNot(contains('99. 리뷰해줘')));
    expect(analysis.fullPrompts.single.text, '99. 리뷰해줘');
  });

  test('같은 한도 길이 저장 입력은 서로 다른 제출로 세며 묶음과 잘림 경고를 유지한다', () {
    final stored = '가' * promptPreviewCharacterLimit;
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, stored),
      _prompt(2, stored),
    ]);

    expect(analysis.fullPrompts.single.submissionCount, 2);
    expect(analysis.fullPrompts.single.text, stored);
    expect(analysis.fullPrompts.single.mayBeClipped, isTrue);
  });

  test('자동 요약과 실제 입력이 같은 구문이어도 사용자 입력에서만 빈도를 센다', () {
    const phrase = '검사를 실행해줘';
    const notification =
        '<task-notification><task-id>worker-1</task-id>'
        '<status>completed</status><summary>$phrase</summary>'
        '</task-notification>';
    final events = <DashboardHistoryEvent>[
      _prompt(1, phrase),
      _prompt(2, '$phrase\n추가 조건'),
      _prompt(3, notification),
      _prompt(4, notification),
    ];
    final analysis = analyzePrompts(events);
    final repeated = analysis.phrases.firstWhere((item) => item.text == phrase);

    expect(repeated.submissionCount, 2);
    expect(repeated.occurrenceCount, 2);
    expect(repeated.examples.map((event) => event.id), [2, 1]);
    expect(analysis.automaticMessageCount, 2);
    for (final query in [
      'task-notification',
      'summary',
      'completed',
      'worker-1',
    ]) {
      final searched = analyzePrompts(events, query: query);
      expect(searched.terms, isEmpty, reason: query);
      expect(searched.phrases, isEmpty, reason: query);
      expect(searched.fullPrompts, isEmpty, reason: query);
      expect(searched.automaticMessageCount, 2);
      expect(searched.prompts, analysis.prompts);
    }
  });

  test('붙여넣기 ID가 반복돼도 각 행을 세고 분석 문자열과 예시 원본을 분리한다', () {
    const body = '  검사를\t실행해줘\n';
    const raw = '<pasted_content id="c0de">$body</pasted_content>';
    final first = _prompt(1, raw);
    final second = _prompt(2, raw, session: 'claude-code:other/session');
    final events = <DashboardHistoryEvent>[first, second];
    final analysis = analyzePrompts(events);
    final full = analysis.fullPrompts.single;

    expect(full.text, body);
    expect(full.normalizedKey, '검사를 실행해줘');
    expect(full.submissionCount, 2);
    expect(full.sessionCount, 2);
    expect(full.variants, [body]);
    expect(full.examples, [second, first]);
    expect(full.examples.every((event) => event.message == raw), isTrue);
    expect(analysis.prompts, [second, first]);
    expect(analysis.automaticMessageCount, 0);
    expect(analysis.phrases.single.text, '검사를\t실행해줘');
    final searched = analyzePrompts(events, query: 'pasted_content');
    expect(searched.terms, isEmpty);
    expect(searched.phrases, isEmpty);
    expect(searched.fullPrompts, isEmpty);
    expect(searched.prompts, analysis.prompts);
  });

  test('Codex 답변의 질문과 감싸기 메타데이터는 모든 분석 보기와 검색에서 빠진다', () {
    const body = '  검사를\n실행해줘  ';
    const raw =
        '<send_user_message_question_reply>'
        '[{"answer":"  검사를\\n실행해줘  ","question":"기계 질문 자동문구",'
        '"questionItemId":"machine-id"}]'
        '</send_user_message_question_reply>';
    final events = <DashboardHistoryEvent>[
      _prompt(1, raw, source: 'codex'),
      _prompt(2, raw, source: 'codex'),
    ];
    final analysis = analyzePrompts(events);

    expect(analysis.fullPrompts.single.text, body);
    expect(analysis.fullPrompts.single.submissionCount, 2);
    expect(analysis.fullPrompts.single.examples.first.message, raw);
    expect(
      analysis.terms.map((item) => item.text),
      containsAll(['검사를', '실행해줘']),
    );
    for (final query in [
      'question',
      'machine-id',
      '기계 질문',
      '자동문구',
      'send_user',
    ]) {
      final searched = analyzePrompts(events, query: query);
      expect(searched.terms, isEmpty, reason: query);
      expect(searched.phrases, isEmpty, reason: query);
      expect(searched.fullPrompts, isEmpty, reason: query);
      expect(searched.prompts, analysis.prompts);
    }
  });

  test('자동 미해독 미수집과 잘림 수는 검색에 독립적이며 기간 출처와 중복을 따른다', () {
    const taskPrefix =
        '<task-notification><task-id>worker-1</task-id><status>completed</status>';
    final automatic = _prompt(
      1,
      '$taskPrefix${'가' * (promptPreviewCharacterLimit - taskPrefix.length)}',
      at: 100,
    );
    const replyPrefix = '<send_user_message_question_reply>[{"answer":"';
    final unreadable =
        '$replyPrefix${'가' * (promptPreviewCharacterLimit - replyPrefix.length)}';
    const pasteOpen = '<pasted_content id="c0de">';
    const pasteClose = '</pasted_content>';
    final closedPaste =
        '$pasteOpen${'나' * (promptPreviewCharacterLimit - pasteOpen.length - pasteClose.length)}$pasteClose';
    const completeArray =
        '[{"answer":"확인해줘","question":"질문","questionItemId":"first"}]';
    final reply =
        '<send_user_message_question_reply>$completeArray'
        '</send_user_message_question_reply>';
    final events = <DashboardHistoryEvent>[
      automatic,
      automatic,
      _prompt(2, unreadable, source: 'codex', at: 150),
      _prompt(3, null, at: 150),
      _prompt(4, taskPrefix, source: 'unknown', at: 150),
      _prompt(
        5,
        '🙂' * (promptPreviewCharacterLimit ~/ 2),
        source: 'grok',
        at: 150,
      ),
      _prompt(6, closedPaste, at: 150),
      _prompt(7, reply, source: 'codex', at: 150),
      _prompt(8, taskPrefix, event: 'Stop', at: 150),
      _prompt(9, taskPrefix, at: 99),
      _prompt(10, taskPrefix, at: 200),
    ];
    final full = analyzePrompts(events, since: 100, until: 200);
    final searched = analyzePrompts(
      events,
      since: 100,
      until: 200,
      query: '없음',
    );

    expect(full.observedEventsCount, 7);
    expect(full.automaticMessageCount, 1);
    expect(full.unreadableInputCount, 1);
    expect(full.missingContentCount, 1);
    expect(full.possibleTruncationCount, 1);
    expect(full.unsupportedSources, {'unknown': 1});
    expect(full.prompts.map((event) => event.id), [7, 6, 5]);
    expect(searched.automaticMessageCount, full.automaticMessageCount);
    expect(searched.unreadableInputCount, full.unreadableInputCount);
    expect(searched.missingContentCount, full.missingContentCount);
    expect(searched.possibleTruncationCount, full.possibleTruncationCount);
    expect(searched.observedEventsCount, full.observedEventsCount);
    expect(searched.unsupportedSources, full.unsupportedSources);
    expect(searched.prompts, full.prompts);
    final codex = analyzePrompts(
      events,
      source: 'codex',
      since: 100,
      until: 200,
    );
    expect(codex.observedEventsCount, 2);
    expect(codex.unreadableInputCount, 1);
    expect(codex.automaticMessageCount, 0);
    expect(codex.possibleTruncationCount, 0);
    expect(codex.prompts.single.id, 7);
  });

  test('감싸기를 뺀 본문의 마지막 표현만 실제 저장 경계 잘림을 이어받는다', () {
    const open = '<pasted_content id="c0de">';
    const prefix = '앞 문구';
    const repeated = '반복 문구';
    final padding =
        '가' *
        (promptPreviewCharacterLimit -
            open.length -
            prefix.length -
            repeated.length -
            2);
    final raw = '$open$prefix\n$padding\n$repeated';
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, raw),
      _prompt(2, '$prefix\n$repeated'),
    ]);

    expect(raw.length, promptPreviewCharacterLimit);
    expect(analysis.possibleTruncationCount, 1);
    expect(
      analysis.phrases
          .firstWhere((item) => item.normalizedKey == prefix)
          .mayBeClipped,
      isFalse,
    );
    expect(
      analysis.phrases
          .firstWhere((item) => item.normalizedKey == repeated)
          .mayBeClipped,
      isTrue,
    );
    expect(
      analysis.terms
          .firstWhere((item) => item.normalizedKey == '문구')
          .mayBeClipped,
      isTrue,
    );
    expect(
      analysis.fullPrompts
          .firstWhere((item) => item.text.contains(padding))
          .mayBeClipped,
      isTrue,
    );
    expect(
      analysis.fullPrompts
          .firstWhere((item) => item.text.contains(padding))
          .text,
      '$prefix\n$padding\n$repeated',
    );
  });

  test('감싸기만 저장 끝에 닿은 완전한 붙여넣기와 답변의 표현은 잘림 경고를 받지 않는다', () {
    const open = '<pasted_content id="c0de">';
    const close = '</pasted_content>';
    const phrase = '반복 문구';
    final padding =
        '가' *
        (promptPreviewCharacterLimit -
            open.length -
            close.length -
            phrase.length -
            1);
    final raw = '$open$padding\n$phrase$close';
    const replyPrefix = '<send_user_message_question_reply>[{"answer":"';
    const replyMiddle = '","question":"';
    const replySuffix = '","questionItemId":"first"}]';
    final question =
        '나' *
        (promptPreviewCharacterLimit -
            replyPrefix.length -
            phrase.length -
            replyMiddle.length -
            replySuffix.length);
    final reply = '$replyPrefix$phrase$replyMiddle$question$replySuffix';
    final analysis = analyzePrompts(<DashboardHistoryEvent>[
      _prompt(1, raw),
      _prompt(2, reply, source: 'codex'),
    ]);

    expect(raw.length, promptPreviewCharacterLimit);
    expect(reply.length, promptPreviewCharacterLimit);
    expect(analysis.possibleTruncationCount, 0);
    expect(analysis.phrases.single.text, phrase);
    expect(analysis.phrases.single.mayBeClipped, isFalse);
    expect(analysis.fullPrompts.every((item) => !item.mayBeClipped), isTrue);
    expect(analysis.terms.every((item) => !item.mayBeClipped), isTrue);
  });
}
