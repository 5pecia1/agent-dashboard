import 'dart:io';

/// Select the exact pixel baseline for the host renderer.
String hostGolden(String name) {
  const macos27Version = 'Version 27.';
  final host = Platform.isMacOS &&
          Platform.operatingSystemVersion.startsWith(macos27Version)
      ? 'macos27'
      : Platform.operatingSystem;
  return '../goldens/${name}_$host.png';
}
