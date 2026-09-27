import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:my_dashboard/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('실제_Rust_인사말을_화면에_표시한다', (tester) async {
    await app.main();
    await tester.pumpAndSettle();
    expect(find.text('Hello, my_dashboard!'), findsOneWidget);
  });
}
