import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/session_auth.dart';

void main() {
  tearDown(() => SessionAuth.pin = null);

  test('a PIN is six digits', () {
    final pin = SessionAuth.generatePin(Random(1));
    expect(pin, matches(RegExp(r'^\d{6}$')));
  });

  test('PIN comparison', () {
    expect(SessionAuth.matches('123456', '123456'), isTrue);
    expect(SessionAuth.matches('123457', '123456'), isFalse);
    expect(SessionAuth.matches('12345', '123456'), isFalse);
    expect(SessionAuth.matches(null, '123456'), isFalse);
  });

  test('headers carry the PIN only when one is set', () {
    expect(SessionAuth.headers, isEmpty);
    SessionAuth.pin = '424242';
    expect(SessionAuth.headers, {'x-session-pin': '424242'});
  });

  group('host gate', () {
    bool allows(String path, {String? pin = '111222', String? given, bool self = false}) =>
        SessionAuth.allows(path: path, requiredPin: pin, given: given, fromThisPhone: self);

    test('guarded paths need the PIN from other phones', () {
      for (final p in ['admin/reset_experiment', 'admin/scheduler', 'assignments/j/next', 'files']) {
        expect(allows(p), isFalse, reason: p);
        expect(allows(p, given: '000000'), isFalse, reason: p);
        expect(allows(p, given: '111222'), isTrue, reason: p);
      }
    });

    test('file downloads, the host itself, and open sessions pass', () {
      expect(allows('files/abc'), isTrue);
      expect(allows('files/abc/info'), isTrue);
      expect(allows('admin/reset_experiment', self: true), isTrue);
      expect(allows('admin/reset_experiment', pin: null), isTrue);
    });
  });
}
