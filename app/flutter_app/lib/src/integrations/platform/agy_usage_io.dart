import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:my_dashboard/src/integrations/data/agy_usage_api.dart';
import 'package:my_dashboard/src/integrations/data/agy_usage_models.dart';

const Duration kAgyCommandTimeout = Duration(seconds: 25);
const Duration kAgyVersionTimeout = Duration(seconds: 3);
const Duration _processExitTimeout = Duration(seconds: 1);
const int kAgyOutputLimitBytes = 1024 * 1024;
const int _executableModeBits = 0x49; // Unix permission bits 0111.
const String _pathListSeparator = ':'; // This transport targets macOS.
const kAgyReadOnlyEnvironment = {'AGY_CLI_DISABLE_AUTO_UPDATE': 'true'};

/// Finder launches do not inherit the user's shell PATH. Check the official
/// installer location first; the explicit override also supports custom installs.
String? findAgyExecutable({String? home, String? path, String? override}) {
  final explicit = override?.trim();
  final candidates = explicit != null && explicit.isNotEmpty
      ? [explicit]
      : <String>[
          if (home != null && home.isNotEmpty) '$home/.local/bin/agy',
          '/opt/homebrew/bin/agy',
          '/usr/local/bin/agy',
          for (final dir in (path ?? '').split(_pathListSeparator))
            if (dir.isNotEmpty && dir.startsWith('/')) '$dir/agy',
        ];
  for (final candidate in candidates) {
    if (!candidate.startsWith('/')) continue;
    try {
      final stat = File(candidate).statSync();
      if (stat.type == FileSystemEntityType.file &&
          (stat.mode & _executableModeBits) != 0) {
        return candidate;
      }
    } on FileSystemException {
      continue;
    }
  }
  return null;
}

Future<AgyUsageReading> fetchInstalledAgyUsage() => fetchAgyUsageAt(
  home: Platform.environment['HOME'],
  path: Platform.environment['PATH'],
  executableOverride: Platform.environment['AGY_CLI_PATH'],
);

Future<AgyUsageReading> fetchAgyUsageAt({
  String? home,
  String? path,
  String? executableOverride,
  Duration commandTimeout = kAgyCommandTimeout,
}) async {
  final executable = findAgyExecutable(
    home: home,
    path: path,
    override: executableOverride,
  );
  if (executable == null) throw const AgyUsageFailure('agy.not_installed');
  // Neutral cwd avoids loading project-specific customizations for a quota read.
  // Each call owns its log; cleanup prevents logs accumulating every poll.
  final directory = await Directory.systemTemp.createTemp('dashboard-agy-');
  try {
    return await AgyUsageApi(
      (arguments) => runAgyCommand(
        executable: executable,
        arguments: arguments,
        directory: directory.path,
        timeout: arguments.first == '--version'
            ? kAgyVersionTimeout
            : commandTimeout,
      ),
    ).fetch();
  } finally {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // A filesystem cleanup failure must not discard a successful reading.
    }
  }
}

/// Bound both the process and its pipes. Future.timeout alone does not stop agy.
Future<AgyCommandResult> runAgyCommand({
  required String executable,
  required List<String> arguments,
  required String directory,
  required Duration timeout,
}) async {
  final process = await Process.start(
    executable,
    [
      ...arguments,
      if (arguments.first != '--version') ...[
        '--log-file',
        '$directory/usage.log',
      ],
    ],
    workingDirectory: directory,
    environment: kAgyReadOnlyEnvironment,
  );
  unawaited(process.stdin.close().catchError((Object _) {}));
  final out = BytesBuilder(copy: false);
  final err = BytesBuilder(copy: false);
  var outputBytes = 0;
  var overflow = false;
  final subscriptions = <StreamSubscription<List<int>>>[];
  Future<void> capture(Stream<List<int>> stream, BytesBuilder buffer) {
    final done = Completer<void>();
    subscriptions.add(
      stream.listen(
        (bytes) {
          outputBytes += bytes.length;
          if (outputBytes > kAgyOutputLimitBytes) {
            overflow = true;
            process.kill(ProcessSignal.sigkill);
          } else {
            buffer.add(bytes);
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object error, StackTrace stack) {
          if (!done.isCompleted) done.completeError(error, stack);
        },
      ),
    );
    return done.future;
  }

  try {
    final results = await Future.wait<Object?>([
      process.exitCode,
      capture(process.stdout, out),
      capture(process.stderr, err),
    ]).timeout(timeout);
    if (overflow) throw const AgyUsageFailure('agy.invalid_response');
    return AgyCommandResult(
      exitCode: results.first! as int,
      stdout: utf8.decode(out.takeBytes()),
      stderr: utf8.decode(err.takeBytes(), allowMalformed: true),
    );
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    throw const AgyUsageFailure('agy.timeout');
  } finally {
    process.kill(ProcessSignal.sigkill);
    try {
      await process.exitCode.timeout(_processExitTimeout);
    } on TimeoutException {
      // Pipes are canceled below even if the operating system delays reaping.
    }
    await Future.wait(
      subscriptions.map((subscription) => subscription.cancel()),
    );
  }
}
