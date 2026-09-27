import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/config_store_io.dart';

void main() {
  test('공개 설정을 저장해도 모르는 중첩 필드와 자격증명은 그대로 남는다', () {
    final old = <String, Object?>{
      'client_token': 'fixture-client',
      'cursor': 41,
      'optional_connection': <String, Object?>{
        'url': 'https://fixture.example',
        'api_key': 'fixture-private',
        'nested': <Object?>[
          1,
          null,
          <String, Object?>{'enabled': true},
        ],
      },
      'future_setting': false,
    };
    final read = DashboardConfigValues.fromJson(old);
    final saved = read.copyWith(cursor: 42, themeMode: 'dark');
    expect(saved.toJson()['optional_connection'], old['optional_connection']);
    expect(saved.toJson()['future_setting'], false);
    expect(saved.toString(), isNot(contains('fixture-private')));
    final again = DashboardConfigValues.fromJson(
      jsonDecode(jsonEncode(saved.toJson())) as Map<String, Object?>,
    );
    expect(again, saved);
    expect(again.hashCode, saved.hashCode);
    expect(again.copyWith(cursor: 42), saved, reason: '같은 값 패치는 다시 저장하지 않는다');
  });

  test('최초 저장은 원본 바이트를 백업하고 반복 저장은 백업을 덮지 않는다', () async {
    final dir = await Directory.systemTemp.createTemp('dashboard-config-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/config.json');
    const original = '{\n "cursor": 41, "future": {"token": "fixture"}\n}\n';
    await file.writeAsString(original);
    final values = DashboardConfigValues.fromJson(
      jsonDecode(original) as Map<String, Object?>,
    );
    await saveDashboardConfigFile(file, values.copyWith(cursor: 42));
    final backup = File('${file.path}.before-extensions');
    expect(await backup.readAsString(), original);
    await saveDashboardConfigFile(file, values.copyWith(cursor: 43));
    expect(await backup.readAsString(), original);
    final persisted =
        jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(persisted['cursor'], 43);
    expect(persisted['future'], {'token': 'fixture'});
    if (!Platform.isWindows) {
      expect((await file.stat()).mode & 0x1ff, 0x180);
      expect((await backup.stat()).mode & 0x1ff, 0x180);
    }
  });
}
