import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/experiment_report.dart';
import 'package:mqtt_demo/services/metrics/metrics_store.dart';
import 'package:mqtt_demo/services/metrics/traffic_counter.dart';

MetricSample sample(int t, {int rx = 0, int tx = 0, int rxPk = 0, int txPk = 0, int payload = 0}) => MetricSample(
      t: t, cpuPct: 40, cpuNormPct: 5, memMb: 300, rxKBps: 0, txKBps: 0, rxBytes: rx, txBytes: tx,
      payloadBytes: payload, rxPackets: rxPk, txPackets: txPk, battery: 80, measuredMw: null, modelMw: 1000,
    );

ReportDevice device(MetricsStore store, String name, String ip, {bool master = false, int images = 0, Map<String, dynamic>? traffic}) {
  final dm = DeviceMetrics(ip, name);
  dm.samples
    ..add(sample(0))
    ..add(sample(10000, rx: 90000, tx: 10000, rxPk: 120, txPk: 80, payload: 80000));
  return ReportDevice(name: name, ip: ip, isMaster: master, imagesProcessed: images, summary: store.summarize(dm), traffic: traffic);
}

void main() {
  final store = MetricsStore.instance;

  test('report contains every requested section in order, with the client table and packets', () {
    TrafficCounter.instance.reset();
    final traffic = {
      'tx': {'http_data': 100, 'http_control': 40, 'mqtt': 10, 'mqtt_metrics': 5},
      'rx': {'http_data': 90000, 'http_control': 400},
      'tx_msgs': {'http_data': 12, 'http_control': 7, 'mqtt': 2, 'mqtt_metrics': 3},
      'rx_msgs': {'http_data': 12, 'http_control': 7},
    };
    final text = buildExperimentReport(
      fileName: 'run1',
      generatedAt: DateTime(2026, 10, 8, 14, 5, 0),
      experimentStart: DateTime(2026, 10, 8, 14, 0, 0),
      models: ['yolo11n.tflite'],
      datasetName: 'coco_val.zip',
      datasetBytes: 5 * 1024 * 1024,
      datasetUnits: 100,
      schedulerName: 'Greedy (greedy)',
      scheduleCalls: 10,
      avgScheduleMs: 0.5,
      devices: [
        device(store, 'PixelA', '10.0.0.11', images: 60, traffic: traffic),
        device(store, 'PixelB', '10.0.0.12', images: 40),
        device(store, 'Host', '10.0.0.1', master: true),
      ],
    );

    final order = [
      '1. EXPERIMENT', '2. MODEL', '3. DATASET', '4. SCHEDULING ALGORITHM', '5. CLIENTS CONNECTED',
      '6. CLIENT TABLE', '7. COMPUTE AND NETWORK METRICS', '8. NETWORK PACKETS AND OVERHEAD',
    ];
    var at = -1;
    for (final h in order) {
      final i = text.indexOf(h);
      expect(i, greaterThan(at), reason: '$h should appear after the previous section');
      at = i;
    }
    expect(text, contains('File name         : run1.txt'));
    expect(text, contains('2026-10-08 14:05:00'));
    expect(text, contains('Experiment length : 5m 00s'));
    expect(text, contains('yolo11n.tflite'));
    expect(text, contains('coco_val.zip'));
    expect(text, contains('5.0 MB'));
    expect(text, contains('100 images'));
    expect(text, contains('Greedy (greedy)'));
    expect(RegExp(r'5\. CLIENTS CONNECTED\n-+\n2\n').hasMatch(text), isTrue, reason: 'two clients, master not counted');
    expect(RegExp(r'PixelA\s+10\.0\.0\.11\s+60\s+60\.0%').hasMatch(text), isTrue);
    expect(RegExp(r'PixelB\s+10\.0\.0\.12\s+40\s+40\.0%').hasMatch(text), isTrue);
    // PixelA uploaded traffic: data 12 msgs each way, control sent 7+2+3=12, received 7.
    final a = text.split('\n').firstWhere((l) => l.startsWith('PixelA') && l.contains('12 / 12'));
    expect(a, contains('12 / 7'));
    // On-wire packets from the OS counters: 80 sent, 120 received.
    expect(RegExp(r'PixelA\s+80\s+120').hasMatch(text), isTrue);
    // A device that has not uploaded yet is marked n/a rather than shown as zero.
    expect(text.split('\n').firstWhere((l) => l.startsWith('PixelB') && l.contains('n/a')), isNotEmpty);
    expect(text, contains('(master)'));
  });

  test('a not-yet-started experiment and an empty fleet do not crash', () {
    final text = buildExperimentReport(
      fileName: 'empty',
      generatedAt: DateTime(2026, 1, 1),
      models: const [],
      schedulerName: 'Greedy (greedy)',
      devices: const [],
    );
    expect(text, contains('not started'));
    expect(text, contains('Not reported by any client yet.'));
    expect(text, contains('No dataset shared.'));
  });

  group('file names', () {
    test('safeFileName strips paths, extensions and reserved characters', () {
      expect(MetricsStore.safeFileName('../../etc/passwd'), isNot(contains('/')));
      expect(MetricsStore.safeFileName('my run: 1?.txt'), 'my_run__1_');
      expect(MetricsStore.safeFileName('  '), 'experiment_metrics');
      expect(MetricsStore.safeFileName(null), 'experiment_metrics');
      expect(MetricsStore.safeFileName('a' * 200).length, 80);
    });
  });

  group('live visibility', () {
    setUp(() => store.clear());

    test('polls per minute and time since the last poll', () {
      store.setLocalIdentity('10.0.0.1', 'Host');
      store.recordPoll('10.0.0.11', nowMs: 1000);
      store.recordPoll('10.0.0.11', nowMs: 20000);
      store.recordPoll('10.0.0.11', nowMs: 70000);
      final d = store.device('10.0.0.11')!;
      expect(store.pollsLastMinute(d, nowMs: 75000), 2, reason: 'the poll at 1 s is older than a minute');
      expect(store.lastPollAgeS(d, nowMs: 75000), 5);
    });

    test('sample interval is the median gap of the latest samples', () {
      final d = DeviceMetrics('x', 'x');
      for (final t in [0, 5000, 10000, 15500, 20500]) {
        d.samples.add(sample(t));
      }
      expect(d.sampleIntervalS, 5.0);
    });

    test('remote phones are placed on the host clock', () {
      store.setLocalIdentity('10.0.0.1', 'Host');
      final now = DateTime.now().millisecondsSinceEpoch;
      // The worker's clock runs 10 minutes behind the host.
      store.ingestWire('{"i":"10.0.0.9","name":"W","c":1,"m":1,"b":"50%","t":${now - 600000}}');
      final d = store.device('10.0.0.9')!;
      expect((d.hostTime(d.samples.first.t) - now).abs(), lessThan(5000));
    });

    test('decisions are recorded, capped, exported and cleared', () {
      for (var i = 0; i < 520; i++) {
        store.recordDecision(DecisionRecord(
          t: i, deviceKey: '10.0.0.11', deviceName: 'A', units: [i], scheduler: 'greedy', healthByDevice: {'10.0.0.11': 0.5},
        ));
      }
      expect(store.decisions.length, 500);
      expect(store.experimentStartMs, 0);
      expect(store.decisionsCsv().trim().split('\n').length, 501);
      store.clear();
      expect(store.decisions, isEmpty);
      expect(store.experimentStartMs, isNull);
    });
  });

  test('traffic counter counts messages per channel and resets them', () {
    final t = TrafficCounter.instance..reset();
    t.countTxMsg(TrafficChannel.httpData);
    t.countRxMsg(TrafficChannel.httpControl, 3);
    expect(t.txMsgs(TrafficChannel.httpData), 1);
    expect((t.toJson()['rx_msgs'] as Map)[TrafficChannel.httpControl], 3);
    t.reset();
    expect(t.rxMsgs(TrafficChannel.httpControl), 0);
  });

  test('sample packets survive the wire and the CSV', () {
    final s = sample(1, rxPk: 7, txPk: 9);
    final back = MetricSample.fromWire(s.toWire());
    expect(back.rxPackets, 7);
    expect(back.txPackets, 9);
    expect(MetricSample.csvHeader.length, s.csvCells('d', 'n').length);
  });
}
