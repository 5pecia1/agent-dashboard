/// 호스트별로 스냅샷을 돌려주는 가짜 대시보드 서버.
///
/// 첫 실행·서버 변경 테스트가 "새 연결로 요청이 나갔는가"를 실제
/// `DashboardApi`·실제 `SyncController` 아래에서 보려고 `httpSendProvider`
/// 자리에 꽂는다. 서버는 요청 주소의 호스트로 구분하고(주소를 바꾼 앱이 어느
/// 서버에 말을 거는지), 토큰이 다르면 401을 돌려준다. 보낸 요청은 전부 기록한다.
///
/// 응답 모양은 `contracts/dashboard-protocol.v1.json`의 `sync` 절을 따른다:
/// `since`가 없으면 스냅샷(`reset: true`, 서버가 아는 세션 전부), 있으면 변화가
/// 없는 델타(`reset: false`, 세션 없음)다. 그래서 커서를 들고 온 앱이 세션을
/// 비우지 않았다면 새 서버의 응답에 옛 서버의 세션이 그대로 남는다.
library;

import 'dart:convert';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';

/// 가짜 서버 하나: 받아들이는 토큰, 지금 커서, 가진 세션 키(`<source>:<id>`).
class FakeServerScript {
  const FakeServerScript({
    required this.token,
    required this.cursor,
    this.sessionKeys = const <String>[],
  });

  /// `Authorization: Bearer`로 받아들이는 CLIENT_TOKEN.
  final String token;

  /// 이 서버가 지금 말하는 마지막 전이 id.
  final int cursor;

  /// 서버가 아는 세션 키. `claude-code:<id>` 꼴이어야 한다.
  final List<String> sessionKeys;
}

/// [FakeServerScript]를 호스트 이름으로 찾아 응답하고 요청을 기록하는 전송.
class FakeDashboardServer {
  FakeDashboardServer(this.servers);

  /// 호스트 이름 -> 그 서버. 테스트가 중간에 바꿔 끼울 수 있다(예: 토큰 교체).
  final Map<String, FakeServerScript> servers;

  /// 지금까지 받은 요청 전부(오래된 순).
  final List<ApiRequest> requests = <ApiRequest>[];

  /// `GET /dashboard/sync` 요청만.
  List<ApiRequest> get syncRequests => <ApiRequest>[
    for (final request in requests)
      if (request.url.path == kSyncPath) request,
  ];

  /// `httpSendProvider`에 꽂는 함수 모양.
  Future<ApiResponse> call(ApiRequest request) async {
    requests.add(request);
    final script = servers[request.url.host];
    if (script == null) {
      return const ApiResponse(
        statusCode: 404,
        body: '{"error":"unknown host"}',
      );
    }
    if (request.headers['Authorization'] != 'Bearer ${script.token}') {
      return const ApiResponse(
        statusCode: 401,
        body: '{"error":"unauthorized"}',
      );
    }
    if (request.url.path != kSyncPath) {
      return const ApiResponse(statusCode: 200, body: '{}');
    }
    final isSnapshot = !request.url.queryParameters.containsKey('since');
    return ApiResponse(
      statusCode: 200,
      body: jsonEncode(
        fakeSyncBody(
          cursor: script.cursor,
          reset: isSnapshot,
          sessionKeys: isSnapshot ? script.sessionKeys : const <String>[],
        ),
      ),
    );
  }
}

/// `GET /dashboard/sync` 응답 본문 하나.
Map<String, Object?> fakeSyncBody({
  required int cursor,
  required bool reset,
  List<String> sessionKeys = const <String>[],
  int serverTimeMs = 1000,
}) => <String, Object?>{
  'protocol_version': kDashboardProtocolVersion,
  'reset': reset,
  'cursor': cursor,
  'has_more': false,
  'server_time': serverTimeMs,
  'pruned_below_id': 0,
  'stall_ms': kDefaultStallMs,
  'mute_until': null,
  'sessions': <Map<String, Object?>>[
    for (final key in sessionKeys)
      fakeSessionJson(key, updatedAtMs: serverTimeMs),
  ],
  'transitions': const <Object?>[],
  'sessions_touched': const <String>[],
};

/// 세션 하나의 JSON. [key]는 `claude-code:<id>` 꼴이다.
Map<String, Object?> fakeSessionJson(String key, {int updatedAtMs = 1000}) {
  final sessionId = key.substring(key.indexOf(':') + 1);
  return <String, Object?>{
    'key': key,
    'state': 'working',
    'source': 'claude-code',
    'session_id': sessionId,
    'project': 'project-$sessionId',
    'last_event': 'x',
    'last_message': null,
    'last_occurred_at': updatedAtMs,
    'created_at': updatedAtMs,
    'updated_at': updatedAtMs,
    'stale': false,
  };
}
