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
      fileUrl: 'http://benchmark/$index',
    );

ClientEstimate _client({
  required double procMs,
  required double bandwidthKbps,
  int pending = 0,
  double recentLatencyMs = 0,
  double cpuPct = 20,
  String deviceName = '',
}) =>
    ClientEstimate(
      ttprocMs: procMs,
      bandwidthKbps: bandwidthKbps,
      pending: pending,
      recentLatencyMs: recentLatencyMs,
      deviceName: deviceName,
      health: DeviceHealth(
        batteryPct: 80,
        charging: false,
        cpuPct: cpuPct,
      ),
    );

class _Scenario {
  final String name;
  final List<Unit> units;
  final Map<String, ClientEstimate> clients;
  final int maxUnitsPerAssign;

  const _Scenario({
    required this.name,
    required this.units,
    required this.clients,
    required this.maxUnitsPerAssign,
  });
}

class _ObjectivePoint {
  final double makespanMs;
  final double energyJ;

  const _ObjectivePoint(this.makespanMs, this.energyJ);

  @override
  String toString() =>
      '(${makespanMs.toStringAsFixed(2)} ms, ${energyJ.toStringAsFixed(4)} J)';
}

class _BenchmarkResult {
  final String scheduler;
  final int seed;
  final _ObjectivePoint objective;
  final double distanceToFront;
  final bool onExactFront;
  final double runtimeMs;

  const _BenchmarkResult({
    required this.scheduler,
    required this.seed,
    required this.objective,
    required this.distanceToFront,
    required this.onExactFront,
    required this.runtimeMs,
  });
}

class _ExactOracleResult {
  final List<_ObjectivePoint> feasiblePoints;
  final List<_ObjectivePoint> paretoFront;

  const _ExactOracleResult({
    required this.feasiblePoints,
    required this.paretoFront,
  });
}

_ExactOracleResult _buildExactOracle({
  required FleetModel fleet,
  required List<Unit> units,
  required List<String> clientIds,
  required List<int> capacities,
}) {
  final assignment = List<int>.filled(units.length, 0);
  final counts = List<int>.filled(clientIds.length, 0);
  final objectives = <_ObjectivePoint>[];

  void visit(int task) {
    if (task == units.length) {
      final result = BatchObjectiveEvaluator.evaluate(
        fleet: fleet,
        units: units,
        clientIds: clientIds,
        capacities: capacities,
        assignment: List<int>.of(assignment),
      );
      objectives.add(_ObjectivePoint(result.completionTime, result.energy));
      return;
    }

    for (var worker = 0; worker < clientIds.length; worker++) {
      if (counts[worker] >= capacities[worker]) continue;
      if (!fleet.isEligible(clientIds[worker])) continue;

      assignment[task] = worker;
      counts[worker]++;
      visit(task + 1);
      counts[worker]--;
    }
  }

  visit(0);

  final front = <_ObjectivePoint>[];
  for (final candidate in objectives) {
    final dominated = objectives.any((other) {
      final noWorse = other.makespanMs <= candidate.makespanMs &&
          other.energyJ <= candidate.energyJ;
      final strictlyBetter = other.makespanMs < candidate.makespanMs ||
          other.energyJ < candidate.energyJ;
      return noWorse && strictlyBetter;
    });
    if (dominated) continue;

    final duplicate = front.any((point) =>
        point.makespanMs == candidate.makespanMs &&
        point.energyJ == candidate.energyJ);
    if (!duplicate) front.add(candidate);
  }

  return _ExactOracleResult(
    feasiblePoints: List.unmodifiable(objectives),
    paretoFront: List.unmodifiable(front),
  );
}

/// Calculates Euclidean distance to the nearest Pareto point after normalizing
/// both objectives with ranges from ALL feasible assignments, not only the
/// Pareto front. This prevents a one-point front or a zero-range front
/// objective from making a worse result appear to have distance zero.
double _distanceToFront(
  _ObjectivePoint point,
  List<_ObjectivePoint> front,
  List<_ObjectivePoint> feasiblePoints,
) {
  if (front.isEmpty) throw StateError('Exact Pareto front is empty.');
  if (feasiblePoints.isEmpty) {
    throw StateError('Exact feasible objective set is empty.');
  }

  final minTime = feasiblePoints.map((p) => p.makespanMs).reduce(min);
  final maxTime = feasiblePoints.map((p) => p.makespanMs).reduce(max);
  final minEnergy = feasiblePoints.map((p) => p.energyJ).reduce(min);
  final maxEnergy = feasiblePoints.map((p) => p.energyJ).reduce(max);
  final timeRange = maxTime - minTime;
  final energyRange = maxEnergy - minEnergy;

  double normalizedDifference(double difference, double range, double scale) {
    if (range > 1e-12) return difference / range;
    // For a truly constant objective across all feasible assignments, a valid
    // candidate has zero difference. The fallback also keeps any unexpected
    // out-of-space candidate from being silently assigned zero contribution.
    if (difference.abs() <= 1e-9) return 0.0;
    return difference / max(scale.abs(), 1.0);
  }

  return front.map((candidate) {
    final dt = normalizedDifference(
      point.makespanMs - candidate.makespanMs,
      timeRange,
      max(minTime.abs(), maxTime.abs()),
    );
    final de = normalizedDifference(
      point.energyJ - candidate.energyJ,
      energyRange,
      max(minEnergy.abs(), maxEnergy.abs()),
    );
    return sqrt(dt * dt + de * de);
  }).reduce(min);
}

bool _isOnFront(_ObjectivePoint point, List<_ObjectivePoint> front) =>
    front.any((candidate) {
      const tolerance = 1e-6;
      return (candidate.makespanMs - point.makespanMs).abs() <= tolerance &&
          (candidate.energyJ - point.energyJ).abs() <= tolerance;
    });

_BenchmarkResult _runOne({
  required Scheduler scheduler,
  required int seed,
  required List<Unit> units,
  required Map<String, ClientEstimate> clients,
  required int maxUnitsPerAssign,
  required List<String> clientIds,
  required List<int> capacities,
  required List<_ObjectivePoint> exactFront,
  required List<_ObjectivePoint> feasiblePoints,
}) {
  final stopwatch = Stopwatch()..start();
  final assignments = scheduler.schedule(
    List<Unit>.of(units),
    Map<String, ClientEstimate>.of(clients),
    maxUnitsPerAssign,
  );
  stopwatch.stop();

  final unitToWorker = <int, int>{};
  for (var worker = 0; worker < clientIds.length; worker++) {
    final clientId = clientIds[worker];
    final assignedUnits = assignments[clientId] ?? const <Unit>[];
    expect(
      assignedUnits.length,
      lessThanOrEqualTo(capacities[worker]),
      reason: '${scheduler.id} exceeded capacity for $clientId',
    );

    for (final unit in assignedUnits) {
      expect(
        units.any((candidate) => candidate.unitIndex == unit.unitIndex),
        isTrue,
        reason: '${scheduler.id} returned a unit outside the benchmark batch',
      );
      expect(
        unitToWorker.containsKey(unit.unitIndex),
        isFalse,
        reason: '${scheduler.id} assigned a unit more than once',
      );
      unitToWorker[unit.unitIndex] = worker;
    }
  }

  expect(
    unitToWorker.length,
    units.length,
    reason: '${scheduler.id} did not assign every benchmark unit',
  );

  final vector = [for (final unit in units) unitToWorker[unit.unitIndex]!];
  final fleet = FleetModel(clients, units, maxUnitsPerAssign);
  final objective = BatchObjectiveEvaluator.evaluate(
    fleet: fleet,
    units: units,
    clientIds: clientIds,
    capacities: capacities,
    assignment: vector,
  );
  final point = _ObjectivePoint(objective.completionTime, objective.energy);

  expect(point.makespanMs.isFinite, isTrue);
  expect(point.energyJ.isFinite, isTrue);
  expect(point.makespanMs, greaterThanOrEqualTo(0));
  expect(point.energyJ, greaterThanOrEqualTo(0));

  return _BenchmarkResult(
    scheduler: scheduler.id,
    seed: seed,
    objective: point,
    distanceToFront: _distanceToFront(point, exactFront, feasiblePoints),
    onExactFront: _isOnFront(point, exactFront),
    runtimeMs: stopwatch.elapsedMicroseconds / 1000.0,
  );
}

List<_Scenario> _scenarios() {
  final scenarios = <_Scenario>[
      _Scenario(
        name: 'heterogeneous transfer and compute',
        units: [
          _unit(0, 64 * 1024),
          _unit(1, 256 * 1024),
          _unit(2, 1024 * 1024),
          _unit(3, 384 * 1024),
        ],
        clients: {
          'worker-fast-cpu': _client(
            procMs: 80,
            bandwidthKbps: 700,
            deviceName: 'fast-cpu',
          ),
          'worker-fast-network': _client(
            procMs: 260,
            bandwidthKbps: 6000,
            deviceName: 'fast-network',
          ),
          'worker-balanced': _client(
            procMs: 150,
            bandwidthKbps: 2200,
            deviceName: 'balanced',
          ),
        },
        maxUnitsPerAssign: 2,
      ),
      _Scenario(
        name: 'existing queue and measured latency',
        units: [
          _unit(10, 128 * 1024),
          _unit(11, 768 * 1024),
          _unit(12, 512 * 1024),
          _unit(13, 1024 * 1024),
        ],
        clients: {
          'worker-queued': _client(
            procMs: 100,
            bandwidthKbps: 3000,
            pending: 2,
            recentLatencyMs: 850,
            deviceName: 'queued-worker',
          ),
          'worker-idle': _client(
            procMs: 180,
            bandwidthKbps: 1800,
            deviceName: 'idle-worker',
          ),
          'worker-slow': _client(
            procMs: 350,
            bandwidthKbps: 900,
            recentLatencyMs: 500,
            deviceName: 'slow-worker',
          ),
        },
        maxUnitsPerAssign: 2,
      ),
      _Scenario(
        name: 'tight per-worker capacity',
        units: [
          _unit(20, 96 * 1024),
          _unit(21, 192 * 1024),
          _unit(22, 384 * 1024),
        ],
        clients: {
          'worker-a': _client(procMs: 120, bandwidthKbps: 2500),
          'worker-b': _client(procMs: 240, bandwidthKbps: 5000),
          'worker-c': _client(procMs: 190, bandwidthKbps: 1400),
        },
        maxUnitsPerAssign: 1,
      ),
      _Scenario(
        name: 'near-homogeneous workers with uneven task sizes',
        units: [
          _unit(30, 48 * 1024),
          _unit(31, 128 * 1024),
          _unit(32, 512 * 1024),
          _unit(33, 1536 * 1024),
        ],
        clients: {
          'worker-1': _client(procMs: 180, bandwidthKbps: 2200),
          'worker-2': _client(procMs: 190, bandwidthKbps: 2100),
          'worker-3': _client(procMs: 175, bandwidthKbps: 2300),
        },
        maxUnitsPerAssign: 2,
      ),
    ];
  scenarios.addAll(_randomizedScenarios());
  return scenarios;
}

/// Fixed-seed generated workloads. The data varies across task sizes, worker
/// speeds, queues, and measured latency while keeping exhaustive enumeration
/// tractable (4 workers, 5 tasks, and a per-worker cap of 2).
List<_Scenario> _randomizedScenarios() {
  final random = Random(20261017);
  final scenarios = <_Scenario>[];
  for (var scenarioIndex = 0; scenarioIndex < 4; scenarioIndex++) {
    final baseUnit = 100 + scenarioIndex * 10;
    final units = <Unit>[
      for (var task = 0; task < 5; task++)
        _unit(baseUnit + task, (32 + random.nextInt(1500)) * 1024),
    ];
    final clients = <String, ClientEstimate>{};
    for (var worker = 0; worker < 4; worker++) {
      final pending = random.nextInt(3);
      clients['generated-$scenarioIndex-worker-$worker'] = _client(
        procMs: (80 + random.nextInt(321)).toDouble(),
        bandwidthKbps: (500 + random.nextInt(5001)).toDouble(),
        pending: pending,
        recentLatencyMs: random.nextBool()
            ? (200 + random.nextInt(1201)).toDouble()
            : 0,
        cpuPct: (10 + random.nextInt(81)).toDouble(),
        deviceName: 'generated-worker-$worker',
      );
    }
    scenarios.add(_Scenario(
      name: 'generated workload ${scenarioIndex + 1}',
      units: units,
      clients: clients,
      maxUnitsPerAssign: 2,
    ));
  }
  return scenarios;
}

void main() {
  group('MOMPSO convergence diagnostics', () {
    test('traces archive quality and swarm diversity for existing-queue scenario', () {
      final scenario = _scenarios().singleWhere(
        (item) => item.name == 'existing queue and measured latency',
      );
      final fleet = FleetModel(
        scenario.clients,
        scenario.units,
        scenario.maxUnitsPerAssign,
      );
      final clientIds = List<String>.of(fleet.eligibleIds)..sort();
      final capacities = [for (final id in clientIds) fleet.capFor(id)];
      final oracle = _buildExactOracle(
        fleet: fleet,
        units: scenario.units,
        clientIds: clientIds,
        capacities: capacities,
      );
      final trace = <MOMPSOIterationDiagnostics>[];
      final scheduler = MOMPSOScheduler(
        random: Random(0),
        onIterationDiagnostics: trace.add,
      );

      scheduler.schedule(
        List<Unit>.of(scenario.units),
        Map<String, ClientEstimate>.of(scenario.clients),
        scenario.maxUnitsPerAssign,
      );

      final firstCall = trace.where((item) => item.optimizationCall == 0).toList();
      expect(firstCall, isNotEmpty, reason: 'No MOMPSO iteration diagnostics emitted.');
      expect(firstCall.first.iteration, 0);
      expect(firstCall.last.iteration, scheduler.iterations);

      print('\n=== MOMPSO convergence: ${scenario.name}, seed=0 ===');
      print('Exact Pareto front: ${oracle.paretoFront}');
      for (final snapshot in firstCall) {
        final archivePoints = snapshot.archiveSolutions.map((solution) =>
          _ObjectivePoint(
            solution.objectives.completionTime,
            solution.objectives.energy,
          ),
        ).toList();
        final bestDistance = archivePoints.isEmpty
            ? double.infinity
            : archivePoints.map((point) => _distanceToFront(
                  point,
                  oracle.paretoFront,
                  oracle.feasiblePoints,
                )).reduce(min);
        final frontHits = archivePoints.where((point) =>
          _isOnFront(point, oracle.paretoFront)).length;
        final leaderSummary = snapshot.leaderSelectionCounts.entries
            .map((entry) => '${entry.key}:${entry.value}')
            .join(' ');
        print(
          'call=${snapshot.optimizationCall} iter=${snapshot.iteration} '
          'archive=${snapshot.archiveSolutions.length} '
          'bestDistance=${bestDistance.toStringAsFixed(4)} '
          'frontHits=$frontHits '
          'uniqueCurrent=${snapshot.uniqueCurrentAssignments} '
          'uniquePBest=${snapshot.uniquePersonalBestAssignments} '
          'leaders={$leaderSummary}',
        );
      }

      expect(
        firstCall.every((snapshot) =>
          snapshot.uniqueCurrentAssignments <= scheduler.particles &&
          snapshot.uniquePersonalBestAssignments <= scheduler.particles),
        isTrue,
      );
    });
    test('returns the same batch assignment selected from its final archive', () {
      final scenario = _scenarios().singleWhere(
        (item) => item.name == 'existing queue and measured latency',
      );
      final trace = <MOMPSOIterationDiagnostics>[];
      final scheduler = MOMPSOScheduler(
        random: Random(0),
        onIterationDiagnostics: trace.add,
      );

      final assignments = scheduler.schedule(
        List<Unit>.of(scenario.units),
        Map<String, ClientEstimate>.of(scenario.clients),
        scenario.maxUnitsPerAssign,
      );

      // A batch plan must optimize once, then preserve that full assignment
      // instead of combining decisions from multiple optimization snapshots.
      expect(trace.map((item) => item.optimizationCall).toSet(), hasLength(1));
      expect(trace, isNotEmpty);
      final finalArchive = trace.last.archiveSolutions;

      final fleet = FleetModel(
        scenario.clients,
        scenario.units,
        scenario.maxUnitsPerAssign,
      );
      final clientIds = List<String>.of(fleet.eligibleIds)..sort();
      final capacities = [for (final id in clientIds) fleet.capFor(id)];
      final unitToWorker = <int, int>{};
      for (var worker = 0; worker < clientIds.length; worker++) {
        for (final unit in assignments[clientIds[worker]] ?? const <Unit>[]) {
          unitToWorker[unit.unitIndex] = worker;
        }
      }
      expect(unitToWorker.length, scenario.units.length);

      final assignment = [
        for (final unit in scenario.units) unitToWorker[unit.unitIndex]!,
      ];
      final objective = BatchObjectiveEvaluator.evaluate(
        fleet: fleet,
        units: scenario.units,
        clientIds: clientIds,
        capacities: capacities,
        assignment: assignment,
      );

      expect(
        finalArchive.any((solution) =>
          (solution.objectives.completionTime - objective.completionTime).abs() <= 1e-6 &&
          (solution.objectives.energy - objective.energy).abs() <= 1e-6),
        isTrue,
        reason: 'The returned schedule objective must match a solution in the final MOMPSO archive.',
      );
    });
  });

  group('Scheduler comparison against exact Pareto fronts', () {
    test('distance remains positive for a worse point with a one-point front', () {
      const frontPoint = _ObjectivePoint(500.0, 2.0);
      const worsePoint = _ObjectivePoint(625.0, 2.0);
      const feasible = <_ObjectivePoint>[
        _ObjectivePoint(500.0, 2.0),
        _ObjectivePoint(750.0, 2.0),
      ];

      final distance = _distanceToFront(
        worsePoint,
        const [frontPoint],
        feasible,
      );

      expect(distance, greaterThan(0.0));
      expect(_isOnFront(worsePoint, const [frontPoint]), isFalse);
    });

    for (final scenario in _scenarios()) {
      test('${scenario.name}: feasible schedules and objective comparison', () {
        final initialFleet = FleetModel(
          scenario.clients,
          scenario.units,
          scenario.maxUnitsPerAssign,
        );
        final clientIds = List<String>.of(initialFleet.eligibleIds)..sort();
        expect(clientIds, isNotEmpty, reason: 'Scenario has no eligible workers.');

        final capacities = [
          for (final id in clientIds) initialFleet.capFor(id),
        ];
        final totalCapacity = capacities.fold<int>(0, (sum, cap) => sum + cap);
        final taskCount = min(scenario.units.length, totalCapacity);
        final units = scenario.units.take(taskCount).toList();
        expect(units, isNotEmpty, reason: 'Scenario has no schedulable tasks.');

        // Rebuild the fleet against exactly the workload being benchmarked so
        // the oracle and schedulers share the same task set and capacity model.
        final fleet = FleetModel(
          scenario.clients,
          units,
          scenario.maxUnitsPerAssign,
        );
        final oracleClientIds = List<String>.of(fleet.eligibleIds)..sort();
        final oracleCapacities = [
          for (final id in oracleClientIds) fleet.capFor(id),
        ];
        final oracleCapacity =
            oracleCapacities.fold<int>(0, (sum, cap) => sum + cap);
        final oracleTaskCount = min(scenario.units.length, oracleCapacity);
        final benchmarkUnits = scenario.units.take(oracleTaskCount).toList();

        final oracleFleet = FleetModel(
          scenario.clients,
          benchmarkUnits,
          scenario.maxUnitsPerAssign,
        );
        final exactClientIds = List<String>.of(oracleFleet.eligibleIds)..sort();
        final exactCapacities = [
          for (final id in exactClientIds) oracleFleet.capFor(id),
        ];
        final oracle = _buildExactOracle(
          fleet: oracleFleet,
          units: benchmarkUnits,
          clientIds: exactClientIds,
          capacities: exactCapacities,
        );
        final exactFront = oracle.paretoFront;
        final feasiblePoints = oracle.feasiblePoints;
        expect(exactFront, isNotEmpty, reason: 'Oracle front is empty.');
        expect(feasiblePoints, isNotEmpty, reason: 'Oracle feasible set is empty.');

        final results = <_BenchmarkResult>[];
        results.add(
          _runOne(
            scheduler: GreedyScheduler(random: Random(7)),
            seed: 7,
            units: benchmarkUnits,
            clients: scenario.clients,
            maxUnitsPerAssign: scenario.maxUnitsPerAssign,
            clientIds: exactClientIds,
            capacities: exactCapacities,
            exactFront: exactFront,
            feasiblePoints: feasiblePoints,
          ),
        );

        for (var seed = 0; seed < 30; seed++) {
          results.add(
            _runOne(
              scheduler: MOMPSOScheduler(random: Random(seed)),
              seed: seed,
              units: benchmarkUnits,
              clients: scenario.clients,
              maxUnitsPerAssign: scenario.maxUnitsPerAssign,
              clientIds: exactClientIds,
              capacities: exactCapacities,
              exactFront: exactFront,
              feasiblePoints: feasiblePoints,
            ),
          );
          results.add(
            _runOne(
              scheduler: MOMPSOGAScheduler(random: Random(seed)),
              seed: seed,
              units: benchmarkUnits,
              clients: scenario.clients,
              maxUnitsPerAssign: scenario.maxUnitsPerAssign,
              clientIds: exactClientIds,
              capacities: exactCapacities,
              exactFront: exactFront,
              feasiblePoints: feasiblePoints,
            ),
          );
        }

        print('\n=== Scenario: ${scenario.name} ===');
        print('Tasks=${benchmarkUnits.length}, workers=${exactClientIds.length}');
        print('Feasible assignments: ${feasiblePoints.length}');
        print('Exact Pareto front (${exactFront.length} points): $exactFront');
        for (final result in results) {
          print(
            '${result.scheduler} seed=${result.seed}: ${result.objective}, '
            'distance=${result.distanceToFront.toStringAsFixed(4)}, '
            'onFront=${result.onExactFront}, '
            'runtime=${result.runtimeMs.toStringAsFixed(3)} ms',
          );
        }

        for (final schedulerName in ['mompso', 'mompso-ga']) {
          final stochastic = results
              .where((result) => result.scheduler == schedulerName)
              .toList();
          final frontHits = stochastic.where((result) => result.onExactFront).length;
          final meanDistance = stochastic
                  .map((result) => result.distanceToFront)
                  .reduce((a, b) => a + b) /
              stochastic.length;
          final meanRuntimeMs = stochastic
                  .map((result) => result.runtimeMs)
                  .reduce((a, b) => a + b) /
              stochastic.length;
          print(
            'SUMMARY $schedulerName: frontHits=$frontHits/${stochastic.length} '
            '(${(100 * frontHits / stochastic.length).toStringAsFixed(1)}%), '
            'meanDistance=${meanDistance.toStringAsFixed(4)}, '
            'meanRuntime=${meanRuntimeMs.toStringAsFixed(3)} ms',
          );
        }

        expect(results, hasLength(61));
      });
    }
  });
}