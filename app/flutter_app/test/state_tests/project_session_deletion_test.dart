import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import '../test_helpers/session_deletion_harness.dart';

void main() {
  test('확인한 키만 중복 없이 삭제하고 실패한 세션과 알림은 보존한다', () async {
    final requests = <ApiRequest>[];
    final harness = SessionDeletionHarness(
      send: (request) async {
        requests.add(request);
        return ApiResponse(
          statusCode: request.url.pathSegments.last == deletionSecondKey
              ? 500
              : 200,
          body: '{}',
        );
      },
    );
    addTearDown(harness.container.dispose);
    final result = await harness.controller.deleteSessions([
      deletionFirstKey,
      deletionSecondKey,
      deletionFirstKey,
    ], expectedConnectionRevision: harness.revision);
    expect(result.deletedCount, 1);
    expect(result.failedCount, 1);
    expect(requests.map((r) => r.url.pathSegments.last), [
      deletionFirstKey,
      deletionSecondKey,
    ]);
    expect(requests.every((r) => r.method == 'DELETE'), isTrue);
    expect(
      harness.state.sync.sessions.keys,
      containsAll([deletionSecondKey, deletionOtherKey]),
    );
    expect(harness.state.sync.sessions.containsKey(deletionFirstKey), isFalse);
    expect(harness.state.sync.pendingAlerts.map((a) => a.id), [9, 10]);
    expect(harness.state.lastError, isNotNull);
  });

  test('삭제 성공은 이전 알림만 정리하고 요청 중 새로 도착한 활동을 남긴다', () async {
    final response = Completer<ApiResponse>();
    final harness = SessionDeletionHarness(send: (_) => response.future);
    addTearDown(harness.container.dispose);
    final deletion = harness.controller.deleteSession(deletionFirstKey);
    expect(harness.state.sync.sessions.containsKey(deletionFirstKey), isFalse);
    harness.controller.addSession(
      deletionSession(deletionFirstKey).copyWith(lastTransitionId: 11),
    );
    harness.controller.addAlert(deletionAlert(11, deletionFirstKey));
    response.complete(const ApiResponse(statusCode: 200, body: '{}'));
    expect(await deletion, isTrue);
    expect(harness.state.sync.sessions[deletionFirstKey]?.lastTransitionId, 11);
    expect(harness.state.sync.pendingAlerts.map((a) => a.id), [9, 10, 11]);
  });

  test('확인 중 연결이 바뀌면 삭제 요청을 보내지 않는다', () async {
    final requests = <ApiRequest>[];
    final harness = SessionDeletionHarness(
      send: (request) async {
        requests.add(request);
        return const ApiResponse(statusCode: 200, body: '{}');
      },
    );
    addTearDown(harness.container.dispose);
    final revision = harness.revision;
    harness.changeConnection();
    final result = await harness.controller.deleteSessions([
      deletionFirstKey,
      deletionSecondKey,
    ], expectedConnectionRevision: revision);
    expect(result.connectionChanged, isTrue);
    expect(requests, isEmpty);
    expect(harness.state.sync.sessions, hasLength(3));
  });

  test('삭제 중 연결이 바뀌면 남은 키를 새 서버에 보내지 않는다', () async {
    final response = Completer<ApiResponse>();
    final requests = <ApiRequest>[];
    final harness = SessionDeletionHarness(
      send: (request) {
        requests.add(request);
        return response.future;
      },
    );
    addTearDown(harness.container.dispose);
    final deletion = harness.controller.deleteSessions([
      deletionFirstKey,
      deletionSecondKey,
    ], expectedConnectionRevision: harness.revision);
    harness.changeConnection();
    response.complete(const ApiResponse(statusCode: 200, body: '{}'));
    final result = await deletion;
    expect(result.connectionChanged, isTrue);
    expect(requests, hasLength(1));
    expect(requests.single.url.host, 'original.example.test');
    expect(harness.state.sync.sessions.containsKey(deletionSecondKey), isTrue);
  });
}
