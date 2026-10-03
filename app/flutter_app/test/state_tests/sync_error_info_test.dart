/// 실패를 화면용 오류 한 건으로 접는 규칙을 닫는다: [classifyError]의 종류
/// 분류와, [SyncErrorInfo.fromError]가 실패의 사실([DashboardFault])을 화면까지
/// 그대로 옮기는지. 동기화 사이클·ack·삭제 세 실패 경로가 모두 이 팩토리를
/// 쓴다(`sync_controller.dart`). 사이클에서 화면 문구까지 이어지는 경로는
/// `widget_tests/sync_error_detail_test.dart`가, ack·삭제 경로는
/// `sync_controller_ack_test.dart`·`sync_controller_seen_delete_test.dart`가
/// 실제 컨트롤러로 덮는다.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart'
    show kDashboardProtocolVersion;
import 'package:my_dashboard/src/state/sync_controller.dart';
import '../test_helpers/capture_logs.dart';
import '../test_helpers/unconfigured_api_error.dart';

const TransportFault _transport = TransportFault(
  method: 'GET',
  path: kSyncPath,
  cause: 'SocketException: Connection refused',
);

const TimeoutFault _timeout = TimeoutFault(
  method: 'GET',
  path: kSyncPath,
  timeoutMs: 10000,
);

const MalformedResponseFault _malformed = MalformedResponseFault(
  method: 'GET',
  path: kSyncPath,
  detail: 'FormatException: Unexpected character (at character 1)',
);

const ProtocolMismatchFault _mismatch = ProtocolMismatchFault(
  serverVersion: kDashboardProtocolVersion + 1,
  supportedVersion: kDashboardProtocolVersion,
);

void main() {
  group('classifyError / isAuthFailure', () {
    test('401/403은 auth로 분류되고, auth만 재시도 중단 대상이다', () {
      expect(
        classifyError(const DashboardUnauthorized('x')),
        SyncErrorKind.auth,
      );
      expect(classifyError(const DashboardForbidden('x')), SyncErrorKind.auth);
      expect(isAuthFailure(SyncErrorKind.auth), isTrue);
      expect(isAuthFailure(SyncErrorKind.network), isFalse);
    });

    test('타임아웃 · 전송 실패는 network다', () {
      expect(
        classifyError(const DashboardTimeout('x', fault: _timeout)),
        SyncErrorKind.network,
      );
      expect(
        classifyError(const DashboardNetworkFailure('x')),
        SyncErrorKind.network,
      );
    });

    test('5xx는 server, 프로토콜 불일치는 protocol이다', () {
      expect(
        classifyError(const DashboardServerError('x', statusCode: 500)),
        SyncErrorKind.server,
      );
      expect(
        classifyError(const DashboardProtocolMismatch('x', fault: _mismatch)),
        SyncErrorKind.protocol,
      );
    });

    test('그 밖의 4xx나 응답 해석 실패는 other다(자동으로 멈추지 않는다)', () {
      expect(
        classifyError(const DashboardClientError('x', statusCode: 400)),
        SyncErrorKind.other,
      );
      expect(
        classifyError(const DashboardMalformedResponse('x', fault: _malformed)),
        SyncErrorKind.other,
      );
      expect(
        classifyError(const DashboardPushUnavailable('x')),
        SyncErrorKind.other,
      );
    });

    test('DashboardApiException이 아닌 예외는 unexpected이고 자동으로 멈추지 않는다', () {
      final unexpected = <Object>[
        StateError('무관한 예외'),
        const FormatException('type mismatch'),
        unconfiguredApiReadError(),
      ];

      for (final error in unexpected) {
        expect(
          classifyError(error),
          SyncErrorKind.unexpected,
          reason: '${error.runtimeType}',
        );
      }
      expect(isAuthFailure(SyncErrorKind.unexpected), isFalse);
    });
  });

  group('SyncErrorInfo.fromError', () {
    test('사실을 싣는 실패는 그 사실을 fault로 옮기고 원문은 message에 남긴다', () {
      final failures = <DashboardApiException, DashboardFault>{
        DashboardNetworkFailure('$_transport', fault: _transport): _transport,
        DashboardTimeout('$_timeout', fault: _timeout): _timeout,
        DashboardMalformedResponse('$_malformed', fault: _malformed):
            _malformed,
        DashboardProtocolMismatch('$_mismatch', fault: _mismatch): _mismatch,
      };

      for (final MapEntry(key: error, value: fault) in failures.entries) {
        final info = SyncErrorInfo.fromError(error, atMs: 7);

        expect(info.fault, fault, reason: '$error');
        expect(info.message, '$error');
        expect(info.kind, classifyError(error));
        expect(info.atMs, 7);
      }
    });

    test('사실이 없는 실패와 그 밖의 오류에는 fault가 없다', () async {
      final unrelated = <Object>[
        // 시임 미설정처럼 요청 없이 접힌 전송 실패.
        const DashboardNetworkFailure('httpSendProvider'),
        const DashboardServerError(
          'GET /dashboard/sync: boom',
          statusCode: 503,
        ),
        StateError('dashboardApiConfigProvider'),
      ];

      for (final error in unrelated) {
        late final SyncErrorInfo info;
        // 예상하지 못한 예외는 원문을 로그로 남긴다 — 이 테스트의 출력에
        // 섞지 않는다.
        await captureDebugPrint(
          () => info = SyncErrorInfo.fromError(error, atMs: 0),
        );
        expect(info.fault, isNull, reason: '$error');
        expect(info.message, '$error');
        expect(info.kind, classifyError(error));
      }
    });

    test('DashboardApiException이 아닌 예외는 unexpected이고 원문은 로그로만 남는다', () async {
      final error = unconfiguredApiReadError();
      late final SyncErrorInfo info;

      final logged = await captureDebugPrint(() {
        info = SyncErrorInfo.fromError(error, atMs: 3);
      });

      expect(info.kind, SyncErrorKind.unexpected);
      expect(info.fault, isNull);
      expect(info.message, '$error', reason: '원문은 진단용으로 보존한다');
      expect(logged, hasLength(1), reason: '실패 한 건에 로그 한 줄');
      expect(logged.single, contains('${error.runtimeType}'));
      expect(logged.single, contains('$error'));
    });

    test('DashboardApiException 실패는 화면이 사실이나 원문을 보이므로 로그를 남기지 않는다', () async {
      final apiFailures = <DashboardApiException>[
        DashboardNetworkFailure('$_transport', fault: _transport),
        DashboardTimeout('$_timeout', fault: _timeout),
        DashboardMalformedResponse('$_malformed', fault: _malformed),
        DashboardProtocolMismatch('$_mismatch', fault: _mismatch),
        const DashboardUnauthorized('x'),
        const DashboardServerError('x', statusCode: 503),
        const DashboardClientError('x', statusCode: 400),
      ];

      final logged = await captureDebugPrint(() {
        for (final error in apiFailures) {
          SyncErrorInfo.fromError(error, atMs: 0);
        }
      });

      expect(logged, isEmpty);
    });

    test('fault가 다르면 같은 오류로 보지 않는다', () {
      const other = TransportFault(
        method: 'POST',
        path: kSessionsPath,
        cause: 'SocketException: Connection refused',
      );
      const base = SyncErrorInfo(
        kind: SyncErrorKind.network,
        message: 'same',
        atMs: 0,
        fault: _transport,
      );

      expect(
        base,
        const SyncErrorInfo(
          kind: SyncErrorKind.network,
          message: 'same',
          atMs: 0,
          fault: _transport,
        ),
      );
      for (final fault in const <DashboardFault>[other, _timeout]) {
        expect(
          base,
          isNot(
            SyncErrorInfo(
              kind: SyncErrorKind.network,
              message: 'same',
              atMs: 0,
              fault: fault,
            ),
          ),
        );
      }
    });
  });
}
