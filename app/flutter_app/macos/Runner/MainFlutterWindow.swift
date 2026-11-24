import FlutterMacOS
import my_dashboard_frb

class MainFlutterWindow: DashboardFlutterWindow {
  override func registerDashboardPlugins(_ registry: FlutterPluginRegistry) {
    RegisterGeneratedPlugins(registry: registry)
  }
}
