import 'device_health.dart';

class ResultReport {
  final String jobId;
  final String clientId;
  final int unitIndex;
  final int ttprocMs; // inference time only
  final double bandwidthKbps; // download throughput in kB/s (bytes / download time), despite the name
  final int bytes; // bytes downloaded for this unit
  final int downloadMs; // download time only
  final int totalMs; // download + inference
  final List<dynamic>? detections;
  final String? resultUri;
  final bool warmup;

  /// Device health at the moment this unit finished (fresher than the 5 s MQTT
  /// sample). Null from older clients.
  final DeviceHealth? health;

  /// Set when the phone could not process the unit (download or inference
  /// failed). A failed report carries no detections or timings; the host puts
  /// the unit back in the pool instead of counting it as completed.
  final String? error;

  bool get failed => error != null;

  ResultReport({
    required this.jobId,
    required this.clientId,
    required this.unitIndex,
    required this.ttprocMs,
    required this.bandwidthKbps,
    this.bytes = 0,
    this.downloadMs = 0,
    this.totalMs = 0,
    this.detections,
    this.resultUri,
    this.warmup = false,
    this.health,
    this.error,
  });

  Map<String, dynamic> toJson() => {
        'j': jobId,
        'i': clientId,
        'unit_index': unitIndex,
        'ttproc_ms': ttprocMs,
        'bandwidth_kBps': bandwidthKbps,
        'bytes': bytes,
        'download_ms': downloadMs,
        'total_ms': totalMs,
        'detections': detections,
        'result_uri': resultUri,
        'warmup': warmup,
        if (health != null && !health!.isUnknown) 'health': health!.toWire(),
        if (error != null) 'error': error,
      };

  static ResultReport fromJson(Map<String, dynamic> j) => ResultReport(
        jobId: j['j'] as String,
        clientId: j['i'] as String,
        unitIndex: j['unit_index'] as int,
        ttprocMs: j['ttproc_ms'] as int,
        bandwidthKbps: (j['bandwidth_kBps'] as num).toDouble(),
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        downloadMs: (j['download_ms'] as num?)?.toInt() ?? 0,
        totalMs: (j['total_ms'] as num?)?.toInt() ?? 0,
        detections: (j['detections'] as List<dynamic>?)?.toList(),
        resultUri: j['result_uri'] as String?,
        warmup: j['warmup'] as bool? ?? false,
        health: j['health'] is Map
            ? DeviceHealth.fromWire(Map<String, dynamic>.from(j['health'] as Map))
            : null,
        error: j['error'] as String?,
      );
}

/// What the host knows about one worker phone when it makes a scheduling decision.
///
/// `ttprocMs` and `bandwidthKbps` are slow-moving EMAs learned from finished
/// units. The remaining fields are the *dynamic* state: `DistributionManager`
/// fills them into a fresh snapshot for every scheduling call, so a scheduler
/// always sees the situation as it is now. All have neutral defaults, so code
/// that builds a plain `ClientEstimate(ttprocMs:, bandwidthKbps:)` still works.
class ClientEstimate {
  double ttprocMs; // inference ms per unit (EMA)
  double bandwidthKbps; // download kB/s (EMA of bytes / download time)

  /// Latest known device health (battery, thermal, RAM, Wi-Fi, CPU load...).
  DeviceHealth health;

  /// Units assigned to this client and not yet completed (its queue depth).
  int pending;

  /// Mean (download + inference) ms of its last few units; 0 until it has finished one.
  double recentLatencyMs;

  /// Milliseconds since the host last heard from this client; -1 = unknown.
  int ageMs;

  /// Recent units this client failed (lease timed out or it reported an error)
  /// that had to be re-queued.
  int failures;

  /// Device model name (from the client id), used for power priors.
  String deviceName;

  ClientEstimate({
    required this.ttprocMs,
    required this.bandwidthKbps,
    this.health = DeviceHealth.unknown,
    this.pending = 0,
    this.recentLatencyMs = 0,
    this.ageMs = -1,
    this.failures = 0,
    this.deviceName = '',
  });

  ClientEstimate copy() => ClientEstimate(
        ttprocMs: ttprocMs,
        bandwidthKbps: bandwidthKbps,
        health: health,
        pending: pending,
        recentLatencyMs: recentLatencyMs,
        ageMs: ageMs,
        failures: failures,
        deviceName: deviceName,
      );
}
