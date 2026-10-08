/// What a phone needs to join a hosted session, as carried by the host's QR
/// code: `mqttdemo://join?host=192.168.1.10&pin=123456`.
class SessionLink {
  static const String scheme = 'mqttdemo';

  final String host;
  final String? pin;

  const SessionLink(this.host, {this.pin});

  String encode() => Uri(
        scheme: scheme,
        host: 'join',
        queryParameters: {'host': host, if (pin != null && pin!.isNotEmpty) 'pin': pin},
      ).toString();

  /// The link in [text], or null if it is not one. A bare IPv4 address is
  /// accepted too, so a QR code with just the host's address also works.
  static SessionLink? parse(String text) {
    final t = text.trim();
    if (_ipv4.hasMatch(t)) return SessionLink(t);
    final uri = Uri.tryParse(t);
    if (uri == null || uri.scheme != scheme || uri.host != 'join') return null;
    final host = uri.queryParameters['host'] ?? '';
    if (!_ipv4.hasMatch(host)) return null;
    final pin = uri.queryParameters['pin'];
    return SessionLink(host, pin: (pin == null || pin.isEmpty) ? null : pin);
  }

  static final RegExp _ipv4 = RegExp(r'^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$');
}
