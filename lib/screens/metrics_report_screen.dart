import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import '../services/assignments_client.dart';
import '../services/distribution_singleton.dart';
import '../services/metrics/metrics_store.dart';
import '../services/metrics/traffic_counter.dart';
import '../services/mqtt_service.dart';
import '../services/schedulers/scheduler_registry.dart';
import '../widgets/file_name_dialog.dart';

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
  bool _overlay = false; // host: one line per phone instead of one phone
  bool _busy = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Re-draw every 2 s so "updated N s ago" and the live cards keep moving even
    // when no new sample has arrived.
    _tick = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

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
              if (_isHost) ...[
                const SizedBox(height: 12),
                _schedulerCard(),
                const SizedBox(height: 8),
                _liveSchedulerCard(),
              ],
              const SizedBox(height: 12),
              _chartChips(),
              const SizedBox(height: 8),
              _chartCard(device),
              const SizedBox(height: 12),
              _freshnessCard(device),
              if (_isHost) ...[const SizedBox(height: 12), _workCard()],
              const SizedBox(height: 16),
              _summaryGrid(summary),
              const SizedBox(height: 16),
              _trafficCard(device, summary),
              if (_isHost) ...[const SizedBox(height: 16), _decisionsCard()],
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

  static const int _maxPoints = 240;
  static const List<Color> _palette = [
    Colors.black,
    Color(0xFF1E88E5),
    Color(0xFFF57C00),
    Color(0xFF43A047),
    Color(0xFF8E24AA),
    Color(0xFFE53935),
  ];

  Widget _chartChips() {
    const labels = {
      _Chart.cpu: 'CPU %',
      _Chart.memory: 'RAM MB',
      _Chart.network: 'Network KB/s',
      _Chart.power: 'Power mW',
    };
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final e in labels.entries)
          ChoiceChip(label: Text(e.value), selected: _chart == e.key, onSelected: (_) => setState(() => _chart = e.key)),
        if (_isHost && _store.devices.length > 1)
          FilterChip(
            avatar: const Icon(Icons.layers, size: 16),
            label: const Text('All phones'),
            selected: _overlay,
            onSelected: (v) => setState(() => _overlay = v),
          ),
      ],
    );
  }

  /// Host-clock time of the earliest sample on any phone: the shared zero of the time axis.
  int _globalStartMs() {
    var start = 1 << 62;
    for (final d in _store.devices) {
      if (d.samples.isNotEmpty) start = math.min(start, d.hostTime(d.samples.first.t));
    }
    return start == 1 << 62 ? 0 : start;
  }

  /// The whole recording as at most [_maxPoints] points (neighbouring samples are
  /// averaged), x = seconds since [startMs] on the host's clock.
  List<FlSpot> _spots(DeviceMetrics d, double Function(MetricSample) f, int startMs) {
    final s = d.samples;
    if (s.isEmpty) return const [];
    final group = math.max(1, (s.length / _maxPoints).ceil());
    final out = <FlSpot>[];
    for (var i = 0; i < s.length; i += group) {
      final end = math.min(i + group, s.length);
      var sumY = 0.0;
      var n = 0;
      var sumX = 0.0;
      for (var k = i; k < end; k++) {
        final y = f(s[k]);
        if (!y.isNaN) {
          sumY += y;
          n++;
        }
        sumX += (d.hostTime(s[k].t) - startMs) / 1000.0;
      }
      if (n > 0) out.add(FlSpot(sumX / (end - i), sumY / n));
    }
    return out;
  }

  List<_Series> _seriesFor(DeviceMetrics d, int startMs) {
    switch (_chart) {
      case _Chart.cpu:
        return [
          _Series('CPU (100 = 1 core)', _palette[0], _spots(d, (s) => s.cpuPct, startMs)),
          _Series('Share of SoC', Colors.grey, _spots(d, (s) => s.cpuNormPct, startMs)),
        ];
      case _Chart.memory:
        return [_Series('RAM in use', _palette[0], _spots(d, (s) => s.memMb, startMs))];
      case _Chart.network:
        return [
          _Series('Down', _palette[0], _spots(d, (s) => s.rxKBps, startMs)),
          _Series('Up', Colors.grey, _spots(d, (s) => s.txKBps, startMs)),
        ];
      case _Chart.power:
        return [
          _Series('Modelled (app)', _palette[0], _spots(d, (s) => s.modelMw, startMs)),
          if (d.samples.any((s) => s.measuredMw != null))
            _Series('Measured (whole device)', Colors.grey, _spots(d, (s) => s.measuredMw ?? double.nan, startMs)),
        ];
    }
  }

  /// One line per phone for the selected metric.
  List<_Series> _overlaySeries(int startMs) {
    double Function(MetricSample) f;
    switch (_chart) {
      case _Chart.cpu:
        f = (s) => s.cpuPct;
        break;
      case _Chart.memory:
        f = (s) => s.memMb;
        break;
      case _Chart.network:
        f = (s) => s.rxKBps + s.txKBps;
        break;
      case _Chart.power:
        f = (s) => s.modelMw;
        break;
    }
    final out = <_Series>[];
    var i = 0;
    for (final d in _store.devices) {
      if (d.samples.isEmpty) continue;
      out.add(_Series(d.isLocal ? '${d.name} (master)' : d.name, _palette[i % _palette.length], _spots(d, f, startMs)));
      i++;
    }
    return out;
  }

  Widget _chartCard(DeviceMetrics d) {
    final startMs = _globalStartMs();
    final overlay = _isHost && _overlay && _store.devices.length > 1;
    final series = overlay ? _overlaySeries(startMs) : _seriesFor(d, startMs);
    final spots = series.expand((s) => s.spots).toList();
    final maxY = spots.isEmpty ? 1.0 : spots.map((p) => p.y).reduce(math.max);
    final maxX = spots.isEmpty ? 1.0 : math.max(1.0, spots.map((p) => p.x).reduce(math.max));
    final yMax = math.max(1.0, maxY * 1.2);

    final last = d.samples.isEmpty ? null : d.samples.last;
    final ageS = last == null ? null : (DateTime.now().millisecondsSinceEpoch - d.hostTime(last.t)) / 1000.0;

    return Container(
      decoration: _boxDecoration(),
      padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 8),
            child: Row(
              children: [
                Icon(Icons.circle, size: 9, color: (ageS != null && ageS < 15) ? Colors.green : Colors.grey),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    overlay
                        ? 'Live, whole experiment, every phone'
                        : ageS == null
                            ? 'Waiting for samples'
                            : 'Live, whole experiment, last sample ${ageS.toStringAsFixed(0)} s ago',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                  ),
                ),
              ],
            ),
          ),
          AspectRatio(
            aspectRatio: 1.8,
            child: spots.length < 2
                ? const Center(child: Text('Collecting samples...', style: TextStyle(color: Colors.grey)))
                : LineChart(
                    LineChartData(
                      minX: 0,
                      maxX: maxX,
                      minY: 0,
                      maxY: yMax,
                      gridData: FlGridData(show: true, drawVerticalLine: false, horizontalInterval: yMax / 4),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 22,
                            interval: maxX / 4,
                            getTitlesWidget: (v, meta) => Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(_clock(v), style: const TextStyle(fontSize: 10, color: Colors.grey)),
                            ),
                          ),
                        ),
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
                            spots: s.spots,
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
            runSpacing: 4,
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

  // -- how often things update ------------------------------------------------

  Widget _freshnessCard(DeviceMetrics d) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final interval = d.sampleIntervalS;
    final lastAge = d.samples.isEmpty ? null : (now - d.hostTime(d.samples.last.t)) / 1000.0;
    final polls = _store.pollsLastMinute(d);
    final pollAge = _store.lastPollAgeS(d);
    final isMasterRow = d.isLocal && _isHost;

    String row2(String a, String b) => '$a|$b';
    final rows = <String>[
      row2(
        'Metrics sample interval',
        interval > 0
            ? '${interval.toStringAsFixed(1)} s ${d.isLocal ? '(recorded on this phone)' : '(as received by the master)'}'
            : 'not enough samples yet',
      ),
      row2('Last metrics update', lastAge == null ? 'none yet' : '${lastAge.toStringAsFixed(0)} s ago'),
      row2(
        'Work requests (polls)',
        isMasterRow
            ? 'n/a (the master serves requests)'
            : '$polls in the last minute${pollAge == null ? '' : ', last ${pollAge.toStringAsFixed(0)} s ago'}',
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _boxDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.update, size: 16),
            const SizedBox(width: 6),
            Text('Update frequency: ${d.label}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          ]),
          const SizedBox(height: 8),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 4, child: Text(r.split('|').first, style: TextStyle(fontSize: 12, color: Colors.grey.shade700))),
                  Expanded(flex: 6, child: Text(r.split('|').last, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Text(
            'Each phone records a sample every 2 s and the master receives it about every 5 s. '
            'An idle worker asks the master for work about every 2 s.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  // -- who is doing the work (host) -----------------------------------------

  Widget _workCard() {
    final workers = _store.devices.where((d) => !d.isLocal).toList();
    final total = workers.fold<int>(0, (a, d) => a + d.units.length);
    final most = workers.fold<int>(1, (a, d) => math.max(a, d.units.length));
    final now = DateTime.now().millisecondsSinceEpoch;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _boxDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.groups_2_outlined, size: 16),
            const SizedBox(width: 6),
            Text('Images processed per phone ($total total)', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          ]),
          const SizedBox(height: 8),
          if (workers.isEmpty)
            Text('No workers have reported yet.', style: TextStyle(fontSize: 12, color: Colors.grey.shade600))
          else
            for (final d in workers)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(child: Text('${d.name}  ${d.key}', style: const TextStyle(fontSize: 12))),
                      Text(
                        '${d.units.length}${total > 0 ? '  (${(d.units.length * 100 / total).toStringAsFixed(0)}%)' : ''}',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ]),
                    const SizedBox(height: 3),
                    LinearProgressIndicator(
                      value: d.units.length / most,
                      minHeight: 5,
                      backgroundColor: Colors.grey.shade200,
                      color: Colors.black,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'polls ${_store.pollsLastMinute(d, nowMs: now)}/min · '
                      'metrics ${d.samples.isEmpty ? 'none' : '${((now - d.hostTime(d.samples.last.t)) / 1000).toStringAsFixed(0)} s ago'}',
                      style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  /// Why the scheduler sees each phone the way it does, right now.
  Widget _liveSchedulerCard() {
    final views = distributionManager.clientViews();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _boxDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.psychology_outlined, size: 16),
            const SizedBox(width: 6),
            const Text('What the scheduler sees now', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          ]),
          const SizedBox(height: 8),
          if (views.isEmpty)
            Text('No active workers yet.', style: TextStyle(fontSize: 12, color: Colors.grey.shade600))
          else
            for (final e in views.entries)
              Opacity(
                opacity: (e.value['eligible'] == false) ? 0.5 : 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(child: Text(deviceNameFromClientId(e.key), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                        if (e.value['gated_by'] != null)
                          Text('no new work: ${e.value['gated_by']}', style: const TextStyle(fontSize: 11, color: Colors.red)),
                      ]),
                      const SizedBox(height: 3),
                      LinearProgressIndicator(
                        value: ((e.value['health'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0),
                        minHeight: 5,
                        backgroundColor: Colors.grey.shade200,
                        color: Colors.black,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'health ${_n(e.value['health'])} · queue ${e.value['pending']} · capacity ${_n(e.value['capacity'])} · '
                        '${_n(e.value['bw_kBps'], 0)} kB/s · ${_n(e.value['proc_ms'], 0)} ms/img'
                        '${e.value['battery_pct'] != null ? ' · battery ${e.value['battery_pct']}%' : ''}'
                        '${e.value['thermal'] != null ? ' · thermal ${e.value['thermal']}' : ''}',
                        style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }

  /// The most recent assignment decisions, newest first.
  Widget _decisionsCard() {
    final recent = _store.decisions.reversed.take(12).toList();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _boxDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.alt_route, size: 16),
            const SizedBox(width: 6),
            Text('Scheduling decisions (${_store.decisions.length} recorded)', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          ]),
          const SizedBox(height: 8),
          if (recent.isEmpty)
            Text('No work has been assigned yet.', style: TextStyle(fontSize: 12, color: Colors.grey.shade600))
          else
            for (final d in recent)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_hms(d.t)}  ${d.deviceName} ← image${d.units.length == 1 ? '' : 's'} ${d.units.join(', ')}  [${d.scheduler}]',
                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                    ),
                    if (d.healthByDevice.isNotEmpty)
                      Text(
                        'health: ${d.healthByDevice.entries.map((e) => '${e.key} ${e.value.toStringAsFixed(2)}').join(' · ')}',
                        style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                      ),
                  ],
                ),
              ),
          const SizedBox(height: 4),
          Text('Every decision is included in the export (decisions.csv).', style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
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
        if (_isHost)
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _downloadReport,
            icon: const Icon(Icons.description_outlined),
            label: const Text('Experiment report (.txt)'),
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
    final name = await askFileName(context, title: 'Export metrics files');
    if (name == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final dir = await _exportDir();
      final files = await _store.exportTo(dir, deviceKey: _isHost ? null : _store.local.key, baseName: name);
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

  /// The host's plain-text experiment report (model, dataset, algorithm, clients,
  /// images per client, compute/network metrics, packets and overhead).
  Future<void> _downloadReport() async {
    final svc = widget.mqttService;
    if (svc == null) return;
    final name = await askFileName(context, title: 'Save experiment report');
    if (name == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final url = Uri.parse('${svc.serverUrl}/admin/metrics').replace(queryParameters: {'name': name});
      final response = await http.get(url);
      if (response.statusCode != 200) throw 'server returned ${response.statusCode}';
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'Save experiment report',
        fileName: '$name.txt',
        type: FileType.custom,
        allowedExtensions: ['txt'],
        bytes: response.bodyBytes,
      );
      if (mounted && saved != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Report saved to $saved')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not get the report: $e')));
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

  /// Seconds as m:ss for the time axis.
  static String _clock(double seconds) {
    final t = seconds.round();
    return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
  }

  static String _hms(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  static String _n(Object? v, [int digits = 2]) => v is num ? v.toStringAsFixed(digits) : '-';

  static String _compact(double v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : v.toStringAsFixed(v < 10 ? 1 : 0);
}

class _Series {
  final String name;
  final Color color;
  final List<FlSpot> spots;
  _Series(this.name, this.color, this.spots);
}

class _Tile {
  final String label;
  final String value;
  _Tile(this.label, this.value);
}
