import 'dart:io';

const qaStateRelativePath = '.local/state/my-dashboard';
const _marker = '.my-dashboard-qa-home';

void requireFreshDashboardHome(String? home) {
  if (home == null || !File('$home/$_marker').existsSync()) {
    throw StateError('QA requires $_marker in its isolated HOME');
  }
  final state = '$home/$qaStateRelativePath';
  if (FileSystemEntity.typeSync(state, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw StateError('QA requires a fresh state directory: $state');
  }
}
