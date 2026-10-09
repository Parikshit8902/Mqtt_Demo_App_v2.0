import 'fault_injector.dart';
import 'metrics/detection_accuracy.dart';
import 'metrics/metrics_store.dart';
import 'metrics/run_metrics.dart';
import 'metrics/traffic_counter.dart';

/// One phone's row in the experiment report.
class ReportDevice {
  final String name;
  final String ip;
  final bool isMaster;
  final int imagesProcessed;
  final DeviceSummary summary;

  /// `TrafficCounter.toJson()` for this phone, or null if it has not uploaded one yet.
  final Map<String, dynamic>? traffic;

  const ReportDevice({
    required this.name,
    required this.ip,
    required this.isMaster,
    required this.imagesProcessed,
    required this.summary,
    required this.traffic,
  });
}

/// Builds the plain-text experiment report. Pure (no I/O), so it is unit-tested.
///
/// Sections, in order: experiment (file name, date/time), model, dataset,
/// scheduling algorithm, number of clients, client table (name, IP, images
/// processed), compute and network metrics, per-device message/packet
/// counts split into data and control for the network-overhead calculation,
/// and the run's comparison metrics next to earlier runs.
String buildExperimentReport({
  required String fileName,
  required DateTime generatedAt,
  DateTime? experimentStart,
  required List<String> models,
  String? datasetName,
  int? datasetBytes,
  int datasetUnits = 0,
  String imageSetting = 'original',
  required String schedulerName,
  int scheduleCalls = 0,
  double avgScheduleMs = 0,
  required List<ReportDevice> devices,
  RunMetrics? run,
  List<RunMetrics> previousRuns = const [],
  AccuracyResult? accuracy,
  List<FaultEvent> faults = const [],
}) {
  final b = StringBuffer();
  final clients = devices.where((d) => !d.isMaster).toList();
  final master = devices.where((d) => d.isMaster).toList();

  void title(String t) {
    b.writeln();
    b.writeln(t);
    b.writeln('-' * t.length);
  }

  b.writeln('DISTRIBUTED INFERENCE EXPERIMENT REPORT');
  b.writeln('=======================================');

  title('1. EXPERIMENT');
  b.writeln('File name         : $fileName.txt');
  b.writeln('Report generated  : ${_stamp(generatedAt)}');
  if (experimentStart == null) {
    b.writeln('Experiment start  : not started (no work has been assigned yet)');
  } else {
    b.writeln('Experiment start  : ${_stamp(experimentStart)}');
    b.writeln('Experiment length : ${_duration(generatedAt.difference(experimentStart).inSeconds)} (until report generation)');
  }

  title('2. MODEL');
  b.writeln(models.isEmpty ? 'Not reported by any client yet.' : models.join(', '));

  title('3. DATASET');
  if (datasetName == null) {
    b.writeln('No dataset shared.');
  } else {
    b.writeln('Name  : $datasetName');
    b.writeln('Size  : ${datasetBytes == null ? 'unknown' : '${_bytes(datasetBytes)} ($datasetBytes bytes)'}');
    b.writeln('Units : $datasetUnits images / work units');
    b.writeln('Served: ${imageSetting == 'original' ? 'original images' : imageSetting}');
  }

  title('4. SCHEDULING ALGORITHM');
  b.writeln(schedulerName);
  if (scheduleCalls > 0) {
    b.writeln('Scheduling decisions: $scheduleCalls, average ${avgScheduleMs.toStringAsFixed(2)} ms each');
  }

  title('5. CLIENTS CONNECTED');
  b.writeln('${clients.length}');

  title('6. CLIENT TABLE');
  final nameW = _width(clients.map((c) => c.name), 'Name');
  final ipW = _width(clients.map((c) => c.ip), 'IP address');
  b.writeln('${'Name'.padRight(nameW)}  ${'IP address'.padRight(ipW)}  ${'Images processed'.padLeft(16)}  ${'Share'.padLeft(6)}');
  final totalImages = clients.fold<int>(0, (a, c) => a + c.imagesProcessed);
  for (final c in clients) {
    final share = totalImages > 0 ? '${(c.imagesProcessed * 100 / totalImages).toStringAsFixed(1)}%' : '-';
    b.writeln('${c.name.padRight(nameW)}  ${c.ip.padRight(ipW)}  ${'${c.imagesProcessed}'.padLeft(16)}  ${share.padLeft(6)}');
  }
  b.writeln('${'Total'.padRight(nameW)}  ${''.padRight(ipW)}  ${'$totalImages'.padLeft(16)}');

  title('7. COMPUTE AND NETWORK METRICS (per device)');
  b.writeln('CPU is the app\'s own process time: 100% = one full core; "of SoC" divides by the core count.');
  for (final d in [...clients, ...master]) {
    final s = d.summary;
    b.writeln();
    b.writeln('${d.name} (${d.ip})${d.isMaster ? '  [master / host]' : ''}');
    if (s.durationS <= 0) {
      b.writeln('  No samples recorded for this device yet.');
      continue;
    }
    b.writeln('  Recording length      : ${_duration(s.durationS.round())}');
    b.writeln('  CPU avg / peak        : ${s.avgCpuPct.toStringAsFixed(1)}% / ${s.peakCpuPct.toStringAsFixed(1)}% '
        '(of SoC ${s.avgCpuNormPct.toStringAsFixed(1)}% / ${s.peakCpuNormPct.toStringAsFixed(1)}%)');
    b.writeln('  Memory avg / peak     : ${s.avgMemMb.toStringAsFixed(0)} MB / ${s.peakMemMb.toStringAsFixed(0)} MB');
    b.writeln('  Battery               : ${s.batteryStart < 0 ? 'n/a' : '${s.batteryStart}% -> ${s.batteryEnd}%'}');
    b.writeln('  Energy (modelled)     : ${s.energyModelJ.toStringAsFixed(1)} J, avg ${s.avgPowerModelMw.toStringAsFixed(0)} mW');
    if (s.avgMeasuredMw != null) {
      b.writeln('  Energy (measured)     : ${s.energyMeasuredJ.toStringAsFixed(1)} J, avg ${s.avgMeasuredMw!.toStringAsFixed(0)} mW (whole device)');
    }
    if (!d.isMaster) {
      b.writeln('  Per image             : download ${s.avgDownloadMs.toStringAsFixed(0)} ms, '
          'inference ${s.avgInferMs.toStringAsFixed(0)} ms, link ${s.avgDownloadKBps.toStringAsFixed(0)} kB/s');
    }
    b.writeln('  Network on the wire   : received ${_bytes(s.onWireRxBytes)}, sent ${_bytes(s.onWireTxBytes)}');
  }

  title('8. NETWORK PACKETS AND OVERHEAD (per device)');
  b.writeln('On-wire packets : counted by the operating system for this app (all traffic).');
  b.writeln('Data messages   : image / model transfers (HTTP file requests and responses).');
  b.writeln('Control messages: assignments, results, warm-up, metrics reports (HTTP) and all MQTT messages.');
  b.writeln('A message is one request, response or MQTT publish; one message may need many packets.');
  b.writeln('Overhead        : (on-wire bytes - application payload bytes) / on-wire bytes.');
  b.writeln();
  final cols = <String>[
    'Device',
    'Pkts sent',
    'Pkts rcvd',
    'Data msgs S/R',
    'Ctrl msgs S/R',
    'Data bytes S/R',
    'Ctrl bytes S/R',
    'On-wire bytes',
    'Overhead',
  ];
  final rows = <List<String>>[];
  for (final d in [...clients, ...master]) {
    final s = d.summary;
    final t = d.traffic;
    String pair(num? x, num? y, String Function(num) f) => (x == null || y == null) ? 'n/a' : '${f(x)} / ${f(y)}';
    final dataTx = _sum(t, 'tx_msgs', const [TrafficChannel.httpData]);
    final dataRx = _sum(t, 'rx_msgs', const [TrafficChannel.httpData]);
    const control = [TrafficChannel.httpControl, TrafficChannel.mqtt, TrafficChannel.mqttMetrics];
    final ctrlTx = _sum(t, 'tx_msgs', control);
    final ctrlRx = _sum(t, 'rx_msgs', control);
    final dataBytesTx = _sum(t, 'tx', const [TrafficChannel.httpData]);
    final dataBytesRx = _sum(t, 'rx', const [TrafficChannel.httpData]);
    final ctrlBytesTx = _sum(t, 'tx', control);
    final ctrlBytesRx = _sum(t, 'rx', control);
    final hasPackets = s.rxPackets > 0 || s.txPackets > 0;
    rows.add([
      d.isMaster ? '${d.name} (master)' : d.name,
      hasPackets ? '${s.txPackets}' : 'n/a',
      hasPackets ? '${s.rxPackets}' : 'n/a',
      pair(dataTx, dataRx, (v) => '${v.toInt()}'),
      pair(ctrlTx, ctrlRx, (v) => '${v.toInt()}'),
      pair(dataBytesTx, dataBytesRx, (v) => _bytes(v.toInt())),
      pair(ctrlBytesTx, ctrlBytesRx, (v) => _bytes(v.toInt())),
      s.onWireBytes > 0 ? _bytes(s.onWireBytes) : 'n/a',
      s.onWireBytes > 0 && s.payloadBytes > 0 ? '${s.overheadPct.toStringAsFixed(1)}%' : 'n/a',
    ]);
  }
  final widths = [
    for (var i = 0; i < cols.length; i++) _width(rows.map((r) => r[i]), cols[i]),
  ];
  String line(List<String> cells) => [
        for (var i = 0; i < cells.length; i++) i == 0 ? cells[i].padRight(widths[i]) : cells[i].padLeft(widths[i]),
      ].join('  ');
  b.writeln(line(cols));
  for (final r in rows) {
    b.writeln(line(r));
  }
  b.writeln();
  b.writeln('n/a = not available: a worker uploads its message counts every 30 s while it works and when it finishes,');
  b.writeln('so a device that has not reported yet shows n/a. The master\'s on-wire figures include MQTT traffic it relays for the clients.');

  title('9. RUN METRICS (for comparing runs)');
  if (run == null || run.units == 0) {
    b.writeln('No finished images yet.');
  } else {
    b.writeln('Makespan          : ${run.makespanS.toStringAsFixed(1)} s (first assignment to last result, host clock)');
    b.writeln('Throughput        : ${run.throughput.toStringAsFixed(3)} images/s (${run.units} images, ${run.phones} phones)');
    b.writeln('Latency per image : mean ${run.meanLatencyMs.toStringAsFixed(0)} ms, '
        'p50 ${run.p50LatencyMs.toStringAsFixed(0)} ms, p95 ${run.p95LatencyMs.toStringAsFixed(0)} ms (download + inference)');
    b.writeln('Load balance      : Jain ${run.jainUnits.toStringAsFixed(3)} over images per phone, '
        '${run.jainBusy.toStringAsFixed(3)} over busy time (1 = even)');
    b.writeln('Energy per image  : ${run.energyPerImageJ == null ? 'n/a' : '${run.energyPerImageJ!.toStringAsFixed(2)} J'} '
        '(modelled, all phones incl. host, over each recording)');
  }
  if (previousRuns.isNotEmpty) {
    b.writeln();
    b.writeln('Earlier runs since the app started (oldest first):');
    final head = ['Run', 'Scheduler', 'Makespan s', 'Images/s', 'p50 ms', 'p95 ms', 'Jain', 'J/image'];
    final table = <List<String>>[
      for (var i = 0; i < previousRuns.length; i++)
        [
          '${i + 1}',
          previousRuns[i].scheduler,
          previousRuns[i].makespanS.toStringAsFixed(1),
          previousRuns[i].throughput.toStringAsFixed(3),
          previousRuns[i].p50LatencyMs.toStringAsFixed(0),
          previousRuns[i].p95LatencyMs.toStringAsFixed(0),
          previousRuns[i].jainUnits.toStringAsFixed(3),
          previousRuns[i].energyPerImageJ?.toStringAsFixed(2) ?? 'n/a',
        ],
    ];
    final w = [for (var i = 0; i < head.length; i++) _width(table.map((r) => r[i]), head[i])];
    String row(List<String> c) => [for (var i = 0; i < c.length; i++) i < 2 ? c[i].padRight(w[i]) : c[i].padLeft(w[i])].join('  ');
    b.writeln(row(head));
    for (final r in table) {
      b.writeln(row(r));
    }
  }

  title('10. ACCURACY (against labels in the dataset)');
  if (accuracy == null) {
    b.writeln('Not scored: the dataset ZIP has no YOLO label files for the finished images.');
  } else {
    b.writeln('Images scored : ${accuracy.images} (labelled boxes ${accuracy.labelledBoxes}, detections ${accuracy.detectedBoxes})');
    b.writeln('mAP@0.5       : ${accuracy.map50.toStringAsFixed(3)}');
    b.writeln('Precision     : ${accuracy.precision.toStringAsFixed(3)}');
    b.writeln('Recall        : ${accuracy.recall.toStringAsFixed(3)}');
    final classes = accuracy.apByClass.entries.toList()..sort((a, c) => a.key.compareTo(c.key));
    for (final e in classes) {
      b.writeln('  AP ${e.key.padRight(16)} ${e.value.toStringAsFixed(3)}');
    }
  }

  title('11. INJECTED FAULTS');
  if (faults.isEmpty) {
    b.writeln('None.');
  } else {
    for (final f in faults) {
      final at = DateTime.fromMillisecondsSinceEpoch(f.t);
      final offset = experimentStart == null ? '' : ' (+${(at.difference(experimentStart).inMilliseconds / 1000).toStringAsFixed(1)} s)';
      b.writeln('${_stamp(at)}$offset  ${f.deviceKey}: ${f.fault.describe()}');
    }
  }
  return b.toString();
}

num? _sum(Map<String, dynamic>? traffic, String key, List<String> channels) {
  if (traffic == null) return null;
  final m = traffic[key];
  if (m is! Map) return null;
  var total = 0;
  for (final c in channels) {
    final v = m[c];
    if (v is num) total += v.toInt();
  }
  return total;
}

int _width(Iterable<String> cells, String header) {
  var w = header.length;
  for (final c in cells) {
    if (c.length > w) w = c.length;
  }
  return w;
}

String _two(int n) => n.toString().padLeft(2, '0');

String _stamp(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

String _duration(int seconds) {
  if (seconds < 0) seconds = 0;
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (h > 0) return '${h}h ${_two(m)}m ${_two(s)}s';
  if (m > 0) return '${m}m ${_two(s)}s';
  return '${s}s';
}

String _bytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
