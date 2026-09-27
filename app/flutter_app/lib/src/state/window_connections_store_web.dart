import 'package:my_dashboard/src/data/window_connection.dart';

Future<List<WindowConnectionRule>> loadWindowConnections() async => const [];

Future<void> saveWindowConnections(List<WindowConnectionRule> rules) async {
  throw UnsupportedError(
    'Window connections are available only in the desktop app',
  );
}
