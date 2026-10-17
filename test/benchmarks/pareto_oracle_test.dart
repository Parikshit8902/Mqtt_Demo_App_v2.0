
import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/models/assignment.dart';
import 'package:mqtt_demo/services/models/device_health.dart';
import 'package:mqtt_demo/services/models/result_dto.dart';
import 'package:mqtt_demo/services/schedulers/batch_objective_evaluator.dart';
import 'package:mqtt_demo/services/schedulers/scheduling_model.dart';

Unit _unit(int index, int bytes) => Unit(
      unitIndex: index,
      start: 0,
      end: bytes - 1,
      fileUrl: 'http://host/$index',
    );

ClientEstimate _client({
  required double procMs,
  required double bandwidthKbps,
}) =>
    ClientEstimate(
      ttprocMs: procMs,
      bandwidthKbps: bandwidthKbps,
      pending: 0,
      health: DeviceHealth(
        batteryPct: 80,
        charging: false,
        cpuPct: 20,
      ),
    );

class _Point {
  final double makespan;
  final double energy;

  const _Point(this.makespan, this.energy);

  @override
  String toString() => '(_Point: $makespan ms, $energy J)';
}

/// Enumerates every feasible assignment for a small batch.
///
/// Worker indices in [assignment] refer to positions in [clientIds].
/// Capacities must not exceed FleetModel.capFor().
List<_Point> _enumerate({
  required FleetModel fleet,
  required List<Unit> units,
  required List<String> clientIds,
  required List<int> capacities,
}) {
  if (clientIds.length != capacities.length) {
    throw ArgumentError(
      'clientIds and capacities must have the same length.',
    );
  }

  if (clientIds.toSet().length != clientIds.length) {
    throw ArgumentError('clientIds must be unique.');
  }

  for (var i = 0; i < clientIds.length; i++) {
    final capacity = capacities[i];

    if (capacity < 0) {
      throw ArgumentError('Capacity cannot be negative.');
    }

    if (capacity > fleet.capFor(clientIds[i])) {
      throw ArgumentError(
        'Capacity for ${clientIds[i]} ($capacity) exceeds '
        'FleetModel.capFor() (${fleet.capFor(clientIds[i])}).',
      );
    }
  }

  final assignment = List<int>.filled(units.length, 0);
  final counts = List<int>.filled(clientIds.length, 0);
  final feasible = <_Point>[];

  void visit(int taskIndex) {
    if (taskIndex == units.length) {
      final objective = BatchObjectiveEvaluator.evaluate(
        fleet: fleet,
        units: units,
        clientIds: clientIds,
        capacities: capacities,
        assignment: List<int>.of(assignment),
      );

      feasible.add(
        _Point(objective.completionTime, objective.energy),
      );
      return;
    }

    for (var worker = 0; worker < clientIds.length; worker++) {
      if (counts[worker] >= capacities[worker]) continue;
      if (!fleet.isEligible(clientIds[worker])) continue;

      assignment[taskIndex] = worker;
      counts[worker]++;

      visit(taskIndex + 1);

      counts[worker]--;
    }
  }

  visit(0);
  return feasible;
}

/// Returns unique, non-dominated objective pairs.
///
/// Both makespan and energy are minimized.
List<_Point> _paretoFront(List<_Point> points) {
  final front = <_Point>[];

  for (final candidate in points) {
    final dominated = points.any((other) {
      final noWorse =
          other.makespan <= candidate.makespan &&
          other.energy <= candidate.energy;

      final strictlyBetter =
          other.makespan < candidate.makespan ||
          other.energy < candidate.energy;

      return noWorse && strictlyBetter;
    });

    if (dominated) continue;

    final duplicate = front.any(
      (point) =>
          point.makespan == candidate.makespan &&
          point.energy == candidate.energy,
    );

    if (!duplicate) {
      front.add(candidate);
    }
  }

  return front;
}

void main() {
  group('Exhaustive Pareto oracle', () {
    test('single worker has exactly one feasible assignment', () {
      final units = [
        _unit(0, 512 * 1024),
        _unit(1, 1024 * 1024),
      ];

      final fleet = FleetModel(
        {
          'worker-a': _client(
            procMs: 200,
            bandwidthKbps: 1000,
          ),
        },
        units,
        2,
      );

      final assignments = _enumerate(
        fleet: fleet,
        units: units,
        clientIds: const ['worker-a'],
        capacities: const [2],
      );

      expect(assignments, hasLength(1));

      final front = _paretoFront(assignments);

      expect(front, hasLength(1));
      expect(front.single.makespan, greaterThan(0));
      expect(front.single.energy, greaterThan(0));
    });

    test(
      'insufficient aggregate capacity produces no feasible assignments',
      () {
        final units = [
          _unit(0, 512 * 1024),
          _unit(1, 1024 * 1024),
        ];

        final fleet = FleetModel(
          {
            'worker-a': _client(
              procMs: 200,
              bandwidthKbps: 1000,
            ),
          },
          units,
          2,
        );

        final assignments = _enumerate(
          fleet: fleet,
          units: units,
          clientIds: const ['worker-a'],
          capacities: const [1],
        );

        expect(assignments, isEmpty);
        expect(_paretoFront(assignments), isEmpty);
      },
    );

    test('finds multiple non-dominated makespan-energy trade-offs', () {
      final units = [
        _unit(0, 1024 * 1024),
        _unit(1, 1024 * 1024),
      ];

      final fleet = FleetModel(
        {
          'worker-a': _client(
            procMs: 500,
            bandwidthKbps: 4000,
          ),
          'worker-b': _client(
            procMs: 100,
            bandwidthKbps: 500,
          ),
        },
        units,
        2,
      );

      final clientIds = const ['worker-a', 'worker-b'];

      // Use capacities allowed by the fleet model.
      final capacities = [
        fleet.capFor(clientIds[0]),
        fleet.capFor(clientIds[1]),
      ];

      final assignments = _enumerate(
        fleet: fleet,
        units: units,
        clientIds: clientIds,
        capacities: capacities,
      );

      expect(assignments, isNotEmpty);

      final front = _paretoFront(assignments);

      // This workload should yield multiple trade-offs. If it does not,
      // the workload or objective model needs investigation.
      expect(front.length, greaterThan(1));

      for (var i = 0; i < front.length; i++) {
        for (var j = 0; j < front.length; j++) {
          if (i == j) continue;

          final a = front[i];
          final b = front[j];

          final bDominatesA =
              b.makespan <= a.makespan &&
              b.energy <= a.energy &&
              (b.makespan < a.makespan ||
                  b.energy < a.energy);

          expect(bDominatesA, isFalse);
        }
      }
    });

    test('enumeration respects each worker capacity', () {
      final units = [
        _unit(0, 512 * 1024),
        _unit(1, 512 * 1024),
        _unit(2, 512 * 1024),
      ];

      final fleet = FleetModel(
        {
          'worker-a': _client(
            procMs: 200,
            bandwidthKbps: 1000,
          ),
          'worker-b': _client(
            procMs: 300,
            bandwidthKbps: 2000,
          ),
        },
        units,
        3,
      );

      final clientIds = const ['worker-a', 'worker-b'];

      // Cap A at one task, and B at two tasks, without exceeding
      // the capacities permitted by FleetModel.
      final capacities = [
        1,
        fleet.capFor('worker-b').clamp(0, 2),
      ];

      final assignments = _enumerate(
        fleet: fleet,
        units: units,
        clientIds: clientIds,
        capacities: capacities,
      );

      // With capacities [1, 2], exactly three assignments exist:
      // choose which task goes to A; B receives the other two.
      // If FleetModel permits less capacity, the oracle will correctly
      // enumerate fewer assignments instead.
      if (capacities[0] == 1 && capacities[1] == 2) {
        expect(assignments, hasLength(3));
      } else {
        expect(assignments, isNotEmpty);
      }
    });
  });
}