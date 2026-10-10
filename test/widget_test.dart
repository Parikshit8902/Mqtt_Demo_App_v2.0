import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/main.dart';

void main() {
  testWidgets('Application starts', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.byType(MyApp), findsOneWidget);
  });
}