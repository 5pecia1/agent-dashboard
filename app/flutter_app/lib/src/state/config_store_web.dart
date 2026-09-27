/// `config_provider.dart`의 웹 브리지 — `window.localStorage`.
///
/// 다른 탭/새로고침 사이에 값을 남긴다. 브라우저가 localStorage를 막았거나
/// (사생활 보호 모드 등) 파싱이 깨지면 [DashboardConfigValues.empty]로
/// 접는다 — `config_store_io.dart`와 같은 관용이다.
library;

import 'dart:convert';

import 'package:web/web.dart' as web;

import 'package:my_dashboard/src/state/config_provider.dart'
    show DashboardConfigValues;

const String _storageKey = 'my-dashboard.config.v1';
const String _backupKey = '$_storageKey.before-extensions';

Future<DashboardConfigValues> loadDashboardConfig() async {
  try {
    final raw = web.window.localStorage.getItem(_storageKey);
    if (raw == null) return DashboardConfigValues.empty;
    final Object? decoded = jsonDecode(raw) as Object?;
    if (decoded is! Map<String, Object?>) return DashboardConfigValues.empty;
    return DashboardConfigValues.fromJson(decoded);
  } on Object {
    return DashboardConfigValues.empty;
  }
}

Future<void> saveDashboardConfig(DashboardConfigValues values) async {
  final storage = web.window.localStorage;
  final previous = storage.getItem(_storageKey);
  if (previous != null && storage.getItem(_backupKey) == null) {
    storage.setItem(_backupKey, previous);
  }
  storage.setItem(_storageKey, jsonEncode(values.toJson()));
}
