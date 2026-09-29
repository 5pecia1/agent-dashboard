/// 세션 목록 화면 — T15의 홈. 상단 경고 배너(설정 필요 -> staleData 시
/// [StaleDataBanner] -> 훅 구버전 시 [HookSkewBanner], 심각도 내림차순
/// — `alert_banner.dart` 파일 머리말 참고) -> "그동안 있었던 일" 패널 ->
/// 세션 카드 목록 순서로 쌓는다.
///
/// 본문 데이터는 `syncControllerProvider`(`state/sync_controller.dart`)
/// 하나에서 온다 — 세션 맵·미확인 알림·오류·단계가 전부 그 한 상태에 있다.
/// 새로고침 버튼의 비활성 판정으로 두 쿼터 컨트롤러의 loading도 본다.
/// FRB는 이 화면에서 직접 만지지 않는다(`quality_check.py boundary`).
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:my_dashboard/src/state/dashboard_extensions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/routing/app_router.dart'
    show sessionDetailRouteName;
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/diagnostics_page.dart';
import 'package:my_dashboard/src/ui/setup_page.dart';
import 'package:my_dashboard/src/ui/widgets/alert_banner.dart';
import 'package:my_dashboard/src/ui/widgets/catchup_panel.dart';
import 'package:my_dashboard/src/ui/widgets/session_card.dart';

/// 목록 화면이 지금 무엇을 그려야 하는지의 순수 판정. 위젯을 펌프하지
/// 않고도 값만으로 재현할 수 있게 뽑아 둔다(완료 기준 c: loading/error/
/// empty/stale을 위젯 테스트가 각각 override 하나로 만들어낸다).
enum SessionsScreenPhase {
  /// 첫 동기화가 아직 끝나지 않았다(스냅샷도 오류도 없음).
  loading,

  /// 첫 동기화가 오류로 끝나 보여줄 데이터가 아예 없다.
  error,

  /// 동기화는 됐지만 활성 세션이 없다.
  empty,

  /// 이전 스냅샷은 있는데 최근 동기화가 실패해 데이터가 오래됐을 수 있다.
  staleData,

  /// 정상 목록.
  ready,
}

SessionsScreenPhase sessionsScreenPhaseFor(SyncControllerState state) {
  final isFirstBoot = state.sync.isFirstBoot;
  if (isFirstBoot && state.lastError != null) return SessionsScreenPhase.error;
  if (isFirstBoot) return SessionsScreenPhase.loading;
  if (state.sync.activeSessions.isEmpty) return SessionsScreenPhase.empty;
  if (state.lastError != null) return SessionsScreenPhase.staleData;
  return SessionsScreenPhase.ready;
}

/// 세션 목록을 [SessionViewDto.project](전체 경로) 기준으로 묶은 한 그룹.
/// [sessions]는 이미 [sortedSessionsFor] 순서다 — 그룹 안 정렬은 그 정본
/// 하나만 쓴다(중복 규칙을 만들지 않는다).
class SessionGroup {
  const SessionGroup({required this.project, required this.sessions});

  /// 그룹 키 그대로의 전체 경로. 비어 있을 수 있다(프로젝트 정보가 없는
  /// 세션) — 화면은 이 경우를 `session.group.unknown_project`로 보여준다.
  final String project;

  final List<SessionViewDto> sessions;

  /// 그룹 정렬 1순위: 이 그룹에 사람이 지금 개입해야 하는(대기 중이거나
  /// 멈춘) 세션이 하나라도 있는가. `sortedSessionsFor`가 그룹 **안** 순서에
  /// 쓰는 [SessionViewDto.isAlertState]와 우연히 같은 상태 집합을 가리키지만
  /// (`done`이 push 대상에서 빠지면서 둘 다 `waiting_input`/`stalled`뿐이다)
  /// 기준의 의미 자체는 다르다 — 여기는 "지금 사람을 기다리는 그룹을 맨
  /// 위로"라는 그룹 단위 요구라 [SessionViewDto.needsAttention]이 정확히
  /// 맞다.
  bool get needsAttention => sessions.any((s) => s.needsAttention);

  /// 그룹 정렬 2순위: 그룹 안에서 가장 최근에 갱신된 세션의 시각.
  int get latestUpdatedAt =>
      sessions.map((s) => s.updatedAt).reduce((a, b) => a > b ? a : b);
}

/// 완료 기준이 요구하는 프로젝트별 그룹핑 + 그룹 정렬(순수 함수).
///
/// 그룹 정렬: "주의가 필요한 세션이 있는 그룹 우선 -> 그룹의 가장 최근
/// `updated_at` 내림차순 -> `project` 오름차순(완전 결정)". 그룹 **안**
/// 세션 순서는 별도 규칙을 만들지 않고 [sortedSessionsFor]를 그대로
/// 재사용한다.
List<SessionGroup> groupSessionsByProject(Iterable<SessionViewDto> sessions) {
  final byProject = <String, List<SessionViewDto>>{};
  for (final session in sessions) {
    (byProject[session.project] ??= <SessionViewDto>[]).add(session);
  }
  final groups = [
    for (final entry in byProject.entries)
      SessionGroup(
        project: entry.key,
        sessions: sortedSessionsFor(entry.value),
      ),
  ];
  groups.sort((a, b) {
    final aAttn = a.needsAttention ? 0 : 1;
    final bAttn = b.needsAttention ? 0 : 1;
    if (aAttn != bAttn) return aAttn.compareTo(bAttn);
    final byTime = b.latestUpdatedAt.compareTo(a.latestUpdatedAt);
    if (byTime != 0) return byTime;
    return a.project.compareTo(b.project);
  });
  return groups;
}

/// 완료 기준 (그리드): 뷰포트 폭 -> 열 수. 경계값은 흔한 폰/태블릿/데스크톱
/// 3단 구분을 그대로 옮긴 것뿐이라 별도 근거 문서는 없다 — ≤600은 완료
/// 기준이 명시한 "좁은 폭에서 1열" 경계 그 자체다(`narrow_width_test.dart`의
/// 360 뷰포트가 이 경계 안에 들어온다).
const double kSessionGridNarrowMaxWidth = 600;
const double kSessionGridMediumMaxWidth = 900;
const double kSessionGridDesktopColumnWidth = 300;
const double kSessionCardCompactExtent = 144;

int sessionGridColumnCountFor(double width) {
  if (width <= kSessionGridNarrowMaxWidth) return 1;
  if (width <= kSessionGridMediumMaxWidth) return 2;
  return (width / kSessionGridDesktopColumnWidth).floor().clamp(3, 6);
}

/// [SessionCard]는 고정 높이 위젯이 아니지만(내용에 따라 자연스레
/// 늘어난다), 그리드 칸은 전부 같은 높이를 써야 한다(완료 기준: 카드 높이
/// 통제로 그리드 균일성). 카드 내부 구성(패딩 12*2, 배지 줄, 제목,
/// host+id 줄, 메시지 2줄, 시간 줄, margin 12)을 그대로 잰 값이라
/// `session_card.dart`의 레이아웃이 바뀌면 이 값도 같이 조정해야 한다.
///
/// 칩 잘림 수정(Sol 지적)으로 맨 위 배지 줄이 `Row`에서 `Wrap`으로 바뀌면서
/// 좁은 카드 폭에서 배지들이 여러 줄로 내려갈 수 있게 됐다 — 바깥 `Wrap`
/// (state 칩 + stale 배지를 묶은 안쪽 `Wrap`, source 배지, 총 3개의 원자
/// 조각)이 최악의 경우 세 조각 전부를 각자 다른 줄로 떨어뜨릴 수 있다
/// (state 칩 한 줄 / stale 배지 한 줄 / source 배지 한 줄). 검증 리뷰
/// 지적(medium) 이전에는 "두 줄일 때"만 재고 188에서 212로만 올렸는데,
/// 그 측정이 실제 도달 가능한 최악(세 줄)을 놓쳤다 — `narrow_width_test.dart`가
/// `i18nTranslateOverride`로 i18n 키를 그대로 에코하는 관례를 쓰다 보니
/// (`(key, locale) => key`) 실제 영어 라벨("Waiting for input" 등, 가장 긴
/// state 라벨)의 길이가 만드는 줄바꿈까지는 못 봤기 때문이다.
///
/// 234로 다시 올린 근거: `UnconstrainedBox` + 실제 en 라벨 문자열로 만든
/// 임시 위젯 테스트 하네스로 `SessionCard`의 자연 높이를 직접 재
/// (`Ahem` 결정론적 테스트 폰트 기준, `flutter test` 기본값) state=idle
/// 1줄 기준선 177px, state=waiting_input(칩만, stale 없음) 2줄 203px,
/// state=waiting_input+stale(칩+stale+source 세 줄) 223px을 확인했다 —
/// 폭을 260~360 사이에서 여러 값으로 바꿔도 동일했다(구조적 상한이라 폭에
/// 민감하지 않다). 223이 실측 최댓값이고, 234는 거기에 기존 관례
/// (188→212의 +24처럼 여유를 더하는 방식)를 따라 11px의 여유를 더한
/// 값이다 — 실제 기기 폰트가 테스트 폰트(Ahem)와 미세하게 다르게 줄바꿈할
/// 여지까지 흡수한다.
const double kSessionCardGridExtent = 234;

/// [foldSessionGroupsForRender]가 [SessionGroup] 목록을 접어 내는 렌더
/// 단위 하나. `sealed`라 [_SessionGroupsView]의 `switch`가 새 변형을
/// 빠뜨리면 컴파일 타임에 잡힌다.
sealed class SessionRenderUnit {
  const SessionRenderUnit();
}

/// "세션 1개짜리" [SessionGroup]들을 헤더 없이 한 [GridView]로 흘릴 병합
/// 런. 실화면 진단: 실데이터는 프로젝트당 세션이 대부분 1개라 그룹=카드
/// 1장이 되고, 그룹마다 자기 [GridView](열 수만큼의 폭)를 새로 열다 보니
/// 화면이 "헤더+카드 1장" 세로 나열로 퇴화하고 나머지 열은 통째로 빈다 —
/// 카드에 프로젝트명·host·세션ID가 이미 있어(`session_card.dart`) 헤더가
/// 없어도 정보 손실은 없으므로, 헤더를 걷어내고 한 그리드로 합쳐 카드가
/// 갤러리처럼 가로로 흐르게 한다.
///
/// Sol 지적(그룹핑 결함): 이 런은 [groups] 안에서의 위치와 무관하게 항상
/// 화면 맨 위, 단 하나만 존재한다([foldSessionGroupsForRender] 참고) —
/// 헤더 있는 [SessionRenderSection] 바로 아래에 헤더 없는 카드가 있으면
/// 그 카드가 위 섹션 소속처럼 보이는 착시가 생기기 때문이다.
final class SessionRenderRun extends SessionRenderUnit {
  const SessionRenderRun(this.groups);

  /// 이 런을 이루는 그룹들 — 전부 `sessions.length == 1`이다. 그룹 순서는
  /// [groupSessionsByProject]가 정한 순서 그대로다(재정렬하지 않는다).
  final List<SessionGroup> groups;
}

/// 세션이 2개 이상인 [SessionGroup] 하나 — 지금처럼 프로젝트명 헤더 +
/// [GridView]로 그린다(병합 대상이 아니다: 헤더가 몇 세션인지 알려주는
/// 정보 자체가 유용하다). [foldSessionGroupsForRender]가 만드는 모든
/// [SessionRenderSection]은 유일한 [SessionRenderRun]보다 항상 뒤(아래)에
/// 온다.
final class SessionRenderSection extends SessionRenderUnit {
  const SessionRenderSection(this.group);

  final SessionGroup group;
}

/// 정렬된 [groups]를 화면이 그릴 렌더 단위 목록으로 접는다(순수 함수).
///
/// Sol 지적(그룹핑 결함): 예전 구현은 "연속으로 나오는 1개짜리 그룹만"
/// 하나의 런으로 합쳐, 헤더 있는 섹션과 헤더 없는 단독 카드가 번갈아
/// 나올 수 있었다 — 그러면 섹션 바로 아래 오는 헤더 없는 카드가 마치 그
/// 섹션 소속인 것처럼 보이는 착시가 생긴다. 이제는 [groups]를 한 번 훑어
/// 1개짜리는 전부 모아 **맨 앞에 런 하나로만**, 2개 이상은 각자
/// [SessionRenderSection]으로 **그 뒤에** 놓는다 — 헤더 없는 카드와 헤더
/// 있는 섹션이 시각적으로 다시 섞이지 않는다.
///
/// 두 부분 각각의 **안**에서는 [groups]의 순서(attention 우선 정렬,
/// `groupSessionsByProject` 문서 참고)를 전혀 건드리지 않는다 — 재정렬하지
/// 않고 속하는 부분(런/섹션)만 나눈다.
List<SessionRenderUnit> foldSessionGroupsForRender(List<SessionGroup> groups) {
  final singleGroups = <SessionGroup>[];
  final sections = <SessionRenderUnit>[];
  for (final group in groups) {
    if (group.sessions.length == 1) {
      singleGroups.add(group);
    } else {
      sections.add(SessionRenderSection(group));
    }
  }
  return [
    if (singleGroups.isNotEmpty) SessionRenderRun(singleGroups),
    ...sections,
  ];
}

class SessionsPage extends ConsumerWidget {
  const SessionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final controllerState = ref.watch(syncControllerProvider);
    final phase = sessionsScreenPhaseFor(controllerState);
    // 검증 지적(medium): 배너 표시를 phase(empty/staleData 분기) 안에
    // 가두지 않고 독립 조건으로 뽑는다 — activeSessions가 비어 있으면
    // sessionsScreenPhaseFor가 staleData보다 먼저 empty로 판정해 버리므로
    // (친절한 "세션 없음" 화면을 우선하려는 의도적 순서), 그 조합에서도
    // "최신이 아닐 수 있다"를 놓치지 않으려면 배너는 phase와 별개로
    // "첫 부팅이 아니고 마지막 동기화가 실패했다"만 보면 된다.
    final showStaleDataBanner =
        !controllerState.sync.isFirstBoot && controllerState.lastError != null;
    // 훅 스큐 배너는 동기화 성패와 무관하게 독립적으로 뜬다 — 앞의 두
    // 배너(연결 끊김/데이터 의심)와 동시에 나타날 수 있다.
    final hookSkew = controllerState.sync.hookSkew;

    final refreshing =
        controllerState.phase == SyncPhase.syncing ||
        ref.watch(dashboardExtensionRefreshingProvider);

    final children = <Widget>[
      ...ref.watch(dashboardHomeSectionsProvider),
      if (controllerState.needsSetup)
        NeedsSetupBanner(onOpenSetup: () => _openSetup(context)),
      if (showStaleDataBanner)
        // 결함 3: 마지막 스냅샷(또는 empty 화면)을 그대로 보여주는 것과
        // 별개로, "이게 최신이 아닐 수 있다"를 목록 위 얇은 배너로
        // 명시한다.
        StaleDataBanner(
          lastSuccessAtMs: controllerState.lastSuccessAtMs,
          errorDetail: controllerState.lastError?.message ?? '',
          onRetry: () =>
              ref.read(syncControllerProvider.notifier).triggerNow(force: true),
        ),
      if (hookSkew.isNotEmpty) HookSkewBanner(hookSkew: hookSkew),
      ...switch (phase) {
        SessionsScreenPhase.loading => [_LoadingView(tokens: tokens)],
        SessionsScreenPhase.error => [
          _ErrorView(tokens: tokens, controllerState: controllerState),
        ],
        SessionsScreenPhase.empty => [_EmptyView(tokens: tokens)],
        SessionsScreenPhase.staleData || SessionsScreenPhase.ready =>
          _sessionListChildren(context, controllerState),
      },
      const SizedBox(height: 16),
    ];

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        title: Text(t(ref, 'session.list.title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: t(ref, 'session.list.action.refresh'),
            onPressed: refreshing ? null : () => unawaited(_refresh(ref)),
          ),
          IconButton(
            icon: const Icon(Icons.query_stats_outlined),
            tooltip: t(ref, 'session.list.action.diagnostics'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DiagnosticsPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: t(ref, 'session.list.action.setup'),
            onPressed: () => _openSetup(context),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refresh(ref),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: children,
        ),
      ),
    );
  }

  /// staleData/ready 두 phase가 공유하는 본문 — "그동안 있었던 일" 패널 +
  /// 프로젝트별로 묶인 세션 그리드. [StaleDataBanner]는 더 이상 이 스위치
  /// 안이 아니라 `build()`에서 phase와 무관하게(empty에도) 앞세운다.
  List<Widget> _sessionListChildren(
    BuildContext context,
    SyncControllerState controllerState,
  ) => <Widget>[
    if (controllerState.sync.pendingAlerts.isNotEmpty)
      CatchupPanel(pendingAlerts: controllerState.sync.pendingAlerts),
    _SessionGroupsView(
      groups: groupSessionsByProject(controllerState.sync.activeSessions),
    ),
  ];

  void _openSetup(BuildContext context) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const SetupPage()));

  /// 새로고침 진입점(앱바 버튼과 pull-to-refresh 공용). 사용량 갱신을 먼저
  /// 시작하고 `triggerNow(force: true)`로 즉시 한 사이클을 깨운 뒤, 그
  /// 사이클이 끝날 때까지(최대 5초) 짧게 폴링해 스피너를 붙잡아 둔다 —
  /// 컨트롤러는 완료를 알리는 Future를 직접 노출하지 않는다.
  Future<void> _refresh(WidgetRef ref) async {
    final extensionRefresh = ref.read(dashboardExtensionRefreshProvider)();
    ref.read(syncControllerProvider.notifier).triggerNow(force: true);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!ref.context.mounted) return;
      if (ref.read(syncControllerProvider).phase != SyncPhase.syncing) break;
    }
    await extensionRefresh;
  }
}

class _SessionGroupsView extends StatelessWidget {
  const _SessionGroupsView({required this.groups});

  final List<SessionGroup> groups;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columnCount = sessionGridColumnCountFor(constraints.maxWidth);
        final units = foldSessionGroupsForRender(groups);
        final sections = units.whereType<SessionRenderSection>().toList();
        if (columnCount > 1 &&
            sections.isNotEmpty &&
            MediaQuery.textScalerOf(context).scale(1) <= 1.2) {
          // 데스크톱에서는 프로젝트별 묶음도 가로로 배치한다. 프로젝트마다
          // 전체 너비를 차지하면 적은 수의 세션만으로 다음 프로젝트가 화면 밖으로 밀린다.
          final projectColumns = columnCount.clamp(1, sections.length);
          return Column(
            children: [
              for (final run in units.whereType<SessionRenderRun>())
                _SessionCardGrid(
                  sessions: [for (final group in run.groups) ...group.sessions],
                  columnCount: columnCount,
                ),
              Wrap(
                children: [
                  for (final section in sections)
                    SizedBox(
                      width: constraints.maxWidth / projectColumns,
                      child: _SessionGroupSection(
                        tokens: tokens,
                        group: section.group,
                        columnCount: (columnCount / projectColumns)
                            .floor()
                            .clamp(1, columnCount),
                      ),
                    ),
                ],
              ),
            ],
          );
        }
        return Column(
          children: [
            for (final unit in units)
              switch (unit) {
                SessionRenderRun(groups: final runGroups) => _SessionCardGrid(
                  sessions: [for (final group in runGroups) ...group.sessions],
                  columnCount: columnCount,
                ),
                SessionRenderSection(:final group) => _SessionGroupSection(
                  tokens: tokens,
                  group: group,
                  columnCount: columnCount,
                ),
              },
          ],
        );
      },
    );
  }
}

class _SessionGroupSection extends StatelessWidget {
  const _SessionGroupSection({
    required this.tokens,
    required this.group,
    required this.columnCount,
  });

  final AppTokens tokens;
  final SessionGroup group;
  final int columnCount;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _SessionGroupHeader(tokens: tokens, group: group),
      _SessionCardGrid(sessions: group.sessions, columnCount: columnCount),
    ],
  );
}

/// [_SessionGroupSection]과 헤더 없는 병합 런([SessionRenderRun])이 공유하는
/// 카드 그리드 자체 — 헤더 유무만 다르고 그리드 구조(열 수 계산·카드
/// extent·shrinkWrap/`NeverScrollableScrollPhysics`)는 완전히 같다.
class _SessionCardGrid extends StatelessWidget {
  const _SessionCardGrid({required this.sessions, required this.columnCount});

  final List<SessionViewDto> sessions;
  final int columnCount;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final compact =
        MediaQuery.sizeOf(context).width > kSessionGridNarrowMaxWidth &&
        scale <= 1.2;
    return GridView.builder(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 0),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columnCount,
        mainAxisExtent:
            (compact ? kSessionCardCompactExtent : kSessionCardGridExtent) *
            scale.clamp(1.0, 3.0),
      ),
      itemCount: sessions.length,
      itemBuilder: (context, index) {
        final session = sessions[index];
        return SessionCard(
          key: ValueKey(session.key),
          session: session,
          compact: compact,
          // T-wire: 세션 상세로 가는 유일한 경로(`routing/app_router.dart`)를
          // 통해 push한다 — macOS 알림 클릭 딥링크(`app.dart`의
          // `handleNotificationTap`)와 웹 해시(`#/session/<key>`)가
          // 들어오는 라우트와 완전히 같은 라우트다.
          onTap: () => Navigator.of(
            context,
          ).pushNamed(sessionDetailRouteName(session.key)),
        );
      },
    );
  }
}

class _SessionGroupHeader extends ConsumerWidget {
  const _SessionGroupHeader({required this.tokens, required this.group});

  final AppTokens tokens;
  final SessionGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasProject = group.project.isNotEmpty;
    // 카드 제목과 같은 원칙(session_card.dart의 [projectBasename] 문서
    // 참고): 헤더는 basename만, 전체 경로는 Tooltip으로만.
    final title = hasProject
        ? projectBasename(group.project)
        : t(ref, 'session.group.unknown_project');
    final countText = t(ref, 'session.group.count', <String, String>{
      'count': '${group.sessions.length}',
    });
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Tooltip(
        message: hasProject ? group.project : title,
        child: Row(
          children: [
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: tokens.fg,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(countText, style: TextStyle(color: tokens.fg2, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _LoadingView extends ConsumerWidget {
  const _LoadingView({required this.tokens});

  final AppTokens tokens;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = t(ref, 'session.list.loading');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64),
      child: Column(
        children: [
          CircularProgressIndicator(color: tokens.accent),
          const SizedBox(height: 12),
          Text(label, style: TextStyle(color: tokens.fg2)),
        ],
      ),
    );
  }
}

class _EmptyView extends ConsumerWidget {
  const _EmptyView({required this.tokens});

  final AppTokens tokens;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
      child: Column(
        children: [
          Icon(Icons.inbox_outlined, color: tokens.fg2, size: 40),
          const SizedBox(height: 12),
          Text(
            t(ref, 'session.list.empty.title'),
            style: TextStyle(color: tokens.fg, fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            t(ref, 'session.list.empty.body'),
            style: TextStyle(color: tokens.fg2, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends ConsumerWidget {
  const _ErrorView({required this.tokens, required this.controllerState});

  final AppTokens tokens;
  final SyncControllerState controllerState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `lastError.message`는 서버/전송 계층 원문이라 번역하지 않는다 —
    // 로컬 변수로 옮겨서 `Text()`에 리터럴이 아닌 값으로 넘긴다
    // (`i18n_check.py`는 `Text('...')` 리터럴만 본다, 변수는 대상이 아니다).
    final detail = controllerState.lastError?.message ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
      child: Column(
        children: [
          Icon(Icons.error_outline, color: tokens.warn, size: 40),
          const SizedBox(height: 12),
          Text(
            t(ref, 'session.list.error.title'),
            style: TextStyle(color: tokens.fg, fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              detail,
              style: TextStyle(color: tokens.fg2, fontSize: 12),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => ref
                .read(syncControllerProvider.notifier)
                .triggerNow(force: true),
            child: Text(t(ref, 'action.retry')),
          ),
        ],
      ),
    );
  }
}
