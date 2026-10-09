import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/session_link.dart';

void main() {
  test('round trip', () {
    final text = const SessionLink('192.168.1.10', pin: '123456').encode();
    expect(text, 'mqttdemo://join?host=192.168.1.10&pin=123456');
    final back = SessionLink.parse(text)!;
    expect(back.host, '192.168.1.10');
    expect(back.pin, '123456');
  });

  test('a bare address works, other text does not', () {
    expect(SessionLink.parse(' 10.0.0.5 ')!.host, '10.0.0.5');
    expect(SessionLink.parse('10.0.0.5')!.pin, isNull);
    expect(SessionLink.parse('https://example.com'), isNull);
    expect(SessionLink.parse('mqttdemo://join?host=not-an-ip&pin=1'), isNull);
    expect(SessionLink.parse('300.1.1.1'), isNull);
    expect(SessionLink.parse('mqttdemo://join?host=10.0.0.5')!.pin, isNull);
  });
}
