/// DTO가 정본(`contracts/dashboard-protocol.v1.json`)의 JSON 모양과
/// 왕복하는지, 그리고 서버가 필드를 더하거나 빠뜨려도 견디는지 본다.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';

void main() {
  test('상태 어휘 상수가 정본과 같다', () {
    expect(kDashboardStates, <String>[
      'idle',
      'working',
      'waiting_input',
      'done',
      'ended',
      'stalled',
    ]);
    expect(kDashboardPushStates, <String>['waiting_input', 'stalled']);
    // push 상태는 전부 상태 어휘의 부분집합이다.
    expect(kDashboardStates.toSet().containsAll(kDashboardPushStates), isTrue);
    expect(kDashboardProtocolVersion, 1);
  });

  // 회귀 방지(2026-09-14, Sol 확정): done은 조건부 승격으로 곧 working으로
  // 되돌아가 "끝났다" 직후 "진행 중" 알림이 이어지는 소음이 있었다 - done은
  // push_states에서 빠졌고, 이 값을 보는 isAlertState/isAlert도 done에는
  // false여야 한다.
  test('done 상태는 더 이상 알림 대상이 아니다', () {
    expect(kDashboardPushStates.contains('done'), isFalse);
    const session = SessionViewDto(key: 'claude-code:a1', state: 'done');
    expect(session.isAlertState, isFalse);
    const transition = TransitionDto(id: 1, sessionKey: 'claude-code:a1', toState: 'done');
    expect(transition.isAlert, isFalse);
  });

  test('세션·전이 JSON이 snake_case로 왕복한다', () {
    const session = SessionViewDto(
      key: 'claude-code:a1',
      state: 'waiting_input',
      source: 'claude-code',
      sessionId: 'a1',
      project: '/w/a1',
      host: 'mac-0',
      lastEvent: 'Notification',
      lastMessage: '승인 대기',
      lastOccurredAt: 1757299999000,
      createdAt: 1757299000000,
      updatedAt: 1757299999000,
    );
    final json = session.toJson();
    expect(json['session_id'], 'a1');
    expect(json['last_occurred_at'], 1757299999000);
    expect(SessionViewDto.fromJson(json), session);

    const transition = TransitionDto(
      id: 4213,
      sessionKey: 'claude-code:a1',
      fromState: 'working',
      toState: 'waiting_input',
      source: 'claude-code',
      project: '/w/a1',
      host: 'mac-0',
      message: '승인 대기',
      occurredAt: 1757299999000,
      createdAt: 1757299999005,
    );
    final transitionJson = transition.toJson();
    expect(transitionJson['to_state'], 'waiting_input');
    expect(TransitionDto.fromJson(transitionJson), transition);
  });

  test('0004 seen: last_transition_id가 snake_case로 왕복한다', () {
    const session = SessionViewDto(
      key: 'claude-code:a1',
      state: 'waiting_input',
      lastTransitionId: 42,
    );
    final json = session.toJson();
    expect(json['last_transition_id'], 42);
    // 읽음 계약: seen_transition_id는 더 이상 session_object에 없다 —
    // 응답 최상위 `seen` 배열([SeenMarkerDto])이 유일한 표현이다.
    expect(json.containsKey('seen_transition_id'), isFalse);
    expect(SessionViewDto.fromJson(json), session);
  });

  test('읽음 계약: SeenMarkerDto와 SyncResponseDto.seen이 snake_case로 왕복한다', () {
    const marker = SeenMarkerDto(key: 'claude-code:a1', seenTransitionId: 40);
    final markerJson = marker.toJson();
    expect(markerJson['key'], 'claude-code:a1');
    expect(markerJson['seen_transition_id'], 40);
    expect(SeenMarkerDto.fromJson(markerJson), marker);

    // seenTransitionId가 null(한 번도 seen 정보 없음)인 항목도 배열에
    // 실릴 수 있다.
    const nullMarker = SeenMarkerDto(key: 'claude-code:b2');
    expect(SeenMarkerDto.fromJson(nullMarker.toJson()), nullMarker);

    const response = SyncResponseDto(
      reset: true,
      cursor: 9,
      seen: <SeenMarkerDto>[marker, nullMarker],
    );
    // `explicitToJson`을 켜지 않은 codegen이라 `response.toJson()`은 중첩
    // DTO를 그대로 품는다(sessions/transitions와 같은 기존 패턴) — 실제
    // 와이어 모양은 `jsonEncode`가 각 원소의 `toJson()`을 재귀 호출한
    // 뒤에야 나온다.
    final wireJson =
        jsonDecode(jsonEncode(response.toJson())) as Map<String, dynamic>;
    expect(wireJson['seen'], <Object?>[
      <String, Object?>{'key': 'claude-code:a1', 'seen_transition_id': 40},
      <String, Object?>{'key': 'claude-code:b2', 'seen_transition_id': null},
    ]);
    expect(SyncResponseDto.fromJson(wireJson).seen, response.seen);
  });

  test(
    'hook_skew: HookSkewDto와 SyncResponseDto.hookSkew가 snake_case로 왕복한다',
    () {
      const withRev = HookSkewDto(
        host: 'dev-mac',
        rev: 'a1b2c3d4',
        project: '/Users/example/dev/trim.page',
      );
      final withRevJson = withRev.toJson();
      expect(withRevJson['host'], 'dev-mac');
      expect(withRevJson['rev'], 'a1b2c3d4');
      expect(withRevJson['project'], '/Users/example/dev/trim.page');
      expect(HookSkewDto.fromJson(withRevJson), withRev);

      // rev/project 둘 다 null = 훅이 버전·프로젝트 미신고(더 구버전 또는
      // devcontainer처럼 project를 아직 안 붙인 서버 응답).
      const withoutRev = HookSkewDto(host: 'sol-linux');
      final withoutRevJson = withoutRev.toJson();
      expect(HookSkewDto.fromJson(withoutRevJson).rev, isNull);
      expect(HookSkewDto.fromJson(withoutRevJson).project, isNull);

      // project 없이 온 wire(구버전 서버 응답)도 additive 필드라 null로 접는다.
      expect(
        HookSkewDto.fromJson(<String, dynamic>{'host': 'sol-linux'}).project,
        isNull,
      );

      final response = SyncResponseDto.fromJson(<String, dynamic>{
        'reset': true,
        'cursor': 9,
        'hook_skew': <Object?>[
          <String, Object?>{
            'host': 'dev-mac',
            'rev': 'a1b2c3d4',
            'project': '/Users/example/dev/trim.page',
          },
          <String, Object?>{'host': 'sol-linux', 'rev': null},
        ],
      });
      expect(response.hookSkew, <HookSkewDto>[withRev, withoutRev]);
    },
  );

  test('모르는 키는 무시하고 없는 키는 기본값으로 접는다', () {
    final session = SessionViewDto.fromJson(<String, dynamic>{
      'key': 'generic:x',
      'state': 'idle',
      'not_a_field_we_know': 42,
    });
    expect(session.source, '');
    expect(session.host, isNull);
    expect(session.createdAt, 0);
    expect(session.stale, isFalse);
    // additive 필드 — 구형 서버 응답에서도 안전한 기본값(null)이다. null은
    // "seen을 아직 한 번도 안 함"이 아니라 "이 필드 자체를 서버가 아직 안
    // 보낸다"는 뜻이라 `isSessionUnseen`이 곧바로 false로 접는다
    // (sync_reducer.dart 문서 참고).
    expect(session.lastTransitionId, isNull);

    final response = SyncResponseDto.fromJson(<String, dynamic>{
      'reset': true,
      'cursor': 9,
    });
    expect(response.protocolVersion, kDashboardProtocolVersion);
    expect(response.isSupportedProtocol, isTrue);
    expect(response.stallMs, kDefaultStallMs);
    expect(response.sessions, isEmpty);
    expect(response.transitions, isEmpty);
    expect(response.muteUntil, isNull);
    // 읽음 계약: seen 배열도 additive라 구형/빈 응답에서 빈 리스트로
    // 접힌다 — SessionViewDto가 사라진 필드 덕분에 통으로 손댈 게 없다.
    expect(response.seen, isEmpty);
    // hook_skew도 additive다 — 빈 배열은 "전부 최신"이지 "모름"이 아니다.
    expect(response.hookSkew, isEmpty);
  });

  test('알림 대상 판정은 정본 push_states를 따른다', () {
    for (final state in kDashboardStates) {
      final transition = TransitionDto(
        id: 1,
        sessionKey: 'generic:x',
        toState: state,
      );
      expect(transition.isAlert, kDashboardPushStates.contains(state));
    }
  });

  test('session_key에서 source와 session_id를 분리한다', () {
    const transition = TransitionDto(
      id: 1,
      sessionKey: 'claude-code:0f2c:1a9e',
      toState: 'done',
    );
    expect(transition.sourceFromKey, 'claude-code');
    // session_id 안에 콜론이 있어도 첫 구분자에서만 자른다.
    expect(transition.sessionIdFromKey, '0f2c:1a9e');

    const malformed = TransitionDto(
      id: 2,
      sessionKey: 'no-colon',
      toState: 'done',
    );
    expect(malformed.sourceFromKey, '');
    expect(malformed.sessionIdFromKey, 'no-colon');
  });

  group('PushConfigDto는 서버 응답 모양에 유연하다', () {
    test('평평한 snake_case', () {
      final config = PushConfigDto.fromServer(<String, dynamic>{
        'channels': <String>['fcm'],
        'firebase_config': <String, dynamic>{'apiKey': 'k'},
        'vapid_key': 'v',
        'options': <String, dynamic>{'serviceWorker': '/sw.js'},
      });
      expect(config.channels, <String>['fcm']);
      expect(config.firebaseConfig['apiKey'], 'k');
      expect(config.vapidKey, 'v');
      expect(config.options['serviceWorker'], '/sw.js');
      expect(config.canSubscribeOnWeb, isTrue);
    });

    test('중첩 camelCase에서도 채널을 추론한다', () {
      final config = PushConfigDto.fromServer(<String, dynamic>{
        'fcm': <String, dynamic>{
          'firebaseConfig': <String, dynamic>{'apiKey': 'k'},
          'vapidKey': 'v',
        },
      });
      expect(config.channels, <String>['fcm']);
      expect(config.canSubscribeOnWeb, isTrue);
    });

    test('빈 응답은 unavailable이다', () {
      final config = PushConfigDto.fromServer(<String, dynamic>{});
      expect(config.isUnavailable, isTrue);
      expect(config.canSubscribeOnWeb, isFalse);
      expect(config.channels, isEmpty);
    });

    test('채널은 있는데 VAPID 키가 없으면 웹 구독은 못 한다', () {
      final config = PushConfigDto.fromServer(<String, dynamic>{
        'channels': <String>['fcm'],
        'firebase_config': <String, dynamic>{'apiKey': 'k'},
      });
      expect(config.isUnavailable, isFalse);
      expect(config.canSubscribeOnWeb, isFalse);
    });

    test('실제 dashboard-server 응답(중첩 web_config + client_ready)을 읽는다', () {
      final config = PushConfigDto.fromServer(<String, dynamic>{
        'channels': <String>['fcm'],
        'fcm': <String, dynamic>{
          'web_config': <String, dynamic>{'apiKey': 'k', 'projectId': 'p'},
          'vapid_key': 'v',
          'client_ready': true,
        },
      });
      expect(config.channels, <String>['fcm']);
      expect(config.firebaseConfig['projectId'], 'p');
      expect(config.vapidKey, 'v');
      expect(config.clientReady, isTrue);
      expect(config.canSubscribeOnWeb, isTrue);
    });

    test('완료 기준 (d): client_ready:false면 값이 다 있어도 웹 등록을 하지 않는다', () {
      final config = PushConfigDto.fromServer(<String, dynamic>{
        'channels': <String>['fcm'],
        'fcm': <String, dynamic>{
          'web_config': <String, dynamic>{'apiKey': 'k'},
          'vapid_key': 'v',
          'client_ready': false,
        },
      });
      // 채널 자체는 살아 있다(서버가 macOS 기기에는 보낼 수 있다).
      expect(config.isUnavailable, isFalse);
      expect(config.clientReady, isFalse);
      expect(config.canSubscribeOnWeb, isFalse);
    });

    test('A안 설계 ③: 실제 dashboard-server 응답의 apple_config를 읽는다', () {
      final config = PushConfigDto.fromServer(<String, dynamic>{
        'channels': <String>['fcm'],
        'fcm': <String, dynamic>{
          'web_config': <String, dynamic>{'apiKey': 'web-k'},
          'vapid_key': 'v',
          'client_ready': true,
          'apple_config': <String, dynamic>{
            'apiKey': 'apple-k',
            'appId': '1:1:ios:abc',
            'messagingSenderId': '1',
            'projectId': 'p',
          },
          'apple_client_ready': true,
        },
      });
      expect(config.appleConfig['appId'], '1:1:ios:abc');
      // 웹 설정과 Apple 설정은 값이 다른 별개의 앱이다 — 섞이지 않는다.
      expect(config.firebaseConfig['apiKey'], 'web-k');
      expect(config.appleClientReady, isTrue);
      expect(config.canSubscribeOnApple, isTrue);
      expect(config.canSubscribeOnWeb, isTrue);
    });

    test('apple_client_ready:false면 값이 다 있어도 APNs 등록을 하지 않는다', () {
      final config = PushConfigDto.fromServer(<String, dynamic>{
        'channels': <String>['fcm'],
        'fcm': <String, dynamic>{
          'apple_config': <String, dynamic>{'apiKey': 'k'},
          'apple_client_ready': false,
        },
      });
      expect(config.isUnavailable, isFalse);
      expect(config.canSubscribeOnApple, isFalse);
    });

    test('apple_config가 없으면 웹만 가능하고 Apple은 불가능하다', () {
      final config = PushConfigDto.fromServer(<String, dynamic>{
        'channels': <String>['fcm'],
        'fcm': <String, dynamic>{
          'web_config': <String, dynamic>{'apiKey': 'k'},
          'vapid_key': 'v',
          'client_ready': true,
          'apple_config': null,
          'apple_client_ready': false,
        },
      });
      expect(config.canSubscribeOnWeb, isTrue);
      expect(config.canSubscribeOnApple, isFalse);
      expect(config.appleConfig, isEmpty);
    });

    test('apple_config만 온 응답도 채널을 추론한다(구형 호환)', () {
      final config = PushConfigDto.fromServer(<String, dynamic>{
        'apple_config': <String, dynamic>{'apiKey': 'k'},
      });
      expect(config.channels, <String>['fcm']);
      expect(config.canSubscribeOnApple, isTrue);
    });

    test('apple_client_ready를 안 보내는 구형 응답은 "모름"이지 false가 아니다', () {
      final config = PushConfigDto.fromServer(<String, dynamic>{
        'channels': <String>['fcm'],
        'fcm': <String, dynamic>{
          'apple_config': <String, dynamic>{'apiKey': 'k'},
        },
      });
      expect(config.appleClientReady, isNull);
      expect(config.canSubscribeOnApple, isTrue);
    });

    test('client_ready를 안 보내는 응답은 "모름"이지 false가 아니다', () {
      final config = PushConfigDto.fromServer(<String, dynamic>{
        'channels': <String>['fcm'],
        'firebase_config': <String, dynamic>{'apiKey': 'k'},
        'vapid_key': 'v',
      });
      expect(config.clientReady, isNull);
      expect(config.canSubscribeOnWeb, isTrue);
    });

    test('JSON 왕복이 값을 보존한다', () {
      const config = PushConfigDto(
        channels: <String>['fcm'],
        firebaseConfig: <String, Object?>{'apiKey': 'k'},
        vapidKey: 'v',
        clientReady: true,
      );
      expect(PushConfigDto.fromJson(config.toJson()), config);
    });
  });

  test('DiagnosticsDto는 빈 응답에서도 안전한 기본값을 갖는다', () {
    final diagnostics = DiagnosticsDto.fromJson(<String, dynamic>{});
    expect(diagnostics.lastEventAt, isNull);
    expect(diagnostics.maxTransitionId, 0);
    expect(diagnostics.lastPush, isNull);
    expect(diagnostics.channels, isEmpty);
    expect(diagnostics.hasLivePushChannel, isFalse);
  });

  test('TestPushResultDto는 채널별 발송 수를 합산한다', () {
    final result = TestPushResultDto.fromJson(<String, dynamic>{
      'ok': true,
      'transition_id': 7,
      'channels': <String, dynamic>{
        'fcm': <String, dynamic>{'sent': 2, 'removed': 0},
        'web-push': <String, dynamic>{'sent': 1, 'removed': 0},
      },
    });
    expect(result.sentCount, 3);
    expect(result.transitionId, 7);
  });
}
