import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:hotkey_manager/hotkey_manager.dart';

import 'package:sol_app/src/platform/feature_status.dart';

export 'package:hotkey_manager/hotkey_manager.dart'
    show HotKey, HotKeyModifier, HotKeyScope;

typedef RegisterHotkey =
    Future<void> Function(HotKey key, {HotKeyHandler? keyDownHandler});

/// Owns only the bindings explicitly supplied by this app's caller.
class GlobalHotkeys {
  GlobalHotkeys({
    RegisterHotkey? register,
    Future<void> Function(HotKey)? unregister,
    bool Function()? supported,
    DesktopFeatureStatus? status,
  }) : _register =
           register ??
           ((key, {keyDownHandler}) =>
               hotKeyManager.register(key, keyDownHandler: keyDownHandler)),
       _unregister = unregister ?? ((key) => hotKeyManager.unregister(key)),
       _supported = supported ?? (() => hasDesktopHost),
       _status = status ?? desktopFeatureStatus;

  final RegisterHotkey _register;
  final Future<void> Function(HotKey) _unregister;
  final bool Function() _supported;
  final DesktopFeatureStatus _status;
  final Map<String, HotKey> _owned = {};
  final Set<String> _observed = {};
  Object? lastError;

  bool get hasRegistrations => _owned.isNotEmpty;
  bool get hasConfirmedCallbacks => _observed.isNotEmpty;

  Future<bool> register(HotKey key, VoidCallback onPressed) async {
    if (!_supported()) return false;
    if (key.scope != HotKeyScope.system) {
      throw ArgumentError('global bindings require HotKeyScope.system');
    }
    if (_owned.containsKey(key.identifier)) {
      throw StateError('binding already owned: ${key.identifier}');
    }
    try {
      await _register(
        key,
        keyDownHandler: (_) {
          if (!_owned.containsKey(key.identifier)) return;
          _observed.add(key.identifier);
          _status.hotkeyChanged(true);
          onPressed();
        },
      );
      _owned[key.identifier] = key;
      lastError = null;
      // The pinned macOS plugin acknowledges requests even when native
      // registration fails. Only an observed callback proves availability.
      _status.hotkeyChanged(_observed.isNotEmpty);
      return true;
    } on Exception catch (error) {
      lastError = error;
      _status.hotkeyChanged(_observed.isNotEmpty);
      return false;
    }
  }

  Future<void> unregister(HotKey key) async {
    final owned = _owned[key.identifier];
    if (owned == null) return;
    await _unregister(owned);
    _owned.remove(key.identifier);
    _observed.remove(key.identifier);
    _status.hotkeyChanged(_observed.isNotEmpty);
  }

  /// Call in the owner's shutdown/finally path; other bindings are never cleared.
  Future<void> dispose() async {
    for (final key in _owned.values.toList()) {
      await unregister(key);
    }
  }
}

final globalHotkeys = GlobalHotkeys();
