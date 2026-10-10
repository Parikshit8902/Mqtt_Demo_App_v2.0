import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/distribution_manager.dart';
import 'package:mqtt_demo/services/metrics/metrics_store.dart';
import 'package:mqtt_demo/services/models/assignment.dart';
import 'package:mqtt_demo/services/models/device_health.dart';
import 'package:mqtt_demo/services/models/result_dto.dart';
import 'package:mqtt_demo/services/schedulers/greedy_scheduler.dart';
import 'package:mqtt_demo/services/schedulers/mompso_ga_scheduler.dart';
import 'package:mqtt_demo/services/schedulers/mompso_scheduler.dart';
import 'package:mqtt_demo/services/schedulers/pso_scheduler.dart';
import 'package:mqtt_demo/services/schedulers/scheduler.dart';
import 'package:mqtt_demo/services/schedulers/scheduler_type.dart';
import 'package:mqtt_demo/services/schedulers/scheduling_model.dart';

List<Unit> units(int n) =>
    [
      for (var i = 0; i < n; i++)
        Unit(
          unitIndex: i,
          start: 0,
          end: 100 * 1024 - 1,
          fileUrl: 'http://h/$i',
        )
    ];

ClientEstimate phone({
  double proc = 200,
  double bw = 2000,
  DeviceHealth health = const DeviceHealth(
    batteryPct: 80,
    charging: false,
    cpuPct: 20,
  ),
  int pending = 0,
  double latency = 0,
}) =>
    ClientEstimate(
      ttprocMs: proc,
      bandwidthKbps: bw,
      health: health,
      pending: pending,
      recentLatencyMs: latency,
    );

/// Mean number of units "b" receives from a big batch, averaged over seeds so the
/// randomised schedulers can be judged on their expectation.
double shareOfB(
  Scheduler Function(int seed) make,
  ClientEstimate a,
  ClientEstimate b,
) {
  var total = 0;
  const seeds = 40;

  for (var s = 0; s < seeds; s++) {
    final out = make(s).schedule(
      units(60),
      {
        'a': a,
        'b': b,
      },
      60,
    );

    total += out['b']!.length;
  }

  return total / seeds;
}

final Map<String, Scheduler Function(int)> makers = {
  'greedy': (s) => GreedyScheduler(random: Random(s)),
  'pso': (s) => PSOScheduler(random: Random(s)),
  'mompso': (s) => MOMPSOScheduler(random: Random(s)),
  'mompso-ga': (s) => MOMPSOGAScheduler(random: Random(s)),
};

void main() {
  group('every live parameter moves work away from the degraded phone', () {
    final base = phone();

    final degradations = <String, ClientEstimate>{
      'lower bandwidth': phone(bw: 300),
      'slower inference': phone(proc: 900),
      'deeper queue': phone(pending: 6),
      'thermal throttling': phone(
        health: const DeviceHealth(
          batteryPct: 80,
          charging: false,
          cpuPct: 20,
          thermalStatus: 3,
        ),
      ),
      'low battery unplugged': phone(
        health: const DeviceHealth(
          batteryPct: 12,
          charging: false,
          cpuPct: 20,
        ),
      ),
      'low memory': phone(
        health: const DeviceHealth(
          batteryPct: 80,
          charging: false,
          cpuPct: 20,
          lowMemory: true,
          memFreeMb: 400,
        ),
      ),
      'weak Wi-Fi signal': phone(
        health: const DeviceHealth(
          batteryPct: 80,
          charging: false,
          cpuPct: 20,
          rssiDbm: -88,
        ),
      ),
      'higher recent latency': phone(latency: 4000),
    };

    for (final alg in makers.entries) {
      for (final d in degradations.entries) {
        test('${alg.key}: ${d.key}', () {
          final healthy = shareOfB(
            alg.value,
            base,
            base,
          );

          final degraded = shareOfB(
            alg.value,
            base,
            d.value,
          );

          expect(
            degraded,
            lessThan(healthy),
            reason:
                '${alg.key} should give a phone with ${d.key} less work',
          );
        });
      }
    }
  });

  group('gating', () {
    for (final alg in makers.entries) {
      test(
        '${alg.key}: a phone at 3% battery unplugged gets nothing while a healthy phone exists',
        () {
          final out = alg.value(1).schedule(
            units(10),
            {
              'ok': phone(),
              'dying': phone(
                health: const DeviceHealth(
                  batteryPct: 3,
                  charging: false,
                ),
              ),
            },
            5,
          );

          expect(out['dying'], isEmpty);
          expect(out['ok'], isNotEmpty);
        },
      );

      test(
        '${alg.key}: if every phone is gated the job is not starved',
        () {
          const critical = DeviceHealth(thermalStatus: 4);

          final out = alg.value(1).schedule(
            units(4),
            {
              'a': phone(health: critical),
              'b': phone(health: critical),
            },
            2,
          );

          expect(
            out.values.expand((l) => l),
            isNotEmpty,
          );
        },
      );

      test(
        '${alg.key}: charging overrides the low-battery gate',
        () {
          final out = alg.value(1).schedule(
            units(6),
            {
              'plugged': phone(
                health: const DeviceHealth(
                  batteryPct: 3,
                  charging: true,
                ),
              ),
              'ok': phone(),
            },
            3,
          );

          expect(out['plugged'], isNotEmpty);
        },
      );
    }
  });

  group('health score matches the DetectNet reference formula', () {
    test('hScore computed independently from the reference', () {
      // Reference (public/index.html hScore):
      //
      //   batW = 0.20 if battery known; rest = 1 - batW
      //
      //   score =
      //     bat/100*batW
      //     + (1-cpu/100)*rest*0.28
      //     + throughput*rest*0.32
      //     + fps*rest*0.22
      //     + 1/(1+pending)*rest*0.18
      //
      // Throughput and fps are taken relative to the best phone here.

      final fast = phone(
        proc: 100,
        bw: 4000,
        health: const DeviceHealth(
          batteryPct: 90,
          charging: false,
          cpuPct: 30,
        ),
        pending: 1,
      );

      final slow = phone(
        proc: 400,
        bw: 1000,
        health: const DeviceHealth(
          batteryPct: 40,
          charging: false,
          cpuPct: 60,
        ),
        pending: 2,
      );

      final fleet = FleetModel(
        {
          'fast': fast,
          'slow': slow,
        },
        units(4),
        2,
      );

      double expected(
        ClientEstimate c,
        double bwRel,
        double rateRel,
      ) {
        const batW = 0.20;
        const rest = 1 - batW;

        return c.health.batteryPct! / 100 * batW +
            (1 - c.health.cpuPct! / 100) * rest * 0.28 +
            bwRel * rest * 0.32 +
            rateRel * rest * 0.22 +
            1 / (1 + c.pending) * rest * 0.18;
      }

      expect(
        fleet.healthScore('fast'),
        closeTo(
          expected(fast, 1.0, 1.0),
          1e-9,
        ),
      );

      expect(
        fleet.healthScore('slow'),
        closeTo(
          expected(slow, 0.25, 0.25),
          1e-9,
        ),
      );
    });

    test('battery weight is shared out when battery is unknown (iOS)', () {
      final p = phone(
        health: const DeviceHealth(cpuPct: 0),
      );

      final fleet = FleetModel(
        {'a': p},
        units(1),
        1,
      );

      // cpu free 1.0, throughput 1.0, rate 1.0, queue 1.0 => weights sum to 1.
      expect(
        fleet.healthScore('a'),
        closeTo(1.0, 1e-9),
      );
    });

    test('each assignment lengthens the queue and lowers the health score', () {
      final fleet = FleetModel(
        {'a': phone()},
        units(3),
        3,
      );

      final before = fleet.healthScore('a');

      fleet.recordAssignment('a');

      expect(
        fleet.healthScore('a'),
        lessThan(before),
      );
    });
  });

  group('spreading and caps', () {
    test('identical phones split a batch roughly evenly', () {
      for (final alg in makers.entries) {
        var a = 0;
        var b = 0;

        for (var s = 0; s < 20; s++) {
          final out = alg.value(s).schedule(
            units(40),
            {
              'a': phone(),
              'b': phone(),
            },
            40,
          );

          a += out['a']!.length;
          b += out['b']!.length;
        }

        expect(
          (a - b).abs() / (a + b),
          lessThan(0.35),
          reason: alg.key,
        );
      }
    });

    test('greedy selects the minimum predicted completion-time pair', () {
      // Each unit is 100 KiB.
      //
      // Phone A:
      //   processing = 100 ms
      //   transfer   = 100 ms
      //   total      = 200 ms/unit
      //
      // Phone B:
      //   processing = 300 ms
      //   transfer   = 100 ms
      //   total      = 400 ms/unit
      //
      // Therefore the greedy completion-time sequence is:
      //
      //   1. A (200 vs 400)
      //   2. A (400 vs 400, deterministic tie-break)
      //   3. B (600 vs 400)
      //   4. A (600 vs 800)
      //   5. A (800 vs 800, deterministic tie-break)
      //   6. B (1000 vs 800)
      //
      // Expected final allocation:
      //
      //   A = {0, 1, 3, 4}
      //   B = {2, 5}

      final scheduler = GreedyScheduler(
        random: Random(7),
      );

      final out = scheduler.schedule(
        units(6),
        {
          'A': phone(
            proc: 100,
            bw: 1000,
          ),
          'B': phone(
            proc: 300,
            bw: 1000,
          ),
        },
        6,
      );

      final a = out['A']!
          .map((u) => u.unitIndex)
          .toList();

      final b = out['B']!
          .map((u) => u.unitIndex)
          .toList();

      expect(
        a,
        [0, 1, 3, 4],
      );

      expect(
        b,
        [2, 5],
      );
    });

    test('greedy balances identical workers deterministically', () {
      final scheduler = GreedyScheduler(
        random: Random(7),
      );

      final out = scheduler.schedule(
        units(10),
        {
          'A': phone(
            proc: 200,
            bw: 2000,
          ),
          'B': phone(
            proc: 200,
            bw: 2000,
          ),
        },
        10,
      );

      expect(
        out['A']!.length,
        5,
      );

      expect(
        out['B']!.length,
        5,
      );

      final assigned = out.values
          .expand((items) => items)
          .map((u) => u.unitIndex)
          .toSet();

      expect(
        assigned.length,
        10,
      );
    });

    test('no unit is assigned twice and nobody exceeds maxUnitPerAssign', () {
      for (final alg in makers.entries) {
        final out = alg.value(3).schedule(
          units(30),
          {
            'a': phone(),
            'b': phone(proc: 600),
            'c': phone(bw: 500),
          },
          4,
        );

        final all = out.values
            .expand((l) => l)
            .map((u) => u.unitIndex)
            .toList();

        expect(
          all.toSet().length,
          all.length,
          reason: alg.key,
        );

        for (final l in out.values) {
          expect(
            l.length,
            lessThanOrEqualTo(4),
            reason: alg.key,
          );
        }
      }
    });

    test('seeded schedulers are deterministic', () {
      for (final alg in makers.entries) {
        List<int> run() => alg.value(7)
            .schedule(
              units(20),
              {
                'a': phone(),
                'b': phone(proc: 300),
                'c': phone(bw: 900),
              },
              6,
            )
            .values
            .expand((l) => l)
            .map((u) => u.unitIndex)
            .toList();

        expect(
          run(),
          run(),
          reason: alg.key,
        );
      }
    });
  });
  
  
  group('MOMPSO-specific behavior', () {
    test('same seed produces the same worker-to-unit assignments', () {
      Map<String, List<int>> run() {
        final out = MOMPSOScheduler(
          random: Random(42),
          particles: 12,
          iterations: 12,
        ).schedule(
          units(20),
          {
            'a': phone(proc: 150, bw: 3000),
            'b': phone(proc: 300, bw: 1800),
            'c': phone(proc: 220, bw: 1000),
          },
          6,
        );

        return {
          for (final entry in out.entries)
            entry.key: entry.value.map((u) => u.unitIndex).toList()
              ..sort(),
        };
      }

      expect(run(), equals(run()));
    });

    test('assignments remain unique and respect worker capacity', () {
      final out = MOMPSOScheduler(
        random: Random(17),
        particles: 12,
        iterations: 12,
      ).schedule(
        units(30),
        {
          'fast': phone(proc: 100, bw: 3000),
          'medium': phone(proc: 300, bw: 1800),
          'slow': phone(proc: 700, bw: 700),
        },
        4,
      );

      final assignedUnits = out.values
          .expand((assigned) => assigned)
          .map((unit) => unit.unitIndex)
          .toList();

      // A unit must never be assigned to more than one worker.
      expect(
        assignedUnits.toSet().length,
        assignedUnits.length,
      );

      // No worker may exceed the configured assignment cap.
      for (final assigned in out.values) {
        expect(assigned.length, lessThanOrEqualTo(4));
      }

      // Total assigned work cannot exceed aggregate worker capacity.
      expect(assignedUnits.length, lessThanOrEqualTo(12));
    });

    test('scheduler handles fewer capacity slots than remaining tasks', () {
      final out = MOMPSOScheduler(
        random: Random(23),
        particles: 12,
        iterations: 12,
      ).schedule(
        units(20),
        {
          'a': phone(proc: 150, bw: 3000),
          'b': phone(proc: 300, bw: 1800),
        },
        2,
      );

      final assignedUnits = out.values
          .expand((assigned) => assigned)
          .map((unit) => unit.unitIndex)
          .toList();

      expect(assignedUnits.toSet().length, assignedUnits.length);
      expect(assignedUnits.length, lessThanOrEqualTo(4));

      for (final assigned in out.values) {
        expect(assigned.length, lessThanOrEqualTo(2));
      }
    });
  });


  group('wire format', () {
    test('legacy battery "-1%" is unknown, not 1%', () {
      expect(
        DeviceHealth.fromWire({'b': '-1%'}).batteryPct,
        isNull,
      );

      expect(
        MetricSample.fromWire({'t': 1, 'b': '-1%'}).battery,
        -1,
      );
    });

    test('health round-trips and merge keeps older fields', () {
      const h = DeviceHealth(
        batteryPct: 55,
        charging: true,
        thermalStatus: 2,
        rssiDbm: -60,
        linkMbps: 300,
        memFreeMb: 1200.5,
      );

      final back = DeviceHealth.fromWire(
        h.toWire(),
      );

      expect(
        back.batteryPct,
        55,
      );

      expect(
        back.charging,
        true,
      );

      expect(
        back.thermalStatus,
        2,
      );

      expect(
        back.rssiDbm,
        -60,
      );

      final merged = h.merge(
        const DeviceHealth(batteryPct: 54),
      );

      expect(
        merged.batteryPct,
        54,
      );

      expect(
        merged.thermalStatus,
        2,
      );
    });

    test('invalid sensor readings become unknown', () {
      final h = DeviceHealth.fromWire({
        'rs': -127,
        'ls': 0,
        'th': -1,
        'bp': 150,
      });

      expect(
        h.rssiDbm,
        isNull,
      );

      expect(
        h.linkMbps,
        isNull,
      );

      expect(
        h.thermalStatus,
        isNull,
      );

      expect(
        h.batteryPct,
        isNull,
      );
    });

    test('ResultReport carries health and still parses old payloads', () {
      final rr = ResultReport(
        jobId: 'j',
        clientId: 'c',
        unitIndex: 0,
        ttprocMs: 10,
        bandwidthKbps: 5,
        health: const DeviceHealth(
          batteryPct: 70,
          thermalStatus: 1,
        ),
      );

      expect(
        ResultReport.fromJson(rr.toJson()).health!.thermalStatus,
        1,
      );

      expect(
        ResultReport.fromJson({
          'j': 'j',
          'i': 'c',
          'unit_index': 0,
          'ttproc_ms': 1,
          'bandwidth_kBps': 1,
        }).health,
        isNull,
      );
    });
  });

  group('DistributionManager live state', () {
    const a = 'mqtt_client_PixelA_10-0-0-1_10-0-0-11';
    const b = 'mqtt_client_PixelB_10-0-0-1_10-0-0-12';

    var now = 0;

    late DistributionManager dm;

    setUp(() {
      now = 1000;

      dm = DistributionManager(
        nowMs: () => now,
        leaseMs: 10000,
        activeWindowMs: 30000,
      );

      dm.setSchedulerType(
        SchedulerType.greedy,
      );

      dm.registerJob(
        'j',
        units(20),
      );

      dm.registerClient(
        a,
        ClientEstimate(
          ttprocMs: 200,
          bandwidthKbps: 2000,
        ),
      );

      dm.registerClient(
        b,
        ClientEstimate(
          ttprocMs: 200,
          bandwidthKbps: 2000,
        ),
      );
    });

    test(
      'a unit not finished within the lease is requeued and never held by two phones',
      () {
        final first = dm.assignNext(
          'j',
          a,
          maxUnits: 2,
        );

        expect(
          first,
          isNotEmpty,
        );

        now += 11000;

        dm.touchClient(a);
        dm.touchClient(b);

        final second = dm.assignNext(
          'j',
          b,
          maxUnits: 20,
        );

        final ids = second
            .map((u) => u.unitIndex)
            .toSet();

        expect(
          first.every(
            (u) => ids.contains(u.unitIndex),
          ),
          isTrue,
          reason: 'expired units are offered again',
        );

        expect(
          dm.getClientQueue(a),
          isEmpty,
        );
      },
    );

    test(
      'a late result for a requeued unit is still accepted',
      () {
        final first = dm.assignNext(
          'j',
          a,
          maxUnits: 1,
        );

        now += 11000;

        dm.assignNext(
          'j',
          b,
          maxUnits: 20,
        );

        dm.markUnitComplete(
          'j',
          first.single.unitIndex,
        );

        expect(
          dm.jobProgress('j')['completed'],
          1,
        );

        expect(
          dm.getClientQueue(b).any(
            (u) => u.unitIndex == first.single.unitIndex,
          ),
          isFalse,
        );
      },
    );

    test(
      'a silent phone is dropped from the plan but the requester is always kept',
      () {
        now += 60000;

        // Both silent for longer than the active window.
        dm.touchClient(b);

        final views = dm.clientViews();

        expect(
          views.containsKey(b),
          isTrue,
        );

        expect(
          views.containsKey(a),
          isFalse,
        );

        expect(
          dm.assignNext(
            'j',
            a,
            maxUnits: 2,
          ),
          isNotEmpty,
          reason:
              'the requester a is included even when stale',
        );
      },
    );

    test(
      'health reported by device IP reaches the right client and drives gating',
      () {
        dm.updateClientHealth(
          '10.0.0.11',
          const DeviceHealth(
            batteryPct: 2,
            charging: false,
          ),
        );

        final got = dm.assignNext(
          'j',
          a,
          maxUnits: 5,
        );

        expect(
          got,
          isEmpty,
          reason: 'a is gated at 2% battery while b is healthy',
        );

        expect(
          dm.assignNext(
            'j',
            b,
            maxUnits: 5,
          ),
          isNotEmpty,
        );
      },
    );

    test(
      'recordResult updates the estimate and ignores bad samples',
      () {
        dm.recordResult(
          ResultReport(
            jobId: 'j',
            clientId: a,
            unitIndex: 0,
            ttprocMs: 1000,
            bandwidthKbps: 500,
            totalMs: 1100,
          ),
        );

        final v = dm.clientViews()[a]!;

        expect(
          v['proc_ms'] as double,
          closeTo(
            0.8 * 200 + 0.2 * 1000,
            1.0,
          ),
        );

        dm.recordResult(
          ResultReport(
            jobId: 'j',
            clientId: a,
            unitIndex: 1,
            ttprocMs: 0,
            bandwidthKbps: 0,
          ),
        );

        expect(
          dm.clientViews()[a]!['proc_ms'] as double,
          closeTo(
            0.8 * 200 + 0.2 * 1000,
            1.0,
          ),
        );
      },
    );

    test(
      'an unregistered requester gets nothing instead of crashing',
      () {
        expect(
          dm.assignNext(
            'j',
            'mqtt_client_Ghost_1_2',
            maxUnits: 2,
          ),
          isEmpty,
        );
      },
    );

    test(
      'suggestNext does not change job state',
      () {
        final before = dm.jobProgress('j');

        dm.suggestNext(
          'j',
          a,
          maxUnits: 2,
        );

        expect(
          dm.jobProgress('j'),
          before,
        );
      },
    );

    test(
      'dynamic schedulers expose a decision trace, baselines do not',
      () {
        dm.assignNext(
          'j',
          a,
          maxUnits: 2,
        );

        expect(
          dm.lastDecisionTrace,
          isNotNull,
        );

        dm.setSchedulerType(
          SchedulerType.roundRobin,
        );

        expect(
          dm.lastDecisionTrace,
          isNull,
        );
      },
    );
  });
}