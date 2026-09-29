import 'dart:convert';
import 'dart:io';

import 'package:my_dashboard/src/integrations/data/grok_usage_models.dart';

String grokAuthFilePath({String? grokHome, String? home}) {
  final override = grokHome?.trim();
  final root = override != null && override.isNotEmpty
      ? override
      : '${(home ?? '').trim()}/.grok';
  final separator = root.endsWith('/') ? '' : '/';
  return '$root${separator}auth.json';
}

GrokAuthReadResult readInstalledGrokAuth({DateTime? now}) => readGrokAuthAt(
  grokHome: Platform.environment['GROK_HOME'],
  home: Platform.environment['HOME'],
  now: now,
);

GrokAuthReadResult readGrokAuthAt({
  String? grokHome,
  String? home,
  DateTime? now,
}) {
  final file = File(grokAuthFilePath(grokHome: grokHome, home: home));
  if (!file.existsSync()) return const GrokAuthReadResult.missing();
  try {
    return interpretGrokAuthJson(
      jsonDecode(file.readAsStringSync()),
      now: now ?? DateTime.now(),
    );
  } on FormatException {
    return const GrokAuthReadResult.invalid();
  } catch (_) {
    return const GrokAuthReadResult.invalid();
  }
}

Uri resolveGrokBillingBase([String? override]) => resolveGrokBillingBaseValue(
  override ?? Platform.environment['GROK_CLI_CHAT_PROXY_BASE_URL'],
);
