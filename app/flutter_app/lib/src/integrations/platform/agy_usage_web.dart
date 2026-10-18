import 'package:my_dashboard/src/integrations/data/agy_usage_api.dart';
import 'package:my_dashboard/src/integrations/data/agy_usage_models.dart';

Future<AgyUsageReading> fetchInstalledAgyUsage() async =>
    throw const AgyUsageFailure('agy.macos_only');
