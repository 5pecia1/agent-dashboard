import 'package:integration_test/integration_test_driver.dart';

const _qaTimeout = Duration(minutes: 10);

Future<void> main() => integrationDriver(timeout: _qaTimeout);
