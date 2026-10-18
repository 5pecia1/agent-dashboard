import 'dart:convert';

import 'package:my_dashboard/src/integrations/data/agy_usage_models.dart';

const kAgyUsageArguments = <String>[
  '-p',
  '/usage',
  '--output-format',
  'json',
  '--print-timeout',
  '15s',
];
// 1.2.9 fixes headless daemons keeping stdout open after exit (official changelog).
const kAgyMinimumVersion = <int>[1, 2, 9];
final _versionPattern = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+[\w.]+)?$');

class AgyUsageFailure implements Exception {
  const AgyUsageFailure(this.labelKey);
  final String labelKey;
  bool get blocksPolling => const {
    'agy.not_installed',
    'agy.unsupported_version',
    'agy.sign_in_required',
  }.contains(labelKey);
  @override
  String toString() => labelKey;
}

class AgyCommandResult {
  const AgyCommandResult({
    required this.exitCode,
    required this.stdout,
    this.stderr = '',
  });
  final int exitCode;
  final String stdout;
  final String stderr;
}

typedef AgyCommandRun =
    Future<AgyCommandResult> Function(List<String> arguments);

/// Official read-only slash command, introduced in agy 1.1.11.
/// Version-check before querying: older releases could treat slash text as a turn.
class AgyUsageApi {
  const AgyUsageApi(this.run);
  final AgyCommandRun run;

  Future<AgyUsageReading> fetch() async {
    try {
      final version = await run(const ['--version']);
      if (version.exitCode != 0) throw _commandFailure(version);
      if (!_supportedVersion(version.stdout.trim())) {
        throw const AgyUsageFailure('agy.unsupported_version');
      }
      final result = await run(kAgyUsageArguments);
      Object? json;
      try {
        json = jsonDecode(result.stdout);
      } on FormatException {
        if (result.exitCode != 0) throw _commandFailure(result);
        rethrow;
      }
      if (result.exitCode != 0 || (json is Map && json['status'] == 'ERROR')) {
        throw _commandFailure(
          result,
          error: json is Map ? json['error'] : null,
        );
      }
      if (json is! Map || json['status'] != 'SUCCESS') {
        throw const AgyUsageFailure('agy.invalid_response');
      }
      final command = json['command'];
      if (json['num_turns'] != 0 ||
          command is! Map ||
          command['name'] != 'usage') {
        throw const AgyUsageFailure('agy.invalid_response');
      }
      final reading = agyUsageReadingFromJson(command['data']);
      if (reading.groups.isEmpty) throw const AgyUsageFailure('agy.no_usage');
      return reading;
    } on AgyUsageFailure {
      rethrow;
    } on FormatException {
      throw const AgyUsageFailure('agy.invalid_response');
    } catch (_) {
      throw const AgyUsageFailure('agy.query_failed');
    }
  }
}

bool _supportedVersion(String text) {
  final match = _versionPattern.firstMatch(text);
  if (match == null) return false;
  for (var i = 0; i < kAgyMinimumVersion.length; i++) {
    final part = int.parse(match[i + 1]!);
    if (part != kAgyMinimumVersion[i]) return part > kAgyMinimumVersion[i];
  }
  return true;
}

AgyUsageFailure _commandFailure(AgyCommandResult result, {Object? error}) {
  // Only classify diagnostics; never expose them (they may contain account data).
  final message = '${error ?? ''}\n${result.stdout}\n${result.stderr}'
      .toLowerCase();
  const authMessages = [
    'authentication required',
    'authentication expired',
    'not authenticated',
    'not logged in',
    'please log in',
    'please sign in',
    'invalid_grant',
  ];
  return AgyUsageFailure(
    authMessages.any(message.contains)
        ? 'agy.sign_in_required'
        : 'agy.query_failed',
  );
}
