import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import '../test_helpers/session_deletion_harness.dart';

void main() {
  test('확인한 키만 한 요청으로 삭제하고 중복은 제외한다', () async {
    final requests = <ApiRequest>[];
    final harness = SessionDeletionHarness(
      send: (request) async {
        requests.add(request);
        return const ApiResponse(statusCode: 200, body: '{"ok":true}');
      },
    );
    addTearDown(harness.container.dispose);
    final result = await harness.controller.deleteSessions([
      deletionFirstKey,
      deletionSecondKey,
      deletionFirstKey,
    ], expectedConnectionRevision: harness.revision);
    expect(result.deletedCount, 2);
    expect(result.failedCount, 0);
    final request = requests.single;
    expect(request.method, 'POST');
    expect(request.url.path, '/dashboard/sessions/delete');
    expect(jsonDecode(request.body!), {
      'keys': [deletionFirstKey, deletionSecondKey],
    });
    expect(harness.state.sync.sessions.keys, [deletionOtherKey]);
    expect(harness.state.sync.pendingAlerts.map((alert) => alert.id), [10]);
  });

  test('일괄 삭제 실패 시 기존 세션을 복구하고 새 활동과 알림을 보존한다', () async {
    final response = Completer<ApiResponse>();
    final harness = SessionDeletionHarness(send: (_) => response.future);
    addTearDown(harness.container.dispose);
    final deletion = harness.controller.deleteSessions([
      deletionFirstKey,
      deletionSecondKey,
    ], expectedConnectionRevision: harness.revision);
    expect(harness.state.sync.sessions.keys, [deletionOtherKey]);
    harness.controller.addSession(
      deletionSession(deletionFirstKey).copyWith(lastTransitionId: 11),
    );
    harness.controller.addAlert(deletionAlert(11, deletionFirstKey));
    response.complete(const ApiResponse(statusCode: 500, body: '{}'));
    final result = await deletion;
    expect(result.failedCount, 2);
    expect(result.deletedCount, 0);
    expect(
      harness.state.sync.sessions.keys,
      unorderedEquals([deletionFirstKey, deletionSecondKey, deletionOtherKey]),
    );
    expect(harness.state.sync.sessions[deletionFirstKey]?.lastTransitionId, 11);
    expect(harness.state.sync.pendingAlerts.map((alert) => alert.id), [
      8,
      9,
      10,
      11,
    ]);
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
    harness.controller.addSession(deletionSession(deletionSecondKey));
    harness.controller.addAlert(deletionAlert(11, deletionSecondKey));
    response.complete(const ApiResponse(statusCode: 200, body: '{}'));
    final result = await deletion;
    expect(result.connectionChanged, isTrue);
    expect(requests, hasLength(1));
    expect(requests.single.url.host, 'original.example.test');
    expect(harness.state.sync.pendingAlerts.map((alert) => alert.id), [
      8,
      9,
      10,
      11,
    ]);
    expect(harness.state.sync.sessions.containsKey(deletionSecondKey), isTrue);
  });
}
