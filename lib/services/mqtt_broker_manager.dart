import 'dart:async';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:mqtt_server/mqtt_server.dart';
import 'message_logger.dart';
import 'udp_broadcast_manager.dart';
import 'client_tracker.dart';
import 'session_auth.dart';

/// Manages MQTT broker operations
class MqttBrokerManager {
  final MessageLogger _logger;
  final Function()? _onStateChanged;
  final ClientTracker _clientTracker;
  
  MqttBroker? _broker;
  bool _isBrokerRunning = false;
  MqttServerClient? _brokerMonitorClient;
  UdpBroadcastManager? _udpBroadcastManager;

  // The session PIN the running broker requires, or null when it is open.
  String? _pin;
  
  MqttBrokerManager(this._logger, this._clientTracker, {Function()? onStateChanged}) 
    : _onStateChanged = onStateChanged;
  
  /// Get broker running status
  bool get isBrokerRunning => _isBrokerRunning;
  
  /// Start MQTT broker. With a [pin], only clients logging in with it (see
  /// SessionAuth) may connect; without one the broker is open.
  Future<bool> startBroker({String? pin}) async {
    _logger.log('🚀 Starting MQTT broker...');
    try {
      // Stop existing broker if running
      if (_broker != null) {
        _logger.log('⚠️  Stopping existing broker before starting new one');
        await _broker!.stop();
      }
      
      // Stop existing broadcast if running
      await _udpBroadcastManager?.stopBroadcast();
      
      // Create broker configuration
      final open = pin == null || pin.isEmpty;
      _pin = open ? null : pin;
      _logger.log('⚙️  Creating broker configuration (port: 1883, ${open ? 'open' : 'session PIN required'})');
      final config = MqttBrokerConfig(
        port: 1883,
        allowAnonymous: open,
        enablePersistence: false,
      );
      
      // Create and start broker
      _logger.log('🔧 Creating broker instance');
      _broker = MqttBroker(config);
      if (!open) _broker!.addCredentials(SessionAuth.mqttUsername, pin);
      
      // Set up client connection tracking
      _setupClientTracking();
      
      _logger.log('🎯 Starting broker on port 1883...');
      await _broker!.start();
      
      _isBrokerRunning = true;
      _logger.log('✅ MQTT Broker started successfully on port 1883');
      _logger.log('📡 Broker is ready to accept client connections');
      
      // Start UDP broadcasting
      _logger.log('📢 Starting UDP broadcast announcements...');
      _udpBroadcastManager = UdpBroadcastManager(_logger);
      await _udpBroadcastManager!.startBroadcast();
      
      // Start broker monitoring client to log all messages (optional)
      _logger.log('👂 Starting broker monitoring client...');
      _startBrokerMonitoringClient().catchError((error) {
        _logger.log('⚠️  Broker monitoring client failed to start: $error');
        _logger.log('📝 Broker will continue without message monitoring');
      });
      
      _onStateChanged?.call();
      return true;
    } catch (e) {
      _logger.log('❌ Failed to start broker: $e');
      _isBrokerRunning = false;
      _onStateChanged?.call();
      return false;
    }
  }
  
  /// Stop MQTT broker
  Future<void> stopBroker() async {
    _logger.log('🛑 Stopping MQTT broker...');
    try {
      // Stop UDP broadcasting first
      await _udpBroadcastManager?.stopBroadcast();
      _udpBroadcastManager = null;
      
      // Clear client tracking
      _clientTracker.clearAllClients();
      
      // Stop monitoring client
      await _stopBrokerMonitoringClient();
      
      if (_broker != null) {
        _logger.log('🔧 Shutting down broker instance');
        await _broker!.stop();
        _broker = null;
      }
      _isBrokerRunning = false;
      _logger.log('✅ MQTT Broker stopped successfully');
      _onStateChanged?.call();
    } catch (e) {
      _logger.log('❌ Failed to stop broker: $e');
      _onStateChanged?.call();
    }
  }
  
  /// Set up client connection tracking
  void _setupClientTracking() {
    _logger.log('🔧 Setting up client connection tracking');
    _logger.log('ℹ️  Client tracking will be done through message monitoring');
  }
  
  /// Start broker monitoring client to log all messages
  Future<void> _startBrokerMonitoringClient() async {
    try {
      _logger.log('🔧 Creating broker monitoring client...');
      
      // Wait a bit for broker to be fully ready
      await Future.delayed(const Duration(milliseconds: 1000));
      
      const monitorClientId = 'broker_monitor_client';
      
      // Create monitoring client that connects to localhost
      _brokerMonitorClient = MqttServerClient('127.0.0.1', monitorClientId);
      _brokerMonitorClient!.logging(on: false); // Disable client logging to avoid spam
      _brokerMonitorClient!.keepAlivePeriod = 30;
      _brokerMonitorClient!.setProtocolV311();
      
      // Set up connection message
      var connMess = MqttConnectMessage()
          .withClientIdentifier(monitorClientId)
          .startClean()
          .withWillQos(MqttQos.atLeastOnce);
      final pin = _pin;
      if (pin != null) connMess = connMess.authenticateAs(SessionAuth.mqttUsername, pin);
      
      _brokerMonitorClient!.connectionMessage = connMess;
      
      // Connect the monitoring client with timeout
      _logger.log('🔗 Connecting monitoring client to broker...');
      await _brokerMonitorClient!.connect().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _logger.log('⏰ Broker monitoring client connection timed out');
          throw TimeoutException('Connection timeout', const Duration(seconds: 5));
        },
      );
      
      // Check if connection was successful
      if (_brokerMonitorClient?.connectionStatus?.state == MqttConnectionState.connected) {
        _logger.log('✅ Broker monitoring client connected');
        
        // Set up message listener for monitoring
        _brokerMonitorClient!.updates?.listen((List<MqttReceivedMessage<MqttMessage?>>? messages) {
          if (messages != null && messages.isNotEmpty) {
            try {
              final recMess = messages[0].payload as MqttPublishMessage;
              final message = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
              final topic = messages[0].topic;
              
              // _logger.log('📨 [BROKER] Message received: "$message" on topic: $topic');
              // _logger.log('🔄 [BROKER] Broadcasting message to all connected clients...');
              
              // Track client connections through special messages
              if (topic == 'client/connect' || topic == 'client/disconnect') {
                _handleClientConnectionMessage(message, topic);
              }
            } catch (e) {
              _logger.log('❌ Error processing broker message: $e');
            }
          }
        });
        
        // Subscribe to all topics using wildcard
        _logger.log('📡 Subscribing to all topics (#) for message monitoring...');
        _brokerMonitorClient!.subscribe('#', MqttQos.atMostOnce);
        
        // Also subscribe to client connection topics
        _logger.log('📡 Subscribing to client connection topics...');
        _brokerMonitorClient!.subscribe('client/connect', MqttQos.atMostOnce);
        _brokerMonitorClient!.subscribe('client/disconnect', MqttQos.atMostOnce);
        
        _logger.log('👂 Broker is now monitoring all messages');
      } else {
        _logger.log('❌ Failed to connect broker monitoring client - Status: ${_brokerMonitorClient?.connectionStatus?.state}');
        _logger.log('📝 Broker will continue without message monitoring');
      }
    } catch (e) {
      _logger.log('❌ Error starting broker monitoring client: $e');
      _logger.log('🔍 Error type: ${e.runtimeType}');
      _logger.log('📝 Broker will continue without message monitoring');
      // Clean up on error
      _brokerMonitorClient = null;    }
  }
  
  /// Handle client connection/disconnection messages
  void _handleClientConnectionMessage(String message, String topic) {
    try {
      _logger.log('👥 Processing client connection message: $message on $topic');
      
      // Don't forward to TopicManager here - it's already handled by normal MQTT subscription
      // The broker monitoring client is subscribed to these topics like any other client
      
      if (topic == 'client/connect') {
        // Parse client connection message
        final clientInfo = _clientTracker.parseClientInfo(message);
        if (clientInfo != null) {
          _clientTracker.addClient(clientInfo);
        }
      } else if (topic == 'client/disconnect') {
        // Remove client from tracking
        _clientTracker.removeClient(message);
      }
    } catch (e) {
      _logger.log('❌ Error handling client connection message: $e');
    }
  }
  
  /// Stop broker monitoring client
  Future<void> _stopBrokerMonitoringClient() async {
    try {
      if (_brokerMonitorClient != null) {
        _logger.log('🔌 Stopping broker monitoring client...');
        if (_brokerMonitorClient!.connectionStatus?.state == MqttConnectionState.connected) {
          _brokerMonitorClient!.disconnect();
        }
        _brokerMonitorClient = null;
        _logger.log('✅ Broker monitoring client stopped');
      }
    } catch (e) {
      _logger.log('❌ Error stopping broker monitoring client: $e');
      _brokerMonitorClient = null; // Force cleanup
    }
  }
  
  /// Clean up resources
  void dispose() {
    _logger.log('🧹 Disposing MqttBrokerManager');
    _logger.log('📢 Stopping broker broadcast...');
    _udpBroadcastManager?.dispose();
    _logger.log('👂 Stopping broker monitoring client...');
    _stopBrokerMonitoringClient();
    _logger.log('🛑 Stopping broker...');
    stopBroker();
  }
}
