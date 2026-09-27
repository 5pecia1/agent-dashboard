import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/notification_tap.dart';

void main() {
  test('배너의 프로젝트와 호스트 및 잘리지 않은 전이 id를 보존한다', () {
    const original = NotificationTap(
      sessionKey: 'codex:session-1',
      project: '/work/한글 프로젝트',
      host: 'work-mac',
      transitionId: 0x8000002a,
      serverUrl: 'https://example.test/dashboard',
    );

    final decoded = NotificationTap.decode(original.encode())!;

    expect(decoded.sessionKey, original.sessionKey);
    expect(decoded.project, original.project);
    expect(decoded.host, original.host);
    expect(decoded.transitionId, original.transitionId);
    expect(decoded.serverUrl, original.serverUrl);
    expect(decoded.legacy, isFalse);
  });

  test('이미 전달된 단순 세션 키는 읽음 경계 없는 이전 알림으로만 구분한다', () {
    final decoded = NotificationTap.decode('claude-code:session-1')!;

    expect(decoded.sessionKey, 'claude-code:session-1');
    expect(decoded.transitionId, isNull);
    expect(decoded.serverUrl, isNull);
    expect(decoded.legacy, isTrue);
  });

  test('버전과 필드 형식이 잘못된 payload는 세션 키로 오인하지 않는다', () {
    for (final invalid in <String?>[
      null,
      '',
      'not a session key',
      '{broken',
      '{}',
      '[]',
      '"codex:s1"',
      '{"version":2,"session_key":"codex:s1"}',
      '{"version":1.0,"session_key":"codex:s1"}',
      '{"version":1,"project":42}',
      '{"version":1,"host":[]}',
      '{"version":1,"server_url":false}',
      '{"version":1,"transition_id":"42"}',
      '{"version":1,"transition_id":42.1}',
      '{"version":1,"transition_id":-1}',
      '{"version":1,"transition_id":0}',
    ]) {
      expect(NotificationTap.decode(invalid), isNull, reason: '$invalid');
    }
  });

  test('서버 인증정보와 쿼리 및 fragment는 알림에 저장하지 않는다', () {
    const tap = NotificationTap(
      sessionKey: 'codex:s1',
      serverUrl: 'https://user:secret@example.test:8443/dashboard?token=private#private',
    );
    final encoded = tap.encode();

    expect(encoded, isNot(contains('secret')));
    expect(encoded, isNot(contains('private')));
    expect(NotificationTap.decode(encoded)!.serverUrl, 'https://example.test:8443/dashboard');
    expect(NotificationTap.safeServerUrl('file:///tmp/server'), isNull);
  });
}
