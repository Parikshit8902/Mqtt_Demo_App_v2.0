import 'dart:async';
import 'dart:convert';
import '../services/mqtt_client_manager.dart';
import '../services/performance_service.dart';
import '../services/metrics/metrics_store.dart';

/// Publishes client metrics to MQTT at a regular interval with a minimal payload.
class ClientMetricsPublisher {
  final MqttClientManager mqttClientManager;
  final PerformanceService performanceService;
  final Duration interval;
  Timer? _timer;

  ClientMetricsPublisher({
    required this.mqttClientManager,
    required this.performanceService,
    this.interval = const Duration(seconds: 5),
  });

  void start() {
    _timer?.cancel();
    print('DEBUG: ClientMetricsPublisher timer started');
    _timer = Timer.periodic(interval, (_) {
      // print('DEBUG: Timer tick, calling _collectAndPublish');
      _collectAndPublish();
    });
  }

  void stop() {
    print('DEBUG: ClientMetricsPublisher timer stopped');
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _collectAndPublish() async {
    try {
      final clientId = mqttClientManager.clientId;
      final deviceName = deviceNameFromClientId(clientId);
      final deviceIp = deviceKeyFromClientId(clientId);
      final store = MetricsStore.instance;
      store.setLocalIdentity(deviceIp, deviceName);

      // Prefer the pipeline's latest sample (adds network, power and payload
      // counters); fall back to the three original fields if none exists yet.
      final Map<String, dynamic> body;
      if (store.local.samples.isNotEmpty) {
        body = store.local.samples.last.toWire();
      } else {
        body = {
          'c': double.parse(performanceService.cpuUsage.toStringAsFixed(2)),
          'm': double.parse(performanceService.memoryUsage.toStringAsFixed(2)),
          'b': performanceService.batteryLevel,
          't': DateTime.now().millisecondsSinceEpoch,
        };
      }
      final payload = jsonEncode({'i': deviceIp, 'name': deviceName, ...body});

      await mqttClientManager.publishMessage(
        message: payload,
        topic: 'clients/metrics',
      );
    } catch (e) {
      // ignore: avoid_print
      print('❌ Error publishing metrics: $e');
    }
  }
}
