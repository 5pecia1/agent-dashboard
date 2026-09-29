import 'package:my_dashboard/src/integrations/data/grok_usage_models.dart';

GrokAuthReadResult readInstalledGrokAuth({DateTime? now}) =>
    const GrokAuthReadResult.unsupported();

Uri resolveGrokBillingBase([String? override]) =>
    Uri.parse(kGrokDefaultBillingBase);
