import 'dart:async';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:mqtt_server/mqtt_server.dart';

import 'message_logger.dart';
import 'udp_broadcast_manager.dart';
import 'client_tracker.dart';

/// Manages MQTT broker operations.
class MqttBrokerManager {
  final MessageLogger _logger;
  final Function()? _onStateChanged;
  final ClientTracker _clientTracker;

  MqttBroker? _broker;
  bool _isBrokerRunning = false;
  bool _isDisposed = false;
  bool _isStopping = false;

  MqttServerClient? _brokerMonitorClient;
  UdpBroadcastManager? _udpBroadcastManager;

  Future<void>? _stopFuture;
  Future<void>? _monitorStartFuture;

  MqttBrokerManager(
    this._logger,
    this._clientTracker, {
    Function()? onStateChanged,
  }) : _onStateChanged = onStateChanged;

  /// Get broker running status.
  bool get isBrokerRunning => _isBrokerRunning;

  /// Notify listeners only while this manager is alive.
  void _notifyStateChanged() {
    if (!_isDisposed) {
      _onStateChanged?.call();
    }
  }

  /// Start the MQTT broker.
  Future<bool> startBroker() async {
    if (_isDisposed || _isStopping) {
      _logger.log('⚠️ Cannot start broker: manager is stopping or disposed');
      return false;
    }

    _logger.log('🚀 Starting MQTT broker...');

    try {
      // Stop an existing broker before starting another.
      final existingBroker = _broker;
      if (existingBroker != null) {
        _logger.log('⚠️ Stopping existing broker before starting new one');
        _broker = null;
        await existingBroker.stop();
      }

      if (_isDisposed || _isStopping) return false;

      // Stop any existing UDP broadcast.
      await _udpBroadcastManager?.stopBroadcast();
      _udpBroadcastManager = null;

      if (_isDisposed || _isStopping) return false;

      _logger.log(
        '⚙️ Creating broker configuration (port: 1883, anonymous: true)',
      );

      final config = MqttBrokerConfig(
        port: 1883,
        allowAnonymous: true,
        enablePersistence: false,
      );

      _logger.log('🔧 Creating broker instance');

      final broker = MqttBroker(config);
      _broker = broker;

      _setupClientTracking();

      _logger.log('🎯 Starting broker on port 1883...');
      await broker.start();

      // Startup may have overlapped with shutdown.
      if (_isDisposed || _isStopping || !identical(_broker, broker)) {
        await broker.stop();
        return false;
      }

      _isBrokerRunning = true;

      _logger.log('✅ MQTT Broker started successfully on port 1883');
      _logger.log('📡 Broker is ready to accept client connections');

      _logger.log('📢 Starting UDP broadcast announcements...');
      final udpManager = UdpBroadcastManager(_logger);
      _udpBroadcastManager = udpManager;

      await udpManager.startBroadcast();

      if (_isDisposed || _isStopping || !identical(_broker, broker)) {
        await udpManager.stopBroadcast();
        return false;
      }

      _logger.log('👂 Starting broker monitoring client...');

      // Keep the monitoring startup operation so shutdown can await it.
      final monitorFuture = _startBrokerMonitoringClient();
      _monitorStartFuture = monitorFuture;

      unawaited(
        monitorFuture.catchError((Object error, StackTrace stackTrace) {
          _logger.log('⚠️ Broker monitoring client failed to start: $error');
          _logger.log('📝 Broker will continue without message monitoring');
        }),
      );

      _notifyStateChanged();
      return true;
    } catch (e) {
      _logger.log('❌ Failed to start broker: $e');

      _isBrokerRunning = false;
      _notifyStateChanged();

      return false;
    }
  }

  /// Stop the broker. Concurrent calls share the same shutdown operation.
  Future<void> stopBroker() {
    final existingStop = _stopFuture;
    if (existingStop != null) return existingStop;

    _isStopping = true;

    final future = _stopBrokerInternal();
    _stopFuture = future;

    return future;
  }

  Future<void> _stopBrokerInternal() async {
    _logger.log('🛑 Stopping MQTT broker...');

    try {
      // Stop new background work before releasing resources.
      await _udpBroadcastManager?.stopBroadcast();
      _udpBroadcastManager = null;

      _clientTracker.clearAllClients();

      // Await a monitor startup already in progress.
      final monitorStart = _monitorStartFuture;
      if (monitorStart != null) {
        try {
          await monitorStart;
        } catch (_) {
          // Monitoring is optional; continue shutting down.
        }
        _monitorStartFuture = null;
      }

      await _stopBrokerMonitoringClient();

      final broker = _broker;
      _broker = null;

      if (broker != null) {
        _logger.log('🔧 Shutting down broker instance');
        await broker.stop();
      }

      _isBrokerRunning = false;
      _logger.log('✅ MQTT Broker stopped successfully');
    } catch (e) {
      _logger.log('❌ Failed to stop broker: $e');
    } finally {
      _isBrokerRunning = false;
      _isStopping = false;
      _stopFuture = null;

      _notifyStateChanged();
    }
  }

  /// Set up client connection tracking.
  void _setupClientTracking() {
    _logger.log('🔧 Setting up client connection tracking');
    _logger.log(
      'ℹ️ Client tracking will be done through message monitoring',
    );
  }

  /// Start the broker monitoring client.
  Future<void> _startBrokerMonitoringClient() async {
    MqttServerClient? client;

    try {
      // Wait for the broker to become ready.
      await Future.delayed(const Duration(milliseconds: 1000));

      if (_isDisposed || _isStopping || !_isBrokerRunning) return;

      const monitorClientId = 'broker_monitor_client';

      client = MqttServerClient('127.0.0.1', monitorClientId);
      _brokerMonitorClient = client;

      client.logging(on: false);
      client.keepAlivePeriod = 30;
      client.setProtocolV311();

      final connMess = MqttConnectMessage()
          .withClientIdentifier(monitorClientId)
          .startClean()
          .withWillQos(MqttQos.atLeastOnce);

      client.connectionMessage = connMess;

      _logger.log('🔗 Connecting monitoring client to broker...');

      await client.connect().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _logger.log('⏰ Broker monitoring client connection timed out');
          throw TimeoutException(
            'Connection timeout',
            const Duration(seconds: 5),
          );
        },
      );

      // Shutdown may have started while connect() was awaiting.
      if (_isDisposed ||
          _isStopping ||
          !_isBrokerRunning ||
          !identical(_brokerMonitorClient, client)) {
        client.disconnect();

        if (identical(_brokerMonitorClient, client)) {
          _brokerMonitorClient = null;
        }
        return;
      }

      if (client.connectionStatus?.state !=
          MqttConnectionState.connected) {
        _logger.log(
          '❌ Failed to connect broker monitoring client - '
          'Status: ${client.connectionStatus?.state}',
        );
        _logger.log('📝 Broker will continue without message monitoring');

        if (identical(_brokerMonitorClient, client)) {
          _brokerMonitorClient = null;
        }
        return;
      }

      _logger.log('✅ Broker monitoring client connected');

      client.updates?.listen(
        (List<MqttReceivedMessage<MqttMessage?>>? messages) {
          if (_isDisposed || _isStopping) return;
          if (messages == null || messages.isEmpty) return;

          try {
            final recMess =
                messages[0].payload as MqttPublishMessage;
            final message = MqttPublishPayload.bytesToStringAsString(
              recMess.payload.message,
            );
            final topic = messages[0].topic;

            if (topic == 'client/connect' ||
                topic == 'client/disconnect') {
              _handleClientConnectionMessage(message, topic);
            }
          } catch (e) {
            _logger.log('❌ Error processing broker message: $e');
          }
        },
      );

      _logger.log('📡 Subscribing to all topics (#) for message monitoring');
      client.subscribe('#', MqttQos.atMostOnce);

      _logger.log('📡 Subscribing to client connection topics');
      client.subscribe('client/connect', MqttQos.atMostOnce);
      client.subscribe('client/disconnect', MqttQos.atMostOnce);

      _logger.log('👂 Broker is now monitoring all messages');
    } catch (e) {
      _logger.log('❌ Error starting broker monitoring client: $e');
      _logger.log('🔍 Error type: ${e.runtimeType}');
      _logger.log('📝 Broker will continue without message monitoring');

      if (client != null) {
        try {
          client.disconnect();
        } catch (_) {
          // Ignore errors during best-effort cleanup.
        }

        if (identical(_brokerMonitorClient, client)) {
          _brokerMonitorClient = null;
        }
      }
    }
  }

  /// Handle client connection and disconnection messages.
  void _handleClientConnectionMessage(String message, String topic) {
    if (_isDisposed || _isStopping) return;

    try {
      _logger.log(
        '👥 Processing client connection message: $message on $topic',
      );

      if (topic == 'client/connect') {
        final clientInfo = _clientTracker.parseClientInfo(message);

        if (clientInfo != null) {
          _clientTracker.addClient(clientInfo);
        }
      } else if (topic == 'client/disconnect') {
        _clientTracker.removeClient(message);
      }
    } catch (e) {
      _logger.log('❌ Error handling client connection message: $e');
    }
  }

  /// Stop the broker monitoring client.
  Future<void> _stopBrokerMonitoringClient() async {
    final client = _brokerMonitorClient;
    _brokerMonitorClient = null;

    if (client == null) return;

    try {
      _logger.log('🔌 Stopping broker monitoring client...');

      if (client.connectionStatus?.state == MqttConnectionState.connected) {
        client.disconnect();
      }

      _logger.log('✅ Broker monitoring client stopped');
    } catch (e) {
      _logger.log('❌ Error stopping broker monitoring client: $e');
    }
  }

  /// Dispose resources.
  ///
  /// This synchronous method starts asynchronous cleanup. Owners that need
  /// cleanup to finish before disposing dependent services should await
  /// [disposeAsync] instead.
  void dispose() {
    if (_isDisposed) return;

    _isDisposed = true;
    _logger.log('🧹 Disposing MqttBrokerManager');

    unawaited(disposeAsync());
  }

  /// Dispose resources and wait for asynchronous cleanup to finish.
  Future<void> disposeAsync() async {
    if (!_isDisposed) {
      _isDisposed = true;
      _logger.log('🧹 Disposing MqttBrokerManager');
    }

    _logger.log('📢 Stopping broker broadcast...');
    await _udpBroadcastManager?.stopBroadcast();
    _udpBroadcastManager = null;

    _logger.log('👂 Stopping broker monitoring client...');

    final monitorStart = _monitorStartFuture;
    if (monitorStart != null) {
      try {
        await monitorStart;
      } catch (_) {
        // Continue cleanup if optional monitoring failed.
      }
      _monitorStartFuture = null;
    }

    await _stopBrokerMonitoringClient();

    _logger.log('🛑 Stopping broker...');

    // Reuse any stop already in progress.
    await stopBroker();
  }
}