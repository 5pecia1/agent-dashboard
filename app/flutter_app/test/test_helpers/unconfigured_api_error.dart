/// 서버 주소 없이 `dashboardApiProvider`를 읽을 때 Riverpod이 던지는 실제 오류.
///
/// 스택 트레이스를 두 벌 담은 여러 줄 덤프(`ProviderException`)이고, 그 안에
/// 개발자용 한국어 `StateError` 문장이 들어 있다. 첫 실행에서 서버 주소를
/// 저장한 직후 동기화가 만나던 오류이고, 영어 화면에 그대로 새던 원문이다.
/// 가짜 문자열을 지어 쓰지 않고 같은 오류를 직접 만들어 쓴다.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';

/// [dashboardApiProvider]를 override 없이 읽어 던져진 오류를 돌려준다.
Object unconfiguredApiReadError() {
  final container = ProviderContainer();
  try {
    container.read(dashboardApiProvider);
  } on Object catch (error) {
    return error;
  } finally {
    container.dispose();
  }
  throw StateError('설정이 없는데 dashboardApiProvider가 던지지 않았다');
}
