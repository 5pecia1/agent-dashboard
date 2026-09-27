import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/notification_tap.dart';
import 'package:my_dashboard/src/platform/push_signal.dart';
import 'package:my_dashboard/src/platform/push_signal_native.dart';
import 'package:my_dashboard/src/state/notification_click_inbox.dart';
import 'package:my_dashboard/src/state/notification_target_provider.dart';

const _tap = NotificationTap(
  sessionKey: 'codex:s1',
  host: 'mac',
  project: '/work/project',
  transitionId: 10,
  serverUrl: 'https://dashboard.example.test',
);

Future<void> _tick() => Future<void>.delayed(Duration.zero);

void main() {
  group('초기 알림 클릭 보관', () {
    test('루트 준비 전 클릭을 한 번 보관하고 준비 후 전달한다', () async {
      final inbox = NotificationClickInbox();
      final opened = <NotificationTap>[];
      inbox.add(_tap);
      await _tick();
      expect(opened, isEmpty);
      final detach = inbox.bind((tap) async {
        opened.add(tap);
      });
      await _tick();
      expect(opened, [_tap]);
      detach();
      inbox.bind((tap) async {
        opened.add(tap);
      });
      await _tick();
      expect(opened, [_tap]);
    });

    test('부팅 중에는 마지막으로 선택한 알림만 전달한다', () async {
      final inbox = NotificationClickInbox();
      const second = NotificationTap(sessionKey: 'codex:s2');
      final opened = <NotificationTap>[];
      inbox.add(_tap);
      inbox.add(second);
      inbox.bind((tap) async {
        opened.add(tap);
      });
      await _tick();
      expect(opened, [second]);
    });

    test('네이티브 버스에서 보류한 클릭도 마지막 선택만 inbox로 전달한다', () async {
      final bus = NativePushSignalBus();
      addTearDown(bus.close);
      final inbox = NotificationClickInbox();
      final choosing = Completer<void>();
      final opened = <String?>[];
      const first = PushSignal(
        type: kPushSignalNotificationClick,
        sessionKey: 'codex:first',
      );
      const last = PushSignal(
        type: kPushSignalNotificationClick,
        sessionKey: 'codex:last',
      );
      bus.emit(first);
      bus.emit(last);
      final subscription = bus.stream.listen(
        (signal) =>
            inbox.add(NotificationTap(sessionKey: signal.resolvedSessionKey)),
      );
      addTearDown(subscription.cancel);
      inbox.bind((tap) async {
        opened.add(tap.sessionKey);
        await choosing.future;
      });
      await _tick();
      expect(opened, ['codex:last']);

      bus.emit(first);
      await _tick();
      choosing.complete();
      await _tick();
      expect(opened, ['codex:last'], reason: '선택창 처리 중 추가 클릭은 나중에 실행하지 않는다');

      bus.emit(first);
      await _tick();
      expect(opened, [
        'codex:last',
        'codex:first',
      ], reason: '처리 완료 후 재클릭은 새 요청이다');
    });

    test('오래 보류된 클릭은 뒤늦게 포커스를 가져가지 않는다', () async {
      var now = DateTime(2026);
      final inbox = NotificationClickInbox(now: () => now);
      final opened = <NotificationTap>[];
      inbox.add(_tap);
      now = now.add(kNotificationClickLifetime);
      inbox.bind((tap) async {
        opened.add(tap);
      });
      await _tick();
      expect(opened, isEmpty);
    });

    test('선택창 처리 중 클릭은 이후 포커스를 다시 가져오지 않는다', () async {
      final inbox = NotificationClickInbox();
      final choosing = Completer<void>();
      final opened = <NotificationTap>[];
      inbox.bind((tap) async {
        opened.add(tap);
        await choosing.future;
      });
      inbox.add(_tap);
      await _tick();
      inbox.add(_tap);
      inbox.add(const NotificationTap(sessionKey: 'codex:other'));
      choosing.complete();
      await _tick();
      expect(opened, [_tap]);
      inbox.add(_tap);
      await _tick();
      expect(opened, [_tap, _tap], reason: '완료 후 명시적인 재클릭은 새 요청이다');
    });

    test('마운트가 해제되면 전달을 멈추고 다음 루트에서 이어받는다', () async {
      final inbox = NotificationClickInbox();
      final opened = <NotificationTap>[];
      final detach = inbox.bind((tap) async {
        opened.add(tap);
      });
      inbox.add(_tap);
      detach();
      await _tick();
      expect(opened, isEmpty);
      inbox.bind((tap) async {
        opened.add(tap);
      });
      await _tick();
      expect(opened, [_tap]);
    });

    test('오류가 난 클릭 뒤의 새 요청도 처리한다', () async {
      final inbox = NotificationClickInbox();
      var count = 0;
      inbox.bind((_) async {
        count++;
        throw StateError('fixture');
      });
      inbox.add(_tap);
      await _tick();
      inbox.add(_tap);
      await _tick();
      expect(count, 2);
    });
  });

  group('알림에서 창 연결 대상 복원', () {
    var lookups = 0;
    SessionViewDto? session;
    ProviderContainer create() => ProviderContainer(
      overrides: [
        dashboardApiConfigProvider.overrideWithValue(
          DashboardApiConfig(
            baseUrl: Uri.parse('https://dashboard.example.test/'),
          ),
        ),
        notificationSessionLookupProvider.overrideWithValue((_) async {
          lookups++;
          return session;
        }),
      ],
    );
    setUp(() {
      lookups = 0;
      session = const SessionViewDto(
        key: 'codex:s1',
        state: 'working',
        project: '/new/project',
        host: 'other-mac',
        lastTransitionId: 99,
      );
    });

    test('완전한 배너는 세션 동기화를 기다리지 않고 발생 당시 대상으로 이동한다', () async {
      final container = create();
      addTearDown(container.dispose);
      final target = await container.read(notificationTargetResolverProvider)(
        _tap,
      );
      expect(target!.project, '/work/project');
      expect(target.host, 'mac');
      expect(target.transitionId, 10);
      expect(lookups, 0);
    });

    test('세션이 삭제돼도 배너에 보존한 프로젝트 연결은 유지한다', () async {
      session = null;
      final container = create();
      addTearDown(container.dispose);
      final target = await container.read(notificationTargetResolverProvider)(
        _tap,
      );
      expect(target!.connectionKey!.project, '/work/project');
      expect(lookups, 0);
    });

    test('구버전 배너는 세션에서 대상을 찾되 최신 전이를 읽음 상한으로 쓰지 않는다', () async {
      final container = create();
      addTearDown(container.dispose);
      final target = await container.read(notificationTargetResolverProvider)(
        const NotificationTap(sessionKey: 'codex:s1', legacy: true),
      );
      expect(target!.project, '/new/project');
      expect(target.transitionId, isNull);
      expect(lookups, 1);
    });

    test('원본 서버를 확인할 수 없는 푸시는 대상 확인만 하고 읽지 않는다', () async {
      final container = create();
      addTearDown(container.dispose);
      final target = await container.read(notificationTargetResolverProvider)(
        const NotificationTap(sessionKey: 'codex:s1', transitionId: 7),
      );
      expect(target!.transitionId, isNull);
      expect(target.requireSelection, isTrue);
      expect(target.host, 'other-mac');
    });

    test('프로젝트만 알려진 배너는 표시 정보를 보존하고 영구 연결을 만들지 않는다', () async {
      session = null;
      final container = create();
      addTearDown(container.dispose);
      final target = await container.read(notificationTargetResolverProvider)(
        const NotificationTap(
          sessionKey: 'codex:s1',
          project: '/known/project',
        ),
      );
      expect(target!.project, '/known/project');
      expect(target.connectionKey, isNull);
    });

    test('대상 정보를 찾지 못한 배너는 세션을 추측하지 않는다', () async {
      session = null;
      final container = create();
      addTearDown(container.dispose);
      await expectLater(
        container.read(notificationTargetResolverProvider)(
          const NotificationTap(sessionKey: 'codex:gone', legacy: true),
        ),
        throwsA(
          isA<NotificationTargetUnavailable>().having(
            (e) => e.messageKey,
            'message',
            'notification.target_missing',
          ),
        ),
      );
    });

    test('다른 서버의 알림은 현재 서버의 같은 세션을 열거나 읽지 않는다', () async {
      final container = create();
      addTearDown(container.dispose);
      await expectLater(
        container.read(notificationTargetResolverProvider)(
          const NotificationTap(
            sessionKey: 'codex:s1',
            host: 'mac',
            project: '/work/project',
            transitionId: 10,
            serverUrl: 'https://old.example.test',
          ),
        ),
        throwsA(
          isA<NotificationTargetUnavailable>().having(
            (e) => e.messageKey,
            'message',
            'notification.server_changed',
          ),
        ),
      );
      expect(lookups, 0);
    });

    test('불완전한 과거 프로젝트와 달라진 현재 호스트를 합치지 않는다', () async {
      final container = create();
      addTearDown(container.dispose);
      final target = await container.read(notificationTargetResolverProvider)(
        const NotificationTap(
          sessionKey: 'codex:s1',
          project: '/old/project',
          transitionId: 10,
          serverUrl: 'https://dashboard.example.test',
        ),
      );
      expect(target!.project, '/old/project');
      expect(target.host, isNull);
      expect(target.connectionKey, isNull);
      expect(target.transitionId, 10);
    });

    test('서버가 확인된 푸시의 누락 정보만 채우고 원본 전이 상한을 유지한다', () async {
      final container = create();
      addTearDown(container.dispose);
      final target = await container.read(notificationTargetResolverProvider)(
        const NotificationTap(
          sessionKey: 'codex:s1',
          transitionId: 7,
          serverUrl: 'https://dashboard.example.test',
        ),
      );
      expect(target!.project, '/new/project');
      expect(target.host, 'other-mac');
      expect(target.transitionId, 7);
      expect(target.requireSelection, isFalse);
    });

    test('세션 없는 테스트 알림은 일반 앱 열기로 구분한다', () async {
      final container = create();
      addTearDown(container.dispose);
      expect(
        await container.read(notificationTargetResolverProvider)(
          const NotificationTap(),
        ),
        isNull,
      );
      expect(lookups, 0);
    });
  });
}
