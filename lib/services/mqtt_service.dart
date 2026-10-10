import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'client_warmup_service.dart';
import 'assignments_client.dart';
import 'client_worker_service.dart';
import 'inference_service.dart';
import 'message_logger.dart';
import 'mqtt_client_manager.dart';
import 'mqtt_broker_manager.dart';
import 'client_tracker.dart';
import 'connected_client.dart';
import 'file_server_service.dart';
import 'file_download_service.dart';
import 'topic_manager.dart';
import 'network_helper.dart';
import 'client_metrics_publisher.dart';
import 'performance_service.dart';
import 'device_info_helper.dart';
import 'distribution_singleton.dart';
import 'metrics/metrics_store.dart';
import 'metrics/traffic_counter.dart';
import 'models/device_health.dart';

/// Main MQTT service that orchestrates client and broker operations
class MqttService extends ChangeNotifier {
  late final MessageLogger _logger;
  late final MqttClientManager _clientManager;
  late final MqttBrokerManager _brokerManager;
  late final ClientTracker _clientTracker;
  late final FileServerService _fileServerService;
  // track last shared/downloaded files per distributed topic
  final Map<String, FileShareInfo> _lastSharedInfoByTopic = {};
  final Map<String, File> _lastDownloadedFileByTopic = {};
  late final FileDownloadService _fileDownloadService;
  late final TopicManager _topicManager;
  ClientMetricsPublisher? _clientMetricsPublisher;
  ClientWorkerService? _clientWorkerService;
  
  // Current mode
  AppMode _currentMode = AppMode.none;
  
  // Flag to track if a monitoring client is connected when in broker mode
  bool _brokerMonitoringClientConnected = false;
  
  // Multiple message listeners for different topics/components
  final Map<String, List<Function(String topic, String message)>> _messageListeners = {};
  
  MqttService() {
    _logger = MessageLogger();
    _topicManager = TopicManager();
    _clientManager = MqttClientManager(_logger, 
      onStateChanged: notifyListeners,
      onMessageReceived: _handleIncomingMessage,
    );
    _clientTracker = ClientTracker(_logger);
    _brokerManager = MqttBrokerManager(_logger, _clientTracker, 
      onStateChanged: notifyListeners,
    );
    _fileServerService = FileServerService(_logger, onStateChanged: notifyListeners);
    _fileDownloadService = FileDownloadService(_logger, onStateChanged: notifyListeners);
    
    // Listen to client tracker changes
    _clientTracker.addListener(notifyListeners);
    // Listen to topic manager changes
    _topicManager.addListener(notifyListeners);
    // Feed every worker's periodic metrics into the store (only the broker host
    // subscribes to this topic, so this is a no-op on workers).
    addMessageListener('clients/metrics', (topic, message) => MetricsStore.instance.ingestWire(message));
    // The same samples tell the scheduler how each phone is doing right now.
    addMessageListener('clients/metrics', _feedSchedulerHealth);
  }

  /// Hand a worker's live health (battery, thermal, RAM, Wi-Fi, CPU) to the
  /// distribution manager. Samples are keyed by device IP, which it matches
  /// against the registered client ids.
  void _feedSchedulerHealth(String topic, String message) {
    try {
      final j = jsonDecode(message);
      if (j is! Map<String, dynamic>) return;
      final key = j['i'];
      if (key is! String || key.isEmpty) return;
      distributionManager.updateClientHealth(
        key,
        DeviceHealth.fromWire(j, updatedAtMs: DateTime.now().millisecondsSinceEpoch),
      );
    } catch (_) {
      // A malformed sample is dropped; the next one arrives within seconds.
    }
  }
  
  // Getters
  MessageLogger get messageLogger => _logger;
  MqttClientManager get clientManager => _clientManager;
  bool get isConnected => _clientManager.isConnected;
  bool get isSubscribed => _clientManager.isSubscribed;
  bool get isBrokerRunning => _brokerManager.isBrokerRunning;
  bool get isFileServerRunning => _fileServerService.isServerRunning;
  String get brokerIp => _clientManager.brokerIp;
  List<String> get messages => _logger.messages;
  AppMode get currentMode => _currentMode;
  List<ConnectedClient> get connectedClients => _clientTracker.connectedClients;
  int get connectedClientsCount => _clientTracker.connectedCount;
  bool get canPublishFromHost => isBrokerRunning && (_brokerMonitoringClientConnected || isConnected);
  String get defaultTopic => _clientManager.defaultTopic;
  String get shareTopic => _clientManager.shareTopic;
  Set<String> get subscribedTopics => _clientManager.subscribedTopics;
  List<FileDownloadTask> get activeDownloads => _fileDownloadService.activeTasks;
  TopicManager get topicManager => _topicManager;
  
  // Set mode
  void setMode(AppMode mode) {
    _logger.log('Setting mode to: $mode');
    _currentMode = mode;
    notifyListeners();
  }
  
  // Message listener management
  void addMessageListener(String topic, Function(String topic, String message) listener) {
    final listeners = _messageListeners.putIfAbsent(
      topic,
      () => <Function(String topic, String message)>[],
    );
    // Reconnects must not register the same callback more than once.
    if (listeners.contains(listener)) {
      _logger.log('📡 Listener already registered for topic: $topic');
      return;
    }
    listeners.add(listener);
    _logger.log('📡 Added message listener for topic: $topic');
  }
  
  void removeMessageListener(String topic, Function(String topic, String message) listener) {
    if (_messageListeners.containsKey(topic)) {
      _messageListeners[topic]!.remove(listener);
      if (_messageListeners[topic]!.isEmpty) {
        _messageListeners.remove(topic);
      }
      _logger.log('📡 Removed message listener for topic: $topic');
    }
  }
  
  // Start the host as a first-class scheduler participant after the dataset
  // has been shared. The host uses its selected local model but requests units
  // from the same server-side job as the remote clients.
  String? _hostWorkerJobId;

  Future<bool> startHostWorker({
    required File modelFile,
    required String jobId,
  }) async {
    if (_hostWorkerJobId == jobId && _clientWorkerService?.isRunning == true) {
      return true;
    }
    if (!_brokerMonitoringClientConnected || !_fileServerService.isServerRunning) {
      _logger.log('⚠️ Cannot start host worker before broker/file server are ready');
      return false;
    }

    try {
      final base = serverUrl;
      final datasetUrl = '$base/files/$jobId';
      _logger.log('🧪 Warming up host worker on dataset $jobId');
      final warmup = await ClientWarmupService(_logger)
          .runWarmupWithModel(datasetUrl, modelFile.path, samples: 3);
      if (warmup == null) {
        _logger.log('⚠️ Host warmup failed; host worker was not started');
        return false;
      }

      final hostClientId = _clientManager.clientId;
      final report = jsonEncode({
        'client_id': hostClientId,
        'ttproc_ms': warmup.ttprocMs.round(),
        'bandwidth_kBps': warmup.bandwidthKBps,
        'model': modelFile.uri.pathSegments.isEmpty
            ? modelFile.path
            : modelFile.uri.pathSegments.last,
        'warmup': true,
      });
      final response = await http.post(
        Uri.parse('$base/admin/warmup'),
        headers: {'Content-Type': 'application/json'},
        body: report,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _logger.log('⚠️ Host registration failed: HTTP ${response.statusCode}');
        return false;
      }

      final assignClient = AssignmentsClient(_logger, serverBase: base);
      final inference = InferenceService(modelPath: modelFile.path);
      _clientWorkerService?.stop();
      _clientWorkerService = ClientWorkerService(
        _logger,
        assignClient,
        inference,
        jobId: jobId,
        clientId: hostClientId,
      );
      _hostWorkerJobId = jobId;
      _clientWorkerService!.start();
      _logger.log('🖥️ Host worker started for job $jobId as $hostClientId');
      return true;
    } catch (e) {
      _logger.log('❌ Failed to start host worker: $e');
      return false;
    }
  }

  void stopHostWorker() {
    if (_hostWorkerJobId == null) return;
    _clientWorkerService?.stop();
    _clientWorkerService = null;
    _hostWorkerJobId = null;
    _logger.log('🛑 Host worker stopped');
  }

  // Client metrics publishing management
  void startClientMetricsPublishing() {
    if (_currentMode == AppMode.client && isConnected) {
      _clientMetricsPublisher?.stop(); // Stop any existing publisher
      _clientMetricsPublisher = ClientMetricsPublisher(
        mqttClientManager: _clientManager,
        performanceService: PerformanceService.instance,
        interval: const Duration(seconds: 5),
      );
      _clientMetricsPublisher!.start();
      _logger.log('📊 Client metrics publishing started');
    }
  }
  
  void stopClientMetricsPublishing() {
    _clientMetricsPublisher?.stop();
    _clientMetricsPublisher = null;
    _logger.log('📊 Client metrics publishing stopped');
  }
  
  // MQTT Broker functionality
  Future<bool> startBroker() async {
    final success = await _brokerManager.startBroker();
    
    if (success) {
      // PerformanceService is a lazy singleton: touch it so the host records its own
      // metrics from the start instead of waiting for the Analytics tab to open.
      PerformanceService.instance;
      // Label this phone's own recording so it shows up by IP/name in exports
      final hostIp = await NetworkHelper.getDeviceIPAddress();
      if (hostIp != null) {
        MetricsStore.instance.setLocalIdentity(hostIp, (await DeviceInfoHelper.getDeviceName()) ?? 'Host');
      }
      // Connect a local client for the host to be able to publish messages
      await _setupHostPublishingClient();
      
      // Start the file server on the same IP
      await _fileServerService.startServer(brokerIp);
    }
    
    return success;
  }
  
  // Set up a client for the host to publish messages while in broker mode
  Future<void> _setupHostPublishingClient() async {
    _logger.log('🔧 Setting up host publishing client...');
    // Use the client manager to connect to the local broker
    final success = await _clientManager.connect('127.0.0.1');
    
    if (success) {
      _logger.log('✅ Host publishing client connected successfully');
      await _clientManager.subscribe();
      await _clientManager.subscribeToTopic(_clientManager.shareTopic);
      
      // Subscribe to system topics so broker host can see connection/disconnection events
      await _clientManager.subscribeToTopic('client/connect');
      await _clientManager.subscribeToTopic('client/disconnect');
      
      // Subscribe to clients/metrics to see metrics from connected clients
      await _clientManager.subscribeToTopic('clients/metrics');
      
  // Subscribe to distributed ACK topics so host receives client ACKs
  await _clientManager.subscribeToTopic('ack/mod');
  await _clientManager.subscribeToTopic('ack/data');
      
      _brokerMonitoringClientConnected = true;
    } else {
      _logger.log('❌ Failed to set up host publishing client');
      _brokerMonitoringClientConnected = false;
    }
    
    notifyListeners();
  }
  
  Future<void> stopBroker() async {
    _clientWorkerService?.stop();
    _clientWorkerService = null;
    _hostWorkerJobId = null;
    // Stop the file server
    await _fileServerService.stopServer();
    
    // Disconnect the host publishing client first
    if (_brokerMonitoringClientConnected) {
      await _clientManager.disconnect();
      _brokerMonitoringClientConnected = false;
    }
    
    await _brokerManager.stopBroker();
  }
  
  /// Connect to MQTT broker as a client
  Future<bool> connect(String brokerIp) async {
    final success = await _clientManager.connect(brokerIp);
    
    if (success) {
      // Register handler for file share messages
    // register wrapper handler (client manager expects Function(String))
    _clientManager.setFileShareMessageHandler((String message) async {
      await _handleFileShareMessage('share', message);
    });
  _logger.log('🔧 File share message handler registered');

  // Subscribe to distributed distribution topics and register local listeners
  await _clientManager.subscribeToTopic('dist/mod');
  await _clientManager.subscribeToTopic('dist/data');
  addMessageListener('dist/mod', _handleDistributedShare);
  addMessageListener('dist/data', _handleDistributedShare);
      
      // Start client metrics publishing
      startClientMetricsPublishing();
    }
    
    return success;
  }

  /// Handle distributed share messages (topic-aware) for dist/mod and dist/data
  void _handleDistributedShare(String topic, String message) async {
    _logger.log('📥 Distributed message received on $topic: $message');

    try {
      final messageJson = jsonDecode(message);
      if (messageJson is Map<String, dynamic> &&
          messageJson.containsKey('type') &&
          messageJson['type'] == 'file_notification') {

        // Reuse existing processing to download files
        final task = await _handleFileShareMessage(topic, message);

        // MQTT delivers targeted notifications to all subscribers. A non-target
        // device returns null and must not ACK or attempt warmup with stale state.
        if (task == null || task.status != DownloadStatus.completed ||
            !await task.destinationFile.exists()) {
          _logger.log('⏭️ Ignoring share notification not downloaded by this device');
          return;
        }

        // ACK only after this device successfully downloaded the requested file.
        final currentIp = await NetworkHelper.getDeviceIPAddress() ?? 'unknown';

        // Map dist topic to corresponding ack topic
        String ackTopic;
        if (topic == 'dist/mod') {
          ackTopic = 'ack/mod';
        } else if (topic == 'dist/data') {
          ackTopic = 'ack/data';
        } else {
          ackTopic = 'ack/data';
        }

        // Keep ACK payload minimal as device IP string to save broker bandwidth
        await _clientManager.publishMessage(message: currentIp, topic: ackTopic);
        _logger.log('📣 Published ACK to $ackTopic : $currentIp');

        // After ack, if this was a dataset share (dist/data), attempt warmup
        if (topic == 'dist/data') {
          try {
            final shareInfo = _lastSharedInfoByTopic['dist/data'];
            final modelFile = _lastDownloadedFileByTopic['dist/mod'];
            if (shareInfo != null && modelFile != null && task != null && task.status == DownloadStatus.completed) {
              _logger.log('🔁 Starting client warmup using ${shareInfo.url} and model ${modelFile.path}');
              final warmupSrv = ClientWarmupService(_logger);
              final res = await warmupSrv.runWarmupWithModel(shareInfo.url, modelFile.path, samples: 3);
              if (res != null) {
                _logger.log('📤 Warmup complete — ttproc=${res.ttprocMs.toStringAsFixed(1)} ms, bw=${res.bandwidthKBps.toStringAsFixed(1)} kB/s');
                // Post warmup results to the host file server admin endpoint
                final postUrl = '${shareInfo.url.split('/files/').first}/admin/warmup';
                final body = jsonEncode({
                  'client_id': _clientManager.clientId,
                  'ttproc_ms': res.ttprocMs.round(),
                  'bandwidth_kBps': res.bandwidthKBps,
                  'model': modelFile.path.split(RegExp(r'[\\/]')).last,
                  'warmup': true,
                });
                try {
                  await http.post(Uri.parse(postUrl), headers: {'Content-Type': 'application/json'}, body: body);
                  TrafficCounter.instance.addTx(TrafficChannel.httpControl, utf8.encode(body).length);
                  TrafficCounter.instance.countTxMsg(TrafficChannel.httpControl);
                  TrafficCounter.instance.countRxMsg(TrafficChannel.httpControl);
                  _logger.log('✅ Posted warmup results to host: $postUrl');
                  // Start client worker to fetch assignments and run inference on assigned units
                  try {
                    final serverBase = shareInfo.url.split('/files/').first; // e.g. http://host:8080
                    final assignClient = AssignmentsClient(_logger, serverBase: serverBase);
                    final inference = InferenceService(modelPath: modelFile.path);
                    final jobId = shareInfo.fileId.isNotEmpty ? shareInfo.fileId : 'demo_job';
                    _clientWorkerService = ClientWorkerService(_logger, assignClient, inference, jobId: jobId, clientId: _clientManager.clientId);
                    // start worker without awaiting to keep UI responsive
                    _clientWorkerService!.start();
                    _logger.log('🚀 Client worker started to process assigned units for job $jobId');
                  } catch (e) {
                    _logger.log('⚠️ Failed to start client worker: $e');
                  }
                } catch (e) {
                  _logger.log('⚠️ Failed to post warmup results: $e');
                }
              } else {
                _logger.log('⚠️ Warmup returned no result');
              }
            } else {
              _logger.log('⚠️ Skipping warmup — missing shareInfo or model file or download not completed');
            }
          } catch (e) {
            _logger.log('❌ Warmup flow error: $e');
          }
        }
      }
    } catch (e) {
      _logger.log('❌ Error handling distributed share message: $e');
    }
  }
  
  /// Handle incoming file share messages
  Future<FileDownloadTask?> _handleFileShareMessage(String topic, String message) async {
    _logger.log('📥 Processing share topic message...');
    
    try {
      // Try to parse the message as JSON
      final messageJson = jsonDecode(message);
      
      // Check if it's a file notification message
      if (messageJson is Map<String, dynamic> && 
          messageJson.containsKey('type') && 
          messageJson['type'] == 'file_notification') {
        
        _logger.log('📁 File notification detected, processing...');
        
        // Check if this file is targeted to this client
        if (messageJson.containsKey('target_ids')) {
          final targetIds = messageJson['target_ids'] as String;
          _logger.log('🎯 Target IDs: $targetIds');
          
          if (targetIds != 'all') {
            // Get current device IP
            final currentIp = await NetworkHelper.getDeviceIPAddress();
            _logger.log('🔍 Current device IP: $currentIp');
            
            if (currentIp != targetIds) {
              _logger.log('⏭️ File not targeted to this device, skipping download');
              return null;
            } else {
              _logger.log('✅ File is targeted to this device, proceeding with download');
            }
          } else {
            _logger.log('📢 File shared with all clients, proceeding with download');
          }
        } else {
          _logger.log('📢 No target specified, treating as broadcast to all clients');
        }
        
  final serverUrl = messageJson['server_url'] as String;
        _logger.log('🔍 Server URL: $serverUrl');
        
        // Fetch file list from the server
        final fileId = messageJson['file_id'];
        final fileName = messageJson['file_name'];
        final fileSize = messageJson['file_size'];
        final mimeType = messageJson['mime_type'];
        final fileUrl = messageJson['file_url'];
        if (fileId is String && fileName is String && fileSize is num &&
            mimeType is String && fileUrl is String) {
          final shareInfo = FileShareInfo(
            fileId: fileId,
            fileName: fileName,
            fileSize: fileSize.toInt(),
            mimeType: mimeType,
            url: fileUrl,
          );
          _lastSharedInfoByTopic[topic] = shareInfo;
          _logger.log('🎯 Downloading exact shared file ${shareInfo.fileName} ($fileId)');
          final task = await _fileDownloadService.downloadFile(shareInfo);
          if (task != null && task.status == DownloadStatus.completed &&
              await task.destinationFile.exists()) {
            _lastDownloadedFileByTopic[topic] = task.destinationFile;
          }
          return task;
        }

        // Backward-compatible fallback for older senders that only publish server_url.
        final fileListUrl = '$serverUrl/files';
        _logger.log('🔍 Fetching file list from: $fileListUrl');
        
        // Download file list
        try {
          final response = await http.get(Uri.parse(fileListUrl));
          
          if (response.statusCode == 200) {
            final fileList = jsonDecode(response.body) as List;
            _logger.log('✅ Received file list with ${fileList.length} files');
            
            // Process each file in the list (usually just the latest one)
            FileDownloadTask? lastTask;
            for (final fileInfo in fileList) {
              if (fileInfo is Map<String, dynamic>) {
                // Create a FileShareInfo
                final shareInfo = FileShareInfo(
                  fileId: fileInfo['id'],
                  fileName: fileInfo['name'],
                  fileSize: fileInfo['size'],
                  mimeType: fileInfo['mimeType'],
                  url: fileInfo['url'],
                );
                
                _logger.log('📦 File available: ${shareInfo.fileName}');
                _logger.log('📊 File size: ${_formatFileSize(shareInfo.fileSize)}');
                _logger.log('🔗 Download URL: ${shareInfo.url}');
                
                // Track shared info for this topic (used later for warmup/reporting)
                _lastSharedInfoByTopic[topic] = shareInfo;
                // Start download and capture task
                final task = await _fileDownloadService.downloadFile(shareInfo);
                if (task != null && task.destinationFile.existsSync()) {
                  _lastDownloadedFileByTopic[topic] = task.destinationFile;
                }
                lastTask = task;
              }
            }
            return lastTask;
          } else {
            _logger.log('❌ Failed to fetch file list: ${response.statusCode}');
          }
        } catch (e) {
          _logger.log('❌ Error fetching file list: $e');
        }
        } else {
          _logger.log('💬 Regular text message on share topic (not a file notification)');
          // This is just a regular text message, not a file notification
          // It will be handled by TopicManager for UI display
      }
      } catch (e) {
      // This is likely a regular text message, not JSON - this is normal
      _logger.log('💬 Text message on share topic: "$message"');
      // No error logging needed - regular text messages are expected
    }
    notifyListeners();
    return null;
  }
  
  Future<void> disconnect() async {
    // Stop client metrics publishing
    stopClientMetricsPublishing();
    await _clientManager.disconnect();
  }
  
  Future<void> subscribe() async {
    // Subscribe to both default and share topics
    await _clientManager.subscribe();
    await _clientManager.subscribeToTopic(_clientManager.shareTopic);
    
    // Subscribe to system topics so all clients can see connection/disconnection events
    await _clientManager.subscribeToTopic('client/connect');
    await _clientManager.subscribeToTopic('client/disconnect');
    
    // Subscribe to clients/metrics (important for analytics dashboard)
    await _clientManager.subscribeToTopic('clients/metrics');
  // Subscribe to distributed ACK topics (host wants to receive ACKs)
  await _clientManager.subscribeToTopic('ack/mod');
  await _clientManager.subscribeToTopic('ack/data');
  }
  
  Future<void> subscribeToTopic(String topic) async {
    await _clientManager.subscribeToTopic(topic);
  }
  
  Future<void> unsubscribe() async {
    await _clientManager.unsubscribe();
    await _clientManager.unsubscribeFromTopic(_clientManager.shareTopic);
    
    // Unsubscribe from system topics
    await _clientManager.unsubscribeFromTopic('client/connect');
    await _clientManager.unsubscribeFromTopic('client/disconnect');
  }
  
  Future<void> unsubscribeFromTopic(String topic) async {
    await _clientManager.unsubscribeFromTopic(topic);
  }
  
  Future<void> publishMessage({String? message, String? topic}) async {
    final usedTopic = topic ?? _clientManager.defaultTopic;
    final usedMessage = message ?? 'Hello, MQTT!';

    if (!_clientManager.isConnected) {
      throw StateError('Cannot publish to $usedTopic: MQTT client is disconnected');
    }

    // Send the original message as-is to avoid payload size issues.
    await _clientManager.publishMessage(message: usedMessage, topic: usedTopic);
    
    // Don't add to TopicManager here - wait for the message to come back from broker
    // This ensures consistent behavior across all devices and prevents duplicates
    
    // If we're running a broker, also log the message as received by broker
    if (_brokerManager.isBrokerRunning) {
      _logger.log('📨 [BROKER] Message published to topic: $usedTopic');
      _logger.log('📝 [BROKER] Message content: "$usedMessage"');
      _logger.log('🔄 [BROKER] Broadcasting to all connected clients...');
    }
  }
  
  // File sharing functionality
  
  /// Share a file with all connected clients or specific target IP
  Future<bool> shareFile(File file, {String? targetIp}) async {
    if (!isFileServerRunning) {
      _logger.log('❌ Cannot share file - file server not running');
      return false;
    }
    
    try {
      // Share the file via HTTP server
      final shareInfo = await _fileServerService.shareFile(file);
      
      if (shareInfo != null) {
        // Use the network-accessible IP for the server URL
        final networkServerUrl = _fileServerService.networkServerUrl;
        
        _logger.log('🌐 Using network-accessible server URL for notification: $networkServerUrl');
        
        // Determine target for file sharing
        final targetIds = targetIp ?? 'all';
        
        if (targetIds == 'all') {
          _logger.log('📢 File sharing broadcast to all clients');
        } else {
          _logger.log('🎯 File sharing targeted to IP: $targetIds');
        }
        
        // Create a minimal notification - ONLY sending notification
        // No file metadata through MQTT to avoid broker size limits
        final notification = {
          'type': 'file_notification',
          'server_url': networkServerUrl,
          'target_ids': targetIds,
          // Identify the exact file; /files can change after the next share.
          'file_id': shareInfo.fileId,
          'file_name': shareInfo.fileName,
          'file_size': shareInfo.fileSize,
          'mime_type': shareInfo.mimeType,
          'file_url': '$networkServerUrl/files/${shareInfo.fileId}',
        };
        
        // Convert notification to JSON
        final notificationJson = jsonEncode(notification);
        
        // Publish notification to share topic
        await publishMessage(message: notificationJson, topic: shareTopic);
        
        _logger.log('📤 File share notification published');
        return true;
      } else {
        _logger.log('❌ Failed to prepare file for sharing');
        return false;
      }
    } catch (e) {
      _logger.log('❌ Error sharing file: $e');
      return false;
    }
  }

  /// Share a file but publish notification to a specific MQTT topic (e.g., 'dist/mod' or 'dist/data')
  Future<bool> shareFileToTopic(File file, String distTopic, {String? targetIp}) async {
    if (!isFileServerRunning) {
      _logger.log('❌ Cannot share file - file server not running');
      return false;
    }

    try {
      final shareInfo = await _fileServerService.shareFile(file);
      if (shareInfo != null) {
        final networkServerUrl = _fileServerService.networkServerUrl;
        final targetIds = targetIp ?? 'all';

        final notification = {
          'type': 'file_notification',
          'server_url': networkServerUrl,
          'target_ids': targetIds,
          'file_id': shareInfo.fileId,
          'file_name': shareInfo.fileName,
          'file_size': shareInfo.fileSize,
          'mime_type': shareInfo.mimeType,
          'file_url': '$networkServerUrl/files/${shareInfo.fileId}',
        };

  final notificationJson = jsonEncode(notification);
        _logger.log('🔔 Preparing to publish to $distTopic: $notificationJson');
        _logger.log('🔌 ClientManager connected=${_clientManager.isConnected}, subscribedTopics=${_clientManager.subscribedTopics}');

        // Small delay to ensure file server has registered the file before clients request it
        await Future.delayed(const Duration(milliseconds: 200));

        try {
          await publishMessage(message: notificationJson, topic: distTopic);
          _logger.log('📤 File share notification published to $distTopic (target=$targetIds)');
          try {
            // Also add a local TopicManager entry so host UI shows the outgoing notification immediately
            _topicManager.addMessage(
              topic: distTopic,
              content: notificationJson,
              senderId: 'host',
              senderName: 'Host',
              type: MessageType.notification,
            );
          } catch (_) {
            // ignore
          }
        } catch (e) {
          _logger.log('❌ publishMessage wrapper failed for $distTopic: $e');

          // Fallback: try to publish directly via client manager
          try {
            if (_clientManager.isConnected) {
              _logger.log('🔁 Attempting direct publish via MqttClientManager to $distTopic');
              await _clientManager.publishMessage(message: notificationJson, topic: distTopic);
              _logger.log('✅ Direct publish via client manager succeeded for $distTopic');
            } else {
              _logger.log('❌ Cannot direct-publish: client manager not connected');
              return false;
            }
          } catch (e2) {
            _logger.log('❌ Direct publish also failed for $distTopic: $e2');
            return false;
          }
        }
        return true;
      }
      return false;
    } catch (e) {
      _logger.log('❌ Error sharing file to $distTopic: $e');
      return false;
    }
  }
  
  /// Get server URL for file sharing
  String get serverUrl => _fileServerService.networkServerUrl;
  
  /// Process incoming file share message - deprecated but kept for compatibility
  Future<FileDownloadTask?> processFileShareMessage(String message) async {
    try {
      _logger.log('📥 Processing file share message');
      
      // Parse the message as JSON
      final messageJson = jsonDecode(message);
      
      // If it's a file notification, handle with the new method
      if (messageJson is Map<String, dynamic> && 
          messageJson.containsKey('type') && 
          messageJson['type'] == 'file_notification') {
        
  _logger.log('📥 File notification received');
  await _handleFileShareMessage('share', message);
        return null;
      } else if (messageJson is Map<String, dynamic> && 
          messageJson.containsKey('type') && 
          messageJson['type'] == 'file_share') {
        
        // Legacy handling for old file_share messages
        // Extract required fields
        final fileId = messageJson['fileId'] as String? ?? '';
        final fileName = messageJson['fileName'] as String? ?? 'unknown.file';
        final fileSize = messageJson['fileSize'] as int? ?? 0;
        final url = messageJson['url'] as String? ?? '';
        
        if (fileId.isNotEmpty && url.isNotEmpty) {
          // Create a FileShareInfo object
          final shareInfo = FileShareInfo(
            fileId: fileId,
            fileName: fileName,
            fileSize: fileSize,
            url: url,
            mimeType: _guessMimeTypeFromFileName(fileName),
          );
          
          _logger.log('📦 File share received: ${shareInfo.fileName}');
          _logger.log('📊 File size: ${_formatFileSize(shareInfo.fileSize)}');
          _logger.log('🔗 Download URL: ${shareInfo.url}');
          
          // Start download
          return await _fileDownloadService.downloadFile(shareInfo);
        }
      } else {
        _logger.log('⚠️ Not a recognized file share message');
      }
      
      return null;
    } catch (e) {
      _logger.log('❌ Error processing file share message: $e');
      return null;
    }
  }
  
  /// Guess MIME type from file name
  String _guessMimeTypeFromFileName(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    switch (extension) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      case 'doc':
      case 'docx':
        return 'application/msword';
      case 'xls':
      case 'xlsx':
        return 'application/vnd.ms-excel';
      case 'ppt':
      case 'pptx':
        return 'application/vnd.ms-powerpoint';
      case 'mp3':
        return 'audio/mpeg';
      case 'mp4':
        return 'video/mp4';
      case 'zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }
  
  /// Cancel a file download
  Future<bool> cancelDownload(String fileId) async {
    return await _fileDownloadService.cancelDownload(fileId);
  }
  
  /// Format file size for display
  String _formatFileSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(2)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }
  
  void clearMessages() {
    _logger.clearMessages();
    notifyListeners();
  }
  
  @override
  void dispose() {
    _logger.log('🧹 Disposing MqttService');
    _clientTracker.removeListener(notifyListeners);
    _clientManager.dispose();
    _brokerManager.dispose();
    _fileServerService.dispose();
    _fileDownloadService.dispose();
    _topicManager.dispose();
    _logger.log('✅ MqttService disposed');
    super.dispose();
  }
  
  /// Handle incoming messages from MQTT
  void _handleIncomingMessage(String topic, String message) {
    // _logger.log('📥 Message received on topic "$topic": $message');
    
    // Parse message content to extract sender info if possible (for logging/tracking only)
    String senderId = 'unknown';
    String senderName = 'Unknown Device';
    // Always use the raw message content for TopicManager to ensure raw display
    String actualContent = message;
    
    try {
      // Try to parse as JSON to extract sender info (for structured messages)
      final Map<String, dynamic> messageData = jsonDecode(message);
      if (messageData.containsKey('senderId')) {
        senderId = messageData['senderId'];
      }
      if (messageData.containsKey('senderName')) {
        senderName = messageData['senderName'];
      }
      // NO content extraction - always use raw message for TopicManager display
    } catch (e) {
      // If not JSON, treat the entire message as content
      // Use simple sender identification based on connection state
      if (isConnected || (_currentMode == AppMode.broker && _brokerMonitoringClientConnected)) {
        // This could be our own message echoed back, but we'll treat all as external
        // since we can't reliably distinguish without structured messages
        senderId = 'device';
        senderName = 'Connected Device';
      } else if (_currentMode == AppMode.broker && _clientTracker.connectedClients.isNotEmpty) {
        // In broker mode, this is from a remote client
        senderId = 'remote_client';
        senderName = 'Remote Client';
      }
    }
    
    // Forward to TopicManager
    _topicManager.addMessage(
      topic: topic,
      content: actualContent,
      senderId: senderId,
      senderName: senderName,
      type: MessageType.user,
    );
    
    // Notify specific message listeners for this topic
    final listeners = List<Function(String topic, String message)>.from(
      _messageListeners[topic] ?? const <Function(String topic, String message)>[],
    );
    for (final listener in listeners) {
      try {
        listener(topic, message);
      } catch (e) {
        _logger.log('❌ Error in message listener for topic $topic: $e');
      }
    }
    
    // Notify listeners about the new message
    notifyListeners();
  }
}

enum AppMode {
  none,
  broker,
  client,
}