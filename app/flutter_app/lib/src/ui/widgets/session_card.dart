/// 세션 목록 한 줄 — 상태 배지 · 프로젝트 · 호스트 · 소스 배지 · 상대
/// 시간 · 마지막 메시지 · stale/stalled 표시를 한 카드에 모은다.
///
/// FRB는 직접 만지지 않는다 — 상태 판정은 `dashboard_provider.dart`의
/// [sessionStateDtoFromCode](`state_chip.dart`가 재노출)와 [StateChip]을,
/// 신선도 판정은
/// `dashboard_provider.dart`의 [isSessionStaleFnProvider] 시임을 거친다
/// (`quality_check.py boundary`가 이 파일에서 `rust/`/FRB 직접 import를
/// 금지한다).
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart'
    show syncControllerProvider;
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/widgets/delete_session_dialog.dart';
import 'package:my_dashboard/src/ui/widgets/relative_time.dart';
import 'package:my_dashboard/src/ui/widgets/state_chip.dart';
import 'package:my_dashboard/src/util/project_path.dart';

/// [projectBasename]은 이제 `util/project_path.dart`에 산다 — 알림 제목
/// (`state/notify_provider.dart`)이 같은 규칙을 쓰게 되면서 ui/state 두
/// 계층이 공유하는 값이 됐기 때문이다(그 파일 문서 참고). 이 카드가 그
/// 이름의 역사적 출처라 기존 import 경로(`session_card.dart`)를 그대로
/// 살려 두기 위해 재노출한다 — 화면 계층 호출부는 한 줄도 바뀌지 않는다.
export 'package:my_dashboard/src/util/project_path.dart' show projectBasename;

/// `SessionViewDto.source` -> 배지 i18n 키. 표에 없는 값은 generic으로
/// 접는다(정본 `sources.registered` 밖의 값도 화면이 죽지 않아야 한다).
///
/// 정본 값은 하이픈(`contracts/dashboard-protocol.v1.json:66`의
/// `claude-code`) — i18n 키 이름 자체의 밑줄(`session.source.claude_code`)은
/// 카탈로그 식별자일 뿐이라 값과 다를 수 있다.
String sourceLabelKeyFor(String source) => switch (source) {
  'claude-code' => 'session.source.claude_code',
  'codex' => 'session.source.codex',
  'devin' => 'session.source.devin',
  'grok' => 'session.source.grok',
  'antigravity' => 'session.source.antigravity',
  _ => 'session.source.generic',
};

/// 완료 기준: 카드의 host 줄 근처에 세션 식별자 일부를 보여준다. `#` +
/// 앞 8자 — 전체 [SessionViewDto.sessionId]는 상세 화면에서 이미 보여주므로
/// 여기서는 다른 세션과 구분할 정도의 짧은 표식이면 충분하다. 8자보다
/// 짧으면(테스트 픽스처 등) 있는 만큼만 보여주고 자르지 않는다.
String sessionIdAbbreviation(String sessionId) =>
    '#${sessionId.length <= 8 ? sessionId : sessionId.substring(0, 8)}';

/// B/F 표시 보강: `working` 카드에만 "마지막 신호 N분 전" 보조
/// 라벨을 보여줄지. working이 아닌 카드는 이미 다른 문구(예: stale
/// 배지)로 충분하므로 이 라벨을 더하지 않는다.
bool showLastSignalLabelFor(SessionStateDto state) =>
    state == SessionStateDto.working;

/// 세션 하나를 그리는 카드. hover(데스크톱 마우스)로만 드러나는 우상단
/// 삭제(×) 버튼을 갖기 때문에(삭제 UI 사양) hover 자체의 켜짐/꺼짐을
/// 기억할 로컬 상태가 필요해 [ConsumerStatefulWidget]이다 — 그 전에는
/// [ConsumerWidget]이었다.
class SessionCard extends ConsumerStatefulWidget {
  const SessionCard({
    super.key,
    required this.session,
    this.onTap,
    this.compact = false,
  });

  final SessionViewDto session;
  final VoidCallback? onTap;
  final bool compact;

  @override
  ConsumerState<SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends ConsumerState<SessionCard> {
  /// 지금 마우스가 카드 위에 있는가. [MouseRegion]은 실제 마우스 장치가
  /// 있는 플랫폼(데스크톱·웹의 마우스 입력)에서만 enter/exit를 보낸다 —
  /// 터치 기기에서는 이 값이 그냥 계속 false라, 삭제 UI 사양이 요구하는
  /// "데스크톱 전용 제스처"가 플랫폼 분기 없이 저절로 성립한다.
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final onTap = widget.onTap;
    final tokens = context.tokens;
    final state = sessionStateDtoFromCode(session.state);

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // stale 판정은 **서버 시계끼리만** 비교한다(stale 판정 계약 — 정본
    // `states.detail.stalled.derivation.$note`의 화면판): 기기 시계
    // (`DateTime.now()`)도, 클라이언트 기계 시계인 `lastOccurredAt`도 쓰지
    // 않는다 — 느린 클라이언트 시계는 살아있는 세션을 즉시 stale로, 빠른
    // 시계는 죽은 세션을 영영 stale 아님으로 만드는 교차 시계 오염이기
    // 때문이다. 서버가 준 두 값만 비교한다:
    //   - `lastProgressAt`(`SessionViewDto.lastProgressAt`) — 마지막 진척
    //     신호(상태 변경·heartbeat)를 서버가 **수신한** 시각. 기록-전용
    //     이벤트는 이 값을 밀지 않는다.
    //   - `serverTime`(`SyncState.serverTime`) — 이 sync 응답을 만들 때의
    //     서버 "지금".
    // `lastProgressAt`은 additive라 구형 응답에는 없을 수 있어(nullable)
    // `updatedAt`(역시 서버 시계)으로 접는다. `staleMs`도 하드코딩 상수
    // ([kDefaultStallMs]) 대신 sync 응답이 내려주는 `stallMs`
    // (`SyncState.stallMs` — 서버의 실제 `DASHBOARD_STALL_MS`)를 그대로
    // 쓴다.
    final referenceMs = session.lastOccurredAt ?? session.updatedAt;
    final lastProgressAtMs = session.lastProgressAt ?? session.updatedAt;
    final stallMs = ref.watch(
      syncControllerProvider.select((s) => s.sync.stallMs),
    );
    final serverTimeMs = ref.watch(
      syncControllerProvider.select((s) => s.sync.serverTime),
    );
    // 읽음/안읽음(0004 seen 기능): attention 배지(아래 stale/state 칩 색)와는
    // 완전히 독립된 신호다 — 전이 id 비교뿐(시계 무관, `isSessionUnseen`
    // 문서 참고), 둘 다 동시에 켜지거나 어느 한쪽만 켜질 수 있다.
    final isUnseen = ref.watch(
      syncControllerProvider.select((s) => s.sync.isSessionUnseen(session)),
    );
    final isStale = ref.read(isSessionStaleFnProvider)(
      now: serverTimeMs,
      updatedAt: lastProgressAtMs,
      staleMs: stallMs,
    );
    // 상태가 이미 `stalled`면 배지 색으로 그 사실을 보여준다 — legacy
    // [SessionViewDto.stale]/신선도 판정과 중복 표시하지 않는다.
    final showStaleBadge =
        state != SessionStateDto.stalled && (isStale || session.stale);

    final hasProject = session.project.isNotEmpty;
    // 제목은 basename만 — 전체 경로는 [Tooltip]으로만 노출한다(Sol 요구,
    // `util/project_path.dart`의 [projectBasename] 문서 참고). project가
    // 비면 기존과 같이 sessionId 폴백을 쓴다(그때는 basename을 뽑을 대상
    // 자체가 없다). 알림 제목도 같은 함수를 쓴다 — 배너를 받고 목록을
    // 열었을 때 같은 이름을 봐야 한다(`state/notify_provider.dart`).
    final title = hasProject
        ? projectBasename(session.project)
        : session.sessionId;
    final fullProjectPath = hasProject ? session.project : session.sessionId;
    final hostText = (session.host?.isNotEmpty ?? false)
        ? session.host!
        : t(ref, 'session.card.host_unknown');
    final message = session.lastMessage;
    final messageText = (message != null && message.isNotEmpty)
        ? message
        : t(ref, 'session.card.no_message');
    final timeText = relativeTimeText(ref, nowMs: nowMs, thenMs: referenceMs);
    final sourceText = t(ref, sourceLabelKeyFor(session.source));
    final showLastSignalLabel = showLastSignalLabelFor(state);
    // 리뷰 지적(medium) 수정: "마지막 신호 N분 전"은 계약이 말하는
    // "클라이언트의 곧-멈춘-듯 표시"다 — stale 배지와 똑같이 서버 시계끼리만
    // 비교해야 한다(위 isStale 계산과 같은 근거·같은 build 안에 이미 있는
    // serverTimeMs/lastProgressAtMs를 그대로 쓴다). 기기 시계(nowMs)나
    // 클라이언트 기계 시계(referenceMs = lastOccurredAt)와는 비교하지
    // 않는다 — 그 둘의 조합이 바로 금지된 교차 시계 비교였다.
    final lastSignalTimeText = relativeTimeText(
      ref,
      nowMs: serverTimeMs,
      thenMs: lastProgressAtMs,
    );
    final lastSignalText = showLastSignalLabel
        ? t(ref, 'session.card.last_signal', {'time': lastSignalTimeText})
        : null;
    final acknowledge = state == SessionStateDto.waitingInput
        ? () =>
              ref.read(syncControllerProvider.notifier).ackSession(session.key)
        : null;

    final cardBody = Card(
      color: tokens.surface,
      margin: widget.compact
          ? const EdgeInsets.all(4)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.all(widget.compact ? 10 : 12),
          child: widget.compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (isUnseen) ...[
                          _UnseenDot(color: tokens.unseenDot),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Tooltip(
                            message: fullProjectPath,
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: tokens.fg,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 24),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Flexible(
                          flex: 2,
                          child: StateChip(state: state, onTap: acknowledge),
                        ),
                        if (showStaleBadge)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Tooltip(
                              message: t(ref, 'session.card.stale_badge'),
                              child: Icon(
                                Icons.warning_amber_rounded,
                                color: tokens.warn,
                                size: 16,
                              ),
                            ),
                          ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: _SourceBadge(tokens: tokens, text: sourceText),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Expanded(
                          child: Tooltip(
                            message:
                                '$hostText ${sessionIdAbbreviation(session.sessionId)}',
                            child: Text(
                              hostText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: tokens.fg2, fontSize: 11),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            lastSignalText ?? timeText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: tokens.fg2, fontSize: 10),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Tooltip(
                      message: messageText,
                      child: Text(
                        messageText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: tokens.fg, fontSize: 12),
                      ),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 칩 잘림 수정(Sol 지적): 이전엔 `Row`+`Spacer`라 상태 칩·
                    // stale 배지·소스 배지 폭 합이 카드 폭을 넘으면 `Flexible`이
                    // 있어도 한 줄 안에서 억지로 눌러 담다가 가장 긴 라벨(EN
                    // "Waiting for input")이 잘렸다. `Wrap`으로 바꿔 폭이
                    // 모자라면 소스 배지가 다음 줄로 자연스럽게 내려가게 한다 —
                    // `Flexible`/`Expanded`는 `Wrap`의 직계 자식으로 못 쓰므로
                    // (Flex 계열 전용) 전부 걷어내고, 칩 라벨 자체의 말줄임
                    // (`state_chip.dart`의 `Flexible`+`ellipsis`)을 최후 방어선
                    // 으로 남긴다. 한 줄에 다 들어갈 때는 `WrapAlignment.
                    // spaceBetween`이 첫 그룹(칩+stale 배지)을 왼쪽, 소스 배지를
                    // 오른쪽에 둬 기존 `Spacer` 레이아웃과 같은 모양을 만든다.
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      runSpacing: 4,
                      children: [
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          children: [
                            StateChip(
                              state: state,
                              // UserAck-impl: waiting_input 칩만 탭 가능하게
                              // 만든다 — `StateChip`이 state로 다시 한번 걸러
                              // 다른 상태에서는 이 콜백을 받아도 비대화형을
                              // 유지한다(방어적 이중 검사).
                              onTap: acknowledge,
                            ),
                            if (showStaleBadge)
                              _StaleBadge(tokens: tokens, ref: ref),
                          ],
                        ),
                        _SourceBadge(tokens: tokens, text: sourceText),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 전체 경로는 여기(Tooltip)와 session_detail_page.dart 두
                    // 곳에서만 본다 — 제목 자체는 basename까지만. 미확인(0004
                    // seen) 점은 제목 바로 앞에 둔다 — 카드의 "정체성"과 같은
                    // 줄이라 눈에 가장 먼저 들어오면서도 줄 높이는 그대로다(점이
                    // 제목 폰트 높이보다 작아 Row 높이를 밀어 올리지 않는다).
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (isUnseen) ...[
                          _UnseenDot(color: tokens.unseenDot),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Tooltip(
                            message: fullProjectPath,
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: tokens.fg,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    // 작은 host 아이콘으로 이 줄이 위 제목(디렉토리 이름)이 어느
                    // 기기에서 온 것인지를 말해준다는 관계를 시각적으로 드러낸다.
                    Row(
                      children: [
                        Icon(Icons.dns_outlined, size: 12, color: tokens.fg2),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            hostText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: tokens.fg2, fontSize: 12),
                          ),
                        ),
                        if (session.sessionId.isNotEmpty) ...[
                          const SizedBox(width: 4),
                          Text(
                            sessionIdAbbreviation(session.sessionId),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                            style: TextStyle(color: tokens.fg2, fontSize: 11),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      messageText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tokens.fg),
                    ),
                    const SizedBox(height: 6),
                    // working 카드는 이 한 줄을 "N분 전"이 아니라 "마지막 신호
                    // N분 전"으로 보여준다(완료 기준 b) — 새 줄을 더하지 않고
                    // 같은 자리를 대체하는 이유: 이 카드는 그리드의 고정
                    // `mainAxisExtent`(kSessionCardGridExtent) 안에 그려지므로,
                    // 줄을 하나 더 얹으면 좁은 화면 그리드에서 오버플로가 난다
                    // (narrow_width_test.dart가 이 회귀를 잡는다).
                    Text(
                      lastSignalText ?? timeText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tokens.fg2, fontSize: 11),
                    ),
                  ],
                ),
        ),
      ),
    );

    // 삭제 UI 사양: hover로만 드러나는 우상단 ×. `Positioned`는 `Stack`의
    // 크기에 관여하지 않으므로(비-positioned 자식인 `cardBody`가 크기를
    // 정한다) 이 오버레이가 나타나도 `kSessionCardGridExtent`(그리드 고정
    // 높이) 계산에는 아무 영향이 없다.
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.backspace): () => unawaited(
          _confirmAndDelete(context, title, session.key),
        ),
        const SingleActivator(LogicalKeyboardKey.delete): () => unawaited(
          _confirmAndDelete(context, title, session.key),
        ),
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: Stack(
          children: [
            cardBody,
            if (_hovering)
              Positioned(
                top: widget.compact ? 6 : 10,
                right: widget.compact ? 6 : 18,
                child: _DeleteHoverButton(
                  tokens: tokens,
                  tooltip: t(ref, 'session.card.delete_tooltip'),
                  onPressed: () =>
                      _confirmAndDelete(context, title, session.key),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// hover × -> 확인 다이얼로그 -> [SyncController.deleteSession].
  ///
  /// **왜 `_DeleteHoverButton` 안이 아니라 여기(`_SessionCardState`)에
  /// 있는가.** 다이얼로그가 뜨면 마우스 포인터는 그 모달 배리어 위에
  /// 있게 되고, `MouseTracker`가 다음 프레임에 같은 좌표를 다시 hit-test
  /// 해 이 카드의 [MouseRegion]에 `onExit`를 보낸다 — `_hovering`이
  /// `false`로 접히며 `_DeleteHoverButton`(과 그 안의 `ref`)이 트리에서
  /// 빠진다. 그 버튼 자신의 `ConsumerWidget.ref`로 `await` 뒤 다이얼로그
  /// 결과를 처리했다면, 다이얼로그가 열려 있던 사이 이미 unmount된
  /// `ref`를 다시 써 "widget is about to or has been unmounted"로
  /// 죽는다(위젯 테스트가 실제로 이렇게 재현했다). [SessionCard] 전체는
  /// 세션이 목록에 남아 있는 한 hover 여부와 무관하게 계속 mount돼
  /// 있으므로, 이 [State]의 `context`/`ref`를 대신 쓴다.
  Future<void> _confirmAndDelete(
    BuildContext context,
    String projectLabel,
    String sessionKey,
  ) async {
    final confirmed = await showDeleteSessionDialog(
      context,
      ref,
      projectLabel: projectLabel,
    );
    if (!confirmed || !mounted) return;
    // 낙관 제거 + 롤백은 컨트롤러 안에 있다(`deleteSession` 문서 참고) —
    // 카드는 그 결과([bool])를 몰라도 된다: 실패하면 세션이 목록에
    // 그대로/다시 보이는 것 자체가 이미 충분한 신호다.
    unawaited(
      ref.read(syncControllerProvider.notifier).deleteSession(sessionKey),
    );
  }
}

/// 미확인(0004 seen) 표시 점. `state_chip.dart`의 attention 배지와 계열이
/// 겹치지 않는 [AppTokens.unseenDot] 하나만 쓴다 — 둘은 독립적으로
/// 켜지므로 이 위젯 자체는 attention 여부를 전혀 모른다.
class _UnseenDot extends StatelessWidget {
  const _UnseenDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// 순수 버튼 껍데기 — `ref`/다이얼로그 호출은 전부 [_SessionCardState.
/// _confirmAndDelete]에 있다(그 문서의 "왜" 참고: 이 위젯 자신은 hover가
/// 꺼지는 순간 트리에서 빠져나가 unmount되므로, 비동기 콜백이 이 위젯
/// 자신의 상태를 참조하면 안전하지 않다).
class _DeleteHoverButton extends StatelessWidget {
  const _DeleteHoverButton({
    required this.tokens,
    required this.tooltip,
    required this.onPressed,
  });

  final AppTokens tokens;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: tokens.surface,
    shape: const CircleBorder(),
    elevation: 2,
    child: IconButton(
      icon: const Icon(Icons.close),
      iconSize: 16,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(),
      color: tokens.fg2,
      tooltip: tooltip,
      onPressed: onPressed,
    ),
  );
}

class _StaleBadge extends StatelessWidget {
  const _StaleBadge({required this.tokens, required this.ref});

  final AppTokens tokens;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final label = t(ref, 'session.card.stale_badge');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tokens.warn.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: TextStyle(
          color: tokens.warn,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.tokens, required this.text});

  final AppTokens tokens;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      border: Border.all(color: tokens.fg2.withValues(alpha: 0.4)),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      style: TextStyle(color: tokens.fg2, fontSize: 11),
    ),
  );
}
