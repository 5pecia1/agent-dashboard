/// Startup API for applications that embed Agent Dashboard.
library;

export 'main.dart' show DashboardBootOverrides, runDashboard;
export 'src/state/config_provider.dart'
    show DashboardConfigValues, configDefaultsFnProvider;
export 'src/state/dashboard_extensions.dart'
    show additionalHomeSectionsProvider, additionalSetupSectionsProvider;
