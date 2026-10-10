import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/models/assignment.dart';
import 'package:mqtt_demo/services/models/device_health.dart';
import 'package:mqtt_demo/services/models/result_dto.dart';
import 'package:mqtt_demo/services/schedulers/mompso_ga_scheduler.dart';

List<Unit> _units(int count) => [
      for (var i = 0; i < count; i++)
        Unit(
          unitIndex: i,
          start: 0,
          end: 1023,
          fileUrl: 'http://host/$i',
        ),
    ];

ClientEstimate _phone({
  double proc = 200,
  double bandwidth = 2000,
}) =>
    ClientEstimate(
      ttprocMs: proc,
      bandwidthKbps: bandwidth,
      health: const DeviceHealth(
        batteryPct: 80,
        charging: false,
        cpuPct: 20,
      ),
    );

void main() {
  group('MOMPSO-GA batch optimizer', () {
    test('uses the approved fixed evaluation budget', () {
      final scheduler = MOMPSOGAScheduler(random: Random(7));
      final available = _units(8);

      final result = scheduler.schedule(
        available,
        {
          'a': _phone(),
          'b': _phone(proc: 350),
        },
        8,
      );

      final assigned = result.values.expand((units) => units).toList();

      // Every assigned unit must come from the available batch.
      expect(assigned.length, lessThanOrEqualTo(available.length));

      // The plan count must agree with the actual assignments.
      expect(scheduler.lastPlanTaskCount, assigned.length);

      // Initial population + iterations * (population + offspring).
      expect(scheduler.lastEvaluationCount, 12 + 8 * (12 + 4));
    });

    test('respects per-client caps and assigns each unit at most once', () {
      final scheduler = MOMPSOGAScheduler(random: Random(11));
      final available = _units(10);

      final result = scheduler.schedule(
        available,
        {
          'a': _phone(),
          'b': _phone(proc: 350),
          'c': _phone(proc: 450),
        },
        3,
      );

      final assigned = result.values.expand((units) => units).toList();
      final assignedIndices =
          assigned.map((unit) => unit.unitIndex).toList();

      // No client may exceed the requested per-client limit.
      expect(
        result.values.every((units) => units.length <= 3),
        isTrue,
      );

      // A unit may be assigned at most once.
      expect(
        assignedIndices.toSet().length,
        assigned.length,
      );

      // The scheduler cannot assign units outside the input batch.
      final availableIndices =
          available.map((unit) => unit.unitIndex).toSet();
      expect(
        assignedIndices.every(availableIndices.contains),
        isTrue,
      );

      expect(assigned.length, lessThanOrEqualTo(available.length));
      expect(scheduler.lastPlanTaskCount, assigned.length);
    });

    test('seeded runs are deterministic', () {
      Map<String, List<int>> run(int seed) {
        final result = MOMPSOGAScheduler(random: Random(seed)).schedule(
          _units(8),
          {
            'a': _phone(),
            'b': _phone(proc: 350),
          },
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

      final result = scheduler.schedule(
        _units(4),
        {'only': _phone()},
        4,
      );

      expect(result['only']!.length, 4);
      expect(scheduler.lastEvaluationCount, 1);
      expect(scheduler.lastPlanTaskCount, 4);
    });
  });
}