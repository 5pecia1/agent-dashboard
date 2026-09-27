/// `ui/sessions_page.dart`의 순수 함수 — [groupSessionsByProject],
/// [SessionGroup], [sessionGridColumnCountFor] — 를 위젯을 펌프하지 않고
/// 값만으로 닫는다. 그룹 안 세션 순서는 [sortedSessionsFor]가 이미 별도로
/// 검증하므로(같은 파일의 다른 테스트), 여기서는 그룹 묶음과 그룹 간
/// 정렬만 본다.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/ui/sessions_page.dart';

SessionViewDto _session({
  required String key,
  required String project,
  String state = 'working',
  int updatedAt = 0,
}) => SessionViewDto(
  key: key,
  state: state,
  project: project,
  updatedAt: updatedAt,
);

void main() {
  group('groupSessionsByProject', () {
    test('같은 project(전체 경로)를 가진 세션끼리 한 그룹으로 묶인다', () {
      final sessions = [
        _session(key: 'a', project: '/repo/x', updatedAt: 1),
        _session(key: 'b', project: '/repo/y', updatedAt: 2),
        _session(key: 'c', project: '/repo/x', updatedAt: 3),
      ];

      final groups = groupSessionsByProject(sessions);

      expect(groups, hasLength(2));
      final byProject = {
        for (final g in groups)
          g.project: g.sessions.map((s) => s.key).toList(),
      };
      expect(byProject['/repo/x'], unorderedEquals(['a', 'c']));
      expect(byProject['/repo/y'], ['b']);
    });

    test('주의가 필요한(waiting_input/stalled) 세션이 있는 그룹이 맨 앞으로 온다', () {
      final sessions = [
        _session(
          key: 'a',
          project: '/repo/quiet',
          state: 'working',
          updatedAt: 100,
        ),
        _session(
          key: 'b',
          project: '/repo/needs-attn',
          state: 'waiting_input',
          updatedAt: 1,
        ),
      ];

      final groups = groupSessionsByProject(sessions);

      expect(groups.first.project, '/repo/needs-attn');
      expect(groups.first.needsAttention, isTrue);
    });

    test(
      "'done'만 있는 그룹은 주의 필요 그룹으로 취급되지 않는다(needsAttention은 waiting_input/stalled만)",
      () {
        final sessions = [
          _session(
            key: 'a',
            project: '/repo/done',
            state: 'done',
            updatedAt: 1,
          ),
        ];

        final groups = groupSessionsByProject(sessions);

        expect(groups.single.needsAttention, isFalse);
      },
    );

    test('주의 필요 여부가 같으면 그룹의 가장 최근 updatedAt 내림차순으로 정렬된다', () {
      final sessions = [
        _session(key: 'a', project: '/repo/old', updatedAt: 10),
        _session(key: 'b', project: '/repo/new', updatedAt: 20),
      ];

      final groups = groupSessionsByProject(sessions);

      expect(groups.map((g) => g.project).toList(), ['/repo/new', '/repo/old']);
    });

    test('주의 필요·최근 시각까지 같으면 project 오름차순으로 완전히 결정된다', () {
      final sessions = [
        _session(key: 'a', project: '/repo/b', updatedAt: 5),
        _session(key: 'b', project: '/repo/a', updatedAt: 5),
      ];

      final groups = groupSessionsByProject(sessions);

      expect(groups.map((g) => g.project).toList(), ['/repo/a', '/repo/b']);
    });

    test('project가 빈 문자열인 세션도 하나의 그룹(빈 키)으로 묶인다', () {
      final sessions = [
        _session(key: 'a', project: ''),
        _session(key: 'b', project: ''),
      ];

      final groups = groupSessionsByProject(sessions);

      expect(groups, hasLength(1));
      expect(groups.single.project, '');
      expect(groups.single.sessions, hasLength(2));
    });

    test('세션이 없으면 빈 목록을 돌려준다', () {
      expect(groupSessionsByProject(const <SessionViewDto>[]), isEmpty);
    });
  });

  group('sessionGridColumnCountFor', () {
    test('좁은 폭(<=600)은 1열이다 — narrow_width_test.dart의 360 뷰포트가 여기 들어온다', () {
      expect(sessionGridColumnCountFor(360), 1);
      expect(sessionGridColumnCountFor(600), 1);
    });

    test('중간 폭(600 초과 900 이하)은 2열이다', () {
      expect(sessionGridColumnCountFor(601), 2);
      expect(sessionGridColumnCountFor(900), 2);
    });

    test('데스크톱은 최소 카드 폭을 유지하면서 최대 6열까지 늘어난다', () {
      expect(sessionGridColumnCountFor(901), 3);
      expect(sessionGridColumnCountFor(1200), 4);
      expect(sessionGridColumnCountFor(1600), 5);
      expect(sessionGridColumnCountFor(2560), 6);
    });
  });

  group('foldSessionGroupsForRender', () {
    SessionGroup groupOf(String project, int count) => SessionGroup(
      project: project,
      sessions: [
        for (var i = 0; i < count; i++)
          _session(key: '$project#$i', project: project),
      ],
    );

    test('전부 1개짜리 그룹이면 런 하나로 합쳐진다', () {
      final groups = [
        groupOf('/repo/a', 1),
        groupOf('/repo/b', 1),
        groupOf('/repo/c', 1),
      ];

      final units = foldSessionGroupsForRender(groups);

      expect(units, hasLength(1));
      final run = units.single as SessionRenderRun;
      expect(run.groups, groups);
    });

    test('전부 2개 이상인 그룹이면 그룹 수만큼 독립 섹션이 된다(병합 없음)', () {
      final groups = [groupOf('/repo/a', 2), groupOf('/repo/b', 3)];

      final units = foldSessionGroupsForRender(groups);

      expect(units, hasLength(2));
      expect(units[0], isA<SessionRenderSection>());
      expect(units[1], isA<SessionRenderSection>());
      expect((units[0] as SessionRenderSection).group, groups[0]);
      expect((units[1] as SessionRenderSection).group, groups[1]);
    });

    test('1,1,3,1,1 순서는 [런(4개 그룹)…, 섹션(3)]로 접힌다', () {
      final groups = [
        groupOf('/repo/a', 1),
        groupOf('/repo/b', 1),
        groupOf('/repo/c', 3),
        groupOf('/repo/d', 1),
        groupOf('/repo/e', 1),
      ];

      final units = foldSessionGroupsForRender(groups);

      // 그룹핑 결함 수정: 1개짜리(a,b,d,e)는 원래 순서를 지킨 채 전부
      // 맨 앞 런 하나로 합쳐지고, 2개 이상인 c는 그 뒤 섹션으로 간다 —
      // 헤더 없는 단독 카드가 헤더 있는 섹션 바로 아래 와서 그 섹션
      // 소속처럼 보이는 착시를 없앤다(Sol 지적).
      expect(units, hasLength(2));
      final run = units[0] as SessionRenderRun;
      expect(run.groups, [groups[0], groups[1], groups[3], groups[4]]);
      final section = units[1] as SessionRenderSection;
      expect(section.group, groups[2]);
    });

    test('빈 목록이면 빈 목록을 돌려준다', () {
      expect(foldSessionGroupsForRender(const <SessionGroup>[]), isEmpty);
    });

    test('입력 그룹 순서를 절대 바꾸지 않는다(attention 우선 정렬을 그대로 보존)', () {
      final groups = [
        groupOf('/repo/z', 1),
        groupOf('/repo/y', 2),
        groupOf('/repo/x', 1),
      ];

      final units = foldSessionGroupsForRender(groups);

      // 이제 1개짜리(z, x)는 원래 상대 순서를 지킨 채 맨 앞 런 하나로
      // 합쳐지고, 2개짜리(y)는 그 뒤 섹션 하나로 간다 — z<x 순서가
      // 뒤바뀌었다면(정렬됐다면) 알파벳순 x,z가 됐을 것이다.
      expect(units, hasLength(2));
      expect((units[0] as SessionRenderRun).groups, [groups[0], groups[2]]);
      expect((units[1] as SessionRenderSection).group, groups[1]);
    });
  });
}
