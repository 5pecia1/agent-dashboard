import 'package:flutter/widgets.dart' show Size;
import 'package:window_manager/window_manager.dart';

import 'package:sol_app/src/platform/feature_status.dart';

Future<void> _initializeWindowManager() async {
  await windowManager.ensureInitialized();
  await windowManager.getSize();
}

/// Window operations preserve the product's geometry until the caller changes it.
class WindowControl {
  WindowControl({
    Future<void> Function()? initialize,
    Future<void> Function(Size)? resize,
    Future<void> Function()? show,
    Future<void> Function()? hide,
    Future<void> Function()? focus,
    bool Function()? supported,
    DesktopFeatureStatus? status,
  }) : _initialize = initialize ?? _initializeWindowManager,
       _resize = resize ?? ((size) => windowManager.setSize(size)),
       _show = show ?? (() => windowManager.show()),
       _hide = hide ?? (() => windowManager.hide()),
       _focus = focus ?? (() => windowManager.focus()),
       _supported = supported ?? (() => hasDesktopHost),
       _status = status ?? desktopFeatureStatus;

  final Future<void> Function() _initialize;
  final Future<void> Function(Size) _resize;
  final Future<void> Function() _show;
  final Future<void> Function() _hide;
  final Future<void> Function() _focus;
  final bool Function() _supported;
  final DesktopFeatureStatus _status;
  Object? lastError;

  Future<bool> initialize() async {
    _status.windowChanged(false);
    if (!_supported()) return false;
    return _perform(_initialize);
  }

  Future<bool> _perform(Future<void> Function() operation) async {
    try {
      await operation();
      lastError = null;
      _status.windowChanged(true);
      return true;
    } on Exception catch (error) {
      lastError = error;
      _status.windowChanged(false);
      return false;
    }
  }

  Future<bool> resize(Size size) async {
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0) {
      throw ArgumentError.value(
        size,
        'size',
        'window dimensions must be positive and finite',
      );
    }
    return _status.windowControl && await _perform(() => _resize(size));
  }

  Future<bool> show() async => _status.windowControl && await _perform(_show);
  Future<bool> hide() async => _status.windowControl && await _perform(_hide);
  Future<bool> focus() async => _status.windowControl && await _perform(_focus);
}

final windowControl = WindowControl();
