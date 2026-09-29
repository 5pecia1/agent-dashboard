import 'dart:convert';
import 'dart:io';

import 'package:my_dashboard/src/integrations/data/grok_bot_models.dart';
import 'package:my_dashboard/src/integrations/data/grok_bot_secret.dart';

typedef GrokBotKeychainReader = Future<GrokBotKeychainRead> Function();

String grokBotSupportDir({String? supportDir, String? home}) {
  final override = supportDir?.trim();
  if (override != null && override.isNotEmpty) return override;
  final root = (home ?? '').trim();
  return '$root/Library/Application Support/Grok Bot';
}

GrokBotPreview readInstalledGrokBotPreview() => readGrokBotPreviewAt(
  supportDir: Platform.environment['GROK_BOT_SUPPORT_DIR'],
  home: Platform.environment['HOME'],
);

GrokBotPreview readGrokBotPreviewAt({String? supportDir, String? home}) {
  final file = File(
    '${grokBotSupportDir(supportDir: supportDir, home: home)}/sand-secrets.json',
  );
  if (!file.existsSync()) return const GrokBotPreview.missing();
  try {
    return grokBotPreviewFromSecrets(jsonDecode(file.readAsStringSync()));
  } on FormatException {
    return const GrokBotPreview.unreadable();
  } catch (_) {
    return const GrokBotPreview.unreadable();
  }
}

Future<GrokBotAuthReadResult> unlockInstalledGrokBot(GrokBotPreview preview) =>
    unlockGrokBotAt(preview);

Future<GrokBotAuthReadResult> unlockGrokBotAt(
  GrokBotPreview preview, {
  GrokBotKeychainReader? readKeychain,
}) async {
  final ciphertext = preview.ciphertext;
  if (preview.status != GrokBotAuthStatus.ready ||
      ciphertext == null ||
      ciphertext.isEmpty) {
    return GrokBotAuthReadResult(preview.status);
  }
  final keychain = await (readKeychain ?? readGrokBotKeychainPassword)();
  if (keychain.status == GrokBotKeychainStatus.denied) {
    return const GrokBotAuthReadResult.keychainDenied();
  }
  final password = keychain.password;
  if (keychain.status != GrokBotKeychainStatus.ready ||
      password == null ||
      password.isEmpty) {
    return const GrokBotAuthReadResult.unreadable();
  }
  final token = decryptGrokBotCiphertext(ciphertext, password);
  if (token == null || token.isEmpty) {
    return const GrokBotAuthReadResult.unreadable();
  }
  return GrokBotAuthReadResult(
    GrokBotAuthStatus.ready,
    accessToken: token,
    ciphertextHash: preview.ciphertextHash,
  );
}

Future<GrokBotKeychainRead> readGrokBotKeychainPassword() async {
  try {
    final result = await Process.run('/usr/bin/security', [
      'find-generic-password',
      '-s',
      kGrokBotKeychainService,
      '-a',
      kGrokBotKeychainAccount,
      '-w',
    ]);
    return interpretGrokBotKeychain(
      exitCode: result.exitCode,
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
    );
  } catch (_) {
    return const GrokBotKeychainRead.unavailable();
  }
}
