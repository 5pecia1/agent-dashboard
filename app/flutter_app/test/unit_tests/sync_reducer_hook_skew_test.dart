/// `sync_reducer.dart`의 hook_skew(훅 구버전) 처리 — `SyncState.hookSkew`가
/// `mute_until`과 같은 절대값 관용으로 매 응답 무조건 대입되는지 본다.
/// `sync_reducer_seen_test.dart`와 파일을 나눈 이유는 그 파일과 같다
/// (`quality_check.py budget` — `sync_reducer_test.dart`가 이미 예산에
/// 가깝다).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';

const int _base = 1757300000000;

void main() {
  group('hook_skew(훅 구버전) — 무조건 대입', () {
    test('빈 상태에서 스냅샷의 hook_skew를 그대로 흡수한다', () {
      final state = reduceSync(
        const SyncState(),
        const SyncResponseDto(
          reset: true,
          cursor: 10,
          serverTime: _base,
          hookSkew: <HookSkewDto>[
            HookSkewDto(host: 'dev-mac', rev: 'a1b2c3d4'),
          ],
        ),
        nowMs: _base,
      );
      expect(state.hookSkew, <HookSkewDto>[
        const HookSkewDto(host: 'dev-mac', rev: 'a1b2c3d4'),
      ]);
    });

    test('델타 응답도 같은 hook_skew 배열을 갖고 온다(스냅샷 전용이 아니다)', () {
      final state = reduceSync(
        const SyncState(cursor: 5),
        const SyncResponseDto(
          cursor: 6,
          serverTime: _base,
          hookSkew: <HookSkewDto>[HookSkewDto(host: 'sol-linux')],
        ),
        nowMs: _base,
      );
      expect(state.hookSkew, <HookSkewDto>[
        const HookSkewDto(host: 'sol-linux'),
      ]);
    });

    test(
      'seen과 달리 MAX 병합이 아니다 — 빈 배열이 오면 기존 값을 무조건 지운다',
      () {
        const seeded = SyncState(
          cursor: 5,
          hookSkew: <HookSkewDto>[HookSkewDto(host: 'dev-mac')],
        );
        final state = reduceSync(
          seeded,
          const SyncResponseDto(cursor: 6, serverTime: _base),
          nowMs: _base,
        );
        // 훅이 갱신됐다면 다음 응답에서 그 기계가 통째로 사라져야 한다 —
        // MAX 병합이었다면 여기서 옛 값이 되살아나 틀렸을 것이다.
        expect(state.hookSkew, isEmpty);
      },
    );

    test('rev가 null인 항목(버전 미신고)도 그대로 옮겨진다', () {
      final state = reduceSync(
        const SyncState(),
        const SyncResponseDto(
          reset: true,
          cursor: 1,
          serverTime: _base,
          hookSkew: <HookSkewDto>[HookSkewDto(host: 'sol-old')],
        ),
        nowMs: _base,
      );
      expect(state.hookSkew.single.rev, isNull);
    });

    test('한 응답 안에서 목록 전체가 최신 값으로 교체된다(부분 갱신 없음)', () {
      const seeded = SyncState(
        cursor: 5,
        hookSkew: <HookSkewDto>[
          HookSkewDto(host: 'dev-mac', rev: 'aaaaaaaa'),
          HookSkewDto(host: 'sol-linux', rev: 'bbbbbbbb'),
        ],
      );
      // dev-mac이 훅을 갱신해 목록에서 빠지고, sol-linux는 여전히 낡았다.
      final state = reduceSync(
        seeded,
        const SyncResponseDto(
          cursor: 6,
          serverTime: _base,
          hookSkew: <HookSkewDto>[HookSkewDto(host: 'sol-linux', rev: 'bbbbbbbb')],
        ),
        nowMs: _base,
      );
      expect(state.hookSkew, <HookSkewDto>[
        const HookSkewDto(host: 'sol-linux', rev: 'bbbbbbbb'),
      ]);
    });
  });
}
