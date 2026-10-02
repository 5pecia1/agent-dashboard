/// `config_provider.dart`의 웹 브리지 — `window.localStorage`.
///
/// 다른 탭/새로고침 사이에 값을 남긴다. 읽기 계약은 `config_store_io.dart`와
/// 같다(`config_provider.dart`의 `ConfigLoadFn`): 키가 없을 때만 빈 값이고,
/// 브라우저가 저장소 접근을 막으면 [ConfigReadFailureKind.access], 저장된
/// 문자열이 설정 JSON 객체가 아니면 [ConfigReadFailureKind.corrupt]를
/// 던진다. 빈 값으로 접으면 다음 저장이 저장된 서버 주소와 토큰을 지운다.
///
/// 부팅만은 막힌 저장소에서 실패 화면 없이 빈 값으로 시작한다
/// (`ui/config_read_failure.dart`의 `shouldBootWithoutStoredConfig`). 이
/// 브리지는 그때도 던진다 — 그래서 시작한 뒤의 읽기와 쓰기는 계속 막힌다.
library;

import 'dart:convert';

import 'package:web/web.dart' as web;

import 'package:my_dashboard/src/state/config_provider.dart'
    show
        ConfigReadException,
        ConfigReadFailureKind,
        DashboardConfigValues,
        decodeStoredDashboardConfig;

const String _storageKey = 'my-dashboard.config.v1';
const String _backupKey = '$_storageKey.before-extensions';
const String _location = 'localStorage[$_storageKey]';

Future<DashboardConfigValues> loadDashboardConfig() async {
  final String? raw;
  try {
    raw = web.window.localStorage.getItem(_storageKey);
  } catch (error) {
    // 저장소 접근 오류(SecurityError 등)의 메시지에는 저장된 값이 없다.
    throw ConfigReadException(
      ConfigReadFailureKind.access,
      location: _location,
      detail: '$error',
    );
  }
  if (raw == null) return DashboardConfigValues.empty;
  return decodeStoredDashboardConfig(raw, location: _location);
}

Future<void> saveDashboardConfig(DashboardConfigValues values) async {
  final storage = web.window.localStorage;
  final previous = storage.getItem(_storageKey);
  if (previous != null && storage.getItem(_backupKey) == null) {
    storage.setItem(_backupKey, previous);
  }
  storage.setItem(_storageKey, jsonEncode(values.toJson()));
}
