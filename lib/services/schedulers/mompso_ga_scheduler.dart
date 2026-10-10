import 'dart:math';

import '../models/assignment.dart';
import 'dynamic_scheduler.dart';
import 'pareto_archive.dart';
import 'scheduling_model.dart';

/// Batch-level MOMPSO-GA scheduler.
///
/// Each scheduling round is optimized once from the initial FleetModel
/// snapshot. Candidate vectors use one integer worker index per task. PSO
/// updates explore the assignment space; a bounded GA stage adds crossover and
/// mutation. Both objectives are minimized: estimated batch makespan and
/// marginal energy. The base class remains responsible for committing picks,
/// capacity checks, queue bookkeeping, and the normal gating policy.
class MOMPSOGAScheduler extends DynamicScheduler {
  final int population;
  final int iterations;
  final int offspringPerIteration;
  final int archiveSize;
  final double inertia;
  final double c1;
  final double c2;
  final double maxVelocity;
  final double crossoverRate;
  final double mutationRate;

  /// Number of complete candidate evaluations in the most recent plan.
  int lastEvaluationCount = 0;

  /// Number of tasks included in the most recent optimized batch.
  int lastPlanTaskCount = 0;

  MOMPSOGAScheduler({
    super.random,
    super.config,
    this.population = 12,
    this.iterations = 8,
    this.offspringPerIteration = 4,
    this.archiveSize = 30,
    this.inertia = 0.72,
    this.c1 = 1.49,
    this.c2 = 1.49,
    this.maxVelocity = 4.0,
    this.crossoverRate = 0.8,
    this.mutationRate = 0.05,
  })  : assert(population > 0),
        assert(iterations >= 0),
        assert(offspringPerIteration >= 0),
        assert(archiveSize > 0),
        assert(inertia >= 0),
        assert(c1 >= 0),
        assert(c2 >= 0),
        assert(maxVelocity > 0),
        assert(crossoverRate >= 0 && crossoverRate <= 1),
        assert(mutationRate >= 0 && mutationRate <= 1);

  @override
  String get id => 'mompso-ga';

  @override
  String get label => 'MOMPSO-GA';

  @override
  List<UnitPick>? planBatch(
    FleetModel fleet,
    List<Unit> remaining,
    List<String> open,
  ) {
    lastEvaluationCount = 0;
    lastPlanTaskCount = 0;
    if (remaining.isEmpty || open.isEmpty) return const <UnitPick>[];

    final clientIds = List<String>.of(open)..sort();
    final capacities = <int>[
      for (final client in clientIds)
        () {
          final view = fleet.views[client]!;
          final baseCap = max(0, fleet.capFor(client) - view.assigned);

          // Reduce this round's assignment capacity for clients that
          // already have substantial queued work.
          final queueFactor = 1.0 / (1.0 + 0.25 * view.pending);
          return min(baseCap, max(0, (baseCap * queueFactor).floor()));
        }(),
    ];
    final capacity = capacities.fold<int>(0, (sum, value) => sum + value);
    final taskCount = min(remaining.length, capacity);
    if (taskCount <= 0) return const <UnitPick>[];

    final problem = _HybridProblem(
      fleet: fleet,
      units: remaining.take(taskCount).toList(),
      clientIds: clientIds,
      capacities: capacities,
      onEvaluate: () => lastEvaluationCount++,
    );
    lastPlanTaskCount = taskCount;

    // A single worker has only one feasible assignment. Avoid unnecessary
    // stochastic search, while still counting its one complete evaluation.
    if (clientIds.length == 1) {
      final vector = List<int>.filled(taskCount, 0);
      problem.evaluate(vector);
      return _toPicks(problem, vector);
    }

    final archive = ParetoArchive(capacity: archiveSize);
    final positions = <List<int>>[];
    final velocities = <List<double>>[];
    final personalBest = <List<int>>[];
    final personalBestObjectives = <ParetoObjectives>[];

    for (var i = 0; i < population; i++) {
      final position = _randomFeasible(problem);
      final velocity = List<double>.generate(
        taskCount * clientIds.length,
        (_) => (random.nextDouble() * 2 - 1) * maxVelocity,
      );
      final objective = problem.evaluate(position);
      positions.add(position);
      velocities.add(velocity);
      personalBest.add(List<int>.of(position));
      personalBestObjectives.add(objective);
      archive.add(ParetoSolution(assignments: position, objectives: objective));
    }

    for (var iteration = 0; iteration < iterations; iteration++) {
      // PSO phase: one complete candidate evaluation per particle.
      for (var p = 0; p < population; p++) {
        final leader = archive.selectLeader(random).assignments;
        final scores = List.generate(
          taskCount,
          (task) => List<double>.filled(clientIds.length, 0),
        );
        for (var task = 0; task < taskCount; task++) {
          for (var worker = 0; worker < clientIds.length; worker++) {
            final d = task * clientIds.length + worker;
            final current = positions[p][task] == worker ? 1.0 : 0.0;
            final pbest = personalBest[p][task] == worker ? 1.0 : 0.0;
            final gbest = leader[task] == worker ? 1.0 : 0.0;
            var velocity = inertia * velocities[p][d] +
                c1 * random.nextDouble() * (pbest - current) +
                c2 * random.nextDouble() * (gbest - current);
            velocity = velocity.clamp(-maxVelocity, maxVelocity).toDouble();
            velocities[p][d] = velocity;
            scores[task][worker] = _sigmoid(velocity);
          }
        }
        final candidate = _repairByScores(scores, problem);
        final objective = problem.evaluate(candidate);
        positions[p] = candidate;
        archive.add(ParetoSolution(assignments: candidate, objectives: objective));
        if (_prefer(objective, personalBestObjectives[p], candidate, personalBest[p])) {
          personalBest[p] = List<int>.of(candidate);
          personalBestObjectives[p] = objective;
        }
      }

      // GA phase: fixed offspring budget, independent of population size.
      for (var childIndex = 0; childIndex < offspringPerIteration; childIndex++) {
        final a = _tournament(personalBest, personalBestObjectives);
        final b = _tournament(personalBest, personalBestObjectives);
        final parentA = personalBest[a];
        final parentB = personalBest[b];
        final child = List<int>.of(parentA);
        if (random.nextDouble() < crossoverRate) {
          for (var gene = 0; gene < taskCount; gene++) {
            if (random.nextBool()) child[gene] = parentB[gene];
          }
        }
        for (var gene = 0; gene < taskCount; gene++) {
          if (random.nextDouble() < mutationRate) {
            child[gene] = random.nextInt(clientIds.length);
          }
        }
        final feasibleChild = _repairVector(child, problem);
        final objective = problem.evaluate(feasibleChild);
        archive.add(ParetoSolution(assignments: feasibleChild, objectives: objective));
        // Replace the less competitive of the two sampled parents when the
        // child dominates it, or when neither dominates and seeded tie-break wins.
        final loser = _lessPreferred(a, b, personalBestObjectives);
        if (_prefer(objective, personalBestObjectives[loser], feasibleChild, personalBest[loser])) {
          personalBest[loser] = List<int>.of(feasibleChild);
          personalBestObjectives[loser] = objective;
          positions[loser] = List<int>.of(feasibleChild);
        }
      }
    }

    final selected = _selectFinal(archive.solutions);
    return _toPicks(problem, selected.assignments);
  }

  @override
  String pick(FleetModel fleet, List<String> open, Unit unit) {
    // Used only if a batch plan is unavailable; retain a safe live-data fallback.
    return DynamicScheduler.argmax(open, (id) => -fleet.etaMs(id, unit));
  }

  List<UnitPick> _toPicks(_HybridProblem problem, List<int> assignment) => [
        for (var i = 0; i < assignment.length; i++)
          UnitPick(problem.units[i], problem.clientIds[assignment[i]]),
      ];

  List<int> _randomFeasible(_HybridProblem problem) {
    final result = List<int>.filled(problem.units.length, -1);
    final capacities = List<int>.of(problem.capacities);
    final tasks = List<int>.generate(result.length, (i) => i)..shuffle(random);
    for (final task in tasks) {
      final available = [for (var i = 0; i < capacities.length; i++) if (capacities[i] > 0) i];
      if (available.isEmpty) throw StateError('MOMPSO-GA could not create a feasible assignment.');
      final worker = available[random.nextInt(available.length)];
      result[task] = worker;
      capacities[worker]--;
    }
    return result;
  }

  List<int> _repairByScores(List<List<double>> scores, _HybridProblem problem) {
    final order = List<int>.generate(scores.length, (i) => i)
      ..sort((a, b) => scores[b].reduce(max).compareTo(scores[a].reduce(max)));
    final result = List<int>.filled(scores.length, -1);
    final capacities = List<int>.of(problem.capacities);
    for (final task in order) {
      final choices = [for (var w = 0; w < capacities.length; w++) if (capacities[w] > 0) w]
        ..sort((a, b) {
          final cmp = scores[task][b].compareTo(scores[task][a]);
          return cmp != 0 ? cmp : problem.clientIds[a].compareTo(problem.clientIds[b]);
        });
      if (choices.isEmpty) throw StateError('MOMPSO-GA repair could not satisfy capacity constraints.');
      result[task] = choices.first;
      capacities[choices.first]--;
    }
    return result;
  }

  List<int> _repairVector(List<int> candidate, _HybridProblem problem) {
    final scores = List.generate(candidate.length, (task) => [
      for (var worker = 0; worker < problem.clientIds.length; worker++)
        candidate[task] == worker ? 1.0 : 0.0,
    ]);
    // Randomize exact ties so crossover/mutation can change which genes survive.
    for (final row in scores) {
      for (var i = 0; i < row.length; i++) {
        row[i] += random.nextDouble() * 1e-9;
      }
    }
    return _repairByScores(scores, problem);
  }

  int _tournament(List<List<int>> vectors, List<ParetoObjectives> objectives) {
    final a = random.nextInt(vectors.length);
    final b = random.nextInt(vectors.length);
    if (ParetoArchive.dominates(objectives[a], objectives[b])) return a;
    if (ParetoArchive.dominates(objectives[b], objectives[a])) return b;
    return random.nextBool() ? a : b;
  }

  int _lessPreferred(int a, int b, List<ParetoObjectives> objectives) {
    if (ParetoArchive.dominates(objectives[a], objectives[b])) return b;
    if (ParetoArchive.dominates(objectives[b], objectives[a])) return a;
    return random.nextBool() ? a : b;
  }

  bool _prefer(ParetoObjectives candidate, ParetoObjectives current, List<int> a, List<int> b) {
    if (ParetoArchive.dominates(candidate, current)) return true;
    if (ParetoArchive.dominates(current, candidate)) return false;
    final candidateScore = candidate.completionTime + candidate.energy;
    final currentScore = current.completionTime + current.energy;
    if (candidateScore != currentScore) return candidateScore < currentScore;
    for (var i = 0; i < min(a.length, b.length); i++) {
      if (a[i] != b[i]) return a[i] < b[i];
    }
    return false;
  }

  ParetoSolution _selectFinal(List<ParetoSolution> solutions) {
    if (solutions.isEmpty) throw StateError('MOMPSO-GA archive is empty.');
    if (solutions.length == 1) return solutions.first;
    final minTime = solutions.map((s) => s.objectives.completionTime).reduce(min);
    final maxTime = solutions.map((s) => s.objectives.completionTime).reduce(max);
    final minEnergy = solutions.map((s) => s.objectives.energy).reduce(min);
    final maxEnergy = solutions.map((s) => s.objectives.energy).reduce(max);
    ParetoSolution best = solutions.first;
    var bestDistance = double.infinity;
    for (final solution in solutions) {
      final t = maxTime > minTime ? (solution.objectives.completionTime - minTime) / (maxTime - minTime) : 0.0;
      final e = maxEnergy > minEnergy ? (solution.objectives.energy - minEnergy) / (maxEnergy - minEnergy) : 0.0;
      final distance = sqrt(t * t + e * e);
      if (distance < bestDistance || (distance == bestDistance && _lexicographicallySmaller(solution.assignments, best.assignments))) {
        best = solution;
        bestDistance = distance;
      }
    }
    return best;
  }

  bool _lexicographicallySmaller(List<int> a, List<int> b) {
    for (var i = 0; i < min(a.length, b.length); i++) {
      if (a[i] != b[i]) return a[i] < b[i];
    }
    return a.length < b.length;
  }

  double _sigmoid(double value) {
    if (value >= 0) {
      final z = exp(-value);
      return 1 / (1 + z);
    }
    final z = exp(value);
    return z / (1 + z);
  }
}

class _HybridProblem {
  final FleetModel fleet;
  final List<Unit> units;
  final List<String> clientIds;
  final List<int> capacities;
  final void Function() onEvaluate;

  _HybridProblem({
    required this.fleet,
    required this.units,
    required this.clientIds,
    required this.capacities,
    required this.onEvaluate,
  });

  ParetoObjectives evaluate(List<int> assignment) {
    onEvaluate();
    final loads = <String, double>{for (final id in clientIds) id: fleet.waitMs(id)};
    final initialWait = <String, double>{for (final id in clientIds) id: fleet.waitMs(id)};
    var energy = 0.0;
    for (var task = 0; task < units.length; task++) {
      final id = clientIds[assignment[task]];
      final service = max(0.0, fleet.etaMs(id, units[task]) - initialWait[id]!);
      loads[id] = loads[id]! + service;
      energy += fleet.energyJ(id);
    }
    return ParetoObjectives(
      completionTime: loads.values.isEmpty ? 0 : loads.values.reduce(max),
      energy: energy,
    );
  }
}