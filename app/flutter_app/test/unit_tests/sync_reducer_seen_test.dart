/// `sync_reducer.dart`의 0004 읽음/안읽음(seen) 불변식 — [SyncState.
/// seenWatermark]/[SyncState.isSessionUnseen]과 [SessionViewDto.
/// lastTransitionId] 프로젝션. `sync_reducer_test.dart`와 파일을 나눈
/// 이유는 그 파일과 같다(관심사 분리 + `quality_check.py budget` —
/// 원래 파일이 1000줄 예산을 넘겨 이 그룹만 옮겼다).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';

const int _base = 1757300000000;
const int _tick = 30000;

void main() {
  group('(f) 읽음/안읽음(0004 seen)', () {
    test('lastTransitionId가 없는 세션은 미확인 판정 대상이 아니다', () {
      const state = SyncState(cursor: 0);
      const session = SessionViewDto(key: 'claude-code:a1', state: 'working');
      expect(state.isSessionUnseen(session), isFalse);
    });

    test('seenTransitionIds에 이 세션 값이 있으면 그 값과만 비교한다(워터마크는 무시)', () {
      const state = SyncState(
        cursor: 0,
        seenWatermark: 100,
        seenTransitionIds: <String, int>{'claude-code:a1': 5},
      );
      const seen = SessionViewDto(
        key: 'claude-code:a1',
        state: 'working',
        lastTransitionId: 5,
      );
      const unseen = SessionViewDto(
        key: 'claude-code:a1',
        state: 'working',
        lastTransitionId: 6,
      );
      expect(state.isSessionUnseen(seen), isFalse);
      expect(state.isSessionUnseen(unseen), isTrue);
    });

    test('seenTransitionIds에 이 세션 키가 없으면(한 번도 seen 정보 없음) seenWatermark로 접는다', () {
      const state = SyncState(cursor: 0, seenWatermark: 10);
      const atWatermark = SessionViewDto(
        key: 'claude-code:a1',
        state: 'working',
        lastTransitionId: 10,
      );
      const aboveWatermark = SessionViewDto(
        key: 'claude-code:a1',
        state: 'working',
        lastTransitionId: 11,
      );
      // 경계값(워터마크와 같음)은 "이미 본 것"으로 접는다(> 비교, >= 아님).
      expect(state.isSessionUnseen(atWatermark), isFalse);
      expect(state.isSessionUnseen(aboveWatermark), isTrue);
    });

    test('첫 기동 스냅샷은 seenWatermark를 그 커서로 딱 한 번만 세운다', () {
      final booted = reduceSync(
        const SyncState(),
        const SyncResponseDto(reset: true, cursor: 42, serverTime: _base),
        nowMs: _base,
      );
      expect(booted.seenWatermark, 42);

      // 재연결로 또 reset을 받아도(진짜 최초 부팅이 아니므로) 다시 오르지
      // 않는다 — 그러면 그 사이 쌓인 진짜 미확인 전이가 지워진다.
      final reconnected = reduceSync(
        booted,
        const SyncResponseDto(reset: true, cursor: 90, serverTime: _base),
        nowMs: _base,
      );
      expect(reconnected.seenWatermark, 42);
    });

    test(
      '리뷰 지적 high: seenWatermark가 아직 null이면 커서를 이미 갖고 있던 '
      '기존 설치라도(isFirstBoot==false) 받는 스냅샷에서 벽을 세운다',
      () {
        // 이 기능 도입 이전부터 커서(cursor: 0)만 저장돼 있던 기존 설치를
        // 흉내낸다 — isFirstBoot(cursor==null)를 트리거로 쓰면 여기서
        // 영영 벽이 안 세워져 모든 카드가 미확인으로 뜬다(버그). 트리거는
        // seenWatermark 자신의 null 여부여야 한다.
        final state = reduceSync(
          const SyncState(cursor: 0),
          const SyncResponseDto(reset: true, cursor: 42, serverTime: _base),
          nowMs: _base,
        );
        expect(state.seenWatermark, 42);
      },
    );

    test('seenWatermark를 이미 세운 뒤(null 아님)에는 또 reset을 받아도 다시 오르지 않는다', () {
      final state = reduceSync(
        const SyncState(cursor: 30, seenWatermark: 10),
        const SyncResponseDto(reset: true, cursor: 42, serverTime: _base),
        nowMs: _base,
      );
      // 이미 세운 값(10)을 지키지, response.cursor(42)로도 state.cursor
      // (30)로도 갈아치우지 않는다 — 그러면 그 사이 쌓인 진짜 미확인
      // 전이가 지워진다.
      expect(state.seenWatermark, 10);
    });

    test('첫 도입 미확인 벽 덕분에 첫 스냅샷의 기존 세션은 미확인으로 뜨지 않는다', () {
      // 서버 쪽 last_transition_id는 "이 세션에 마지막으로 반영된 전이
      // id"다 — 몇 주 전부터 있던 세션이라면 그 값도 오래전에 지나간
      // 전이일 것이다(여기서는 30). 앱을 처음 깐 사람은 seen을 한 번도
      // 호출한 적이 없어(seenTransitionId == null) seenWatermark 하나로만
      // 판정된다.
      final booted = reduceSync(
        const SyncState(),
        const SyncResponseDto(
          reset: true,
          cursor: 30,
          serverTime: _base,
          sessions: <SessionViewDto>[
            SessionViewDto(
              key: 'claude-code:old1',
              state: 'waiting_input',
              lastTransitionId: 30,
            ),
          ],
        ),
        nowMs: _base,
      );
      expect(booted.seenWatermark, 30);
      expect(
        booted.isSessionUnseen(booted.sessions['claude-code:old1']!),
        isFalse,
      );

      // 그 뒤 실제로 새 전이가 오면(워터마크보다 큰 id) 그 세션은
      // 미확인으로 뜬다 — 벽은 첫 스냅샷 시점까지만 가려준다.
      final updated = reduceSync(
        booted,
        SyncResponseDto(
          cursor: 31,
          serverTime: _base + _tick,
          transitions: <TransitionDto>[
            TransitionDto(
              id: 31,
              sessionKey: 'claude-code:old1',
              toState: 'working',
              occurredAt: _base + _tick,
            ),
          ],
        ),
        nowMs: _base + _tick,
      );
      expect(
        updated.isSessionUnseen(updated.sessions['claude-code:old1']!),
        isTrue,
      );
    });

    test('델타로 새로 알게 된 세션은 그 전이 id를 lastTransitionId로 갖는다', () {
      final state = reduceSync(
        const SyncState(cursor: 0),
        SyncResponseDto(
          cursor: 5,
          serverTime: _base,
          transitions: <TransitionDto>[
            TransitionDto(
              id: 5,
              sessionKey: 'claude-code:new1',
              toState: 'working',
              occurredAt: _base,
            ),
          ],
        ),
        nowMs: _base,
      );
      expect(state.sessions['claude-code:new1']?.lastTransitionId, 5);
      expect(
        state.isSessionUnseen(state.sessions['claude-code:new1']!),
        isTrue,
      );
    });

    test('lastTransitionId는 뒤로 가지 않는다(기존 세션에 이어진 전이)', () {
      const seeded = SyncState(
        cursor: 0,
        sessions: <String, SessionViewDto>{
          'claude-code:c9': SessionViewDto(
            key: 'claude-code:c9',
            state: 'working',
            lastOccurredAt: _base,
            lastTransitionId: 9,
          ),
        },
      );
      final state = reduceSync(
        seeded,
        SyncResponseDto(
          cursor: 3,
          serverTime: _base,
          transitions: <TransitionDto>[
            TransitionDto(
              id: 3,
              sessionKey: 'claude-code:c9',
              toState: 'done',
              occurredAt: _base + 1,
            ),
          ],
        ),
        nowMs: _base,
      );
      expect(state.sessions['claude-code:c9']?.lastTransitionId, 9);
    });
  });

  group('(f) 응답 최상위 seen 배열(읽음 계약) — MAX 병합', () {
    test('빈 상태에서 스냅샷의 seen을 그대로 흡수한다', () {
      final state = reduceSync(
        const SyncState(cursor: 0),
        const SyncResponseDto(
          reset: true,
          cursor: 10,
          serverTime: _base,
          seen: <SeenMarkerDto>[
            SeenMarkerDto(key: 'claude-code:a1', seenTransitionId: 7),
          ],
        ),
        nowMs: _base,
      );
      expect(state.seenTransitionIds, <String, int>{'claude-code:a1': 7});
    });

    test('델타 응답도 같은 seen 배열을 갖고 온다(스냅샷 전용이 아니다)', () {
      final state = reduceSync(
        const SyncState(cursor: 5),
        const SyncResponseDto(
          cursor: 6,
          serverTime: _base,
          seen: <SeenMarkerDto>[
            SeenMarkerDto(key: 'claude-code:a1', seenTransitionId: 3),
          ],
        ),
        nowMs: _base,
      );
      expect(state.seenTransitionIds, <String, int>{'claude-code:a1': 3});
    });

    test('더 작은 수신값은 기존 로컬 값을 낮추지 않는다(MAX 멱등)', () {
      const seeded = SyncState(
        cursor: 5,
        seenTransitionIds: <String, int>{'claude-code:a1': 10},
      );
      final state = reduceSync(
        seeded,
        const SyncResponseDto(
          cursor: 6,
          serverTime: _base,
          seen: <SeenMarkerDto>[
            SeenMarkerDto(key: 'claude-code:a1', seenTransitionId: 4),
          ],
        ),
        nowMs: _base,
      );
      expect(state.seenTransitionIds['claude-code:a1'], 10);
    });

    test('seen_transition_id가 null인 항목은 기존 값을 지우지 않는다', () {
      const seeded = SyncState(
        cursor: 5,
        seenTransitionIds: <String, int>{'claude-code:a1': 10},
      );
      final state = reduceSync(
        seeded,
        const SyncResponseDto(
          cursor: 6,
          serverTime: _base,
          seen: <SeenMarkerDto>[
            SeenMarkerDto(key: 'claude-code:a1'),
          ],
        ),
        nowMs: _base,
      );
      expect(state.seenTransitionIds['claude-code:a1'], 10);
    });

    test(
      '깜빡임 방지: 낙관 갱신 직후 비행 중이던 옛 응답이 늦게 도착해도 '
      '더 낮은 seen으로 되돌리지 않는다',
      () {
        // 사람이 markSeen을 눌러(컨트롤러의 낙관 갱신) 로컬 seen이 먼저
        // 12로 올라간 상황을 흉내낸다. 그 직후, 그 갱신이 반영되기 전에
        // 서버로 나갔던 이전 폴링 응답(seen: 5)이 뒤늦게 도착해도 카드가
        // 다시 미확인으로 반짝이면 안 된다.
        const afterOptimisticMarkSeen = SyncState(
          cursor: 5,
          sessions: <String, SessionViewDto>{
            'claude-code:a1': SessionViewDto(
              key: 'claude-code:a1',
              state: 'working',
              lastTransitionId: 12,
            ),
          },
          seenTransitionIds: <String, int>{'claude-code:a1': 12},
        );
        final afterStaleResponse = reduceSync(
          afterOptimisticMarkSeen,
          const SyncResponseDto(
            cursor: 6,
            serverTime: _base,
            seen: <SeenMarkerDto>[
              SeenMarkerDto(key: 'claude-code:a1', seenTransitionId: 5),
            ],
          ),
          nowMs: _base,
        );
        expect(afterStaleResponse.seenTransitionIds['claude-code:a1'], 12);
        expect(
          afterStaleResponse.isSessionUnseen(
            afterStaleResponse.sessions['claude-code:a1']!,
          ),
          isFalse,
        );
      },
    );

    test('다른 세션 키의 seen은 서로 간섭하지 않는다', () {
      const seeded = SyncState(
        cursor: 5,
        seenTransitionIds: <String, int>{'claude-code:a1': 10},
      );
      final state = reduceSync(
        seeded,
        const SyncResponseDto(
          cursor: 6,
          serverTime: _base,
          seen: <SeenMarkerDto>[
            SeenMarkerDto(key: 'claude-code:b2', seenTransitionId: 2),
          ],
        ),
        nowMs: _base,
      );
      expect(state.seenTransitionIds, <String, int>{
        'claude-code:a1': 10,
        'claude-code:b2': 2,
      });
    });
  });
}
