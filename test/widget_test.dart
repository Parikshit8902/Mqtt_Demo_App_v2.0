import 'package:flutter_test/flutter_test.dart';

import 'package:mqtt_demo/main.dart';

void main() {
  testWidgets('home screen offers hosting or joining a session', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('MQTT Sessions'), findsOneWidget);
    expect(find.text('Host a Session'), findsOneWidget);
    expect(find.text('Join a Session'), findsOneWidget);
  });
}
