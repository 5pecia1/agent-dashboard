import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/integrations/data/agy_usage_api.dart';
import 'package:my_dashboard/src/integrations/platform/agy_usage_io.dart';

import '../fixtures/agy_usage_fixture.dart';

Future<File> _executable(Directory directory, String script) async {
  final file = File('${directory.path}/agy');
  await file.writeAsString('#!/usr/bin/env python3\n$script');
  final result = await Process.run('/bin/chmod', ['700', file.path]);
  expect(result.exitCode, 0);
  return file;
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('agy-process-test-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('공식 설치 경로와 PATH를 탐색하고 명시한 경로를 다른 설치로 대체하지 않는다', () async {
    final bin = await Directory(
      '${directory.path}/.local/bin',
    ).create(recursive: true);
    final exe = await _executable(bin, 'print("1.3.3")');
    expect(findAgyExecutable(home: directory.path, path: ''), exe.path);
    final custom = await Directory('${directory.path}/custom').create();
    final customExe = await _executable(custom, 'print("1.3.3")');
    expect(
      findAgyExecutable(home: '/missing', path: '/missing:${custom.path}'),
      customExe.path,
    );
    expect(
      findAgyExecutable(home: directory.path, override: '/not-installed/agy'),
      isNull,
    );
    await Process.run('/bin/chmod', ['600', exe.path]);
    expect(findAgyExecutable(home: directory.path, path: ''), isNull);
    expect(findAgyExecutable(override: 'relative/agy'), isNull);
    await expectLater(
      fetchAgyUsageAt(executableOverride: '/not-installed/agy'),
      throwsA(
        isA<AgyUsageFailure>().having(
          (e) => e.labelKey,
          'label',
          'agy.not_installed',
        ),
      ),
    );
  });

  test('실제 자식 프로세스에 읽기 전용 인자와 환경을 주고 임시 로그를 지운다', () async {
    final marker = File('${directory.path}/cwd.txt');
    final exe = await _executable(directory, '''
import json, os, pathlib, sys
if sys.argv[1:] == ["--version"]:
    print("1.3.3")
    sys.exit(0)
assert os.environ.get("AGY_CLI_DISABLE_AUTO_UPDATE") == "true"
assert sys.argv[1:7] == ["-p", "/usage", "--output-format", "json", "--print-timeout", "15s"]
assert sys.argv[7] == "--log-file"
assert pathlib.Path(sys.argv[8]).parent.resolve() == pathlib.Path.cwd()
assert sys.stdin.read() == ""
pathlib.Path(sys.argv[8]).write_text("fixture log")
pathlib.Path(${jsonEncode(marker.path)}).write_text(os.getcwd())
print(${jsonEncode(jsonEncode(agyUsageFixture()))})
''');
    final reading = await fetchAgyUsageAt(executableOverride: exe.path);
    expect(reading.groups, hasLength(2));
    final work = Directory(await marker.readAsString());
    expect(work.path, isNot(directory.path));
    expect(await work.exists(), isFalse);
  });

  test('시간 초과이면 프로세스를 실제 종료하고 결과나 로그를 남기지 않는다', () async {
    final marker = File('${directory.path}/process.json');
    final exe = await _executable(directory, '''
import json, os, pathlib, sys, time
if sys.argv[1:] == ["--version"]:
    print("1.3.3")
    sys.exit(0)
pathlib.Path(${jsonEncode(marker.path)}).write_text(json.dumps({"pid": os.getpid(), "cwd": os.getcwd()}))
time.sleep(30)
''');
    await expectLater(
      fetchAgyUsageAt(
        executableOverride: exe.path,
        commandTimeout: const Duration(seconds: 1),
      ),
      throwsA(
        isA<AgyUsageFailure>().having(
          (e) => e.labelKey,
          'label',
          'agy.timeout',
        ),
      ),
    );
    final state = jsonDecode(await marker.readAsString()) as Map;
    final alive = await Process.run('/bin/kill', ['-0', '${state['pid']}']);
    expect(alive.exitCode, isNot(0));
    expect(await Directory(state['cwd'] as String).exists(), isFalse);
  });

  test('출력 한도를 넘기는 프로세스는 유효한 쿼터로 받아들이지 않는다', () async {
    final exe = await _executable(directory, '''
import sys
if sys.argv[1:] == ["--version"]:
    print("1.3.3")
else:
    sys.stdout.write("x" * ${kAgyOutputLimitBytes + 1})
''');
    await expectLater(
      fetchAgyUsageAt(executableOverride: exe.path),
      throwsA(
        isA<AgyUsageFailure>().having(
          (e) => e.labelKey,
          'label',
          'agy.invalid_response',
        ),
      ),
    );
  });
}
