/// File, browser storage and asset names belong to the running application.
library;

const dashboardDefaultDirectoryName = 'my-dashboard';

class DashboardHost {
  DashboardHost({
    this.stateDirectoryName = dashboardDefaultDirectoryName,
    this.packageAssets = false,
  }) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(stateDirectoryName)) {
      throw ArgumentError.value(stateDirectoryName, 'stateDirectoryName');
    }
  }

  final String stateDirectoryName;
  final bool packageAssets;

  String stateDirectory(String home) =>
      '$home/.local/state/$stateDirectoryName';

  String storageKey(String key) => '$stateDirectoryName.$key';

  String assetKey(String asset) =>
      packageAssets ? 'packages/my_dashboard/$asset' : asset;
}

DashboardHost dashboardHost = DashboardHost();
