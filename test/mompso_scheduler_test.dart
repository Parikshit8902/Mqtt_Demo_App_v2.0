import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/models/assignment.dart';
import 'package:mqtt_demo/services/models/device_health.dart';
import 'package:mqtt_demo/services/models/result_dto.dart';
import 'package:mqtt_demo/services/schedulers/mompso_scheduler.dart';
import 'package:mqtt_demo/services/schedulers/scheduling_model.dart';

List<Unit> makeUnits(int count) => [
      for (var i = 0; i < count; i++)
        Unit(
          unitIndex: i,
          start: 0,
          end: 100 * 1024 - 1,
          fileUrl: 'http://h/$i',
        ),
    ];

ClientEstimate makePhone({
  double proc = 200,
  double bandwidth = 2000,
  DeviceHealth health = const DeviceHealth(
    batteryPct: 80,
    charging: false,
    cpuPct: 20,
  ),
  int pending = 0,
  double latency = 0,
}) {
  return ClientEstimate(
    ttprocMs: proc,
    bandwidthKbps: bandwidth,
    health: health,
    pending: pending,
    recentLatencyMs: latency,
  );
}

Map<String, List<int>> assignmentIndices(
  Map<String, List<Unit>> assignments,
) {
  return {
    for (final entry in assignments.entries)
      entry.key: (entry.value.map((unit) => unit.unitIndex).toList()..sort()),
  };
}

void main() {
  group('MOMPSOScheduler', () {
    test('exposes the expected scheduler identity', () {
      final scheduler = MOMPSOScheduler(random: Random(1));

      expect(scheduler.id, 'mompso');
      expect(scheduler.label, 'MOMPSO');
    });

    test('same seed produces the same worker-to-unit assignments', () {
      Map<String, List<int>> run() {
        final result = MOMPSOScheduler(
          random: Random(42),
          particles: 12,
          iterations: 12,
        ).schedule(
          makeUnits(20),
          {
            'a': makePhone(proc: 150, bandwidth: 3000),
            'b': makePhone(proc: 300, bandwidth: 1800),
            'c': makePhone(proc: 220, bandwidth: 1000),
          },
          6,
        );

        return assignmentIndices(result);
      }

      expect(run(), equals(run()));
    });

    test('does not assign any unit more than once', () {
      final result = MOMPSOScheduler(
        random: Random(17),
        particles: 12,
        iterations: 12,
      ).schedule(
        makeUnits(30),
        {
          'fast': makePhone(proc: 100, bandwidth: 3000),
          'medium': makePhone(proc: 300, bandwidth: 1800),
          'slow': makePhone(proc: 700, bandwidth: 700),
        },
        4,
      );

      final assignedIndices = result.values
          .expand((assigned) => assigned)
          .map((unit) => unit.unitIndex)
          .toList();

      expect(assignedIndices.toSet().length, assignedIndices.length);
    });

    test('does not exceed the configured per-worker assignment cap', () {
      const cap = 4;

      final result = MOMPSOScheduler(
        random: Random(17),
        particles: 12,
        iterations: 12,
      ).schedule(
        makeUnits(30),
        {
          'fast': makePhone(proc: 100, bandwidth: 3000),
          'medium': makePhone(proc: 300, bandwidth: 1800),
          'slow': makePhone(proc: 700, bandwidth: 700),
        },
        cap,
      );

      for (final assigned in result.values) {
        expect(assigned.length, lessThanOrEqualTo(cap));
      }
    });

    test('handles fewer capacity slots than the number of units', () {
      final result = MOMPSOScheduler(
        random: Random(23),
        particles: 12,
        iterations: 12,
      ).schedule(
        makeUnits(20),
        {
          'a': makePhone(proc: 150, bandwidth: 3000),
          'b': makePhone(proc: 300, bandwidth: 1800),
        },
        2,
      );

      final assignedIndices = result.values
          .expand((assigned) => assigned)
          .map((unit) => unit.unitIndex)
          .toList();

      expect(assignedIndices.toSet().length, assignedIndices.length);
      expect(assignedIndices.length, lessThanOrEqualTo(4));

      for (final assigned in result.values) {
        expect(assigned.length, lessThanOrEqualTo(2));
      }
    });

    test('single-worker scheduling returns only units from the input batch', () {
      final input = makeUnits(8);
      final result = MOMPSOScheduler(
        random: Random(7),
        particles: 8,
        iterations: 4,
      ).schedule(
        input,
        {'only': makePhone()},
        4,
      );

      final assigned = result.values.expand((items) => items).toList();
      final inputIndices = input.map((unit) => unit.unitIndex).toSet();

      expect(assigned, isNotEmpty);
      expect(
        assigned.every((unit) => inputIndices.contains(unit.unitIndex)),
        isTrue,
      );
      expect(
        assigned.map((unit) => unit.unitIndex).toSet().length,
        assigned.length,
      );
      expect(assigned.length, lessThanOrEqualTo(4));
    });

    test('empty unit batch produces no assignments', () {
      final result = MOMPSOScheduler(random: Random(11)).schedule(
        <Unit>[],
        {'a': makePhone(), 'b': makePhone(proc: 300)},
        4,
      );

      expect(result.values.expand((items) => items), isEmpty);
    });

    test('respects a zero-work gate when another worker is eligible', () {
      final result = MOMPSOScheduler(random: Random(13)).schedule(
        makeUnits(8),
        {
          'healthy': makePhone(),
          'critical': makePhone(
            health: const DeviceHealth(
              batteryPct: 80,
              charging: false,
              cpuPct: 20,
              thermalStatus: 4,
            ),
          ),
        },
        4,
      );

      expect(result['critical'], isEmpty);
      expect(result['healthy'], isNotEmpty);
    });
  });
}