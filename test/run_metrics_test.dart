import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/metrics/metrics_store.dart';
import 'package:mqtt_demo/services/metrics/run_metrics.dart';

UnitRecord unit(String device, int index, int totalMs) => UnitRecord(
      deviceKey: device,
      jobId: 'j',
      unitIndex: index,
      bytes: 1000,
      downloadMs: totalMs ~/ 2,
      inferMs: totalMs ~/ 2,
      totalMs: totalMs,
      downloadKBps: 10,
      scheduler: 'greedy',
      t: 0,
    );

void main() {
  group('RunMetrics math', () {
    test('Jain is 1 when even, 1/n when one phone does everything', () {
      expect(RunMetrics.jain([3, 3, 3, 3]), 1);
      expect(RunMetrics.jain([4, 0, 0, 0]), closeTo(0.25, 1e-9));
      expect(RunMetrics.jain([]), 1);
    });

    test('nearest-rank percentiles', () {
      final xs = [for (var i = 1; i <= 20; i++) i * 10.0];
      expect(RunMetrics.percentile(xs, 50), 100);
      expect(RunMetrics.percentile(xs, 95), 190);
      expect(RunMetrics.percentile([], 50), 0);
    });

    test('compute: makespan, throughput, latency, fairness, energy', () {
      final r = RunMetrics.compute(
        scheduler: 'greedy',
        startMs: 1000,
        endMs: 11000,
        latencies: [
          (unitId: 'j:0', phone: 'a', latencyMs: 100),
          (unitId: 'j:1', phone: 'a', latencyMs: 300),
          (unitId: 'j:2', phone: 'b', latencyMs: 200),
          (unitId: 'j:2', phone: 'a', latencyMs: 400), // late duplicate after a requeue
        ],
        phonesWithNoWork: ['c'],
        totalEnergyJ: 30,
      );
      expect(r.makespanS, 10);
      expect(r.units, 3, reason: 'a unit finished twice counts once');
      expect(r.throughput, closeTo(0.3, 1e-9));
      expect(r.phones, 3);
      expect(r.meanLatencyMs, 250);
      expect(r.p50LatencyMs, 200);
      expect(r.p95LatencyMs, 400);
      // images per phone 3, 1, 0 -> 16 / (3 * 10)
      expect(r.jainUnits, closeTo(16 / 30, 1e-9));
      expect(r.energyPerImageJ, 10);
      expect(r.toJson()['makespan_s'], 10.0);
    });

    test('an unstarted run has no makespan or throughput', () {
      final r = RunMetrics.compute(scheduler: 'x', startMs: null, endMs: null, latencies: const []);
      expect(r.makespanS, 0);
      expect(r.throughput, 0);
      expect(r.energyPerImageJ, isNull);
    });
  });

  group('MetricsStore runs', () {
    final store = MetricsStore.instance;

    setUp(() {
      store.clear();
      store.runHistory.clear();
    });

    test('a reset keeps the finished run for comparison', () {
      store.schedulerId = 'greedy';
      store.recordDecision(DecisionRecord(t: 1000, deviceKey: '10.0.0.2', deviceName: 'A', units: const [0], scheduler: 'greedy'));
      store.recordUnit('10.0.0.2', unit('10.0.0.2', 0, 200), nowMs: 6000);
      store.recordUnit('10.0.0.3', unit('10.0.0.3', 1, 400), nowMs: 11000);

      final now = store.runMetrics();
      expect(now.makespanS, 10);
      expect(now.units, 2);
      expect(now.jainUnits, 1);

      store.clear();
      expect(store.runHistory.single.units, 2);
      expect(store.runMetrics().units, 0);
      final csv = store.runsCsv().trim().split('\n');
      expect(csv.first.startsWith('run,scheduler,'), isTrue);
      expect(csv.length, 2, reason: 'one archived run, no current one yet');
      expect(csv[1].startsWith('1,greedy,'), isTrue);
    });

    test('a reset with nothing finished archives nothing', () {
      store.clear();
      expect(store.runHistory, isEmpty);
    });
  });
}
