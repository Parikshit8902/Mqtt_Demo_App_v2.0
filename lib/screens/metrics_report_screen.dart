import 'dart:io';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import '../services/assignments_client.dart';
import '../services/distribution_singleton.dart';
import '../services/metrics/metrics_store.dart';
import '../services/metrics/traffic_counter.dart';
import '../services/mqtt_service.dart';
import '../services/schedulers/scheduler_registry.dart';

/// Per-phone metrics: summary, charts, traffic/overhead breakdown, CSV/JSON export.
/// On the broker phone it lists every phone; on a worker it shows that phone only.
class MetricsReportScreen extends StatefulWidget {
  final MqttService? mqttService;
  const MetricsReportScreen({super.key, this.mqttService});

  @override
  State<MetricsReportScreen> createState() => _MetricsReportScreenState();
}

enum _Chart { cpu, memory, network, power }

class _MetricsReportScreenState extends State<MetricsReportScreen> {
  final MetricsStore _store = MetricsStore.instance;
  String? _selectedKey;
  _Chart _chart = _Chart.cpu;
  bool _busy = false;

  bool get _isHost => widget.mqttService?.currentMode == AppMode.broker;

  DeviceMetrics _current() {
    final devices = _store.devices;
    return devices.firstWhere((d) => d.key == _selectedKey, orElse: () => devices.first);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black),
        title: const Text('Metrics', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w600, fontSize: 18)),
        actions: [
          IconButton(
            tooltip: 'Export CSV + JSON',
            icon: const Icon(Icons.ios_share),
            onPressed: _busy ? null : _export,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _store,
        builder: (context, _) {
          final device = _current();
          final summary = _store.summarize(device);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _deviceChips(device),
              if (_isHost) ...[const SizedBox(height: 12), _schedulerCard()],
              const SizedBox(height: 12),
              _chartChips(),
              const SizedBox(height: 8),
              _chartCard(device),
              const SizedBox(height: 16),
              _summaryGrid(summary),
              const SizedBox(height: 16),
              _trafficCard(device, summary),
              const SizedBox(height: 16),
              _actions(),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  // -- device + scheduler ---------------------------------------------------

  Widget _deviceChips(DeviceMetrics current) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final d in _store.devices)
          ChoiceChip(
            label: Text(d.label),
            selected: d.key == current.key,
            onSelected: (_) => setState(() => _selectedKey = d.key),
          ),
      ],
    );
  }

  Widget _schedulerCard() {
    final active = distributionManager.schedulerId;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: _boxDecoration(),
      child: Row(
        children: [
          const Icon(Icons.alt_route, size: 18),
          const SizedBox(width: 8),
          const Text('Scheduler', style: TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          DropdownButton<String>(
            value: active,
            underline: const SizedBox.shrink(),
            items: [
              for (final id in SchedulerRegistry.ids)
                DropdownMenuItem(value: id, child: Text(SchedulerRegistry.labelFor(id))),
            ],
            onChanged: (id) {
              if (id == null) return;
              setState(() {
                distributionManager.setScheduler(id);
                _store.schedulerId = id;
              });
            },
          ),
        ],
      ),
    );
  }

  // -- chart ----------------------------------------------------------------

  Widget _chartChips() {
    const labels = {
      _Chart.cpu: 'CPU %',
      _Chart.memory: 'Memory MB',
      _Chart.network: 'Network KB/s',
      _Chart.power: 'Power mW',
    };
    return Wrap(
      spacing: 8,
      children: [
        for (final e in labels.entries)
          ChoiceChip(label: Text(e.value), selected: _chart == e.key, onSelected: (_) => setState(() => _chart = e.key)),
      ],
    );
  }

  Widget _chartCard(DeviceMetrics d) {
    final all = d.samples;
    final samples = all.length > 150 ? all.sublist(all.length - 150) : all;
    final List<_Series> series;
    switch (_chart) {
      case _Chart.cpu:
        series = [
          _Series('CPU (100 = 1 core)', Colors.black, [for (final s in samples) s.cpuPct]),
          _Series('Share of SoC', Colors.grey, [for (final s in samples) s.cpuNormPct]),
        ];
        break;
      case _Chart.memory:
        series = [_Series('Memory', Colors.black, [for (final s in samples) s.memMb])];
        break;
      case _Chart.network:
        series = [
          _Series('Down', Colors.black, [for (final s in samples) s.rxKBps]),
          _Series('Up', Colors.grey, [for (final s in samples) s.txKBps]),
        ];
        break;
      case _Chart.power:
        series = [
          _Series('Modelled (app)', Colors.black, [for (final s in samples) s.modelMw]),
          if (samples.any((s) => s.measuredMw != null))
            _Series('Measured (whole device)', Colors.grey, [for (final s in samples) s.measuredMw ?? double.nan]),
        ];
        break;
    }
    final points = series.expand((s) => s.values).where((v) => !v.isNaN);
    final maxY = points.isEmpty ? 1.0 : points.reduce((a, b) => a > b ? a : b);
    final yMax = (maxY * 1.2).clamp(1.0, double.infinity);

    return Container(
      decoration: _boxDecoration(),
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 2.0,
            child: samples.length < 2
                ? const Center(child: Text('Collecting samples...', style: TextStyle(color: Colors.grey)))
                : LineChart(
                    LineChartData(
                      minX: 0,
                      maxX: (samples.length - 1).toDouble(),
                      minY: 0,
                      maxY: yMax.toDouble(),
                      gridData: FlGridData(show: true, drawVerticalLine: false, horizontalInterval: yMax / 4),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 44,
                            interval: yMax / 4,
                            getTitlesWidget: (v, meta) => v == 0
                                ? const SizedBox.shrink()
                                : Text(_compact(v), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                          ),
                        ),
                      ),
                      lineBarsData: [
                        for (final s in series)
                          LineChartBarData(
                            spots: [
                              for (var i = 0; i < s.values.length; i++)
                                if (!s.values[i].isNaN) FlSpot(i.toDouble(), s.values[i]),
                            ],
                            color: s.color,
                            barWidth: 2,
                            isCurved: false,
                            dotData: const FlDotData(show: false),
                          ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            children: [
              for (final s in series)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 10, height: 10, color: s.color),
                  const SizedBox(width: 4),
                  Text(s.name, style: const TextStyle(fontSize: 11)),
                ]),
            ],
          ),
        ],
      ),
    );
  }

  // -- summary --------------------------------------------------------------

  Widget _summaryGrid(DeviceSummary s) {
    final tiles = <_Tile>[
      _Tile('Duration', _duration(s.durationS)),
      _Tile('CPU avg / peak', '${s.avgCpuPct.toStringAsFixed(0)}% / ${s.peakCpuPct.toStringAsFixed(0)}%'),
      _Tile('Memory avg / peak', '${s.avgMemMb.toStringAsFixed(0)} / ${s.peakMemMb.toStringAsFixed(0)} MB'),
      _Tile('Network (on wire)', _bytes(s.onWireBytes)),
      _Tile('Energy (modelled)', '${s.energyModelJ.toStringAsFixed(1)} J'),
      _Tile('Avg power (modelled)', '${s.avgPowerModelMw.toStringAsFixed(0)} mW'),
      _Tile('Energy (measured)', s.avgMeasuredMw == null ? 'n/a' : '${s.energyMeasuredJ.toStringAsFixed(1)} J'),
      _Tile('Battery', s.batteryStart < 0 ? 'n/a' : '${s.batteryStart}% → ${s.batteryEnd}%'),
      _Tile('Units done', '${s.unitsDone}'),
      _Tile('Avg download', '${s.avgDownloadMs.toStringAsFixed(0)} ms'),
      _Tile('Avg inference', '${s.avgInferMs.toStringAsFixed(0)} ms'),
      _Tile('Avg link speed', '${s.avgDownloadKBps.toStringAsFixed(0)} kB/s'),
    ];
    return LayoutBuilder(builder: (context, c) {
      final w = (c.maxWidth - 8) / 2;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final t in tiles)
            Container(
              width: w,
              padding: const EdgeInsets.all(12),
              decoration: _boxDecoration(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.label, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  Text(t.value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
        ],
      );
    });
  }

  Widget _trafficCard(DeviceMetrics d, DeviceSummary s) {
    final traffic = _store.trafficOf(d);
    final tx = (traffic?['tx'] as Map?) ?? const {};
    final rx = (traffic?['rx'] as Map?) ?? const {};
    const names = {
      TrafficChannel.httpData: 'Images / models (HTTP)',
      TrafficChannel.httpControl: 'Control: assignments, results (HTTP)',
      TrafficChannel.mqtt: 'MQTT messages',
      TrafficChannel.mqttMetrics: 'Metrics reporting (MQTT)',
    };
    Widget row(String a, String b, String c, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(flex: 5, child: Text(a, style: TextStyle(fontSize: 12, fontWeight: bold ? FontWeight.w600 : null))),
              Expanded(flex: 2, child: Text(b, textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: bold ? FontWeight.w600 : null))),
              Expanded(flex: 2, child: Text(c, textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: bold ? FontWeight.w600 : null))),
            ],
          ),
        );

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _boxDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Network traffic & overhead', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (traffic == null)
            Text(
              d.isLocal ? 'No traffic recorded yet.' : 'Per-channel breakdown arrives when this phone uploads its report (after it finishes its units).',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            )
          else ...[
            row('Channel', 'Sent', 'Received', bold: true),
            for (final ch in TrafficChannel.all)
              row(names[ch] ?? ch, _bytes((tx[ch] as num?)?.toInt() ?? 0), _bytes((rx[ch] as num?)?.toInt() ?? 0)),
            row('MQTT framing (est.)', _bytes((traffic['mqtt_framing_tx'] as num?)?.toInt() ?? 0),
                _bytes((traffic['mqtt_framing_rx'] as num?)?.toInt() ?? 0)),
          ],
          const Divider(height: 20),
          row('Payload (app data)', _bytes(s.payloadBytes), ''),
          row('On the wire (OS counters)', _bytes(s.onWireBytes), ''),
          row('Overhead / unattributed', _bytes(s.overheadBytes), '${s.overheadPct.toStringAsFixed(1)}%', bold: true),
          const SizedBox(height: 6),
          Text(
            'Overhead = TCP/IP, Wi-Fi and HTTP headers, retransmits, discovery'
            '${d.isLocal && _isHost ? ', plus MQTT traffic the broker relays for other phones' : ''}. '
            '${Platform.isIOS ? 'iOS counts the whole Wi-Fi interface, not just this app. ' : ''}',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  // -- actions --------------------------------------------------------------

  Widget _actions() {
    final canUpload = widget.mqttService?.currentMode == AppMode.client && (widget.mqttService?.brokerIp.isNotEmpty ?? false);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          onPressed: _busy ? null : _export,
          icon: const Icon(Icons.download),
          label: Text(_isHost ? 'Export all phones' : 'Export this phone'),
        ),
        if (canUpload)
          OutlinedButton.icon(
            onPressed: _busy ? null : _upload,
            icon: const Icon(Icons.upload),
            label: const Text('Send report to host'),
          ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _confirmClear,
          icon: const Icon(Icons.delete_outline),
          label: const Text('Clear'),
        ),
      ],
    );
  }

  Future<Directory> _exportDir() async {
    Directory? base;
    try {
      if (Platform.isAndroid) base = await getExternalStorageDirectory();
    } catch (_) {}
    base ??= await getApplicationDocumentsDirectory();
    return Directory('${base.path}/metrics_exports');
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final dir = await _exportDir();
      final files = await _store.exportTo(dir, deviceKey: _isHost ? null : _store.local.key);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Saved ${files.length} files to ${dir.path}'),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(label: 'Open summary', onPressed: () => OpenFile.open(files.first.path)),
      ));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _upload() async {
    final svc = widget.mqttService;
    if (svc == null) return;
    setState(() => _busy = true);
    final client = AssignmentsClient(svc.messageLogger, serverBase: 'http://${svc.brokerIp}:8080');
    final ok = await client.postMetricsReport(_store.localReport());
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Report sent to host' : 'Could not reach the host')));
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Clear recorded metrics?'),
        content: const Text('Removes all samples, unit records and traffic counters on this phone. Use it to start a clean experiment run.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) _store.clear();
  }

  // -- helpers --------------------------------------------------------------

  BoxDecoration _boxDecoration() => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      );

  static String _bytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _duration(double s) {
    final t = s.round();
    return t >= 3600 ? '${t ~/ 3600}h ${(t % 3600) ~/ 60}m' : t >= 60 ? '${t ~/ 60}m ${t % 60}s' : '${t}s';
  }

  static String _compact(double v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : v.toStringAsFixed(v < 10 ? 1 : 0);
}

class _Series {
  final String name;
  final Color color;
  final List<double> values;
  _Series(this.name, this.color, this.values);
}

class _Tile {
  final String label;
  final String value;
  _Tile(this.label, this.value);
}
