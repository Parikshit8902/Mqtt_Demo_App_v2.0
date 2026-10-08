import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/distribution_manager.dart';
import 'package:mqtt_demo/services/metrics/metrics_store.dart';
import 'package:mqtt_demo/services/metrics/power_model.dart';
import 'package:mqtt_demo/services/metrics/traffic_counter.dart';
import 'package:mqtt_demo/services/models/assignment.dart';
import 'package:mqtt_demo/services/models/result_dto.dart';
import 'package:mqtt_demo/services/schedulers/scheduler_registry.dart';

List<Unit> _units(int n, {int size = 100 * 1024}) =>
    [for (var i = 0; i < n; i++) Unit(unitIndex: i, start: 0, end: size - 1, fileUrl: 'http://h/f/$i')];

MetricSample _sample(int t, {double cpu = 50, int rx = 0, int tx = 0, int payload = 0, double? measured, double model = 1000}) =>
    MetricSample(
      t: t, cpuPct: cpu, cpuNormPct: cpu / 8, memMb: 100, rxKBps: 0, txKBps: 0, rxBytes: rx, txBytes: tx,
      payloadBytes: payload, battery: 80, measuredMw: measured, modelMw: model,
    );

void main() {
  group('schedulers', () {
    final clients = {
      'fast': ClientEstimate(ttprocMs: 50, bandwidthKbps: 5000),
      'slow': ClientEstimate(ttprocMs: 800, bandwidthKbps: 200),
      'mid': ClientEstimate(ttprocMs: 200, bandwidthKbps: 1000),
    };

    for (final id in SchedulerRegistry.ids) {
      test('$id honours the Scheduler contract', () {
        final units = _units(10);
        final out = SchedulerRegistry.create(id).schedule(units, clients, 3);
        expect(out.keys.toSet(), clients.keys.toSet());
        final all = out.values.expand((l) => l).map((u) => u.unitIndex).toList();
        expect(all.toSet().length, all.length, reason: 'no unit assigned twice');
        for (final l in out.values) {
          expect(l.length, lessThanOrEqualTo(3));
        }
        if (id == 'round_robin' || id == 'random') {
          expect(all.length, 9, reason: 'baselines fill every slot: 3 clients x 3 units');
        } else {
          // Live-data schedulers cap slower phones lower per round, but every
          // eligible phone is still offered at least one unit.
          expect(all.length, inInclusiveRange(3, 9));
          for (final l in out.values) {
            expect(l, isNotEmpty);
          }
        }
      });

      test('$id tolerates no clients', () {
        expect(SchedulerRegistry.create(id).schedule(_units(3), {}, 2), isEmpty);
      });
    }

    test('greedy gives the fast phone the most work', () {
      final out = SchedulerRegistry.create('greedy').schedule(_units(10), clients, 10);
      expect(out['fast']!.length, greaterThan(out['slow']!.length));
    });

    test('DistributionManager switches algorithm and rejects unknown ids', () {
      final dm = DistributionManager();
      expect(dm.schedulerId, SchedulerRegistry.defaultId);
      dm.setScheduler('round_robin');
      expect(dm.schedulerId, 'round_robin');
      expect(() => dm.setScheduler('nope'), throwsArgumentError);

      dm.registerJob('j', _units(6));
      dm.registerClient('a', ClientEstimate(ttprocMs: 100, bandwidthKbps: 1000));
      dm.registerClient('b', ClientEstimate(ttprocMs: 100, bandwidthKbps: 1000));
      final got = dm.assignNext('j', 'a', maxUnits: 2);
      expect(got.length, 2);
      expect(dm.scheduleCalls, 1);
    });
  });

  group('result report wire format', () {
    test('round-trips the new timing fields', () {
      final rr = ResultReport(
        jobId: 'j', clientId: 'c', unitIndex: 1, ttprocMs: 120, bandwidthKbps: 800.5,
        bytes: 4096, downloadMs: 5, totalMs: 130,
      );
      final back = ResultReport.fromJson(jsonDecode(jsonEncode(rr.toJson())) as Map<String, dynamic>);
      expect(back.bytes, 4096);
      expect(back.downloadMs, 5);
      expect(back.totalMs, 130);
      expect(back.bandwidthKbps, 800.5);
    });

    test('still parses payloads from older clients', () {
      final back = ResultReport.fromJson({'j': 'j', 'i': 'c', 'unit_index': 0, 'ttproc_ms': 10, 'bandwidth_kBps': 1.0});
      expect(back.downloadMs, 0);
      expect(back.bytes, 0);
    });
  });

  group('traffic counter', () {
    test('counts per channel and computes MQTT framing', () {
      final t = TrafficCounter.instance..reset();
      t.addTx(TrafficChannel.mqtt, 100);
      t.addRx(TrafficChannel.httpData, 5000, peer: '10.0.0.2');
      expect(t.totalPayload, 5100);
      expect(t.peerRx['10.0.0.2'], 5000);
      // 1 fixed + 1 remaining-length + 2 topic-length + 3 topic chars
      expect(TrafficCounter.mqttFraming('abc', 10), 7);
      expect(TrafficCounter.mqttFraming('abc', 200), 8);
    });
  });

  group('power model', () {
    test('idle costs nothing, busy CPU and traffic cost more', () {
      const m = PowerModel();
      expect(m.estimateMw(cpuCores: 0, bytesPerSec: 0), 0);
      expect(m.estimateMw(cpuCores: 1, bytesPerSec: 0), closeTo(1200, 0.01));
      expect(m.estimateMw(cpuCores: 1, bytesPerSec: 1024 * 1024), greaterThan(m.estimateMw(cpuCores: 1, bytesPerSec: 0)));
    });
  });

  group('metrics store', () {
    setUp(() => MetricsStore.instance.clear());

    test('integrates energy and summarises overhead', () {
      final s = MetricsStore.instance;
      s.setLocalIdentity('10.0.0.5', 'Pixel');
      s.recordLocal(_sample(0, rx: 0, tx: 0, payload: 0, model: 1000, measured: 2000));
      s.recordLocal(_sample(10000, rx: 90000, tx: 10000, payload: 80000, model: 1000, measured: 2000));
      final sum = s.summarize(s.local);
      expect(sum.durationS, 10);
      expect(sum.energyModelJ, closeTo(10, 0.001)); // 1 W for 10 s
      expect(sum.energyMeasuredJ, closeTo(20, 0.001));
      expect(sum.onWireBytes, 100000);
      expect(sum.overheadBytes, 20000);
      expect(sum.overheadPct, closeTo(20, 0.001));
    });

    test('ingests worker MQTT payloads, including the original 3-field format', () {
      final s = MetricsStore.instance;
      s.setLocalIdentity('10.0.0.1', 'Host');
      s.ingestWire(jsonEncode({'i': '10.0.0.9', 'name': 'Pixel', 'c': 12.5, 'm': 80.0, 'b': '77%', 't': 1000}));
      s.ingestWire(jsonEncode({'i': '10.0.0.9', 'name': 'Pixel', 'c': 15.0, 'm': 81.0, 'b': '77%', 't': 1000})); // duplicate t
      s.ingestWire(jsonEncode({'i': '10.0.0.9', 'name': 'Pixel', 'c': 20.0, 'm': 82.0, 'b': '76%', 't': 3000, 'rx': 5, 'tx': 6}));
      final d = s.device('10.0.0.9')!;
      expect(d.samples.length, 2);
      expect(d.samples.first.battery, 77);
      expect(d.samples.last.rxBytes, 5);
    });

    test('worker upload keeps the scheduler the host stamped', () {
      final s = MetricsStore.instance;
      s.setLocalIdentity('10.0.0.1', 'Host');
      s.recordUnit('10.0.0.9', UnitRecord(
        deviceKey: '10.0.0.9', jobId: 'j', unitIndex: 3, bytes: 1, downloadMs: 1, inferMs: 1, totalMs: 2,
        downloadKBps: 1, scheduler: 'greedy', t: 1,
      ));
      s.mergeDeviceReport({
        'key': '10.0.0.9',
        'name': 'Pixel',
        'units': [
          {'job': 'j', 'unit': 3, 'bytes': 2048, 'download_ms': 4, 'infer_ms': 9, 'total_ms': 13, 'download_kBps': 500.0, 'scheduler': '', 't': 5},
        ],
        'traffic': {'tx': {'http_control': 10}, 'rx': {}},
      });
      final u = s.device('10.0.0.9')!.units['j:3']!;
      expect(u.scheduler, 'greedy');
      expect(u.bytes, 2048, reason: "the worker's richer record wins");
      expect(s.device('10.0.0.9')!.units.length, 1, reason: 'no duplicate');
    });

    test('CSV export has a header and one row per sample, and files are written', () async {
      final s = MetricsStore.instance;
      s.setLocalIdentity('10.0.0.5', 'Pixel, "Pro"');
      s.recordLocal(_sample(0));
      s.recordLocal(_sample(2000));
      final lines = s.samplesCsv().trim().split('\n');
      expect(lines.length, 3);
      expect(lines[1], contains('"Pixel, ""Pro"""'));

      final dir = await Directory.systemTemp.createTemp('metrics_test');
      try {
        final files = await s.exportTo(dir);
        expect(files.length, 5);
        for (final f in files) {
          expect(await f.exists(), isTrue);
        }
        final json = jsonDecode(await files.last.readAsString()) as Map<String, dynamic>;
        expect((json['devices'] as List).length, 1);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
