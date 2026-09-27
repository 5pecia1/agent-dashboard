/// T14 완료 판정의 추가 통합 테스트(best-effort): 실제로 띄운 로컬
/// `wrangler dev` 서버에 hook 이벤트를 주입하고, [SyncController]가 실제
/// HTTP 전송(`http_transport_io.dart`)으로 그 변화를 5초 안에 반영하는지
/// 확인한다.
///
/// 이 파일의 나머지 스위트(`sync_controller_test.dart`)와 다른 점은 딱
/// 하나다 — 거기서는 `syncScheduleFnProvider`/`httpSendProvider`를 전부
/// 가짜로 override해 시간과 네트워크를 완전히 통제하지만, 여기서는
/// [httpSendProviderOverride](진짜 `dart:io HttpClient`)와 진짜
/// `Timer`(기본 [syncScheduleFnProvider])를 그대로 둔다 — 그래야 "5초
/// 안에 반영"이라는 완료 기준을 실제 벽시계 시간·실제 소켓으로 증명할 수
/// 있다. `syncActivityWatchFnProvider`만 빈 스트림으로 override한다 — 이
/// 테스트가 확인하려는 것은 3초 폴링이 실제 서버 응답을 반영하는지이지,
/// 포그라운드 전환이 아니다.
///
/// 서버는 이 테스트가 띄우지 않는다 — dashboard-server는 다른 트랙 소유라
/// (docs/CLAUDE.md 공통 규칙) 이 저장소를 쓰기로 건드릴 수 없고, 실행만
/// 허용된다. 그래서 이 테스트는 "이미 떠 있는 서버"를 전제로 하고, 서버가
/// 없으면(연결 실패) `markTestSkipped`로 건너뛴다 — CI나 서버 없이 도는
/// 일반 `flutter test` 실행에서 이 파일 하나 때문에 스위트 전체가 깨지면
/// 안 된다.
///
/// 실행 방법 (수동, best-effort):
/// ```
/// cd dashboard-server && npx wrangler d1 migrations apply dashboard-server --local \
///   && npx wrangler dev --port 8788 &
/// TEST_SERVER_BASE_URL=http://127.0.0.1:8788 \
/// TEST_AUTH_TOKEN=<dashboard-server/.dev.vars의 AUTH_TOKEN 값> \
///   flutter test test/integration_tests/sync_controller_live_server_test.dart
/// ```
/// (포트가 막히면 8790으로 재시도 — TEST_SERVER_BASE_URL만 바꾸면 된다.)
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/http_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';

void main() {
  test(
    '완료 기준(추가, best-effort): 실제 서버에 curl로 넣은 hook 이벤트가 '
    '5초 안에 SyncController 상태에 반영된다',
    () async {
      final baseUrlString = Platform.environment['TEST_SERVER_BASE_URL'];
      final authToken = Platform.environment['TEST_AUTH_TOKEN'];
      if (baseUrlString == null || authToken == null) {
        markTestSkipped(
          'TEST_SERVER_BASE_URL/TEST_AUTH_TOKEN 환경변수가 없다 — 로컬에서 '
          'wrangler dev를 띄우고 위 파일 헤더의 실행 방법대로 돌려야 하는 '
          'best-effort 통합 테스트라 기본 `flutter test` 실행에서는 '
          '건너뛴다.',
        );
        return;
      }

      // 서버가 실제로 떠 있는지 먼저 확인한다 — 떠 있지 않으면(주소가
      // 설정돼 있어도 이번 실행에 서버를 못 띄웠을 수 있다) 실패로 스위트를
      // 깨뜨리지 않고 건너뛴다.
      final baseUrl = Uri.parse(baseUrlString);
      try {
        final probe = await HttpClient().getUrl(baseUrl.replace(path: '/healthz'));
        final probeResponse = await probe.close().timeout(const Duration(seconds: 2));
        if (probeResponse.statusCode != 200) {
          markTestSkipped(
            '$baseUrlString/healthz가 200이 아니다 '
            '(${probeResponse.statusCode}) — 서버가 준비되지 않았다.',
          );
          return;
        }
      } catch (error) {
        markTestSkipped('$baseUrlString 에 연결할 수 없다: $error');
        return;
      }

      // 이 실행 고유의 session_id — 과거 실행/다른 테스트가 남긴 세션과
      // 절대 헷갈리지 않게 한다.
      final sessionId =
          't14-live-${DateTime.now().millisecondsSinceEpoch}-${sessionIdSuffix()}';
      final eventId = 't14-live-evt-${DateTime.now().microsecondsSinceEpoch}';

      // contracts/dashboard-protocol.v1.json의 event_payload 계약을 그대로
      // 따르는 fixture. curl로 주입한다 — 이 테스트가 확인하려는 것은
      // "hook이 실제로 POST하는 방식"과 SyncController가 정확히 같은
      // 조건에서 반영되는지이지, dart:io로 우회해서 넣는 게 아니다.
      final fixture = jsonEncode(<String, Object?>{
        'protocol_version': 1,
        'source': 'claude-code',
        'session_id': sessionId,
        'project': '/Users/example/projects/my-dashboard',
        'host': 't14-integration-host',
        'event': 'Notification',
        'event_id': eventId,
        'occurred_at': DateTime.now().millisecondsSinceEpoch,
        'message': 'T14 live integration fixture',
      });

      final curlResult = await Process.run('curl', <String>[
        '-s',
        '-o',
        '/dev/null',
        '-w',
        '%{http_code}',
        '-X',
        'POST',
        baseUrl.replace(path: '/dashboard/events').toString(),
        '-H',
        'Authorization: Bearer $authToken',
        '-H',
        'Content-Type: application/json',
        '--data-binary',
        fixture,
      ]);
      expect(
        curlResult.exitCode,
        0,
        reason: 'curl 실행 자체가 실패했다: ${curlResult.stderr}',
      );
      expect(
        curlResult.stdout.toString(),
        '200',
        reason: 'POST /dashboard/events가 200이 아니다: ${curlResult.stdout}',
      );

      // SyncController를 진짜 HTTP 전송(httpSendProviderOverride)과 진짜
      // Timer로 조립한다 — syncScheduleFnProvider/syncNowMsFnProvider는
      // override하지 않는다(기본 구현이 그대로 실제 Timer/실제 시계다).
      final container = ProviderContainer(
        overrides: [
          httpSendProviderOverride,
          dashboardApiConfigProvider.overrideWithValue(
            DashboardApiConfig(baseUrl: baseUrl, clientToken: authToken),
          ),
          dashboardConfigValuesProvider.overrideWithValue(
            DashboardConfigValues.empty,
          ),
          configSaveFnProvider.overrideWithValue(
            (values) async {}, // 이 테스트는 실제 config 저장소를 건드리지 않는다.
          ),
          syncActivityWatchFnProvider.overrideWithValue(
            () => const Stream<bool>.empty(),
          ),
        ],
      );
      addTearDown(container.dispose);

      // build()가 즉시 1회(지연 0)를 실제 Timer로 예약한다. 그 뒤로는
      // 3초 포그라운드 간격으로 계속 폴링한다 — 이 테스트는 그 폴링이
      // 우리가 막 주입한 세션을 5초 안에 주워 오는지를 실제 벽시계로
      // 확인한다.
      container.read(syncControllerProvider);

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      var found = false;
      while (DateTime.now().isBefore(deadline)) {
        final state = container.read(syncControllerProvider);
        if (state.sync.sessions.values.any((s) => s.sessionId == sessionId)) {
          found = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }

      final finalState = container.read(syncControllerProvider);
      expect(
        found,
        isTrue,
        reason:
            '5초 안에 session_id=$sessionId 를 sync 상태에서 찾지 못했다. '
            '마지막 오류: ${finalState.lastError}, phase: ${finalState.phase}, '
            'sessions: ${finalState.sync.sessions.values.map((s) => s.sessionId).toList()}',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

/// 같은 밀리초에 두 번 돌 때를 대비한 짧은 무작위 접미사.
String sessionIdSuffix() =>
    (DateTime.now().microsecondsSinceEpoch % 100000).toString();
