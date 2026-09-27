/// 서버 주소·CLIENT_TOKEN·동기화 커서를 앱 재시작 사이에 남기는 시임.
///
/// `dashboard_api.dart`(T12)의 `dashboardApiConfigProvider`/
/// `httpSendProvider`는 이미 "빌드에 아무것도 굽지 않는다"는 계약을 갖고
/// 있다 — CLIENT_TOKEN이 소스에 없다. 이 파일은 그 값들을 어디서 읽어와
/// 채우는지를 맡는다: 데스크톱은 `~/.local/state/my-dashboard/config.json`
/// 파일(hook_contract의 스풀 경로와 같은 디렉터리 — `config_store_io.dart`
/// 문서 참고), 웹은 `window.localStorage`.
///
/// 동기화 커서(`sync_reducer.dart`의 `SyncState.cursor`)도 같은 저장소에
/// 얹는다 — 앱을 다시 켰을 때 스냅샷 전체를 다시 받지 않고 `since=`로
/// 이어받게 하기 위해서다. 커서를 다시 상태로 되살리는 규칙(손상된 값 처리
/// 포함)은 이미 `sync_reducer.dart`의 [restoreState]/[parseCursor]가 갖고
/// 있다 — 이 파일은 그 함수들이 원하는 `Object?` 원값을 저장·복원하기만
/// 한다(스스로 검증하지 않는다 — 검증은 정본이 하나만 갖는다).
///
/// `capability_provider.dart`와 같은 3계층을 읽기/쓰기 두 함수 각각에
/// 반복한다. 읽기·쓰기가 파일/localStorage IO라 함수 모양이 `Future`를
/// 돌리는 것만 `capabilityCheckFnProvider`(동기 FRB 호출)와 다르다 —
/// `dashboard_api.dart`의 `HttpSendFn`과 같은 자리다.
library;

import 'package:flutter/foundation.dart' show immutable;
import 'package:collection/collection.dart' show DeepCollectionEquality;
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override`는 `.overrideWithValue()`의 실제 반환 타입이지만
// `flutter_riverpod`의 barrel export 목록에는 없다 — 정본 위치인
// `package:riverpod/misc.dart`에서 이름만 가져온다(riverpod은
// flutter_riverpod의 전이 의존성이라 `depend_on_referenced_packages`
// info가 뜨지만, 함수 반환 타입에 이름을 직접 써야 해서 타입 추론만으로는
// 피할 수 없다 — `http_provider.dart`의 `httpSendProviderOverride`처럼
// 변수 선언이었다면 추론으로 피했을 것이다).
import 'package:riverpod/misc.dart' show Override;

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/state/config_store_io.dart'
    if (dart.library.js_interop) 'package:my_dashboard/src/state/config_store_web.dart'
    as bridge;

// ─── 값 ──────────────────────────────────────────────────────────────────

/// TASK D-app (A안 설계 ④): 상주 동작의 기본값은 **켜짐**이다 — 이 앱이
/// macOS 알림 배너의 단일 소유자라(별도 상주 데몬 없음) 창을 닫는 순간
/// 알림이 끊기면 제품이 성립하지 않는다. 사용자가 명시적으로 끄면 그때만
/// 마지막 창을 닫을 때 앱이 종료된다.
const bool kResidentDefault = true;

/// 재시작 사이에 남기는 값 전부. 셋 다 없어도(첫 실행) 정상이다 — 화면이
/// 서버 주소/토큰 입력을 유도하고, 커서가 없으면 다음 sync가 스냅샷을 준다.
@immutable
class DashboardConfigValues {
  const DashboardConfigValues({
    this.serverUrl,
    this.clientToken,
    this.cursor,
    this.resident,
    this.themeMode,
    this.seenWatermark,
    this.uiLang,
    this.extra = const <String, Object?>{},
  });

  /// 예: `https://api.example.workers.dev`.
  final String? serverUrl;

  /// 정본 `auth.tokens.CLIENT_TOKEN`.
  final String? clientToken;

  /// JSON fields owned by other application compositions or future versions.
  /// Values are retained without interpreting or logging their contents.
  final Map<String, Object?> extra;

  /// `sync_reducer.dart`의 `SyncState.cursor`. 원값 그대로 저장하고, 복원할
  /// 때는 [restoreState]/[parseCursor]가 유효성을 검증한다 — 여기서
  /// 다시 검증하지 않는다.
  final int? cursor;

  /// TASK D-app (A안 설계 ④): "창을 닫아도 백그라운드 유지". null이면
  /// 아직 한 번도 정하지 않았다는 뜻이고, 그때의 동작은 [kResidentDefault]
  /// (켜짐)다 — 이 필드가 생기기 전에 저장된 `config.json`도 그 기본값으로
  /// 읽히므로 기존 사용자의 동작이 바뀌지 않는다.
  final bool? resident;

  /// 테마 모드 선택 — `'system'`/`'light'`/`'dark'` 중 하나를 원값 그대로
  /// 저장한다. 파싱·기본값 규칙(정본)은 `state/theme_mode_provider.dart`의
  /// [parseThemeMode]가 갖고 있다 — 여기서는 검증하지 않는다(다른 필드와
  /// 같은 태도, [cursor] 문서 참고). null이면 아직 한 번도 고르지 않았다는
  /// 뜻이고 시스템 설정을 따른다.
  final String? themeMode;

  /// `sync_reducer.dart`의 `SyncState.seenWatermark`(읽음/안읽음 "첫 도입
  /// 미확인 벽"). [cursor]와 같은 태도로 원값 그대로 저장·복원한다 — 검증은
  /// [restoreState]/[parseCursor]가 한다(리뷰 지적 high 수정: 이 값이
  /// 영속화되지 않으면 재기동마다 벽이 다시 서서 이미 확인한 세션이 전부
  /// 재차 미확인으로 뜬다).
  final int? seenWatermark;

  /// UI 표시 언어 선택 — `'system'`/`'ko'`/`'en'` 중 하나를 원값 그대로
  /// 저장한다(테마 모드와 정확히 같은 3값 모양). 파싱·기본값 규칙(정본)은
  /// `state/ui_lang_provider.dart`의 [parseUiLang]이 갖고 있다 — 여기서는
  /// 검증하지 않는다(다른 필드와 같은 태도, [cursor] 문서 참고). null이면
  /// 아직 한 번도 고르지 않았다는 뜻이고 시스템 설정을 따른다.
  ///
  /// 이 필드는 "부팅 시 깜빡임을 막는 캐시"일 뿐 정본이 아니다 — 서버
  /// `dashboard_settings.ui_lang`이 정본이고, sync 응답이 오는 즉시 그
  /// 값으로 무조건 덮인다(`data/sync_reducer.dart`의 [SyncState.uiLang]과
  /// 같은 "절대값 서버 상태" 관용). 그 되쓰기를 하는 곳은 정확히
  /// `state/ui_lang_provider.dart`의 `installUiLangSync` 리스너다(`app.dart`가
  /// 부팅 때 거는 배선) — 이 기기에서 직접 언어를 고른 경우(`ui/setup_page.
  /// dart._setUiLang`)만이 아니라, 다른 기기·웹에서 바뀐 값을 sync로 받은
  /// 경우에도 여기에 남아야 다음 부팅이 깜빡이지 않는다. 서버의 `null`
  /// (안 정함)은 이 필드에서는 `'system'`으로 옮겨 적는다 — `'system'`은
  /// 로컬 기기 사실이라 서버로 보내지 않는다.
  final String? uiLang;

  static const DashboardConfigValues empty = DashboardConfigValues();

  bool get isEmpty =>
      serverUrl == null &&
      clientToken == null &&
      cursor == null &&
      resident == null &&
      themeMode == null &&
      seenWatermark == null &&
      uiLang == null &&
      extra.isEmpty;

  /// [resident]가 아직 없을 때 쓰는 실제 동작. 정본은 이 한 곳이다 —
  /// 화면·부팅·네이티브가 각자 기본값을 정하면 서로 어긋난다.
  bool get residentOrDefault => resident ?? kResidentDefault;

  /// **의도적으로 필드를 null로 되돌릴 수 없는 설계다.** `??` 기반이라
  /// 인자를 안 주는 것과 명시적으로 `null`을 주는 것을 구분하지 못한다 —
  /// 어느 쪽이든 "이 필드는 안 건드린다"로 접힌다. 아래
  /// [configPatchFnProvider]의 패치 의미론("자기가 소유한 필드만 바꾸고
  /// 나머지는 그대로 둔다")과 정확히 맞아떨어지므로 그대로 둔다 — 다중
  /// 작성자 중 누구도 이 메서드만으로는 실수로 다른 필드를 지울 수 없다.
  /// 반대로 "값을 실제로 비운다"가 필요한 유일한 자리(설정 화면의 서버
  /// 주소/토큰 지우기)는 이 메서드를 쓰지 않고 생성자를 직접 호출한다
  /// (`ui/setup_page.dart`의 `_save` 참고).
  DashboardConfigValues copyWith({
    String? serverUrl,
    String? clientToken,
    int? cursor,
    bool? resident,
    String? themeMode,
    int? seenWatermark,
    String? uiLang,
    Map<String, Object?>? extra,
  }) => DashboardConfigValues(
    serverUrl: serverUrl ?? this.serverUrl,
    clientToken: clientToken ?? this.clientToken,
    cursor: cursor ?? this.cursor,
    resident: resident ?? this.resident,
    themeMode: themeMode ?? this.themeMode,
    seenWatermark: seenWatermark ?? this.seenWatermark,
    uiLang: uiLang ?? this.uiLang,
    extra: extra ?? this.extra,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    ...extra,
    'server_url': serverUrl,
    'client_token': clientToken,
    'cursor': cursor,
    'resident': resident,
    'theme_mode': themeMode,
    'seen_watermark': seenWatermark,
    'ui_lang': uiLang,
  };

  factory DashboardConfigValues.fromJson(Map<String, Object?> json) {
    final Object? rawCursor = json['cursor'];
    final Object? rawResident = json['resident'];
    final Object? rawThemeMode = json['theme_mode'];
    final Object? rawSeenWatermark = json['seen_watermark'];
    final Object? rawUiLang = json['ui_lang'];
    return DashboardConfigValues(
      serverUrl: json['server_url'] is String
          ? json['server_url'] as String
          : null,
      clientToken: json['client_token'] is String
          ? json['client_token'] as String
          : null,
      cursor: rawCursor is int
          ? rawCursor
          : rawCursor is num
          ? rawCursor.toInt()
          : null,
      // 손상된 값(문자열 등)은 "안 정했다"로 접는다 — 이 계층은 던지지
      // 않는다는 [ConfigLoadFn] 계약 그대로다.
      resident: rawResident is bool ? rawResident : null,
      themeMode: rawThemeMode is String ? rawThemeMode : null,
      seenWatermark: rawSeenWatermark is int
          ? rawSeenWatermark
          : rawSeenWatermark is num
          ? rawSeenWatermark.toInt()
          : null,
      uiLang: rawUiLang is String ? rawUiLang : null,
      extra: Map<String, Object?>.unmodifiable(
        Map<String, Object?>.from(json)..removeWhere(
          (key, _) => const {
            'server_url',
            'client_token',
            'cursor',
            'resident',
            'theme_mode',
            'seen_watermark',
            'ui_lang',
          }.contains(key),
        ),
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DashboardConfigValues &&
          other.serverUrl == serverUrl &&
          other.clientToken == clientToken &&
          other.cursor == cursor &&
          other.resident == resident &&
          other.themeMode == themeMode &&
          other.seenWatermark == seenWatermark &&
          other.uiLang == uiLang &&
          const DeepCollectionEquality().equals(other.extra, extra);

  @override
  int get hashCode => Object.hash(
    serverUrl,
    clientToken,
    cursor,
    resident,
    themeMode,
    seenWatermark,
    uiLang,
    const DeepCollectionEquality().hash(extra),
  );

  @override
  String toString() =>
      'DashboardConfigValues(serverUrl: $serverUrl, cursor: $cursor, '
      'resident: $resident, themeMode: $themeMode, '
      'seenWatermark: $seenWatermark, uiLang: $uiLang)';
}

// ─── 1계층: 저장소 시임 ──────────────────────────────────────────────────

/// 저장된 값을 읽는다. 아무것도 없거나 손상됐으면
/// [DashboardConfigValues.empty] — 이 계층은 예외를 던지지 않는다(저장소가
/// 아직 없는 첫 실행도, 다른 프로그램이 파일을 망가뜨린 경우도 "값이
/// 없다"로 접는 게 안전한 기본값이다).
typedef ConfigLoadFn = Future<DashboardConfigValues> Function();

/// 값을 저장한다. 저장 실패(권한 없음 등)는 예외를 던진다 — 호출자(설정
/// 화면)가 사용자에게 알려야 하는 실패라 조용히 삼키지 않는다.
typedef ConfigSaveFn = Future<void> Function(DashboardConfigValues values);

typedef ConfigDefaultsFn =
    DashboardConfigValues Function(DashboardConfigValues stored);
final configDefaultsFnProvider = Provider<ConfigDefaultsFn>(
  (ref) =>
      (stored) => stored,
);

final Provider<ConfigLoadFn> configLoadFnProvider = Provider<ConfigLoadFn>(
  (ref) => bridge.loadDashboardConfig,
);

final Provider<ConfigSaveFn> configSaveFnProvider = Provider<ConfigSaveFn>(
  (ref) => bridge.saveDashboardConfig,
);

// ─── 1.5계층: 패치 시임(직렬화된 읽기-수정-쓰기) ──────────────────────────

/// [DashboardConfigValues] 저장의 유일한 쓰기 진입점 — "전체 스냅샷
/// 덮어쓰기"가 아니라 "지금 저장된 값을 다시 읽고, 내가 소유한 필드만
/// 바꾼 뒤 쓰기"다.
///
/// **왜 필요한가(실기기 클로버링 버그).** 이 값의 작성자는 넷이다 —
/// `sync_controller.dart`(cursor), `ui/setup_page.dart`(serverUrl/
/// clientToken, resident, themeMode). 예전에는 각자 부팅 시점에 읽어 둔
/// 자기 사본을 기준으로 [ConfigSaveFn]에 전체 값을 덮어썼다: 설정 화면에서
/// 테마를 고르면 그 순간엔 파일에 반영되지만, 뒤이어 동기화 컨트롤러가
/// (자신의 부팅 스냅샷 기준으로, 즉 `themeMode: null`인 채로) 커서를
/// 저장하면 방금 고른 테마가 통째로 지워졌다 — 실기기에서 `cursor`는
/// 최신인데 `theme_mode`/`resident`만 null인 파일 상태로 확인됐다.
///
/// [mutate]는 **방금 다시 읽은** 값을 받아 자기가 소유한 필드만 바꾼 새
/// 값을 돌려줘야 한다. 그 값이 읽은 값과 같으면([DashboardConfigValues]
/// 값 동등성) 디스크에 다시 쓰지 않는다 — 매 포그라운드 폴링(3초)마다 같은
/// 커서를 다시 쓰는 낭비를 없앤다.
///
/// **경쟁 상태는 직렬화로 막는다.** [configPatchFnProvider]의 기본 구현
/// ([_SerializedConfigPatcher])이 호출을 큐에 줄 세운다 — 테마 저장과 커서
/// 저장이 거의 동시에 들어와도, 뒤엣것의 읽기가 앞엣것의 쓰기보다 먼저
/// 끝나 서로의 필드를 지우는 일이 없다. 이 typedef 자체는 `capability_
/// provider.dart`/`configSaveFnProvider`와 같은 시임 모양이라, 테스트는
/// `configPatchFnProvider`를 통째로 override해 호출 여부만 볼 수도, 아래
/// 층([configLoadFnProvider]/[configSaveFnProvider])만 override해 실제
/// 큐잉·클로버링 방지를 검증할 수도 있다.
typedef ConfigPatchFn =
    Future<void> Function(
      DashboardConfigValues Function(DashboardConfigValues current) mutate,
    );

/// [ConfigPatchFn]의 기본 구현. 인스턴스(= provider 인스턴스)마다 독립된
/// 직렬화 큐를 갖는다 — 호출은 들어온 순서대로 하나씩만 `load -> mutate ->
/// save`를 실행하고, 앞선 호출이 실패해도(디스크 권한 등) 뒤에 대기 중인
/// 다른 필드의 저장까지 막지 않는다(그 실패는 그 호출자에게만 예외로
/// 전달된다 — [ConfigSaveFn] 문서의 "저장 실패는 예외" 계약이 호출자
/// 하나에 대한 것이지, 큐 전체를 멈추라는 뜻이 아니다).
class _SerializedConfigPatcher {
  _SerializedConfigPatcher(this._load, this._save);

  final ConfigLoadFn _load;
  final ConfigSaveFn _save;

  /// 지금까지 줄 세운 작업의 끝. 다음 호출은 이 Future(성공이든 실패든)가
  /// 끝난 뒤에야 자기 `load`를 시작한다.
  Future<void> _tail = Future<void>.value();

  Future<void> call(
    DashboardConfigValues Function(DashboardConfigValues current) mutate,
  ) {
    final ready = _tail.catchError((_) {});
    final turn = ready.then((_) async {
      final current = await _load();
      final next = mutate(current);
      if (next == current) return;
      await _save(next);
    });
    _tail = turn;
    return turn;
  }
}

final Provider<ConfigPatchFn> configPatchFnProvider = Provider<ConfigPatchFn>((
  ref,
) {
  final patcher = _SerializedConfigPatcher(
    ref.watch(configLoadFnProvider),
    ref.watch(configSaveFnProvider),
  );
  return patcher.call;
});

// ─── 부팅이 채우는 값 ────────────────────────────────────────────────────

/// 부팅 시퀀스가 [configLoadFnProvider]로 읽은 값을 담아 override하는
/// 자리. `dashboardApiConfigProvider`(`dashboard_api.dart`)처럼 override하지
/// 않으면 실패한다 — 값을 안 읽고 화면을 띄우면 서버 없이 도는 것이나
/// 마찬가지라 조용히 넘어가면 안 된다.
final Provider<DashboardConfigValues> dashboardConfigValuesProvider =
    Provider<DashboardConfigValues>(
      (ref) => throw StateError(
        'dashboardConfigValuesProvider를 override해야 한다 '
        '(부팅 시퀀스가 configLoadFnProvider로 읽은 값을 넣는다).',
      ),
    );

/// [dashboardConfigValuesProvider]로 [dashboardApiConfigProvider]
/// (`dashboard_api.dart`)를 채운다.
///
/// T-wire 계약(U-fix): 서버 주소가 아직 없으면(첫 실행) **null을 돌려준다**
/// — placeholder URL로 채워 실제 네트워크를 타게 두지 않는다. 예전에는
/// `fallbackBaseUrl`(예: `https://api.example.workers.dev`)을 채워 넣었지만,
/// 그 값은 실존하는 API가 아니라서 `syncController`/`pushRegistrar`가
/// 부팅 즉시 그 자리표시자 호스트로 요청을 쏘는 버그의 원인이었다. 호출자
/// (`main.dart`)는 null이면 `dashboardApiConfigProvider`를 아예 override하지
/// 않는다 — 그 provider를 override 없이 읽으면 던지는 게 원래 계약이고,
/// 서버 주소가 없는 동안은 그 계약대로 **아무도 읽지 않아야** 한다
/// (`sync_controller.dart`의 unconfigured 게이팅, `app.dart`의 push 등록
/// 게이팅 참고).
Override? dashboardApiConfigOverrideFor(
  DashboardConfigValues values, {
  Duration timeout = const Duration(seconds: 10),
}) {
  final serverUrl = values.serverUrl;
  if (serverUrl == null) return null;
  return dashboardApiConfigProvider.overrideWithValue(
    DashboardApiConfig(
      baseUrl: Uri.parse(serverUrl),
      clientToken: values.clientToken,
      timeout: timeout,
    ),
  );
}
