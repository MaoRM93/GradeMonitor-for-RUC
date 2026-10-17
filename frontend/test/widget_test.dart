import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grademonitor/main.dart';

void main() {
  testWidgets('App renders without error', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: GradeMonitorApp(),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text('GradeMonitor'), findsNothing);
  });
}
