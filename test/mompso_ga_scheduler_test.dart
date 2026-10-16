import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/models/assignment.dart';
import 'package:mqtt_demo/services/models/device_health.dart';
import 'package:mqtt_demo/services/models/result_dto.dart';
import 'package:mqtt_demo/services/schedulers/mompso_ga_scheduler.dart';

List<Unit> _units(int count) => [
      for (var i = 0; i < count; i++)
        Unit(unitIndex: i, start: 0, end: 1023, fileUrl: 'http://host/$i'),
    ];

ClientEstimate _phone({
  double proc = 200,
  double bandwidth = 2000,
  int pending = 0,
}) =>
    ClientEstimate(
      ttprocMs: proc,
      bandwidthKbps: bandwidth,
      pending: pending,
      health: const DeviceHealth(batteryPct: 80, charging: false, cpuPct: 20),
    );

void main() {
  group('MOMPSO-GA batch optimizer', () {
    test('uses the approved fixed evaluation budget', () {
      final scheduler = MOMPSOGAScheduler(random: Random(7));
      final result = scheduler.schedule(
        _units(8),
        {'a': _phone(), 'b': _phone(proc: 350)},
        8,
      );

      expect(result.values.expand((units) => units).length, 8);
      expect(scheduler.lastPlanTaskCount, 8);
      expect(scheduler.lastEvaluationCount, 12 + 8 * (12 + 4));
    });

    test('respects per-client caps and assigns each unit at most once', () {
      final scheduler = MOMPSOGAScheduler(random: Random(11));
      final available = _units(10);
      final result = scheduler.schedule(
        available,
        {'a': _phone(), 'b': _phone(proc: 350), 'c': _phone(proc: 450)},
        3,
      );
      final assigned = result.values.expand((units) => units).toList();

      expect(result.values.every((units) => units.length <= 3), isTrue);

      // The shared FleetModel may impose lower per-client caps based on the
      // estimated service rates. Assert that MOMPSO-GA fills every feasible
      // slot, rather than assuming all clients receive maxUnitPerAssign.
      final clientTrace =
          scheduler.lastTrace['clients'] as Map<String, dynamic>;
      final aggregateCapacity = clientTrace.values.fold<int>(
        0,
        (sum, raw) => sum + ((raw as Map<String, dynamic>)['cap'] as num).toInt(),
      );
      final expectedAssignments = min(available.length, aggregateCapacity);

      expect(assigned.length, expectedAssignments);
      expect(assigned.map((unit) => unit.unitIndex).toSet().length, assigned.length);
      expect(scheduler.lastPlanTaskCount, expectedAssignments);
    });

    test('queue depth affects the objective but does not silently lower hard capacity', () {
      final scheduler = MOMPSOGAScheduler(random: Random(13));
      final result = scheduler.schedule(
        _units(6),
        {
          'queued': _phone(pending: 20),
          'free': _phone(pending: 0),
        },
        3,
      );
      final assigned = result.values.expand((units) => units).toList();

      // Shared FleetModel caps govern the number of tasks; queue depth is an
      // objective input, not an additional MOMPSO-GA-only capacity rule.
      expect(scheduler.lastPlanTaskCount, 6);
      expect(assigned.length, 6);
      expect(result.values.every((units) => units.length <= 3), isTrue);
    });

    test('seeded runs are deterministic', () {
      Map<String, List<int>> run(int seed) {
        final result = MOMPSOGAScheduler(random: Random(seed)).schedule(
          _units(8),
          {'a': _phone(), 'b': _phone(proc: 350)},
          8,
        );
        return {
          for (final entry in result.entries)
            entry.key: entry.value.map((unit) => unit.unitIndex).toList(),
        };
      }

      expect(run(19), run(19));
    });

    test('single-worker case avoids unnecessary search', () {
      final scheduler = MOMPSOGAScheduler(random: Random(2));
      final result = scheduler.schedule(_units(4), {'only': _phone()}, 4);

      expect(result['only']!.length, 4);
      expect(scheduler.lastEvaluationCount, 1);
    });
  });
}