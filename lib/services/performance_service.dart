import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'; // Import for WidgetsBindingObserver
import 'metrics/metrics_store.dart';
import 'models/device_health.dart';
import 'metrics/power_model.dart';
import 'metrics/traffic_counter.dart';

// Use the same channel name as defined in MainActivity.kt
const platform = MethodChannel('com.example.mqtt_demo/performance');

/// A data class to hold a snapshot of all performance metrics.
class PerformanceData {
  final double cpuUsage;
  final double memoryUsage;
  final String networkUsage;
  final String diskUsage;
  final String batteryLevel;
  final List<double> cpuDataPoints;
  /// Whole-device draw from battery current x voltage (Android, unplugged), mW. Null if unavailable.
  final double? measuredPowerMw;
  /// Modelled draw of this app only, mW.
  final double modelPowerMw;
  /// Live device state for the schedulers (thermal, RAM, Wi-Fi, charging...).
  final DeviceHealth health;

  PerformanceData({
    this.cpuUsage = 0.0,
    this.memoryUsage = 0.0,
    this.networkUsage = '...',
    this.diskUsage = '...',
    this.batteryLevel = '...',
    this.cpuDataPoints = const [],
    this.measuredPowerMw,
    this.modelPowerMw = 0.0,
    this.health = DeviceHealth.unknown,
  });
}

/// A singleton service that is now lifecycle-aware and uses a dynamic clock speed.
class PerformanceService with WidgetsBindingObserver {
  // --- Metric Getters for external use ---
  double get cpuUsage => notifier.value.cpuUsage;
  double get memoryUsage => notifier.value.memoryUsage;
  String get networkUsage => notifier.value.networkUsage;
  String get diskUsage => notifier.value.diskUsage;
  String get batteryLevel => notifier.value.batteryLevel;
  /// Latest device health; [DeviceHealth.unknown] until the first tick completes.
  DeviceHealth get currentHealth => notifier.value.health;
  // --- Singleton Setup ---
  PerformanceService._privateConstructor() {
    init();
  }
  static final PerformanceService instance = PerformanceService._privateConstructor();

  // --- State Variables ---
  Timer? _timer;
  final List<double> _cpuDataPoints = [];
  final int _maxDataPoints = 30;
  
  // This will hold the actual clock tick rate of the device.
  double _clockTicksPerSecond = 100.0; // Start with a safe default.

  Map<String, int> _lastMetrics = {};
  DateTime _lastTimestamp = DateTime.now();
  
  final ValueNotifier<PerformanceData> notifier = ValueNotifier(PerformanceData());

  /// Initializes the service, gets static data, and registers the lifecycle listener.
  Future<void> init() async {
    // Register this service to listen to app lifecycle events.
    WidgetsBinding.instance.addObserver(this);
    
    // Fetch the device's actual clock tick rate once at startup.
    try {
      final int? ticks = await platform.invokeMethod<int>('getClockTicksPerSecond');
      if (ticks != null && ticks > 0) {
        _clockTicksPerSecond = ticks.toDouble();
        print("✅ Successfully fetched device clock ticks per second: $_clockTicksPerSecond");
      }
    } catch (e) {
      print("⚠️ Could not fetch clock ticks, falling back to 100Hz. Error: $e");
    }
    
    // Start the timer now that we are initialized.
    _startTimer();
  }
  
  // --- Lifecycle Management ---
  
  // Who is running an experiment on this phone (a worker, a hosted session).
  // While anyone is, the screen is kept on and backgrounding does not stop
  // the sampling timer, so the recording has no gaps.
  final Set<String> _runHolders = {};

  bool get runActive => _runHolders.isNotEmpty;

  /// Keep sampling, and keep the screen on, until [endRun] with the same [who].
  /// On Android a foreground service also keeps the run going if the screen
  /// turns off or the app goes to the background anyway.
  void beginRun(String who) {
    final first = _runHolders.isEmpty;
    _runHolders.add(who);
    if (first) {
      _setKeepScreenOn(true);
      _setRunService(true);
      _startTimer();
    }
  }

  void endRun(String who) {
    if (_runHolders.remove(who) && _runHolders.isEmpty) {
      _setKeepScreenOn(false);
      _setRunService(false);
    }
  }

  Future<void> _setRunService(bool on) async {
    try {
      if (on) {
        await platform.invokeMethod('startRunService', {'text': 'Hosting or working on an experiment'});
      } else {
        await platform.invokeMethod('stopRunService');
      }
    } catch (_) {
      // iOS has no such service (it suspends backgrounded apps regardless).
    }
  }

  Future<void> _setKeepScreenOn(bool on) async {
    try {
      await platform.invokeMethod('setKeepScreenOn', {'on': on});
    } catch (_) {
      // Desktop builds and tests have no such method; sampling still works.
    }
  }

  /// Whether the sampling timer runs in [state]. `inactive` is transient (the
  /// notification shade, the app switcher, a system dialog), so it never stops
  /// sampling; leaving the foreground only does when no experiment is running.
  static bool samplesIn(AppLifecycleState state, {required bool runActive}) {
    switch (state) {
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        return true;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        return runActive;
    }
  }

  @override
  // This method is called automatically by the Flutter framework.
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (samplesIn(state, runActive: runActive)) {
      _startTimer();
    } else {
      print("⛔️ App in background with no experiment running, stopping performance timer to save battery.");
      _stopTimer();
    }
  }

  void _startTimer() {
    // Prevent multiple timers from running.
    if (_timer?.isActive ?? false) return;
    
    // Update immediately when resuming, then start the periodic timer.
    _updateMetrics();
    _timer = Timer.periodic(const Duration(seconds: 2), (timer) => _updateMetrics());
  }

  void _stopTimer() {
    _timer?.cancel();
  }

  // --- Core Logic ---
  Future<void> _updateMetrics() async {
    try {
      // Fetch all metrics in a single batch, just like before.
      final results = await Future.wait([
        platform.invokeMapMethod<String, int>('getPerformanceMetrics'),
        platform.invokeMethod<double>('getAppMemoryUsageMB'),
        platform.invokeMethod<int>('getBatteryDetails'),
      ]);

      final currentMetrics = results[0] as Map<String, int>;
      final currentMemory = results[1] as double;
      final currentBattery = results[2] as int;
      final measuredPowerMw = await _readMeasuredPowerMw();
      final now = DateTime.now();
      
      final deltaSeconds = now.difference(_lastTimestamp).inMilliseconds > 0 
          ? now.difference(_lastTimestamp).inMilliseconds / 1000.0 
          : 1.0;

      double cpuUsage = notifier.value.cpuUsage; // Default to old value
      final hadPrevious = _lastMetrics.isNotEmpty;
      if (_lastMetrics.containsKey('cpuJiffies') && currentMetrics.containsKey('cpuJiffies')) {
        final cpuJiffiesDiff = currentMetrics['cpuJiffies']! - _lastMetrics['cpuJiffies']!;
        
        // *** This now uses the dynamically fetched clock speed ***
        final cpuSecondsUsed = cpuJiffiesDiff / _clockTicksPerSecond;
        
        final cpuUsageRatio = cpuSecondsUsed / deltaSeconds;
        cpuUsage = cpuUsageRatio * 100.0;
        
        _cpuDataPoints.add(cpuUsage);
        if (_cpuDataPoints.length > _maxDataPoints) {
          _cpuDataPoints.removeAt(0);
        }
      }

      String networkUsage = notifier.value.networkUsage; // Default to old value
      double rxKBps = 0, txKBps = 0;
      if (_lastMetrics.containsKey('netRxBytes') && currentMetrics.containsKey('netRxBytes')) {
        // TrafficStats reports -1 when unsupported; ignore those readings.
        final rxDiff = currentMetrics['netRxBytes']! >= 0 ? currentMetrics['netRxBytes']! - _lastMetrics['netRxBytes']! : 0;
        final txDiff = currentMetrics['netTxBytes']! >= 0 ? currentMetrics['netTxBytes']! - _lastMetrics['netTxBytes']! : 0;
        rxKBps = (rxDiff / deltaSeconds) / 1024;
        txKBps = (txDiff / deltaSeconds) / 1024;
        final totalSpeed = rxKBps + txKBps;
        networkUsage = '${totalSpeed.toStringAsFixed(1)} KB/s';
      }

      String diskUsage = notifier.value.diskUsage; // Default to old value
      if (_lastMetrics.containsKey('diskReadBytes') && currentMetrics.containsKey('diskReadBytes')) {
        final readDiff = currentMetrics['diskReadBytes']! - _lastMetrics['diskReadBytes']!;
        final writeDiff = currentMetrics['diskWriteBytes']! - _lastMetrics['diskWriteBytes']!;
        final totalSpeed = ((readDiff + writeDiff) / deltaSeconds) / 1024;
        diskUsage = '${totalSpeed.toStringAsFixed(1)} KB/s';
      }

      _lastMetrics = currentMetrics;
      _lastTimestamp = now;

      final cores = Platform.numberOfProcessors > 0 ? Platform.numberOfProcessors : 1;
      final cpuNormPct = cpuUsage / cores;
      final modelMw = _powerModel.estimateMw(
        cpuCores: cpuUsage / 100.0,
        bytesPerSec: (rxKBps + txKBps) * 1024,
      );

      // Read after the rate bookkeeping above so the extra platform call cannot skew the next delta.
      final health = await _readDeviceHealth(
        at: now,
        cpuNormPct: cpuNormPct,
        batteryPct: currentBattery,
        measuredPowerMw: measuredPowerMw,
      );

      // Record a sample for the metrics pipeline (needs a previous reading for rates).
      if (hadPrevious) {
        MetricsStore.instance.recordLocal(MetricSample(
          t: now.millisecondsSinceEpoch,
          cpuPct: cpuUsage,
          cpuNormPct: cpuNormPct,
          memMb: currentMemory,
          rxKBps: rxKBps,
          txKBps: txKBps,
          rxBytes: currentMetrics['netRxBytes'] ?? 0,
          txBytes: currentMetrics['netTxBytes'] ?? 0,
          payloadBytes: TrafficCounter.instance.totalPayload,
          rxPackets: currentMetrics['netRxPackets'] ?? 0,
          txPackets: currentMetrics['netTxPackets'] ?? 0,
          battery: currentBattery,
          measuredMw: measuredPowerMw,
          modelMw: modelMw,
          health: health,
        ));
      }

      // Update the notifier with a new data object containing all metrics.
      notifier.value = PerformanceData(
        cpuUsage: cpuUsage,
        memoryUsage: currentMemory,
        networkUsage: networkUsage,
        diskUsage: diskUsage,
        batteryLevel: currentBattery >= 0 ? '$currentBattery%' : 'N/A',
        cpuDataPoints: List.from(_cpuDataPoints),
        measuredPowerMw: measuredPowerMw,
        modelPowerMw: modelMw,
        health: health,
      );

    } catch (e) {
      print("Failed to fetch performance metrics: $e");
    }
  }

  /// Whole-device power from battery current x voltage. Only meaningful while
  /// unplugged, and only where the OS exposes the current (Android). Returns
  /// null otherwise. This is the *device*, not just this app - use it to
  /// calibrate [PowerModel] rather than to attribute power to the app.
  Future<double?> _readMeasuredPowerMw() async {
    try {
      final p = await platform.invokeMapMethod<String, dynamic>('getPowerDetails');
      if (p == null || p['charging'] == true) return null;
      final currentRaw = (p['currentNow'] as num?)?.toDouble();
      final voltageMv = (p['voltageMv'] as num?)?.toDouble();
      if (currentRaw == null || voltageMv == null || currentRaw == 0 || voltageMv <= 0) return null;
      // BATTERY_PROPERTY_CURRENT_NOW is specified in microamps, but some vendors
      // report milliamps. Real phone draw is >= tens of mA, so a magnitude under
      // 20000 can only be mA.
      final mA = currentRaw.abs() < 20000 ? currentRaw.abs() : currentRaw.abs() / 1000.0;
      return mA * (voltageMv / 1000.0);
    } catch (_) {
      return null;
    }
  }

  /// Native `getDeviceHealth` key -> [DeviceHealth] wire key. Going through the wire
  /// keys keeps one parser, so its "unavailable" sentinels (RSSI -127, negative
  /// thermal status, link speed <= 0) are handled in a single place.
  static const Map<String, String> _nativeHealthKeys = {
    'memFreeMb': 'fm',
    'memTotalMb': 'tm',
    'lowMemory': 'lm',
    'batteryTempC': 'bt',
    'thermalStatus': 'th',
    'charging': 'chg',
    'rssiDbm': 'rs',
    'linkMbps': 'ls',
  };

  /// This tick's health: the values already measured here plus the native readings.
  /// A platform that lacks `getDeviceHealth`, or a native failure, only leaves the
  /// native fields unknown; it must not disturb the tick, so it is never rethrown.
  Future<DeviceHealth> _readDeviceHealth({
    required DateTime at,
    required double cpuNormPct,
    required int batteryPct,
    required double? measuredPowerMw,
  }) async {
    final wire = <String, dynamic>{
      'cn': cpuNormPct,
      if (batteryPct >= 0) 'bp': batteryPct,
      if (measuredPowerMw != null) 'pw': measuredPowerMw,
    };
    try {
      final native = await platform.invokeMapMethod<String, dynamic>('getDeviceHealth');
      if (native != null) {
        _nativeHealthKeys.forEach((nativeKey, wireKey) {
          final value = native[nativeKey];
          if (value != null) wire[wireKey] = value;
        });
      }
    } catch (_) {
      // Deliberately silent: an unimplemented method would otherwise log every 2 s.
    }
    return DeviceHealth.fromWire(wire, updatedAtMs: at.millisecondsSinceEpoch);
  }

  final PowerModel _powerModel = PowerModel.defaults;

  void dispose() {
    // Unregister the observer to prevent memory leaks when the service is no longer needed.
    WidgetsBinding.instance.removeObserver(this);
    _stopTimer();
    notifier.dispose();
  }
}