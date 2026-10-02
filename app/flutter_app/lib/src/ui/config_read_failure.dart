/// 저장된 설정을 읽지 못했을 때의 화면 — 부팅 실패 화면과 설정 화면이
/// 같은 조각([ConfigReadFailureView])을 쓴다.
///
/// **왜 첫 실행 화면으로 넘어가지 않는가.** 설정을 읽지 못한 채 화면을
/// 띄우면 동기화 커서 저장, 설정 화면의 "저장", 연동 패널의 연결 버튼 같은
/// 쓰기가 빈 값을 기준으로 파일을 다시 쓴다 — 서버 주소와 CLIENT_TOKEN이
/// 지워진다(`state/config_provider.dart`의 `ConfigLoadFn` 계약). 그래서
/// 읽을 수 있을 때까지 이 화면만 보여 주고 아무것도 쓰지 않는다.
///
/// **자동 재시도는 접근 오류만 한다.** 권한·입출력 문제는 저절로 풀릴 수
/// 있고, 다시 읽는 것은 아무것도 바꾸지 않는다. 손상된 파일은 사용자가
/// 고치거나 옮긴 뒤 "다시 시도"를 누른다. 형식을 모르는 오류도 자동으로
/// 다시 시도하지 않는다.
///
/// **자동 재시도는 "저장된 것이 없다"를 넘기지 않는다.** 접근 오류를 고치는
/// 사람은 경로에 놓인 디렉터리나 링크를 먼저 치우거나 파일을 잠시 옮긴다 —
/// 그 사이 파일이 없다. 그 순간을 첫 실행으로 받아들이면 빈 설정(빌드에
/// 기본 서버를 구운 개인 빌드는 그 기본값)으로 대시보드가 떠서, 복구가 끝나기
/// 전에 커서만 담긴 새 설정 파일을 쓸 수 있다. 그래서 자동 재시도가 빈 값을
/// 읽으면 [ConfigNothingStoredOnAutoRetry]로 멈추고 사람이 "다시 시도"를
/// 누를 때까지 기다린다. 사람이 누른 "다시 시도"가 빈 값을 읽으면 처음부터
/// 시작하겠다는 뜻으로 받아들인다.
///
/// **웹에서 브라우저가 막은 저장소는 부팅을 막지 않는다.** 쓰기도 같은
/// 저장소를 거쳐 실패하므로 실패 화면이 막아 줄 덮어쓰기가 없다. 그래서
/// 부팅만 예전처럼 저장된 설정 없이 시작하고, 그 뒤의 읽기는 그대로 실패를
/// 알린다([shouldBootWithoutStoredConfig]).
library;

import 'dart:async' show Timer, unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/capability_provider.dart'
    show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';

/// 접근 오류일 때 다시 읽는 간격 — 포그라운드 동기화 주기와 같다.
const Duration kConfigReadRetryInterval = Duration(seconds: 3);

/// 실패 안내의 최대 폭.
const double kConfigReadFailureMaxWidth = 520;

/// 경고 상자의 바탕·테두리 투명도 — 설정 화면의 권한 거부 배너와 같다.
const double _kWarnFillAlpha = 0.14;
const double _kWarnBorderAlpha = 0.5;

/// 사람이 버튼을 누르지 않아도 다시 읽어도 되는 실패인가.
bool shouldAutoRetryConfigRead(Object error) =>
    error is ConfigReadException && error.kind == ConfigReadFailureKind.access;

/// 다시 읽기. [automatic]이면 [kConfigReadRetryInterval] 타이머가 부른
/// 것이고, 아니면 사람이 "다시 시도"를 눌렀다.
typedef ConfigReadRetry = Future<void> Function({required bool automatic});

/// 자동 재시도가 읽은 값이 비어 있어 넘기지 않고 멈춘 상태. 읽기 실패가
/// 아니라 사람의 확인을 기다리는 상태다 — 화면은 이 값을 실패 자리
/// ([ConfigReadFailureView.error])에 들고 "다시 시도"를 기다린다.
@immutable
final class ConfigNothingStoredOnAutoRetry {
  const ConfigNothingStoredOnAutoRetry({required this.location});

  /// 마지막으로 읽지 못했던 위치(파일 경로나 localStorage 키). 모르면 null.
  final String? location;
}

/// 다시 읽은 [stored]를 넘기지 말아야 하면 화면이 대신 들고 있을 상태를
/// 돌려준다. 자동 재시도([automatic])가 빈 값을 읽었을 때만 그렇다 — 파일
/// 문서의 "자동 재시도는 저장된 것이 없다를 넘기지 않는다" 참고. [previous]는
/// 그 직전에 화면이 보여 주던 실패로, 위치를 이어받는다.
ConfigNothingStoredOnAutoRetry? holdEmptyAutomaticConfigRead(
  DashboardConfigValues stored, {
  required bool automatic,
  required Object previous,
}) {
  if (!automatic || !stored.isEmpty) return null;
  return ConfigNothingStoredOnAutoRetry(
    location: switch (previous) {
      ConfigReadException(:final location) => location,
      ConfigNothingStoredOnAutoRetry(:final location) => location,
      _ => null,
    },
  );
}

/// 부팅 읽기가 실패해도 실패 화면 대신 저장된 설정 없이(빈 값으로) 시작하는가.
///
/// 웹([webRuntime])에서 브라우저가 저장소를 막은 경우
/// ([ConfigReadFailureKind.access])만 그렇다 — 예전 웹 부팅과 같다. 그때는
/// 쓰기도 같은 저장소를 거쳐 실패하므로 실패 화면이 막아 줄 덮어쓰기가 없고,
/// 빌드 기본값을 구운 개인 웹 빌드는 계속 떠야 한다. 그 세션은 아무것도
/// 저장하지 못한다. 시작한 뒤의 읽기는 그대로 실패를 알린다: 패치 큐는
/// 아무것도 쓰지 않고, 설정 화면은 폼 대신 읽기 실패 안내를 보인다.
///
/// 웹이라도 저장된 값이 손상됐거나([ConfigReadFailureKind.corrupt]) 형식을
/// 모르는 오류면 실패 화면을 띄운다. 데스크톱은 모든 읽기 실패에 실패 화면을
/// 띄운다.
bool shouldBootWithoutStoredConfig(Object error, {required bool webRuntime}) =>
    webRuntime &&
    error is ConfigReadException &&
    error.kind == ConfigReadFailureKind.access;

/// 부팅이 처음 띄울 루트를 고른다. 읽으면 [dashboard], 못 읽으면
/// [ConfigReadFailureApp]이다 — 다시 읽기에 성공하면 그 화면이
/// [replaceRoot]로 대시보드 루트를 넘긴다(운영에서는 `runApp`). 웹
/// ([webRuntime])에서 브라우저가 저장소를 막았으면 실패 화면 없이 빈 값으로
/// [dashboard]를 부른다([shouldBootWithoutStoredConfig]).
///
/// 그 밖에는 [dashboard]를 읽기에 성공한 뒤에만 부른다. 빌드에 구운 기본값을
/// 채우는 조립(`main.dart`의 `configure`)도 그 안에 있으므로, 기본값이 읽지
/// 못한 저장소를 가려 "설정됨"처럼 보이게 하지 못한다.
Future<Widget> buildBootRoot({
  required ConfigLoadFn load,
  required Widget Function(DashboardConfigValues stored) dashboard,
  required void Function(Widget root) replaceRoot,
  bool webRuntime = false,
}) async {
  final DashboardConfigValues stored;
  try {
    stored = await load();
  } on Object catch (error) {
    if (shouldBootWithoutStoredConfig(error, webRuntime: webRuntime)) {
      // catch 안의 조립 실패는 이 try가 잡지 않는다 — 읽기 실패가 아니다.
      return dashboard(DashboardConfigValues.empty);
    }
    return ConfigReadFailureApp(
      error: error,
      load: load,
      onLoaded: (values) => replaceRoot(dashboard(values)),
    );
  }
  // try 밖에서 조립한다 — 조립 실패는 읽기 실패가 아니다.
  return dashboard(stored);
}

/// 읽기 실패 안내 상자: 제목, "아무것도 바꾸지 않았다", 종류별 안내, 위치와
/// OS·파서 메시지, "다시 시도" 버튼.
///
/// 접근 오류면 [kConfigReadRetryInterval]마다 [onRetry]를 `automatic: true`로
/// 스스로 부른다. 타이머는 하나만 걸고 끝까지 둔다 — 부모가 다시 그려도
/// 재시도가 미뤄지지 않고, 같은 예외 객체가 매번 다시 던져져도 계속 돈다.
/// 진행 중인 시도가 있거나 지금 오류가 자동 재시도 대상이 아니면 그 틱은
/// 건너뛴다.
class ConfigReadFailureView extends ConsumerStatefulWidget {
  const ConfigReadFailureView({
    super.key,
    required this.error,
    required this.onRetry,
  });

  /// 마지막 실패. [ConfigReadException]이면 위치와 메시지를, 그 밖의 오류는
  /// 형식 이름만 보여 준다 — `toString()`이 원문(토큰 포함)을 실을 수 있다.
  /// [ConfigNothingStoredOnAutoRetry]면 위치와 "지금은 아무것도 없다"는
  /// 안내를 보인다.
  final Object error;

  /// 다시 읽는다. 결과(성공이든 새 실패든)는 부모가 [error]로 다시 넘긴다.
  final ConfigReadRetry onRetry;

  @override
  ConsumerState<ConfigReadFailureView> createState() =>
      _ConfigReadFailureViewState();
}

class _ConfigReadFailureViewState extends ConsumerState<ConfigReadFailureView> {
  late final Timer _autoRetry;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _autoRetry = Timer.periodic(kConfigReadRetryInterval, (_) {
      if (_retrying || !shouldAutoRetryConfigRead(widget.error)) return;
      unawaited(_retry(automatic: true));
    });
  }

  @override
  void dispose() {
    _autoRetry.cancel();
    super.dispose();
  }

  Future<void> _retry({required bool automatic}) async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry(automatic: automatic);
    } on Object {
      // 부모가 실패를 [ConfigReadFailureView.error]로 돌려준다. 부모가 놓친
      // 예외라도 여기서는 버튼만 다시 연다.
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final error = widget.error;
    final hintKey = switch (error) {
      ConfigReadException(kind: ConfigReadFailureKind.access) =>
        'config.read_failed.access_hint',
      // 브라우저에는 옮길 파일이 없다 — 저장소 항목을 지우는 길을 알린다.
      ConfigReadException(kind: ConfigReadFailureKind.corrupt) =>
        ref.watch(isWasmRuntimeProvider)
            ? 'config.read_failed.corrupt_hint_web'
            : 'config.read_failed.corrupt_hint',
      ConfigNothingStoredOnAutoRetry() =>
        'config.read_failed.nothing_stored_hint',
      _ => null,
    };
    final detail = switch (error) {
      ConfigReadException(:final location, :final detail) =>
        '$location\n$detail',
      ConfigNothingStoredOnAutoRetry(:final location) => location,
      _ => '${error.runtimeType}',
    };
    final bodyStyle = TextStyle(color: tokens.fg, fontSize: 13);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tokens.warn.withValues(alpha: _kWarnFillAlpha),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: tokens.warn.withValues(alpha: _kWarnBorderAlpha),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, color: tokens.warn, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t(ref, 'config.read_failed.title'),
                  style: TextStyle(
                    color: tokens.warn,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(t(ref, 'config.read_failed.body'), style: bodyStyle),
          if (hintKey != null) ...[
            const SizedBox(height: 4),
            Text(t(ref, hintKey), style: bodyStyle),
          ],
          if (detail != null) ...[
            const SizedBox(height: 8),
            SelectableText(
              detail,
              style: TextStyle(color: tokens.fg2, fontSize: 12),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _retrying ? null : () => _retry(automatic: false),
            child: Text(t(ref, 'action.retry')),
          ),
        ],
      ),
    );
  }
}

/// [ConfigReadFailureView]를 가운데에 좁게 놓는다. 부팅 화면과 설정 화면이
/// 같은 배치를 쓴다.
class ConfigReadFailurePane extends StatelessWidget {
  const ConfigReadFailurePane({
    super.key,
    required this.error,
    required this.onRetry,
    this.footer,
  });

  final Object error;
  final ConfigReadRetry onRetry;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final footer = this.footer;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: kConfigReadFailureMaxWidth,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConfigReadFailureView(error: error, onRetry: onRetry),
              if (footer != null) ...[const SizedBox(height: 12), footer],
            ],
          ),
        ),
      ),
    );
  }
}

/// 부팅 때 설정을 읽지 못하면 대시보드 대신 띄우는 화면.
///
/// 다시 읽기에 성공하면 [onLoaded]를 **먼저** 부르고 그다음 빈 바탕으로
/// 바뀐다 — [onLoaded]가 던지면(대시보드 조립 실패) 화면은 그대로 남아 그
/// 오류의 형식 이름을 보여 주고, 읽기 실패가 아니므로 자동 재시도도 멈춘다.
/// 넘긴 뒤에는 다시 읽지도, [onLoaded]를 다시 부르지도 않는다. 자동 재시도가
/// 빈 값을 읽으면 넘기지 않는다([holdEmptyAutomaticConfigRead]).
class ConfigReadFailureScreen extends ConsumerStatefulWidget {
  const ConfigReadFailureScreen({
    super.key,
    required this.error,
    required this.load,
    required this.onLoaded,
  });

  final Object error;
  final ConfigLoadFn load;
  final void Function(DashboardConfigValues stored) onLoaded;

  @override
  ConsumerState<ConfigReadFailureScreen> createState() =>
      _ConfigReadFailureScreenState();
}

class _ConfigReadFailureScreenState
    extends ConsumerState<ConfigReadFailureScreen> {
  late Object _error = widget.error;
  bool _handedOver = false;

  Future<void> _retry({required bool automatic}) async {
    if (_handedOver) return;
    final DashboardConfigValues stored;
    try {
      stored = await widget.load();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
      return;
    }
    if (!mounted || _handedOver) return;
    final held = holdEmptyAutomaticConfigRead(
      stored,
      automatic: automatic,
      previous: _error,
    );
    if (held != null) {
      setState(() => _error = held);
      return;
    }
    try {
      widget.onLoaded(stored);
    } on Object catch (error) {
      setState(() => _error = error);
      return;
    }
    setState(() => _handedOver = true);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // 넘긴 뒤에는 안내와 그 타이머를 내려놓는다 — 다음 `runApp`이 이 트리를
    // 떼어 낼 때까지 빈 바탕만 남는다.
    if (_handedOver) return ColoredBox(color: tokens.bg);
    return Scaffold(
      backgroundColor: tokens.bg,
      body: SafeArea(
        child: ConfigReadFailurePane(
          error: _error,
          onRetry: _retry,
          footer: Text(
            t(ref, 'config.read_failed.boot_note'),
            style: TextStyle(color: tokens.fg2, fontSize: 12),
          ),
        ),
      ),
    );
  }
}

/// 부팅 실패 화면의 루트. 대시보드 루트와 **다른 위젯 형식**이어야 한다 —
/// 두 번째 `runApp`은 새 루트를 이전 루트와 같은 형식·키면 제자리에서 갱신
/// 하는데, `ProviderScope`가 제자리 갱신되면 override 목록이 바뀐 컨테이너를
/// 그대로 쓰려다 실패한다. 형식이 다르면 이 트리를 통째로 내리고 대시보드를
/// 새로 붙인다.
///
/// 자기 `ProviderScope`를 갖고 부팅 전용 override를 쓰지 않는다. 저장된
/// 테마·언어를 읽지 못했으므로 시스템 테마와 언어를 따른다.
class ConfigReadFailureApp extends StatelessWidget {
  const ConfigReadFailureApp({
    super.key,
    required this.error,
    required this.load,
    required this.onLoaded,
  });

  final Object error;
  final ConfigLoadFn load;
  final void Function(DashboardConfigValues stored) onLoaded;

  @override
  Widget build(BuildContext context) => ProviderScope(
    child: _ConfigReadFailureMaterialApp(
      error: error,
      load: load,
      onLoaded: onLoaded,
    ),
  );
}

class _ConfigReadFailureMaterialApp extends ConsumerWidget {
  const _ConfigReadFailureMaterialApp({
    required this.error,
    required this.load,
    required this.onLoaded,
  });

  final Object error;
  final ConfigLoadFn load;
  final void Function(DashboardConfigValues stored) onLoaded;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
    title: t(ref, 'app.title'),
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    debugShowCheckedModeBanner: false,
    home: ConfigReadFailureScreen(error: error, load: load, onLoaded: onLoaded),
  );
}
