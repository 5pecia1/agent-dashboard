import 'package:integration_test/integration_test_driver.dart';

const Duration kSyncQaTimeout = Duration(minutes: 15);

/// Profile 모드에서 실제 Rust 초기화와 네이티브 앱 부팅을 검증한다.
Future<void> main() => integrationDriver(timeout: kSyncQaTimeout);
