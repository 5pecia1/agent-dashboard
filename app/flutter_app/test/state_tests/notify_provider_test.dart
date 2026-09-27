/// `notify_provider.dart`의 발신 규칙을 실제 OS 알림 없이 닫는다.
/// [localNotifyFnProvider]/[isWasmRuntimeProvider]를 전부 override하므로
/// `osascript`가 절대 실행되지 않는다 — 이 테스트를 macOS 호스트에서 돌려도
/// 실제 알림 배너가 뜨지 않는다.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/i18n/t.dart' show i18nTranslateOverride, localeProvider;
import 'package:my_dashboard/src/rust/api/i18n.dart' show LocaleDto;
import 'package:my_dashboard/src/state/capability_provider.dart' show isWasmRuntimeProvider;
import 'package:my_dashboard/src/state/dashboard_provider.dart'
    show SessionStateDto, stateLabelKeyFnProvider;
import 'package:my_dashboard/src/state/notify_provider.dart';
import 'package:my_dashboard/src/platform/apns_push.dart' show kPushTransportFcmApns;
import 'package:my_dashboard/src/state/push_provider.dart'
    show ApnsOwnership, PushAvailability, PushRegistrationResult, apnsRegisteredProvider;

/// [apnsRegisteredProvider]를 고정값으로 세우는 가짜 소유권 — 실제 등록
/// 경로(서버·Firebase)를 태우지 않고 "배너의 주인이 누구인가"만 준다.
/// 등록 경로 자체는 `apns_push_provider_test.dart`가 닫는다.
class _FixedOwnership extends ApnsOwnership {
  _FixedOwnership(this._owned);

  final bool _owned;

  @override
  bool build() => _owned;
}

TransitionDto _alert({
  required int id,
  String sessionKey = 'claude_code:s1',
  String toState = 'waiting_input',
  String? project,
  String? host,
  String? message,
}) => TransitionDto(
  id: id,
  sessionKey: sessionKey,
  toState: toState,
  project: project,
  host: host,
  message: message,
);

/// [StateLabelResolver]의 결정적 대역 — 실제 i18n 카탈로그(FRB·로케일)를
/// 거치지 않고도 "제목·본문의 어느 자리에 상태 라벨이 들어가는가"만 본다.
/// 실제 조회 경로(코드 -> DTO -> i18n 키 -> 문구)는
/// [alertStateLabelProvider]가 담당하고, 그 세 시임 각각은 이미 자기
/// 테스트(`state_chip_test.dart`, `locale_test.dart`)가 닫는다.
String _fakeLabel(String stateCode) => switch (stateCode) {
  'waiting_input' => '질문·승인 대기',
  'done' => '실행 마침',
  _ => stateCode,
};

void main() {
  group('payloadForAlert — 제목은 프로젝트 이름으로 시작한다', () {
    test('제목은 "{프로젝트 basename} · {상태 라벨}"이다 — 세션 키가 아니다', () {
      final payload = payloadForAlert(
        _alert(
          id: 1,
          project: '/Users/example/projects/my-dashboard',
          message: '입력을 기다립니다',
        ),
        stateLabel: _fakeLabel,
      );

      expect(payload.title, 'my-dashboard · 질문·승인 대기');
      // 딥링크(T16 경로)가 탈 세션 키는 제목에서 빠져도 페이로드에 남는다.
      expect(payload.sessionKey, 'claude_code:s1');
      expect(payload.project, '/Users/example/projects/my-dashboard');
    });

    test('project가 null이거나 비면 그때만 sessionKey로 접는다', () {
      expect(
        payloadForAlert(_alert(id: 1), stateLabel: _fakeLabel).title,
        'claude_code:s1 · 질문·승인 대기',
      );
      expect(
        payloadForAlert(_alert(id: 2, project: ''), stateLabel: _fakeLabel).title,
        'claude_code:s1 · 질문·승인 대기',
      );
    });

    test('상태 라벨은 상태 코드 원문이 아니라 i18n 라벨이다', () {
      final payload = payloadForAlert(
        _alert(id: 1, toState: 'done', project: '/a/b/c'),
        stateLabel: _fakeLabel,
      );
      expect(payload.title, 'c · 실행 마침');
      expect(payload.title, isNot(contains('done')));
    });
  });

  group('payloadForAlert — 본문', () {
    test('message가 있으면 본문으로 쓰고, 없으면 상태 라벨로 접는다', () {
      expect(
        payloadForAlert(_alert(id: 1, message: '입력을 기다립니다'), stateLabel: _fakeLabel).body,
        '입력을 기다립니다',
      );
      expect(payloadForAlert(_alert(id: 2, message: ''), stateLabel: _fakeLabel).body, '질문·승인 대기');
      final nullMessage = payloadForAlert(_alert(id: 3), stateLabel: _fakeLabel);
      expect(nullMessage.body, '질문·승인 대기');
      // 상태 **코드** 원문(`waiting_input`)이 사용자에게 보이던 예전 결함.
      expect(nullMessage.body, isNot(contains('waiting_input')));
    });

    test('host가 있으면 본문 앞에 "{host} · "를 붙인다 (다른 기계 세션 식별)', () {
      expect(
        payloadForAlert(
          _alert(id: 1, host: 'dev-macbook', message: '입력을 기다립니다'),
          stateLabel: _fakeLabel,
        ).body,
        'dev-macbook · 입력을 기다립니다',
      );
      // message가 없으면 접두는 상태 라벨 앞에 붙는다.
      expect(
        payloadForAlert(_alert(id: 2, host: 'dev-macbook'), stateLabel: _fakeLabel).body,
        'dev-macbook · 질문·승인 대기',
      );
      // host가 null/빈 값이면 접두 자체가 없다 — ` · `만 남지 않는다.
      expect(
        payloadForAlert(
          _alert(id: 3, host: '', message: '입력을 기다립니다'),
          stateLabel: _fakeLabel,
        ).body,
        '입력을 기다립니다',
      );
    });

    test('발신 당시의 전체 프로젝트 경로와 호스트를 창 연결 대상으로 보존한다', () {
      final payload = payloadForAlert(
        _alert(id: 42, project: '/work/one/dashboard', host: 'remote-mac'),
        stateLabel: _fakeLabel,
      );

      expect(payload.project, '/work/one/dashboard');
      expect(payload.host, 'remote-mac');
    });
  });

  group('payloadForAlert — 알림 id는 전이 id다 (macOS 무음 배너 회귀 방지)', () {
    // 예전에는 알림 id가 프로세스 메모리 카운터(`_nextNotificationId`,
    // `local_notifications_native.dart`)였다 — 앱을 재시작하면 그 카운터가
    // 2부터 다시 시작하는데, macOS 알림 센터에는 재시작과 무관하게 이전
    // "전달된 알림"이 남아 있어서 되돌아온 id가 그 알림과 충돌하면
    // `UNUserNotificationCenter`가 새 알림이 아니라 제자리 갱신으로 처리해
    // 배너도 소리도 나지 않았다(실 A/B 로그로 확정). 이제 [NotifyPayload.id]는
    // 순수 함수 [payloadForAlert]의 출력이라 값만으로 이 계약을 고정할 수
    // 있다: 서버가 단조 증가시키고 재사용하지 않는 [TransitionDto.id]를
    // 그대로 쓴다.
    test('서로 다른 전이는 서로 다른 알림 id를 받는다', () {
      final first = payloadForAlert(_alert(id: 1), stateLabel: _fakeLabel);
      final second = payloadForAlert(_alert(id: 2), stateLabel: _fakeLabel);

      expect(first.id, isNot(second.id));
    });

    test('같은 전이는 항상 같은 알림 id를 받는다', () {
      final a = payloadForAlert(_alert(id: 7, message: '입력을 기다립니다'), stateLabel: _fakeLabel);
      final b = payloadForAlert(_alert(id: 7, message: '입력을 기다립니다'), stateLabel: _fakeLabel);

      expect(a.id, b.id);
      expect(a, b);
    });

    test('알림 id는 TransitionDto.id와 같다', () {
      final payload = payloadForAlert(_alert(id: 42), stateLabel: _fakeLabel);

      expect(payload.id, 42);
    });
  });

  group('notifyProvider (발신)', () {
    late List<NotifyPayload> sent;

    ProviderContainer buildContainer({required bool isWasm, bool apnsRegistered = false}) {
      sent = <NotifyPayload>[];
      return ProviderContainer(
        overrides: [
          isWasmRuntimeProvider.overrideWithValue(isWasm),
          apnsRegisteredProvider.overrideWith(() => _FixedOwnership(apnsRegistered)),
          localNotifyFnProvider.overrideWithValue((payload) async {
            sent.add(payload);
          }),
        ],
      );
    }

    test('완료 기준 (d): 웹 런타임에서는 호출이 0번이다', () async {
      final container = buildContainer(isWasm: true);
      addTearDown(container.dispose);

      await notifyForAlerts(
        [_alert(id: 1), _alert(id: 2)],
        dispatch: container.read(notifyProvider),
        stateLabel: _fakeLabel,
      );

      expect(sent, isEmpty);
    });

    test('완료 기준 (b): 데스크톱이면 전이당 정확히 한 번씩 호출된다', () async {
      final container = buildContainer(isWasm: false);
      addTearDown(container.dispose);

      final alerts = [
        _alert(id: 1, sessionKey: 'claude_code:s1', message: '첫 번째'),
        _alert(id: 2, sessionKey: 'codex:s2', message: '두 번째'),
        _alert(id: 3, sessionKey: 'claude_code:s3', message: '세 번째'),
      ];

      await notifyForAlerts(
        alerts,
        dispatch: container.read(notifyProvider),
        stateLabel: _fakeLabel,
      );

      expect(sent.length, 3);
      expect(sent.map((p) => p.sessionKey), ['claude_code:s1', 'codex:s2', 'claude_code:s3']);
      expect(sent.map((p) => p.body), ['첫 번째', '두 번째', '세 번째']);
    });

    test('빈 목록이면 호출이 0번이다', () async {
      final container = buildContainer(isWasm: false);
      addTearDown(container.dispose);

      await notifyForAlerts(
        const [],
        dispatch: container.read(notifyProvider),
        stateLabel: _fakeLabel,
      );

      expect(sent, isEmpty);
    });
  });

  group('소유권 (A안 설계 ②)', () {
    late List<NotifyPayload> sent;

    ProviderContainer buildContainer({required bool apnsRegistered}) {
      sent = <NotifyPayload>[];
      return ProviderContainer(
        overrides: [
          isWasmRuntimeProvider.overrideWithValue(false),
          apnsRegisteredProvider.overrideWith(() => _FixedOwnership(apnsRegistered)),
          localNotifyFnProvider.overrideWithValue((payload) async {
            sent.add(payload);
          }),
        ],
      );
    }

    test('APNs가 등록돼 있으면 로컬 알림을 한 번도 띄우지 않는다 (배너 중복 금지)', () async {
      final container = buildContainer(apnsRegistered: true);
      addTearDown(container.dispose);

      await notifyForAlerts(
        [_alert(id: 1, message: '첫 번째'), _alert(id: 2, message: '두 번째')],
        dispatch: container.read(notifyProvider),
        stateLabel: _fakeLabel,
      );

      expect(sent, isEmpty);
    });

    test('APNs가 등록되지 않았으면 기존 로컬 알림 경로가 그대로 산다 (폴백)', () async {
      final container = buildContainer(apnsRegistered: false);
      addTearDown(container.dispose);

      await notifyForAlerts(
        [_alert(id: 1, message: '첫 번째'), _alert(id: 2, message: '두 번째')],
        dispatch: container.read(notifyProvider),
        stateLabel: _fakeLabel,
      );

      expect(sent.length, 2);
    });

    test('소유권이 넘어가면 그 다음 알림부터 즉시 억제된다', () async {
      final container = ProviderContainer(
        overrides: [
          isWasmRuntimeProvider.overrideWithValue(false),
          localNotifyFnProvider.overrideWithValue((payload) async {
            sent.add(payload);
          }),
        ],
      );
      addTearDown(container.dispose);
      sent = <NotifyPayload>[];

      await notifyForAlerts(
        [_alert(id: 1)],
        dispatch: container.read(notifyProvider),
        stateLabel: _fakeLabel,
      );
      expect(sent.length, 1, reason: '아직 앱이 배너의 주인이다');

      // 실제 등록 성공이 하는 것과 같은 상태 전이.
      container
          .read(apnsRegisteredProvider.notifier)
          .applyResult(
            const PushRegistrationResult(
              availability: PushAvailability.registered,
              token: 't',
              transport: kPushTransportFcmApns,
            ),
          );

      await notifyForAlerts(
        [_alert(id: 2)],
        dispatch: container.read(notifyProvider),
        stateLabel: _fakeLabel,
      );
      expect(sent.length, 1, reason: '소유권이 APNs로 넘어갔으므로 늘지 않는다');
    });
  });

  group('alertStateLabelProvider (상태 라벨 시임)', () {
    /// 실제 조립만 본다 — 세 시임(FRB 상태 매핑·i18n 키·번역)을 전부
    /// 결정적 대역으로 바꿔, 이 Provider가 **카드 상태 칩과 같은 경로**
    /// (코드 -> DTO -> `state.*` 키 -> 번역)를 거치는지만 확인한다.
    /// `localeProvider`까지 고정하는 이유: 기본 구현은
    /// `platformLocaleProvider`를 통해 `WidgetsBinding.instance`를 읽는데,
    /// 이 파일은 `testWidgets`가 아니라 순수 `test`로 도는 그룹이 대부분이라
    /// 바인딩이 초기화돼 있다고 가정할 수 없다.
    ProviderContainer buildContainer() => ProviderContainer(
      overrides: [
        localeProvider.overrideWithValue(LocaleDto.ko),
        stateLabelKeyFnProvider.overrideWithValue((SessionStateDto state) => 'state.${state.name}'),
        i18nTranslateOverride.overrideWithValue(
          (String key, LocaleDto locale) => '$key@${locale.name}',
        ),
      ],
    );

    test('상태 코드를 활성 로케일의 상태 라벨로 옮긴다', () {
      final container = buildContainer();
      addTearDown(container.dispose);

      final label = container.read(alertStateLabelProvider);
      expect(label('waiting_input'), 'state.waitingInput@ko');
      expect(label('done'), 'state.done@ko');
    });

    test('알 수 없는 상태 코드는 칩과 같은 폴백(idle)을 탄다', () {
      final container = buildContainer();
      addTearDown(container.dispose);

      expect(container.read(alertStateLabelProvider)('bogus'), 'state.idle@ko');
    });
  });
}
