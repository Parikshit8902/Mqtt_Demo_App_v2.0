import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/device_health.dart';
import 'run_metrics.dart';
import 'traffic_counter.dart';

// ---------------------------------------------------------------------------
// Device identity helpers. Client ids look like
// "mqtt_client_<DeviceName>_<BrokerIP>_<DeviceIP-with-dashes>".
// ---------------------------------------------------------------------------
String deviceKeyFromClientId(String clientId) {
  final parts = clientId.split('_');
  if (parts.length >= 5) return parts.last.replaceAll('-', '.');
  return clientId;
}

String deviceNameFromClientId(String clientId) {
  final parts = clientId.split('_');
  return parts.length >= 3 ? parts[2] : clientId;
}

double _d(dynamic v, [double fallback = 0]) => v is num ? v.toDouble() : fallback;
int _i(dynamic v, [int fallback = 0]) => v is num ? v.toInt() : fallback;

String _csvCell(Object? v) {
  if (v == null) return '';
  final s = v is double ? v.toStringAsFixed(3) : v.toString();
  if (s.contains(',') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

String _csvRow(Iterable<Object?> cells) => cells.map(_csvCell).join(',');

/// One periodic reading from one phone.
class MetricSample {
  final int t; // epoch ms
  final double cpuPct; // process CPU time / wall time * 100 (100 == one full core)
  final double cpuNormPct; // cpuPct / core count: share of the whole SoC
  final double memMb;
  final double rxKBps; // on-wire (OS counters)
  final double txKBps;
  final int rxBytes; // on-wire cumulative since app start
  final int txBytes;
  final int payloadBytes; // app-layer payload (TrafficCounter) cumulative, rx+tx
  final int rxPackets; // on-wire packets (OS counters) cumulative since app start
  final int txPackets;
  final int battery; // percent, -1 unknown
  final double? measuredMw; // whole-device draw from battery current*voltage (Android, unplugged)
  final double modelMw; // modelled app draw
  double energyModelJ; // cumulative, modelled
  double energyMeasuredJ; // cumulative, measured (whole device)

  /// Live device state at sample time (thermal, RAM, Wi-Fi...). Null when none
  /// of it is known.
  final DeviceHealth? health;

  MetricSample({
    required this.t,
    required this.cpuPct,
    required this.cpuNormPct,
    required this.memMb,
    required this.rxKBps,
    required this.txKBps,
    required this.rxBytes,
    required this.txBytes,
    required this.payloadBytes,
    this.rxPackets = 0,
    this.txPackets = 0,
    required this.battery,
    required this.measuredMw,
    required this.modelMw,
    this.energyModelJ = 0,
    this.energyMeasuredJ = 0,
    this.health,
  });

  /// Compact keys: 'c','m','b','t' match the original `clients/metrics` payload.
  /// Health keys are appended only when known, so old hosts just ignore them.
  Map<String, dynamic> toWire() => {
        't': t,
        'c': double.parse(cpuPct.toStringAsFixed(2)),
        'cn': double.parse(cpuNormPct.toStringAsFixed(2)),
        'm': double.parse(memMb.toStringAsFixed(2)),
        'b': '$battery%',
        'rx': rxBytes,
        'tx': txBytes,
        'rxk': double.parse(rxKBps.toStringAsFixed(1)),
        'txk': double.parse(txKBps.toStringAsFixed(1)),
        'ap': payloadBytes,
        if (rxPackets > 0) 'rp': rxPackets,
        if (txPackets > 0) 'tp': txPackets,
        if (measuredMw != null) 'pw': double.parse(measuredMw!.toStringAsFixed(0)),
        'pm': double.parse(modelMw.toStringAsFixed(0)),
        'e': double.parse(energyModelJ.toStringAsFixed(2)),
        if (energyMeasuredJ > 0) 'em': double.parse(energyMeasuredJ.toStringAsFixed(2)),
        // 'cn' and 'pw' already appear above with the same meaning; the sample's own
        // values stay authoritative so a key is never emitted twice or with two values.
        if (health != null) ...(health!.toWire()..remove('cn')..remove('pw')),
      };

  factory MetricSample.fromWire(Map<String, dynamic> j) {
    final bat = j['b'];
    int battery = -1;
    if (bat is num) {
      battery = bat.toInt();
    } else if (bat is String) {
      battery = int.tryParse(RegExp(r'-?\d+').firstMatch(bat)?.group(0) ?? '') ?? -1;
    }
    final c = _d(j['c']);
    final health = DeviceHealth.fromWire(j);
    return MetricSample(
      t: _i(j['t']),
      cpuPct: c,
      cpuNormPct: j.containsKey('cn') ? _d(j['cn']) : c,
      memMb: _d(j['m']),
      rxKBps: _d(j['rxk']),
      txKBps: _d(j['txk']),
      rxBytes: _i(j['rx']),
      txBytes: _i(j['tx']),
      payloadBytes: _i(j['ap']),
      rxPackets: _i(j['rp']),
      txPackets: _i(j['tp']),
      battery: battery,
      measuredMw: j['pw'] is num ? (j['pw'] as num).toDouble() : null,
      modelMw: _d(j['pm']),
      energyModelJ: _d(j['e']),
      energyMeasuredJ: _d(j['em']),
      health: health.isUnknown ? null : health,
    );
  }

  // The health columns come last so exports made before they existed keep their layout.
  static const csvHeader = [
    'device', 'name', 'time_ms', 'cpu_pct', 'cpu_norm_pct', 'mem_mb', 'rx_kBps', 'tx_kBps',
    'rx_bytes_onwire', 'tx_bytes_onwire', 'payload_bytes', 'battery_pct', 'power_measured_mw',
    'power_model_mw', 'energy_model_j', 'energy_measured_j',
    'thermal_status', 'rssi_dbm', 'link_mbps', 'mem_free_mb', 'mem_total_mb', 'low_memory', 'charging',
    'battery_temp_c', 'rx_packets_onwire', 'tx_packets_onwire',
  ];

  /// Flags are written 1/0 like on the wire; an unknown value is an empty cell.
  List<Object?> csvCells(String device, String name) => [
        device, name, t, cpuPct, cpuNormPct, memMb, rxKBps, txKBps, rxBytes, txBytes, payloadBytes,
        battery, measuredMw, modelMw, energyModelJ, energyMeasuredJ,
        health?.thermalStatus, health?.rssiDbm, health?.linkMbps, health?.memFreeMb, health?.memTotalMb,
        _flag(health?.lowMemory), _flag(health?.charging), health?.batteryTempC, rxPackets, txPackets,
      ];

  static int? _flag(bool? v) => v == null ? null : (v ? 1 : 0);
}

/// Per work-unit record (one image / chunk processed by one phone).
class UnitRecord {
  final String deviceKey;
  final String jobId;
  final int unitIndex;
  final int bytes; // bytes downloaded for this unit
  final int downloadMs; // time spent downloading
  final int inferMs; // time spent in inference
  final int totalMs; // download + inference (excludes result upload)
  final double downloadKBps; // effective download throughput (bytes / downloadMs)
  final String scheduler;
  final int t; // epoch ms when finished; the host's clock in the host's records

  UnitRecord({
    required this.deviceKey,
    required this.jobId,
    required this.unitIndex,
    required this.bytes,
    required this.downloadMs,
    required this.inferMs,
    required this.totalMs,
    required this.downloadKBps,
    required this.scheduler,
    required this.t,
  });

  String get id => '$jobId:$unitIndex';

  Map<String, dynamic> toJson() => {
        'device': deviceKey,
        'job': jobId,
        'unit': unitIndex,
        'bytes': bytes,
        'download_ms': downloadMs,
        'infer_ms': inferMs,
        'total_ms': totalMs,
        'download_kBps': downloadKBps,
        'scheduler': scheduler,
        't': t,
      };

  factory UnitRecord.fromJson(Map<String, dynamic> j, {String? deviceKey}) => UnitRecord(
        deviceKey: deviceKey ?? (j['device'] as String? ?? 'unknown'),
        jobId: j['job'] as String? ?? '',
        unitIndex: _i(j['unit']),
        bytes: _i(j['bytes']),
        downloadMs: _i(j['download_ms']),
        inferMs: _i(j['infer_ms']),
        totalMs: _i(j['total_ms']),
        downloadKBps: _d(j['download_kBps']),
        scheduler: j['scheduler'] as String? ?? '',
        t: _i(j['t']),
      );

  static const csvHeader = [
    'device', 'job', 'unit', 'bytes', 'download_ms', 'infer_ms', 'total_ms', 'download_kBps', 'scheduler', 'time_ms',
  ];

  List<Object?> csvCells() =>
      [deviceKey, jobId, unitIndex, bytes, downloadMs, inferMs, totalMs, downloadKBps, scheduler, t];
}

/// One scheduling decision: which phone was handed which units, and why.
class DecisionRecord {
  final int t; // host clock, epoch ms
  final String deviceKey;
  final String deviceName;
  final List<int> units;
  final String scheduler;

  /// Health score of every phone the scheduler considered (0..1), if known.
  final Map<String, double> healthByDevice;

  DecisionRecord({
    required this.t,
    required this.deviceKey,
    required this.deviceName,
    required this.units,
    required this.scheduler,
    this.healthByDevice = const {},
  });

  static const csvHeader = ['time_ms', 'device', 'name', 'scheduler', 'units', 'health_by_device'];

  List<Object?> csvCells() => [
        t,
        deviceKey,
        deviceName,
        scheduler,
        units.join(' '),
        healthByDevice.entries.map((e) => '${e.key}=${e.value}').join(' '),
      ];
}

/// Everything recorded about one phone.
class DeviceMetrics {
  final String key; // device IP
  String name;
  final bool isLocal;
  final List<MetricSample> samples = [];
  final Map<String, UnitRecord> units = {}; // keyed by job:unit so re-uploads de-duplicate
  Map<String, dynamic>? traffic; // TrafficCounter.toJson() (only when the phone uploaded a report)
  int lastSeen = 0;

  /// Host clock minus this phone's clock, learned from its first sample, so
  /// every phone can be drawn on one timeline. Zero for the local phone.
  int? clockOffsetMs;

  /// Host-clock times of this phone's assignment requests (capped).
  final List<int> polls = [];

  /// A sample time converted to the host's clock.
  int hostTime(int sampleT) => sampleT + (clockOffsetMs ?? 0);

  /// Median gap between the last few samples, in seconds (0 if fewer than 2).
  double get sampleIntervalS {
    if (samples.length < 2) return 0;
    final from = samples.length > 11 ? samples.length - 11 : 0;
    final gaps = <int>[
      for (var i = from + 1; i < samples.length; i++) samples[i].t - samples[i - 1].t,
    ]..sort();
    return gaps[gaps.length ~/ 2] / 1000.0;
  }

  DeviceMetrics(this.key, this.name, {this.isLocal = false});

  String get label => isLocal ? '$name (this phone)' : name;
}

/// Aggregates for one phone over its recording window.
class DeviceSummary {
  final String key;
  final String name;
  final double durationS;
  final double avgCpuPct, peakCpuPct, avgCpuNormPct, peakCpuNormPct;
  final double avgMemMb, peakMemMb;
  final int onWireRxBytes, onWireTxBytes, payloadBytes;
  final int batteryStart, batteryEnd;
  final double energyModelJ, energyMeasuredJ;
  final double? avgMeasuredMw;
  final int unitsDone;
  final double avgDownloadMs, avgInferMs, avgDownloadKBps;
  final int unitBytes;
  final int rxPackets, txPackets; // on-wire packets over the recording window

  DeviceSummary({
    required this.key,
    required this.name,
    required this.durationS,
    required this.avgCpuPct,
    required this.peakCpuPct,
    required this.avgCpuNormPct,
    required this.peakCpuNormPct,
    required this.avgMemMb,
    required this.peakMemMb,
    required this.onWireRxBytes,
    required this.onWireTxBytes,
    required this.payloadBytes,
    required this.batteryStart,
    required this.batteryEnd,
    required this.energyModelJ,
    required this.energyMeasuredJ,
    required this.avgMeasuredMw,
    required this.unitsDone,
    required this.avgDownloadMs,
    required this.avgInferMs,
    required this.avgDownloadKBps,
    required this.unitBytes,
    this.rxPackets = 0,
    this.txPackets = 0,
  });

  int get onWireBytes => onWireRxBytes + onWireTxBytes;

  /// On-wire bytes not explained by app payload: TCP/IP/Wi-Fi/HTTP/MQTT framing,
  /// discovery, retransmits - and on the broker phone, relayed MQTT traffic.
  int get overheadBytes => (onWireBytes - payloadBytes).clamp(0, 1 << 62);
  double get overheadPct => onWireBytes > 0 ? overheadBytes * 100.0 / onWireBytes : 0;
  double get avgPowerModelMw => durationS > 0 ? energyModelJ * 1000.0 / durationS : 0;
  int get batteryDrop => (batteryStart >= 0 && batteryEnd >= 0) ? batteryStart - batteryEnd : 0;

  static const csvHeader = [
    'device', 'name', 'duration_s', 'avg_cpu_pct', 'peak_cpu_pct', 'avg_cpu_norm_pct', 'peak_cpu_norm_pct',
    'avg_mem_mb', 'peak_mem_mb', 'onwire_rx_bytes', 'onwire_tx_bytes', 'payload_bytes', 'overhead_bytes',
    'overhead_pct', 'energy_model_j', 'avg_power_model_mw', 'energy_measured_j', 'avg_power_measured_mw',
    'battery_start', 'battery_end', 'units_done', 'unit_bytes', 'avg_download_ms', 'avg_infer_ms',
    'avg_download_kBps', 'rx_packets_onwire', 'tx_packets_onwire',
  ];

  List<Object?> csvCells() => [
        key, name, durationS, avgCpuPct, peakCpuPct, avgCpuNormPct, peakCpuNormPct, avgMemMb, peakMemMb,
        onWireRxBytes, onWireTxBytes, payloadBytes, overheadBytes, overheadPct, energyModelJ, avgPowerModelMw,
        energyMeasuredJ, avgMeasuredMw, batteryStart, batteryEnd, unitsDone, unitBytes, avgDownloadMs,
        avgInferMs, avgDownloadKBps, rxPackets, txPackets,
      ];

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{};
    for (var i = 0; i < csvHeader.length; i++) {
      m[csvHeader[i]] = csvCells()[i];
    }
    return m;
  }
}

/// In-memory recording of metrics for this phone and (on the host) every
/// other phone. Exportable as CSV / JSON.
class MetricsStore extends ChangeNotifier {
  MetricsStore._();
  static final MetricsStore instance = MetricsStore._();

  static const int _maxLocalSamples = 20000; // ~11 h at 2 s
  static const int _maxRemoteSamples = 10000;

  DeviceMetrics local = DeviceMetrics('local', 'This phone', isLocal: true);
  final Map<String, DeviceMetrics> _remote = {};

  /// Which scheduling algorithm the host is running (labels exports).
  String schedulerId = '';

  /// How the host serves dataset images (ImageVariant.label).
  String imageSetting = 'original';

  /// Scheduling decisions, newest last (capped).
  final List<DecisionRecord> decisions = [];
  static const int _maxDecisions = 500;

  /// When the current experiment began (first assignment after a reset), host clock.
  int? experimentStartMs;

  /// When the latest finished unit was recorded, this phone's clock (on the
  /// host: when its result arrived). Ends the run's makespan.
  int? lastUnitAtMs;

  /// Runs finished before the last reset, oldest first, for comparison.
  final List<RunMetrics> runHistory = [];
  static const int _maxRunHistory = 50;

  void recordDecision(DecisionRecord d) {
    experimentStartMs ??= d.t;
    decisions.add(d);
    if (decisions.length > _maxDecisions) decisions.removeAt(0);
    notifyListeners();
  }

  /// Host side: a worker asked for work. Shows how often each phone polls.
  void recordPoll(String deviceKey, {int? nowMs}) {
    final d = deviceKey == local.key ? local : _remoteDevice(deviceKey, null);
    d.polls.add(nowMs ?? DateTime.now().millisecondsSinceEpoch);
    if (d.polls.length > 300) d.polls.removeAt(0);
    notifyListeners();
  }

  /// Assignment requests in the last minute.
  int pollsLastMinute(DeviceMetrics d, {int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return d.polls.where((t) => now - t <= 60000).length;
  }

  /// Seconds since the last assignment request, or null if none yet.
  double? lastPollAgeS(DeviceMetrics d, {int? nowMs}) {
    if (d.polls.isEmpty) return null;
    return ((nowMs ?? DateTime.now().millisecondsSinceEpoch) - d.polls.last) / 1000.0;
  }

  void setLocalIdentity(String key, String name) {
    local = _rekey(local, key, name);
    notifyListeners();
  }

  DeviceMetrics _rekey(DeviceMetrics old, String key, String name) {
    if (old.key == key) {
      old.name = name;
      return old;
    }
    final fresh = DeviceMetrics(key, name, isLocal: true);
    fresh.samples.addAll(old.samples);
    for (final u in old.units.values) {
      fresh.units[u.id] = UnitRecord.fromJson(u.toJson(), deviceKey: key);
    }
    return fresh;
  }

  List<DeviceMetrics> get devices => [local, ..._remote.values];
  DeviceMetrics? device(String key) => key == local.key ? local : _remote[key];

  DeviceMetrics _remoteDevice(String key, String? name) =>
      _remote.putIfAbsent(key, () => DeviceMetrics(key, name ?? key));

  // -- recording ------------------------------------------------------------

  void recordLocal(MetricSample s) {
    final prev = local.samples.isEmpty ? null : local.samples.last;
    if (prev != null && s.t > prev.t) {
      final dt = (s.t - prev.t) / 1000.0;
      s.energyModelJ = prev.energyModelJ + s.modelMw / 1000.0 * dt;
      s.energyMeasuredJ = prev.energyMeasuredJ + (s.measuredMw ?? 0) / 1000.0 * dt;
    }
    local.samples.add(s);
    if (local.samples.length > _maxLocalSamples) local.samples.removeAt(0);
    local.lastSeen = s.t;
    notifyListeners();
  }

  /// Host side: a `clients/metrics` MQTT payload from a worker phone.
  void ingestWire(String message) {
    try {
      final j = jsonDecode(message);
      if (j is! Map<String, dynamic>) return;
      final key = (j['i'] as String?) ?? '';
      if (key.isEmpty || key == local.key) return;
      final d = _remoteDevice(key, j['name'] as String?);
      final s = MetricSample.fromWire(j);
      if (d.samples.isNotEmpty && s.t <= d.samples.last.t) return;
      d.clockOffsetMs ??= DateTime.now().millisecondsSinceEpoch - s.t;
      d.samples.add(s);
      if (d.samples.length > _maxRemoteSamples) d.samples.removeAt(0);
      d.lastSeen = s.t;
      notifyListeners();
    } catch (_) {}
  }

  /// Record a finished unit for [deviceKey] (replaces any earlier record for the same unit).
  void recordUnit(String deviceKey, UnitRecord u, {int? nowMs}) {
    final d = deviceKey == local.key ? local : _remoteDevice(deviceKey, null);
    d.units[u.id] = u;
    lastUnitAtMs = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
  }

  /// Host side: a full report uploaded by a worker (2 s samples, units, traffic).
  void mergeDeviceReport(Map<String, dynamic> report) {
    final key = report['key'] as String? ?? '';
    if (key.isEmpty || key == local.key) return;
    final d = _remoteDevice(key, report['name'] as String?);
    if (report['name'] is String) d.name = report['name'] as String;
    final samples = report['samples'];
    if (samples is List && samples.isNotEmpty) {
      d.samples
        ..clear()
        ..addAll(samples.whereType<Map>().map((m) => MetricSample.fromWire(Map<String, dynamic>.from(m))));
    }
    if (d.clockOffsetMs == null && d.samples.isNotEmpty) {
      d.clockOffsetMs = DateTime.now().millisecondsSinceEpoch - d.samples.last.t;
    }
    final units = report['units'];
    if (units is List) {
      for (final u in units.whereType<Map>()) {
        final incoming = Map<String, dynamic>.from(u);
        final rec = UnitRecord.fromJson(incoming, deviceKey: key);
        final hostRecord = d.units[rec.id];
        if (rec.scheduler.isEmpty) {
          // Workers don't know the active scheduler; keep what the host stamped.
          incoming['scheduler'] = hostRecord?.scheduler ?? schedulerId;
        }
        // Unit times are kept on the host's clock, so phones line up on one
        // timeline: the host's own stamp if it has one, else the worker's
        // time shifted by the phone's clock offset.
        incoming['t'] = hostRecord?.t ?? d.hostTime(rec.t);
        d.units[rec.id] = UnitRecord.fromJson(incoming, deviceKey: key);
      }
    }
    if (report['traffic'] is Map) d.traffic = Map<String, dynamic>.from(report['traffic'] as Map);
    d.lastSeen = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
  }

  /// The payload a worker uploads to the host.
  Map<String, dynamic> localReport() => {
        'key': local.key,
        'name': local.name,
        'samples': local.samples.map((s) => s.toWire()).toList(),
        'units': local.units.values.map((u) => u.toJson()).toList(),
        'traffic': TrafficCounter.instance.toJson(),
      };

  /// Traffic breakdown for [d]: live counters for this phone, uploaded for others.
  Map<String, dynamic>? trafficOf(DeviceMetrics d) => d.isLocal ? TrafficCounter.instance.toJson() : d.traffic;

  /// Clears everything for a new experiment. The finished run's comparison
  /// numbers are kept in [runHistory] first.
  void clear() {
    final finished = runMetrics();
    if (finished.units > 0) {
      runHistory.add(finished);
      if (runHistory.length > _maxRunHistory) runHistory.removeAt(0);
    }
    lastUnitAtMs = null;
    local.samples.clear();
    local.units.clear();
    local.polls.clear();
    _remote.clear();
    decisions.clear();
    experimentStartMs = null;
    TrafficCounter.instance.reset();
    notifyListeners();
  }

  // -- summaries ------------------------------------------------------------

  DeviceSummary summarize(DeviceMetrics d) {
    final s = d.samples;
    double sum(double Function(MetricSample) f) => s.fold(0.0, (a, b) => a + f(b));
    double peak(double Function(MetricSample) f) => s.fold(0.0, (a, b) => f(b) > a ? f(b) : a);
    final n = s.length;
    final first = n > 0 ? s.first : null;
    final last = n > 0 ? s.last : null;
    final measured = s.where((x) => x.measuredMw != null).toList();
    final units = d.units.values.toList();
    final u = units.length;
    return DeviceSummary(
      key: d.key,
      name: d.name,
      durationS: (first != null && last != null) ? (last.t - first.t) / 1000.0 : 0,
      avgCpuPct: n > 0 ? sum((x) => x.cpuPct) / n : 0,
      peakCpuPct: peak((x) => x.cpuPct),
      avgCpuNormPct: n > 0 ? sum((x) => x.cpuNormPct) / n : 0,
      peakCpuNormPct: peak((x) => x.cpuNormPct),
      avgMemMb: n > 0 ? sum((x) => x.memMb) / n : 0,
      peakMemMb: peak((x) => x.memMb),
      onWireRxBytes: (first != null && last != null) ? last.rxBytes - first.rxBytes : 0,
      onWireTxBytes: (first != null && last != null) ? last.txBytes - first.txBytes : 0,
      payloadBytes: (first != null && last != null) ? last.payloadBytes - first.payloadBytes : 0,
      batteryStart: first?.battery ?? -1,
      batteryEnd: last?.battery ?? -1,
      energyModelJ: (first != null && last != null) ? last.energyModelJ - first.energyModelJ : 0,
      energyMeasuredJ: (first != null && last != null) ? last.energyMeasuredJ - first.energyMeasuredJ : 0,
      avgMeasuredMw: measured.isEmpty ? null : measured.fold(0.0, (a, b) => a + b.measuredMw!) / measured.length,
      unitsDone: u,
      avgDownloadMs: u > 0 ? units.fold(0.0, (a, b) => a + b.downloadMs) / u : 0,
      avgInferMs: u > 0 ? units.fold(0.0, (a, b) => a + b.inferMs) / u : 0,
      avgDownloadKBps: u > 0 ? units.fold(0.0, (a, b) => a + b.downloadKBps) / u : 0,
      unitBytes: units.fold(0, (a, b) => a + b.bytes),
      rxPackets: (first != null && last != null) ? last.rxPackets - first.rxPackets : 0,
      txPackets: (first != null && last != null) ? last.txPackets - first.txPackets : 0,
    );
  }

  /// Comparison numbers for the current run: every finished unit on every
  /// phone, the workers that finished none, and every phone's modelled energy.
  RunMetrics runMetrics() {
    final latencies = <({String unitId, String phone, int latencyMs})>[];
    final idle = <String>[];
    var energyJ = 0.0;
    for (final d in devices) {
      for (final u in d.units.values) {
        final ms = u.totalMs > 0 ? u.totalMs : u.downloadMs + u.inferMs;
        latencies.add((unitId: u.id, phone: d.key, latencyMs: ms));
      }
      if (d.units.isEmpty && !d.isLocal) idle.add(d.key);
      energyJ += summarize(d).energyModelJ;
    }
    return RunMetrics.compute(
      scheduler: schedulerId,
      images: imageSetting,
      startMs: experimentStartMs,
      endMs: lastUnitAtMs,
      latencies: latencies,
      phonesWithNoWork: idle,
      totalEnergyJ: energyJ,
    );
  }

  /// One row per earlier run, then the current run if it has finished units.
  String runsCsv() {
    final b = StringBuffer(_csvRow(['run', ...RunMetrics.csvHeader]))..write('\n');
    var i = 1;
    for (final r in runHistory) {
      b.write(_csvRow(['${i++}', ...r.csvCells()]));
      b.write('\n');
    }
    final current = runMetrics();
    if (current.units > 0) {
      b.write(_csvRow(['current', ...current.csvCells()]));
      b.write('\n');
    }
    return b.toString();
  }

  // -- export ---------------------------------------------------------------

  String samplesCsv({String? deviceKey}) {
    final b = StringBuffer(_csvRow(MetricSample.csvHeader))..write('\n');
    for (final d in devices.where((d) => deviceKey == null || d.key == deviceKey)) {
      for (final s in d.samples) {
        b.write(_csvRow(s.csvCells(d.key, d.name)));
        b.write('\n');
      }
    }
    return b.toString();
  }

  String unitsCsv({String? deviceKey}) {
    final b = StringBuffer(_csvRow(UnitRecord.csvHeader))..write('\n');
    for (final d in devices.where((d) => deviceKey == null || d.key == deviceKey)) {
      final list = d.units.values.toList()..sort((a, b) => a.t.compareTo(b.t));
      for (final u in list) {
        b.write(_csvRow(u.csvCells()));
        b.write('\n');
      }
    }
    return b.toString();
  }

  String summaryCsv({String? deviceKey}) {
    final b = StringBuffer(_csvRow(DeviceSummary.csvHeader))..write('\n');
    for (final d in devices.where((d) => deviceKey == null || d.key == deviceKey)) {
      b.write(_csvRow(summarize(d).csvCells()));
      b.write('\n');
    }
    return b.toString();
  }

  Map<String, dynamic> toJson({String? deviceKey}) => {
        'exported_at': DateTime.now().toIso8601String(),
        'scheduler': schedulerId,
        'run': runMetrics().toJson(),
        'previous_runs': runHistory.map((r) => r.toJson()).toList(),
        'devices': [
          for (final d in devices.where((d) => deviceKey == null || d.key == deviceKey))
            {
              'key': d.key,
              'name': d.name,
              'summary': summarize(d).toJson(),
              'traffic': trafficOf(d),
              'samples': d.samples.map((s) => s.toWire()).toList(),
              'units': d.units.values.map((u) => u.toJson()).toList(),
            }
        ],
      };

  /// Writes summary / samples / units CSVs and a JSON dump into [dir].
  /// A user-typed file name made safe: no path separators or reserved characters,
  /// no extension, never empty. [fallback] is used when nothing usable remains.
  static String safeFileName(String? raw, {String fallback = 'experiment_metrics'}) {
    var s = (raw ?? '').trim();
    s = s.replaceAll(RegExp(r'\.(txt|csv|json)$', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').replaceAll(RegExp(r'\s+'), '_');
    s = s.replaceAll(RegExp(r'^[._]+'), '');
    if (s.length > 80) s = s.substring(0, 80);
    return s.isEmpty ? fallback : s;
  }

  String decisionsCsv() {
    final b = StringBuffer(_csvRow(DecisionRecord.csvHeader))..write('\n');
    for (final d in decisions) {
      b.write(_csvRow(d.csvCells()));
      b.write('\n');
    }
    return b.toString();
  }

  /// Writes `<name>_summary.csv`, `_samples.csv`, `_units.csv`, `_decisions.csv`, `_runs.csv` and `_full.json`.
  /// [baseName] is the file name the user chose; without it a timestamped name is used.
  Future<List<File>> exportTo(Directory dir, {String? deviceKey, String? baseName}) async {
    await dir.create(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final scope = deviceKey == null ? 'all' : deviceKey.replaceAll('.', '-');
    final prefix = baseName != null && baseName.trim().isNotEmpty
        ? safeFileName(baseName)
        : 'metrics_${scope}_$stamp';
    final files = <File>[];
    Future<void> write(String suffix, String content) async {
      final f = File('${dir.path}/${prefix}_$suffix');
      await f.writeAsString(content);
      files.add(f);
    }

    await write('summary.csv', summaryCsv(deviceKey: deviceKey));
    await write('samples.csv', samplesCsv(deviceKey: deviceKey));
    await write('units.csv', unitsCsv(deviceKey: deviceKey));
    await write('decisions.csv', decisionsCsv());
    await write('runs.csv', runsCsv());
    await write('full.json', const JsonEncoder.withIndent('  ').convert(toJson(deviceKey: deviceKey)));
    return files;
  }
}
