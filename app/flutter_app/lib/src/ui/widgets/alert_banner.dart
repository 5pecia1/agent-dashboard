/// 화면 상단 경고 배너.
///
/// `sessions_page.dart`가 이 순서(심각도 내림차순)로 쌓는다: 연결 끊김
/// ([NeedsSetupBanner]) > 데이터 의심([StaleDataBanner]) > 일부 기계
/// 낡음([HookSkewBanner]).
///
/// [NeedsSetupBanner] — `SyncControllerState.needsSetup`(401/403으로 멈춘
/// 상태)일 때 설정 화면으로 유도한다.
///
/// [StaleDataBanner] — 첫 부팅이 아니고 마지막 동기화가 실패했을 때(활성
/// 세션이 있어 `SessionsScreenPhase.staleData`든, 없어서 `empty`든 무관하게)
/// 목록/빈 화면 위에서 "지금 보이는 게 최신이 아닐 수 있다"를 알린다.
///
/// [HookSkewBanner] — 서버 sync 응답의 `hook_skew`(`SyncState.hookSkew`)가
/// 비어 있지 않을 때, 구버전 훅을 돌리는 기계 목록을 알린다. 동기화 자체는
/// 정상이라 앞의 두 배너와 별개로 뜬다(동시에 뜰 수 있다).
///
/// 색은 [AppTokens.warn]만 쓴다(`quality_check.py theme`).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/config_provider.dart'
    show dashboardConfigValuesProvider;
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/widgets/relative_time.dart';
import 'package:my_dashboard/src/ui/widgets/session_card.dart'
    show projectBasename;

class _Banner extends StatelessWidget {
  const _Banner({
    required this.title,
    required this.body,
    this.titleTrailing,
    this.action,
  });

  final String title;

  /// 본문. 대부분은 [Text] 하나지만 [StaleDataBanner]처럼 여러 줄(마지막
  /// 동기화 시각 + 오류 요지)을 쌓아야 하는 배너도 있어 `Widget`으로 받는다.
  final Widget body;

  /// 제목과 **같은 줄**에 붙는 보조 action — [HookSkewBanner]의 복사
  /// 아이콘처럼 본문 아래 별도 줄(아래 [action])이 아니라 제목 옆에 있어야
  /// 자연스러운 것을 위한 자리다. null이면 제목 줄은 지금까지와 완전히
  /// 동일하게 그려진다(다른 두 배너는 이 슬롯을 안 쓰므로 영향이 없다).
  final Widget? titleTrailing;

  /// 본문 아래 별도 줄에 붙는 action. [NeedsSetupBanner]/[StaleDataBanner]
  /// 가 쓴다 — [titleTrailing]과는 다른 자리다.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final titleStyle = TextStyle(
      color: tokens.warn,
      fontWeight: FontWeight.w700,
      fontSize: 13,
    );
    // titleTrailing이 있을 때만 제목을 한 줄로 조이고 넘치면 말줄임한다 —
    // 옆에 아이콘이 붙어 폭이 줄어든 만큼, 좁은 화면(모바일 1열)에서
    // 제목이 아이콘을 밀어내며 overflow하는 대신 제목 쪽이 먼저 줄어들게
    // 한다. titleTrailing이 없는 기존 두 배너는 이 분기를 안 타므로
    // 지금까지와 동일하게(줄바꿈 허용) 그려진다.
    final titleText = titleTrailing == null
        ? Text(title, style: titleStyle)
        : Text(
            title,
            style: titleStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tokens.warn.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tokens.warn.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: tokens.warn, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                titleTrailing == null
                    ? titleText
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Flexible(child: titleText),
                          const SizedBox(width: 4),
                          titleTrailing!,
                        ],
                      ),
                const SizedBox(height: 2),
                body,
                if (action != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: action,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 동기화가 401/403으로 멈췄을 때(재시도해도 소용없는 상태) 설정 화면으로
/// 유도한다.
class NeedsSetupBanner extends ConsumerWidget {
  const NeedsSetupBanner({super.key, this.onOpenSetup});

  final VoidCallback? onOpenSetup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    return _Banner(
      title: t(ref, 'alert.banner.needs_setup.title'),
      body: Text(
        t(ref, 'alert.banner.needs_setup.body'),
        style: TextStyle(color: tokens.fg, fontSize: 12),
      ),
      action: onOpenSetup == null
          ? null
          : Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: onOpenSetup,
                child: Text(t(ref, 'alert.banner.needs_setup.action')),
              ),
            ),
    );
  }
}

/// 첫 부팅이 아닌데 최근 동기화가 실패해(`SyncControllerState.lastError`)
/// 화면이 오래됐을 수 있을 때(`sessions_page.dart`의
/// `showStaleDataBanner` — activeSessions가 있어 staleData든 없어서
/// empty든 phase와 무관하다) 목록/빈 화면 위에 얇게 띄운다. 화면이 죽지
/// 않고 마지막 상태를 계속 보여주는 것과 별개로, "이게 최신이 아닐 수
/// 있다"를 명시적으로 알리는 게 이 배너의 역할이다.
class StaleDataBanner extends ConsumerWidget {
  const StaleDataBanner({
    super.key,
    required this.lastSuccessAtMs,
    required this.errorDetail,
    this.onRetry,
  });

  /// `SyncControllerState.lastSuccessAtMs` — 이번 세션에서 아직 한 번도
  /// 성공하지 못했으면 null(예: 이전에 저장된 커서로 재시작했는데 첫
  /// 사이클부터 실패한 경우 — `sessions_page.dart`의 staleData 판정이
  /// "성공한 적 있음"을 전제하지 않는다).
  final int? lastSuccessAtMs;

  /// `SyncControllerState.lastError?.message` — 서버/전송 계층 원문이라
  /// `_ErrorView`와 마찬가지로 번역하지 않는다.
  final String errorDetail;

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final syncedAtMs = lastSuccessAtMs;
    final lastSyncedText = syncedAtMs == null
        ? t(ref, 'alert.banner.stale_data.never_synced')
        : t(ref, 'alert.banner.stale_data.last_synced', {
            'time': relativeTimeText(ref, nowMs: nowMs, thenMs: syncedAtMs),
          });
    return _Banner(
      title: t(ref, 'alert.banner.stale_data.title'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            lastSyncedText,
            style: TextStyle(color: tokens.fg, fontSize: 12),
          ),
          if (errorDetail.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              errorDetail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tokens.fg2, fontSize: 11),
            ),
          ],
        ],
      ),
      action: onRetry == null
          ? null
          : Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: onRetry,
                child: Text(t(ref, 'action.retry')),
              ),
            ),
    );
  }
}

/// [HookSkewDto] 한 항목의 표시 문구 — `"host (project basename)"`, project가
/// null이면 host만. devcontainer 등 host명이 무작위 hex라 그것만으로는 어느
/// 기계인지 식별 불가한 경우를 위해 프로젝트명을 병기한다.
String hookSkewLabel(HookSkewDto skew) {
  final project = skew.project;
  if (project == null || project.isEmpty) return skew.host;
  return '${skew.host} (${projectBasename(project)})';
}

/// 훅 업데이트 명령 전문. `QUICKSTART.md`("기계 연결 — 기계마다 한 번, 한
/// 줄") 코드블록의 한 줄과 **글자 하나까지 같아야 한다** — 사람이 문서를
/// 보고 직접 친 명령과 이 배너에서 복사한 명령이 다르면 안 되기 때문이다.
/// [serverUrl] 끝에 슬래시가 있어도 `//setup.sh`(더블 슬래시)가 되지 않게
/// 벗겨내는 정규화만 한다 — 그 외 가공은 하지 않는다. `hookSkewLabel`처럼
/// 값만으로 재현 가능한 순수 함수로 뽑아 판정 없이 문자열만 조립한다.
String hookSkewUpdateCommand(String serverUrl) {
  final base = serverUrl.endsWith('/')
      ? serverUrl.substring(0, serverUrl.length - 1)
      : serverUrl;
  return 'curl -fsSL $base/setup.sh | bash';
}

/// `SyncState.hookSkew`(sync 응답 최상위 `hook_skew`, 매 응답 절대값)가
/// 비어 있지 않을 때 뜬다 — 서버가 지금 서빙 중인 훅과 다른(구버전) 훅을
/// 돌리는 기계가 있다는 뜻이다. 명령 전문은 QUICKSTART에 이미 있으므로
/// 여기서는 host(+식별용 프로젝트명) 목록과 짧은 안내만 보여준다(각 항목의
/// 리비전 값은 판정에만 쓰이고 화면에는 드러내지 않는다).
///
/// **왜 `serverUrl`을 생성자로 받지 않고 여기서 직접 읽는가.**
/// `sessions_page.dart`는 `syncControllerProvider` 하나만 watch한다는
/// 문서화된 계약이 있어(파일 머리말 참고) 그 화면 쪽에 새 provider 읽기를
/// 얹고 싶지 않다. 이 배너는 이미 `ConsumerWidget`이라 자기 `ref`로
/// `dashboardConfigValuesProvider`(부팅 스냅샷, `config_provider.dart`)를
/// 직접 읽는 쪽이 호출부를 건드리지 않는다. 그 provider는 override 없이
/// 읽으면 던지는 계약이라 이 배너를 펌프하는 위젯 테스트(`alert_banner_
/// test.dart`, `sessions_page_test.dart`)는 전부 그 provider를
/// override해야 한다.
class HookSkewBanner extends ConsumerWidget {
  const HookSkewBanner({super.key, required this.hookSkew});

  /// `SyncState.hookSkew` 그대로. 호출자(`sessions_page.dart`)가 빈
  /// 리스트가 아닐 때만 이 위젯을 넣는다.
  final List<HookSkewDto> hookSkew;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final hosts = hookSkew.map(hookSkewLabel).join(', ');
    final serverUrl = ref.watch(dashboardConfigValuesProvider).serverUrl;
    return _Banner(
      title: t(ref, 'alert.banner.hook_skew.title'),
      body: Text(
        t(ref, 'alert.banner.hook_skew.body', {'hosts': hosts}),
        style: TextStyle(color: tokens.fg, fontSize: 12),
      ),
      // serverUrl이 없으면 복사할 명령을 만들 수 없다 — 눌러도 아무 일도
      // 안 일어나는 거짓 버튼을 두느니 아이콘 자체를 안 그린다. 이 아이콘은
      // 제목과 같은 줄에 붙어야 자연스러워 (본문 아래 별도 줄인) `action`이
      // 아니라 `titleTrailing`에 꽂는다.
      titleTrailing: (serverUrl == null || serverUrl.isEmpty)
          ? null
          : _CopyUpdateCommandButton(
              command: hookSkewUpdateCommand(serverUrl),
              tooltip: t(ref, 'alert.banner.hook_skew.copy_tooltip'),
              copiedTooltip: t(ref, 'alert.banner.hook_skew.copied'),
            ),
    );
  }
}

/// 훅 업데이트 명령을 클립보드로 복사하는 아이콘. 제목과 같은 줄
/// (`_Banner.titleTrailing`)에 붙으므로 제목 줄 높이를 키우면 안 된다 —
/// `TextButton`/`IconButton` 기본 크기는 제목(13px 텍스트)보다 훨씬 커서
/// 줄 높이를 그대로 쓰면 배너가 불필요하게 두꺼워진다. `constraints`/
/// `padding`/`visualDensity`를 모두 조여, `session_card.dart`의
/// `_DeleteHoverButton`처럼 인라인에 맞는 컴팩트한 `IconButton`으로 만든다
/// (다만 그쪽은 호버 전용 원형 버튼이라 `Material`/`CircleBorder`까지
/// 쓰지만, 여긴 상시 노출되는 제목 줄 안이라 그 장식은 필요 없다). 탭
/// 영역은 `constraints`로 28x28까지만 줄인다 — 아이콘 자체(18px)보다는
/// 넉넉해 모바일에서도 누르기 어렵지 않다. 색은 이제 본문(`tokens.fg`)이
/// 아니라 제목과 같은 `tokens.warn`을 쓴다.
///
/// 눌러도 화면이 조용하면 복사됐는지 알 길이 없다. 이 코드베이스에 복사
/// 피드백 선례가 없고(`setup_page.dart`의 `_statusMessage`는 이 배너처럼
/// 짧게 스쳐 지나가는 자리에 놓기엔 너무 무겁다), `SnackBar`도 선례가 없어
/// 새로 들이지 않는다. 대신 아이콘을 잠깐 체크 표시로 바꾸고 툴팁 문구도
/// "복사됨"으로 바꿔치기했다가 원래대로 되돌린다.
class _CopyUpdateCommandButton extends StatefulWidget {
  const _CopyUpdateCommandButton({
    required this.command,
    required this.tooltip,
    required this.copiedTooltip,
  });

  final String command;
  final String tooltip;
  final String copiedTooltip;

  @override
  State<_CopyUpdateCommandButton> createState() =>
      _CopyUpdateCommandButtonState();
}

class _CopyUpdateCommandButtonState extends State<_CopyUpdateCommandButton> {
  /// 체크 표시로 바뀐 상태인지. 위젯이 사라진 뒤 타이머가 돌아와
  /// `setState`를 부르면 안 되므로 매번 `mounted`를 확인한다.
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.command));
    if (!mounted) return;
    setState(() => _copied = true);
    // 체크 표시를 계속 두면 "복사됐다"가 아니라 "이 버튼은 원래 체크
    // 아이콘"처럼 보인다 — 잠깐만 보여주고 원래 아이콘으로 되돌린다.
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // 제목 줄(Row) 안이라 `Align(centerLeft)`는 더 이상 의미가 없다(Row가
    // 이미 왼쪽부터 채운다) — 지웠다.
    //
    // `IconButton`은 `constraints`를 아무리 조여도 기본 탭 영역 관행상
    // 제목 한 줄(13px 굵은 텍스트, 실측 19px)보다 높아 Row 높이를
    // 키운다 — 대신 `InkWell`로 아이콘만 감싼다. Flutter는 위젯이 부모에게
    // 보고한 레이아웃 크기 밖에서는 탭을 인식하지 않으므로(시각적으로만
    // 넘치게 그리는 트릭은 탭 인식에는 효과가 없다), 높이는 세로 padding을
    // 아이콘(15) + 위아래 2씩 = 19로 묶어 제목 텍스트 높이와 **정확히**
    // 맞추고, 그 대신 가로 padding만 넉넉히(6씩) 줘서 세로는 그대로 두고
    // 가로로만 탭 영역을 넓힌다 — 폭까지 줄이면 손가락으로 누르기엔 너무
    // 좁아진다.
    return Tooltip(
      message: _copied ? widget.copiedTooltip : widget.tooltip,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: _copy,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Icon(
              _copied ? Icons.check_outlined : Icons.copy_outlined,
              size: 15,
              color: tokens.warn,
            ),
          ),
        ),
      ),
    );
  }
}
