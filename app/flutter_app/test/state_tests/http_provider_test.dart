/// `http_provider.dart`가 `dashboard_api.dart`(T12)의 [httpSendProvider]
/// 시임에 실제 전송(이 테스트 호스트에서는 `http_transport_io.dart`)을
/// 정확히 꽂는지만 확인한다. 실제 소켓/네트워크는 열지 않는다 —
/// `dashboard_api_test.dart`와 같은 관용대로 전송 계층 자체는 언제나
/// 가짜 핸들러로 닫는다(레포 전체가 이 관용을 지킨다).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart' show httpSendProvider;
import 'package:my_dashboard/src/state/http_provider.dart';
import 'package:my_dashboard/src/state/http_transport_io.dart' as io_transport;

void main() {
  test('httpSendProviderOverride는 io 전송 구현을 그대로 꽂는다', () {
    final container = ProviderContainer(
      overrides: [httpSendProviderOverride],
    );
    addTearDown(container.dispose);

    // 최상위 함수 tear-off는 canonicalize되므로, override가 실제로
    // io 전송 구현을 가리키는지 함수 실행 없이 항등 비교로 확인할 수 있다.
    expect(container.read(httpSendProvider), same(io_transport.sendHttpRequest));
  });

  test('override 없이는 기본값(미설정 오류)이 그대로 남는다', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(httpSendProvider),
      isNot(same(io_transport.sendHttpRequest)),
    );
  });
}
