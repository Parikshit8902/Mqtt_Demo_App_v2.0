import 'dart:math';

import '../models/assignment.dart';
import 'pareto_archive.dart';
import 'scheduling_model.dart';

/// Shared objective evaluator for complete candidate batches.
///
/// Both MOMPSO and MOMPSO-GA must use this implementation so the same
/// assignment vector receives the same makespan and energy values.
class BatchObjectiveEvaluator {
  BatchObjectiveEvaluator._();

  /// Evaluates a worker-index assignment vector.
  ///
  /// [assignment][taskIndex] is an index into [clientIds]. [capacities] are
  /// each worker's remaining capacity for this scheduling round.
  ///
  /// Throws [ArgumentError] when the vector is malformed or infeasible.
  static ParetoObjectives evaluate({
    required FleetModel fleet,
    required List<Unit> units,
    required List<String> clientIds,
    required List<int> capacities,
    required List<int> assignment,
  }) {
    _validate(
      fleet: fleet,
      units: units,
      clientIds: clientIds,
      capacities: capacities,
      assignment: assignment,
    );

    final initialWait = <String, double>{
      for (final id in clientIds) id: fleet.waitMs(id),
    };
    final loads = Map<String, double>.of(initialWait);
    final assignedCounts = <String, int>{for (final id in clientIds) id: 0};
    var energyJ = 0.0;

    for (var task = 0; task < units.length; task++) {
      final id = clientIds[assignment[task]];
      final serviceMs = max(
        0.0,
        fleet.etaMs(id, units[task]) - initialWait[id]!,
      );
      loads[id] = loads[id]! + serviceMs;

      final view = fleet.views[id]!;
      // Existing pending work is a proxy for an already-active radio session.
      // Within this candidate batch, only the first task on an initially idle
      // worker pays startup/tail overhead; every task still pays transfer and
      // compute energy.
      final radioWarm = view.pending + assignedCounts[id]! > 0;
      energyJ += EnergyEstimator.unitEnergyJ(
        power: view.power,
        procMs: view.procMs,
        cpuUtil: max(
          fleet.cfg.nominalUtilization,
          (view.est.health.cpuPct ?? 0) / 100.0,
        ),
        radioWarm: radioWarm,
      );
      assignedCounts[id] = assignedCounts[id]! + 1;
    }

    final makespanMs = loads.values.isEmpty ? 0.0 : loads.values.reduce(max);
    return ParetoObjectives(
      completionTime: makespanMs,
      energy: energyJ,
    );
  }

  static void _validate({
    required FleetModel fleet,
    required List<Unit> units,
    required List<String> clientIds,
    required List<int> capacities,
    required List<int> assignment,
  }) {
    if (assignment.length != units.length) {
      throw ArgumentError.value(
        assignment.length,
        'assignment.length',
        'Must equal units.length (${units.length}).',
      );
    }
    if (clientIds.length != capacities.length) {
      throw ArgumentError('clientIds and capacities must have equal lengths.');
    }
    if (clientIds.toSet().length != clientIds.length) {
      throw ArgumentError('clientIds must not contain duplicates.');
    }

    for (var worker = 0; worker < clientIds.length; worker++) {
      final id = clientIds[worker];
      if (!fleet.views.containsKey(id)) {
        throw ArgumentError('Unknown worker id: $id.');
      }
      if (!fleet.isEligible(id)) {
        throw ArgumentError('Worker $id is not eligible.');
      }
      if (capacities[worker] < 0) {
        throw ArgumentError('Capacity for worker $id cannot be negative.');
      }
    }

    final counts = List<int>.filled(clientIds.length, 0);
    for (var task = 0; task < assignment.length; task++) {
      final worker = assignment[task];
      if (worker < 0 || worker >= clientIds.length) {
        throw ArgumentError('Invalid worker index $worker for task $task.');
      }
      counts[worker]++;
    }

    for (var worker = 0; worker < counts.length; worker++) {
      if (counts[worker] > capacities[worker]) {
        throw ArgumentError(
          'Assignment exceeds capacity for worker ${clientIds[worker]}: '
          '${counts[worker]} tasks assigned, capacity ${capacities[worker]}.',
        );
      }
    }
  }
}