/// TASK D-app 배선 (4): `web/push_sw.js`가 `BroadcastChannel('dashboard')`로
/// 던지는 메시지(그리고 macOS `RemoteMessage.data`)를 [PushSignal]로 옮기는
/// 규칙을 브라우저 없이 닫는다.
///
/// 실제 채널 열기/닫기는 `push_signal_web.dart`가 하고 그건 브라우저에서만
/// 도는 코드다(`app/scripts/web_push_smoke.py`의 몫). 여기서 고정하는 것은
/// **값 계약**이다 — 채널 이름과 키 이름이 서비스 워커와 어긋나면 클릭
/// 신호가 조용히 사라지므로, 그 이름들을 테스트가 문자열로 다시 적어
/// 한쪽만 바뀌는 것을 막는다(`web_push.dart`의 경로 상수를
/// `web_push_smoke.py`가 다시 적는 것과 같은 관용).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/platform/push_signal.dart';

void main() {
  group('서비스 워커와의 이름 계약', () {
    test('채널 이름은 push_sw.js의 BROADCAST_CHANNEL_NAME과 같다', () {
      expect(kPushSignalChannelName, 'dashboard');
    });

    test('메시지 키 이름은 push_sw.js가 postMessage하는 것과 같다', () {
      expect(kPushSignalTypeField, 'type');
      expect(kPushSignalRefreshField, 'refresh');
      expect(kPushSignalLinkField, 'link');
      expect(kPushSignalSessionKeyField, 'session_key');
      expect(kPushSignalTransitionIdField, 'transition_id');
      expect(kPushSignalProjectField, 'project');
      expect(kPushSignalHostField, 'host');
      expect(kPushSignalNotificationClick, 'notification-click');
    });
  });

  group('pushSignalFromMap', () {
    test('push_sw.js가 보내는 모양을 그대로 읽는다', () {
      final signal = pushSignalFromMap(<String, Object?>{
        'type': 'notification-click',
        'refresh': true,
        'link': '/?session=claude_code%3As1',
        'session_key': 'claude_code:s1',
        'transition_id': '42',
      });

      expect(signal.type, kPushSignalNotificationClick);
      expect(signal.refresh, isTrue);
      expect(signal.sessionKey, 'claude_code:s1');
      expect(signal.resolvedSessionKey, 'claude_code:s1');
      expect(signal.transitionId, 42);
    });

    test('양수 정수와 십진 문자열 전이만 클릭 시점으로 보존한다', () {
      for (final value in <Object>[42, '42']) {
        expect(pushSignalFromMap({'transition_id': value}).transitionId, 42);
      }
      for (final value in <Object?>[
        null,
        0,
        -1,
        '0',
        '-42',
        '0x42',
        '42.5',
        '',
        'invalid',
        42.0,
        true,
        <Object>[],
      ]) {
        expect(
          pushSignalFromMap({'transition_id': value}).transitionId,
          isNull,
          reason: '$value는 알림 전이 ID로 사용할 수 없다',
        );
      }
    });

    test('제공된 프로젝트·호스트만 보존하고 없는 값은 추측하지 않는다', () {
      final signal = pushSignalFromMap({'project': '/work/dashboard', 'host': 'work-mac'});
      expect(signal.project, '/work/dashboard');
      expect(signal.host, 'work-mac');
      final absent = pushSignalFromMap({});
      expect(absent.project, isNull);
      expect(absent.host, isNull);
      final malformed = pushSignalFromMap({'project': 42, 'host': ''});
      expect(malformed.project, isNull);
      expect(malformed.host, isNull);
    });

    test('session_key가 비어 와도 link의 쿼리에서 세션을 복구한다', () {
      final signal = pushSignalFromMap(<String, Object?>{
        'type': 'notification-click',
        'session_key': '',
        'link': '/?session=codex%3As2',
      });

      expect(signal.sessionKey, isNull);
      expect(signal.resolvedSessionKey, 'codex:s2');
    });

    test('세션을 알 수 없는 신호는 resolvedSessionKey가 null이다', () {
      final signal = pushSignalFromMap(<String, Object?>{
        'type': 'notification-click',
        'link': '/',
      });

      expect(signal.resolvedSessionKey, isNull);
    });

    test('refresh를 안 보내면 재조회한다 (push는 힌트, 정합성은 sync가 담보)', () {
      final signal = pushSignalFromMap(<String, Object?>{'session_key': 'claude_code:s1'});

      expect(signal.refresh, isTrue);
      expect(signal.type, kPushSignalNotificationClick);
    });

    test('refresh:false는 존중한다', () {
      final signal = pushSignalFromMap(<String, Object?>{'refresh': false});
      expect(signal.refresh, isFalse);
    });

    test('타입이 어긋난 값은 조용히 무시한다 (던지지 않는다)', () {
      final signal = pushSignalFromMap(<String, Object?>{
        'type': 42,
        'session_key': <String>['not', 'a', 'string'],
        'link': null,
        'refresh': 'yes',
      });

      expect(signal.type, kPushSignalNotificationClick);
      expect(signal.sessionKey, isNull);
      expect(signal.link, '');
      expect(signal.refresh, isTrue);
    });
  });

  group('sessionKeyFromPushLink', () {
    test('정본 push.data_keys.link.format을 읽는다', () {
      expect(sessionKeyFromPushLink('/?session=claude_code%3As1'), 'claude_code:s1');
    });

    test('세션 쿼리가 없으면 null이다', () {
      expect(sessionKeyFromPushLink('/'), isNull);
      expect(sessionKeyFromPushLink(''), isNull);
      expect(sessionKeyFromPushLink('/?other=1'), isNull);
    });
  });

  group('PushSignal 값 동등성', () {
    test('클릭 대상과 전이까지 모든 필드로 비교한다', () {
      const a = PushSignal(type: 'notification-click', sessionKey: 's');
      const b = PushSignal(type: 'notification-click', sessionKey: 's');
      const c = PushSignal(type: 'notification-click', sessionKey: 't');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      for (final different in <PushSignal>[
        const PushSignal(type: 'refresh', sessionKey: 's'),
        const PushSignal(type: 'notification-click', sessionKey: 's', link: '/'),
        const PushSignal(type: 'notification-click', sessionKey: 's', refresh: false),
        const PushSignal(type: 'notification-click', sessionKey: 's', transitionId: 42),
        const PushSignal(type: 'notification-click', sessionKey: 's', project: '/work/p'),
        const PushSignal(type: 'notification-click', sessionKey: 's', host: 'work-mac'),
      ]) {
        expect(a, isNot(different));
      }
      const complete = PushSignal(
        type: 'notification-click',
        sessionKey: 's',
        transitionId: 42,
        project: '/work/p',
        host: 'work-mac',
      );
      final parsed = pushSignalFromMap({
        'session_key': 's',
        'transition_id': '42',
        'project': '/work/p',
        'host': 'work-mac',
      });
      expect(complete, parsed);
      expect(complete.hashCode, parsed.hashCode);
    });
  });
}
