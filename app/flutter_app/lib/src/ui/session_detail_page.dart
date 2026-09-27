/// 세션 상세 화면 — 요약(상태/프로젝트/호스트/소스/갱신 시각) + 미확인
/// 알림 타임라인 + 저장된 이벤트 이력 패널.
///
/// 위쪽 타임라인은 `SyncState.pendingAlerts`(아직 확인하지 않은 알림 전이)
/// 중 이 세션 것만 추려 보여주는 제한된 목록이다 — 확인된(이미 지나간)
/// 전이나 알림 대상이 아닌 상태 변화는 거기 나타나지 않는다
/// (`session.detail.timeline_limited_note`로 화면에도 노출). 아래쪽
/// [SessionHistory] 패널은 `GET /dashboard/events`로 서버에 보존된 이벤트
/// 이력을 커서 페이지네이션으로 읽어 그 공백을 메운다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/state/window_navigation_provider.dart';
import 'package:my_dashboard/src/ui/window_navigation_actions.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/widgets/delete_session_dialog.dart';
import 'package:my_dashboard/src/ui/widgets/relative_time.dart';
import 'package:my_dashboard/src/ui/widgets/session_card.dart'
    show projectBasename, sourceLabelKeyFor;
import 'package:my_dashboard/src/ui/widgets/session_history.dart';
import 'package:my_dashboard/src/ui/widgets/state_chip.dart';

class SessionDetailPage extends ConsumerStatefulWidget {
  const SessionDetailPage({super.key, required this.session});

  /// 목록에서 탭한 시점의 스냅샷. 그 세션이 여전히 살아 있으면
  /// [syncControllerProvider]의 최신 값으로 덮어 그린다(아래 `current`).
  final SessionViewDto session;

  @override
  ConsumerState<SessionDetailPage> createState() => _SessionDetailPageState();
}

class _SessionDetailPageState extends ConsumerState<SessionDetailPage> {
  @override
  void initState() {
    super.initState();
    // 읽음 처리(0004 seen 기능): 화면 진입 시 정확히 1회 —
    // `diagnostics_page.dart`의 `_DiagnosticsPageState.initState`가 화면
    // 진입 부수효과를 부르는 것과 같은 자리·같은 모양이다. `markSeen` 자체가
    // 낙관 갱신 + 실패 무해(lastError를 세우지 않음)를 이미 갖고 있어 여기서
    // await하거나 결과를 살필 필요가 없다.
    //
    // **왜 `Future.microtask`로 감싸는가.** `markSeen`은 `await` 전에
    // 먼저 동기적으로 `SyncController`의 상태를 낙관 갱신한다(unseen 점을
    // 즉시 끄려고). 그 동기 갱신이 `initState` 안에서 그대로 실행되면
    // `StatefulElement._firstBuild`가 아직 진행 중인 상태에서 다른
    // Provider(SyncController)의 state를 고쳐 Riverpod의
    // `_debugCanModifyProviders` 가드("Tried to modify a provider while
    // the widget tree was building")에 걸린다 — 이미 빌드를 마친 조상
    // 엘리먼트([ProviderScope])를 빌드 스코프 도중에 다시 dirty로 만들려는
    // 시도라 Flutter가 막는다. 이 화면에 진입하는 보통의 경우
    // `session.lastTransitionId`가 채워져 있어 이 분기가 실제로 실행되므로
    // 테스트에서만 나는 문제가 아니라 실사용에서도 나는 문제다. 현재
    // 빌드 스코프가 끝난 뒤(마이크로태스크)로 미루면 안전하다 — Riverpod
    // 에러 메시지가 권하는 바로 그 해법.
    Future.microtask(
      () => ref.read(syncControllerProvider.notifier).markSeen(widget.session.key),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final tokens = context.tokens;
    final controllerState = ref.watch(syncControllerProvider);
    final stillTracked = controllerState.sync.sessions.containsKey(session.key);
    final current = controllerState.sync.sessions[session.key] ?? session;
    final state = sessionStateDtoFromCode(current.state);
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    final timeline = controllerState.sync.pendingAlerts
        .where((transition) => transition.sessionKey == current.key)
        .toList()
      ..sort((a, b) => b.id.compareTo(a.id));

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        title: Text(t(ref, 'session.detail.title')),
        actions: [
          if (ref.watch(windowNavigationSupportedProvider))
            IconButton(
              icon: const Icon(Icons.open_in_new),
              tooltip: t(ref, 'window.connect'),
              onPressed: () => openSessionWindow(
                context, ref, current, configure: true, markRead: false,
              ),
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: t(ref, 'session.detail.delete_tooltip'),
            onPressed: () => _confirmAndDelete(context, current),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!stillTracked && !controllerState.sync.isFirstBoot)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                t(ref, 'session.detail.not_found'),
                style: TextStyle(color: tokens.warn, fontSize: 12),
              ),
            ),
          StateChip(state: state),
          const SizedBox(height: 16),
          _SummaryRow(
            tokens: tokens,
            label: t(ref, 'session.detail.project_label'),
            value: current.project.isNotEmpty ? current.project : current.sessionId,
          ),
          _SummaryRow(
            tokens: tokens,
            label: t(ref, 'session.detail.host_label'),
            value: current.host ?? t(ref, 'session.card.host_unknown'),
          ),
          _SummaryRow(
            tokens: tokens,
            label: t(ref, 'session.detail.source_label'),
            value: t(ref, sourceLabelKeyFor(current.source)),
          ),
          _SummaryRow(
            tokens: tokens,
            label: t(ref, 'session.detail.updated_label'),
            value: relativeTimeText(ref, nowMs: nowMs, thenMs: current.updatedAt),
          ),
          const SizedBox(height: 20),
          Text(
            t(ref, 'session.detail.timeline_title'),
            style: TextStyle(color: tokens.fg, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            t(ref, 'session.detail.timeline_limited_note'),
            style: TextStyle(color: tokens.fg2, fontSize: 11),
          ),
          const SizedBox(height: 8),
          if (timeline.isEmpty)
            Text(
              t(ref, 'session.detail.timeline_empty'),
              style: TextStyle(color: tokens.fg2, fontSize: 12),
            )
          else
            for (final transition in timeline)
              _TimelineRow(transition: transition, tokens: tokens, nowMs: nowMs),
          const SizedBox(height: 24),
          SessionHistory(key: ValueKey(current.key), sessionKey: current.key),
        ],
      ),
    );
  }

  /// AppBar 삭제 아이콘 -> 확인 다이얼로그 -> [SyncController.deleteSession].
  /// 성공했을 때만 목록으로 pop한다 — 실패하면 이미 컨트롤러가 롤백 +
  /// [SyncControllerState.lastError]로 처리했으므로(`StaleDataBanner`가
  /// 목록 화면에서 그린다) 이 화면에 남아 있어도 사용자가 실패를 알 수
  /// 있다.
  ///
  /// **왜 `Navigator`를 `await` 전에 잡아 두는가.** `deleteSession`은
  /// 응답을 기다리기 전에 세션을 상태에서 먼저 지운다(낙관 삭제). 이 화면이
  /// [SessionDeepLinkPage] 아래에 있으면 그 제거로 즉시 "not found" 화면으로
  /// 갈아끼워져 이 `State`는 네트워크 응답보다 먼저 dispose된다 — 그래서
  /// `await` 뒤의 `context.mounted` 검사는 항상 false가 되어 pop이 스킵되는
  /// 레이스가 있었다. `NavigatorState`는 이 화면이 죽어도 살아 있으므로
  /// 미리 잡아 두고 `maybePop`으로 빠져나간다(사용자가 그 사이 직접
  /// 뒤로가기를 했으면 `canPop`이 false라 no-op이다).
  Future<void> _confirmAndDelete(BuildContext context, SessionViewDto current) async {
    final navigator = Navigator.of(context);
    final title = current.project.isNotEmpty
        ? projectBasename(current.project)
        : current.sessionId;
    final confirmed = await showDeleteSessionDialog(
      context,
      ref,
      projectLabel: title,
    );
    if (!confirmed) return;
    final success = await ref
        .read(syncControllerProvider.notifier)
        .deleteSession(current.key);
    if (success) {
      navigator.maybePop();
    }
  }
}

/// T16: 알림 클릭 딥링크 진입점. payload로 오는 건 `session_key` 문자열
/// 하나뿐이라(알림 자체는 `SessionViewDto` 전체를 들고 있지 않는다),
/// 실제 [SessionViewDto]는 [syncControllerProvider]의 최신 스냅샷에서
/// 그때그때 찾는다 — 알림이 오간 사이 세션이 지워졌을 수도 있어(만료·
/// 종료 등) 못 찾으면 [SessionDetailPage]를 억지로 채우지 않고
/// `session.detail.not_found` 안내만 보여준다(예외를 던지지 않는다).
class SessionDeepLinkPage extends ConsumerWidget {
  const SessionDeepLinkPage({super.key, required this.sessionKey});

  /// 알림 payload에 실려 온 `<source>:<session_id>` 키.
  final String sessionKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final session = ref.watch(syncControllerProvider).sync.sessions[sessionKey];
    if (session == null) {
      return Scaffold(
        backgroundColor: tokens.bg,
        appBar: AppBar(title: Text(t(ref, 'session.detail.title'))),
        body: Center(
          child: Text(
            t(ref, 'session.detail.not_found'),
            style: TextStyle(color: tokens.warn),
          ),
        ),
      );
    }
    return SessionDetailPage(session: session);
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.tokens, required this.label, required this.value});

  final AppTokens tokens;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(label, style: TextStyle(color: tokens.fg2, fontSize: 12)),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(color: tokens.fg, fontSize: 13),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
        ),
      ],
    ),
  );
}

class _TimelineRow extends ConsumerWidget {
  const _TimelineRow({required this.transition, required this.tokens, required this.nowMs});

  final TransitionDto transition;
  final AppTokens tokens;
  final int nowMs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = sessionStateDtoFromCode(transition.toState);
    final timeText = relativeTimeText(ref, nowMs: nowMs, thenMs: transition.occurredAt);
    final message = transition.message;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StateChip(state: state),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message != null && message.isNotEmpty)
                  Text(message, style: TextStyle(color: tokens.fg, fontSize: 12)),
                Text(timeText, style: TextStyle(color: tokens.fg2, fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
