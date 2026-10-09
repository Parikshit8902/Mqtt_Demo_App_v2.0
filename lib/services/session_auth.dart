import 'dart:math';

/// The PIN that protects a hosted session. Without it a phone on the same
/// Wi-Fi cannot join the MQTT broker or call the host's `/admin/*` and
/// `/assignments/*` endpoints (so it cannot reset the experiment, switch the
/// scheduler or post fake results).
///
/// On the host it is generated when the session starts and shown on screen;
/// on a worker it is what the user typed when joining. One app instance is
/// either hosting or joined, so one value serves both.
class SessionAuth {
  SessionAuth._();

  /// MQTT login: this user name with the PIN as the password.
  static const String mqttUsername = 'session';

  /// HTTP header that carries the PIN (a `pin` query parameter also works,
  /// for opening admin URLs in a laptop browser).
  static const String header = 'x-session-pin';

  static String? pin;

  /// Headers to add to every request to the host.
  static Map<String, String> get headers {
    final p = pin;
    return p == null || p.isEmpty ? const {} : {header: p};
  }

  /// A fresh six-digit PIN.
  static String generatePin([Random? random]) {
    final r = random ?? Random.secure();
    return List.generate(6, (_) => r.nextInt(10)).join();
  }

  /// Whether the host serves a request for [path] (relative, no leading
  /// slash). Only `admin/*`, `assignments/*` and the file list are guarded,
  /// only while a PIN is set, and never for requests from the host itself.
  static bool allows({
    required String path,
    required String? requiredPin,
    required String? given,
    required bool fromThisPhone,
  }) {
    final guarded = path.startsWith('admin/') || path.startsWith('assignments/') || path == 'files';
    if (requiredPin == null || !guarded || fromThisPhone) return true;
    return matches(given, requiredPin);
  }

  /// Whether [given] is [expected], compared in constant time so response
  /// timing does not reveal how many leading digits were right.
  static bool matches(String? given, String expected) {
    if (given == null || given.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= given.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return diff == 0;
  }
}
