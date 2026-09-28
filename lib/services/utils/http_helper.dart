import 'dart:convert';
import 'package:http/http.dart' as http;

/// Tiny HTTP helper that returns parsed JSON for 200 responses and throws
/// an exception otherwise. Callers can catch and log as needed.
Future<dynamic> httpGetJson(Uri url) async {
  final resp = await http.get(url);
  if (resp.statusCode == 200) {
    if (resp.body.isEmpty) return null;
    return jsonDecode(resp.body);
  }
  throw HttpException('GET ${url.toString()} returned ${resp.statusCode}');
}

Future<dynamic> httpPostJson(Uri url, Object body) async {
  final resp = await http.post(url, headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));
  if (resp.statusCode == 200) {
    if (resp.body.isEmpty) return null;
    return jsonDecode(resp.body);
  }
  throw HttpException('POST ${url.toString()} returned ${resp.statusCode}');
}

class HttpException implements Exception {
  final String message;
  HttpException(this.message);
  @override
  String toString() => 'HttpException: $message';
}
