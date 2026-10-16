import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'connected_client.dart';
import 'message_logger.dart';

/// Manages tracking of connected MQTT clients
class ClientTracker extends ChangeNotifier {
  final MessageLogger _logger;
  final Map<String, ConnectedClient> _connectedClients = {};
  
  ClientTracker(this._logger);
  
  /// Get list of connected clients
  List<ConnectedClient> get connectedClients => _connectedClients.values.toList();
  
  /// Get count of connected clients
  int get connectedCount => _connectedClients.length;
  
  /// Add a connected client
  void addClient(ConnectedClient client) {
    _logger.log('👥 Client connected: ${client.deviceName} (${client.ipAddress})');
    _connectedClients[client.clientId] = client;
    notifyListeners();
  }
  
  /// Remove a disconnected client
  void removeClient(String clientId) {
    final client = _connectedClients.remove(clientId);
    if (client != null) {
      _logger.log('👋 Client disconnected: ${client.deviceName} (${client.ipAddress})');
      notifyListeners();
    }
  }
  
  /// Check if a client is connected
  bool isClientConnected(String clientId) {
    return _connectedClients.containsKey(clientId);
  }
  
  /// Get client by ID
  ConnectedClient? getClient(String clientId) {
    return _connectedClients[clientId];
  }
  
  /// Clear all clients
  void clearAllClients() {
    _logger.log('🧹 Clearing all connected clients');
    _connectedClients.clear();
    notifyListeners();
  }
  
  /// Parse both the current `mobitest_<nameHex>_<brokerIP>_<deviceIP>_<token>`
  /// format and legacy `mqtt_client_<name>_<brokerIP>_<deviceIP>` IDs.
  ConnectedClient? parseClientInfo(String clientId) {
    try {
      final parts = clientId.split('_');
      if (parts.length >= 5 &&
          (clientId.startsWith('mobitest_') ||
              clientId.startsWith('mqtt_client_'))) {
        final hasToken = clientId.startsWith('mobitest_') && parts.length >= 5;
        final deviceIpPart = hasToken ? parts[parts.length - 2] : parts.last;
        final deviceIp = deviceIpPart.replaceAll('-', '.');
        String deviceName;
        if (clientId.startsWith('mobitest_')) {
          final hex = parts[1];
          final bytes = <int>[];
          for (var i = 0; i + 1 < hex.length; i += 2) {
            final byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
            if (byte == null) throw FormatException('Invalid device-name encoding');
            bytes.add(byte);
          }
          deviceName = utf8.decode(bytes, allowMalformed: true);
        } else {
          final nameEnd = parts.length - 2; // strip broker and device IP
          deviceName = parts.sublist(2, nameEnd).join('_');
        }
        return ConnectedClient(
          clientId: clientId,
          deviceName: deviceName.isEmpty ? clientId : deviceName,
          ipAddress: deviceIp,
          connectedAt: DateTime.now(),
        );
      }

      return ConnectedClient(
        clientId: clientId,
        deviceName: clientId,
        ipAddress: 'Unknown',
        connectedAt: DateTime.now(),
      );
    } catch (e) {
      _logger.log('❌ Error parsing client info from ID: $clientId - $e');
      return null;
    }
  }
}
