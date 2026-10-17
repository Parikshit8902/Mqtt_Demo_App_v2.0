import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/models/assignment.dart';
import 'package:mqtt_demo/services/models/device_health.dart';
import 'package:mqtt_demo/services/models/result_dto.dart';
import 'package:mqtt_demo/services/schedulers/batch_objective_evaluator.dart';
import 'package:mqtt_demo/services/schedulers/greedy_scheduler.dart';
import 'package:mqtt_demo/services/schedulers/mompso_ga_scheduler.dart';
import 'package:mqtt_demo/services/schedulers/mompso_scheduler.dart';
import 'package:mqtt_demo/services/schedulers/scheduler.dart';
import 'package:mqtt_demo/services/schedulers/scheduling_model.dart';

Unit _unit(int index, int bytes) => Unit(
      unitIndex: index,
      start: 0,
      end: bytes - 1,
      fileUrl: 'http://scalability-benchmark/$index',
    );

ClientEstimate _client({
  required double procMs,
  required double bandwidthKbps,
  required int pending,
  required double recentLatencyMs,
  required double cpuPct,
  required String deviceName,
}) =>
    ClientEstimate(
      ttprocMs: procMs,
      bandwidthKbps: bandwidthKbps,
      pending: pending,
      recentLatencyMs: recentLatencyMs,
      deviceName: deviceName,
      health: DeviceHealth(
        batteryPct: 70,
        charging: false,
        cpuPct: cpuPct,
      ),
    );

class _Workload {
  final String name;
  final int taskCount;
  final int workerCount;
  final int maxUnitsPerWorker;
  final int seed;

  const _Workload(this.name, this.taskCount, this.workerCount,
      this.maxUnitsPerWorker, this.seed);
}

_Workload _workloadFor(int index) {
  const definitions = <_Workload>[
    _Workload('8 tasks / 4 workers', 8, 4, 3, 9101),
    _Workload('10 tasks / 4 workers', 10, 4, 4, 9102),
    _Workload('10 tasks / 5 workers', 10, 5, 3, 9103),
    _Workload('12 tasks / 4 workers', 12, 4, 12, 9104), // Ensure aggregate effective capacity can cover all 12 tasks.
    _Workload('12 tasks / 5 workers', 12, 5, 4, 9105),
    _Workload('12 tasks / 6 workers', 12, 6, 3, 9106),
  ];
  return definitions[index];
}

({List<Unit> units, Map<String, ClientEstimate> clients}) _makeProblem(
    _Workload workload) {
  final random = Random(workload.seed);
  final units = <Unit>[];
  for (var i = 0; i < workload.taskCount; i++) {
    // Broad but bounded task-size distribution: 64 KiB to approximately 2 MiB.
    final sizeKiB = 64 + random.nextInt(1985);
    units.add(_unit(i, sizeKiB * 1024));
  }

  final clients = <String, ClientEstimate>{};
  for (var i = 0; i < workload.workerCount; i++) {
    final id = 'worker_$i';
    clients[id] = _client(
      procMs: 90 + random.nextInt(850).toDouble(),
      bandwidthKbps: 350 + random.nextInt(2650).toDouble(),
      pending: random.nextInt(4),
      recentLatencyMs: random.nextInt(3) == 0
          ? 250 + random.nextInt(1600).toDouble()
          : 0,
      cpuPct: 10 + random.nextInt(75).toDouble(),
      deviceName: id,
    );
  }
  return (units: units, clients: clients);
}

class _RunStats {
  final double runtimeMs;
  final double makespanMs;
  final double energyJ;

  const _RunStats(this.runtimeMs, this.makespanMs, this.energyJ);
}

_RunStats _runAndValidate({
  required Scheduler scheduler,
  required List<Unit> units,
  required Map<String, ClientEstimate> clients,
  required int maxUnitsPerWorker,
}) {
  // Only the scheduler call is timed. Validation and objective evaluation are
  // deliberately outside the timed interval.
  final watch = Stopwatch()..start();
  final result = scheduler.schedule(
    List<Unit>.of(units),
    Map<String, ClientEstimate>.of(clients),
    maxUnitsPerWorker,
  );
  watch.stop();
  final runtimeMs = watch.elapsedMicroseconds / 1000.0;

  final unitIds = units.map((u) => u.unitIndex).toSet();
  final assigned = <int, String>{};
  for (final entry in clients.entries) {
    final workerUnits = result[entry.key] ?? const <Unit>[];
    expect(workerUnits.length, lessThanOrEqualTo(maxUnitsPerWorker),
        reason: '${scheduler.id} exceeded capacity for ${entry.key}');
    for (final unit in workerUnits) {
      expect(unitIds.contains(unit.unitIndex), isTrue,
          reason: '${scheduler.id} returned an unknown unit');
      expect(assigned.containsKey(unit.unitIndex), isFalse,
          reason: '${scheduler.id} assigned a unit more than once');
      assigned[unit.unitIndex] = entry.key;
    }
  }
  expect(assigned.length, units.length,
      reason: '${scheduler.id} did not assign every task');

  final clientIds = clients.keys.toList()..sort();
  final assignment = <int>[];
  for (final unit in units) {
    final workerId = assigned[unit.unitIndex];
    expect(workerId, isNotNull);
    assignment.add(clientIds.indexOf(workerId!));
  }
  final fleet = FleetModel(clients, units, maxUnitsPerWorker);
  final capacities = List<int>.filled(clientIds.length, maxUnitsPerWorker);
  final objective = BatchObjectiveEvaluator.evaluate(
    fleet: fleet,
    units: units,
    clientIds: clientIds,
    capacities: capacities,
    assignment: assignment,
  );
  expect(objective.completionTime.isFinite, isTrue);
  expect(objective.energy.isFinite, isTrue);
  expect(objective.completionTime, greaterThanOrEqualTo(0));
  expect(objective.energy, greaterThanOrEqualTo(0));
  return _RunStats(runtimeMs, objective.completionTime, objective.energy);
}

void main() {
  group('Scheduler scalability and feasibility (no exhaustive oracle)', () {
    for (var workloadIndex = 0; workloadIndex < 6; workloadIndex++) {
      final workload = _workloadFor(workloadIndex);
      test('${workload.name}: all schedulers return feasible complete batches', () {
        final problem = _makeProblem(workload);
        final runs = <String, List<_RunStats>>{
          'greedy': [],
          'mompso': [],
          'mompso-ga': [],
        };

        // Use repeated seeds for stochastic optimizers; Greedy is measured once
        // because its result is deterministic for a fixed input ordering.
        runs['greedy']!.add(_runAndValidate(
          scheduler: GreedyScheduler(random: Random(7)),
          units: problem.units,
          clients: problem.clients,
          maxUnitsPerWorker: workload.maxUnitsPerWorker,
        ));
        for (var seed = 0; seed < 10; seed++) {
          runs['mompso']!.add(_runAndValidate(
            scheduler: MOMPSOScheduler(random: Random(seed)),
            units: problem.units,
            clients: problem.clients,
            maxUnitsPerWorker: workload.maxUnitsPerWorker,
          ));
          runs['mompso-ga']!.add(_runAndValidate(
            scheduler: MOMPSOGAScheduler(random: Random(seed)),
            units: problem.units,
            clients: problem.clients,
            maxUnitsPerWorker: workload.maxUnitsPerWorker,
          ));
        }

        print('\n=== Scalability: ${workload.name} ===');
        print('Tasks=${workload.taskCount}, workers=${workload.workerCount}, '
            'maxUnitsPerWorker=${workload.maxUnitsPerWorker}');
        for (final entry in runs.entries) {
          final samples = entry.value;
          final meanRuntime = samples.map((s) => s.runtimeMs).reduce((a, b) => a + b) /
              samples.length;
          final minRuntime = samples.map((s) => s.runtimeMs).reduce(min);
          final maxRuntime = samples.map((s) => s.runtimeMs).reduce(max);
          final meanMakespan = samples.map((s) => s.makespanMs).reduce((a, b) => a + b) /
              samples.length;
          final meanEnergy = samples.map((s) => s.energyJ).reduce((a, b) => a + b) /
              samples.length;
          print('SUMMARY ${entry.key}: runs=${samples.length}, '
              'meanRuntime=${meanRuntime.toStringAsFixed(3)} ms, '
              'minRuntime=${minRuntime.toStringAsFixed(3)} ms, '
              'maxRuntime=${maxRuntime.toStringAsFixed(3)} ms, '
              'meanMakespan=${meanMakespan.toStringAsFixed(2)} ms, '
              'meanEnergy=${meanEnergy.toStringAsFixed(4)} J');
        }
      });
    }
  });
}