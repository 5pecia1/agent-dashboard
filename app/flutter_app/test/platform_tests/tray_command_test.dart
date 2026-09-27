/// TASK TRAY-impl 완료 기준 (6): [TrayCommand.fromKey] 전수 확인.
///
/// 순수 enum이라 `tray_manager`/`dart:io` 어느 쪽도 끌고 오지 않는다 —
/// `platform/tray_command.dart`를 직접 import한다(파사드 `tray.dart`를
/// 거치지 않아도 안전하다는 사실 자체가 "플랫폼 의존이 없다"는 설계
/// 의도를 증명한다).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/platform/tray_command.dart';

void main() {
  group('TrayCommand.fromKey', () {
    for (final command in TrayCommand.values) {
      test('${command.name}는 자기 자신의 menuItemKey로 되찾아진다', () {
        expect(TrayCommand.fromKey(command.menuItemKey), command);
      });
    }

    test('알 수 없는 키는 null이다', () {
      expect(TrayCommand.fromKey('no_such_command'), isNull);
    });

    test('null 키(예: 구분선 MenuItem.separator())도 null이다', () {
      expect(TrayCommand.fromKey(null), isNull);
    });

    test('세 값의 menuItemKey는 서로 겹치지 않는다', () {
      final keys = TrayCommand.values.map((c) => c.menuItemKey).toSet();
      expect(keys, hasLength(TrayCommand.values.length));
    });
  });
}
