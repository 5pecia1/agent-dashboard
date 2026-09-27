/// Flutter GUI 표면의 디자인 토큰 골격.
///
/// **테마 hex 리터럴은 이 파일에만 존재한다.** 위젯 코드에서 `Color(0xFF…)`
/// 를 직접 쓰지 않는다 — 항상 `Theme.of(context).extension<AppTokens>()`
/// (또는 아래 [AppTokensX.tokens] 편의 getter)를 거쳐서 토큰 이름으로
/// 참조한다. 새 색이 필요하면 여기에 토큰을 추가하고 그 토큰을 쓴다 —
/// 호출부에서 원시 hex를 새로 적지 않는다.
///
/// 색은 bg/surface/fg/fg2/accent/warn + 상태별 6개 + 그 밖의 개별 용도
/// 토큰(`unseenDot` 등)을 두는 골격이다. 실제 프로젝트는 화면이 늘어나면서
/// 필요한 토큰(예: 카드 테두리색)을 이 클래스에 계속 추가해간다.
///
/// 상태별 6개(`stateIdle`/`stateWorking`/`stateWaitingInput`/`stateDone`/
/// `stateEnded`/`stateStalled`)는 `contracts/dashboard-protocol.v1.json`의
/// `states.enum` 6종과 1:1 대응한다 — `widgets/state_chip.dart`가 상태별
/// 배지 색을 고를 때 이 토큰만 읽는다(다른 곳에서 hex를 새로 적지 않는다).
///
/// `unseenDot`은 읽음/안읽음(seen) 기능의 미확인 표시 색이다 —
/// `state_chip.dart`의 attention 배지(행동 필요)와는 독립적으로 켜지는
/// 별개 신호라 어느 상태색과도 계열이 겹치지 않게 고른다.
library;

import 'package:flutter/material.dart';

@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.bg,
    required this.surface,
    required this.fg,
    required this.fg2,
    required this.accent,
    required this.warn,
    required this.stateIdle,
    required this.stateWorking,
    required this.stateWaitingInput,
    required this.stateDone,
    required this.stateEnded,
    required this.stateStalled,
    required this.unseenDot,
  });

  /// 화면 배경.
  final Color bg;

  /// 카드/패널 등 배경 위에 떠 있는 표면.
  final Color surface;

  /// 기본 전경(본문 텍스트, 아이콘).
  final Color fg;

  /// 보조 전경 — 캡션, 비활성 라벨, 플레이스홀더.
  final Color fg2;

  /// 브랜드 강조색 — 기본 액션 버튼, 선택 상태 표시.
  final Color accent;

  /// 경고/오류 강조색.
  final Color warn;

  /// `SessionStateDto.idle` 배지 색.
  final Color stateIdle;

  /// `SessionStateDto.working` 배지 색.
  final Color stateWorking;

  /// `SessionStateDto.waitingInput` 배지 색 — push 대상 상태(사용자 입력
  /// 대기)라 눈에 띄어야 한다.
  final Color stateWaitingInput;

  /// `SessionStateDto.done` 배지 색.
  final Color stateDone;

  /// `SessionStateDto.ended` 배지 색 — 종료 상태라 저채도로 가라앉힌다.
  final Color stateEnded;

  /// `SessionStateDto.stalled` 배지 색 — push 대상 상태(멈춘 것으로 추정)라
  /// [warn]과 계열을 맞춘다.
  final Color stateStalled;

  /// 읽음/안읽음(seen) 기능의 "미확인" 점 색. `state_chip.dart`의 attention
  /// 배지(행동 필요 — `stateWaitingInput`/`stateStalled`)와는 완전히 독립된
  /// 신호라 그 두 색과도, [accent]와도 겹치지 않는 계열(청보라)을 쓴다 —
  /// 카드 하나에 두 표시가 동시에 켜져도 시각적으로 구분되어야 한다.
  final Color unseenDot;

  static const AppTokens dark = AppTokens(
    bg: Color(0xFF0A0B0D),
    surface: Color(0xFF14171C),
    fg: Color(0xFFE8EBEF),
    fg2: Color(0xFFB6BCC4),
    accent: Color(0xFF5BD16C),
    warn: Color(0xFFE08260),
    stateIdle: Color(0xFF7A828C),
    stateWorking: Color(0xFF5B8FD1),
    stateWaitingInput: Color(0xFFE0C15B),
    stateDone: Color(0xFF5BD16C),
    stateEnded: Color(0xFF4A4F57),
    stateStalled: Color(0xFFE0705B),
    unseenDot: Color(0xFFB98CE0),
  );

  static const AppTokens light = AppTokens(
    bg: Color(0xFFF4F3EE),
    surface: Color(0xFFFFFFFF),
    fg: Color(0xFF1A1A18),
    fg2: Color(0xFF3D3D39),
    accent: Color(0xFF2E8C44),
    warn: Color(0xFFBF5230),
    stateIdle: Color(0xFF6B7178),
    stateWorking: Color(0xFF2E6BB0),
    stateWaitingInput: Color(0xFF9A7B1E),
    stateDone: Color(0xFF2E8C44),
    stateEnded: Color(0xFF8A8D91),
    stateStalled: Color(0xFFB0472E),
    unseenDot: Color(0xFF7A4FB8),
  );

  @override
  AppTokens copyWith({
    Color? bg,
    Color? surface,
    Color? fg,
    Color? fg2,
    Color? accent,
    Color? warn,
    Color? stateIdle,
    Color? stateWorking,
    Color? stateWaitingInput,
    Color? stateDone,
    Color? stateEnded,
    Color? stateStalled,
    Color? unseenDot,
  }) {
    return AppTokens(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      fg: fg ?? this.fg,
      fg2: fg2 ?? this.fg2,
      accent: accent ?? this.accent,
      warn: warn ?? this.warn,
      stateIdle: stateIdle ?? this.stateIdle,
      stateWorking: stateWorking ?? this.stateWorking,
      stateWaitingInput: stateWaitingInput ?? this.stateWaitingInput,
      stateDone: stateDone ?? this.stateDone,
      stateEnded: stateEnded ?? this.stateEnded,
      stateStalled: stateStalled ?? this.stateStalled,
      unseenDot: unseenDot ?? this.unseenDot,
    );
  }

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return AppTokens(
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      fg: l(fg, other.fg),
      fg2: l(fg2, other.fg2),
      accent: l(accent, other.accent),
      warn: l(warn, other.warn),
      stateIdle: l(stateIdle, other.stateIdle),
      stateWorking: l(stateWorking, other.stateWorking),
      stateWaitingInput: l(stateWaitingInput, other.stateWaitingInput),
      stateDone: l(stateDone, other.stateDone),
      stateEnded: l(stateEnded, other.stateEnded),
      stateStalled: l(stateStalled, other.stateStalled),
      unseenDot: l(unseenDot, other.unseenDot),
    );
  }
}

/// 앰비언트 테마에서 [AppTokens]를 꺼내는 편의 getter.
///
/// extension이 설치되어 있지 않으면 [AppTokens.dark]로 폴백한다 — 테마를
/// 직접 설치하지 않은 단순 위젯 테스트도 의미 있는 색으로 렌더링되게
/// 하기 위함이다. 프로덕션 경로는 항상 [AppTheme]를 거치므로 이 폴백을
/// 타지 않는다.
extension AppTokensX on BuildContext {
  AppTokens get tokens =>
      Theme.of(this).extension<AppTokens>() ?? AppTokens.dark;
}

/// [AppTokens]를 [ThemeData]로 심는 유일한 지점.
///
/// `MaterialApp`을 비롯한 어떤 위젯도 `ThemeData`를 직접 만들지 않는다 —
/// 항상 [light]/[dark] 팩터리를 거친다. 그래야 토큰이 하나 바뀔 때 Material
/// 기본 색(`ColorScheme` 경유로 SnackBar, ProgressIndicator 등이 읽는 값)
/// 과 [AppTokens] 확장이 동시에 갱신된다.
class AppTheme {
  const AppTheme._();

  static ThemeData light() => _build(AppTokens.light, Brightness.light);

  static ThemeData dark() => _build(AppTokens.dark, Brightness.dark);

  static ThemeData _build(AppTokens tokens, Brightness brightness) {
    final onAccent = brightness == Brightness.dark
        ? Colors.black
        : Colors.white;
    final base = ThemeData(
      brightness: brightness,
      useMaterial3: true,
      scaffoldBackgroundColor: tokens.bg,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: tokens.accent,
        onPrimary: onAccent,
        secondary: tokens.accent,
        onSecondary: onAccent,
        surface: tokens.surface,
        onSurface: tokens.fg,
        error: tokens.warn,
        onError: Colors.white,
      ),
    );
    return base.copyWith(extensions: <ThemeExtension<dynamic>>[tokens]);
  }
}
