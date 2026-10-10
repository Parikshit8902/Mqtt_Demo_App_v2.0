import 'dart:math';
import 'pareto_archive.dart';
import '../models/assignment.dart';
import 'dynamic_scheduler.dart';
import 'scheduling_model.dart';

/// Multi-objective Particle Swarm Optimization scheduler.
///
/// The scheduler treats completion time and energy consumption as separate
/// objectives:
///
///   f1(X) = makespan(X)
///   f2(X) = energy(X)
///
/// A solution is preferred only when it Pareto-dominates another solution.
/// A bounded archive stores the non-dominated solutions found by the swarm.
///
/// The task assignment is represented as:
///
///   assignment[j] = i
///
/// meaning task j is assigned to worker i.
///
/// Internally, the PSO maintains a binary/discrete representation using
/// one-hot assignment probabilities:
///
///   x_ij = 1  iff task j is assigned to worker i
///
/// and updates a velocity matrix:
///
///   v_ij(t+1) =
///       w  * v_ij(t)
///     + c1 * r1 * (pbest_ij - x_ij)
///     + c2 * r2 * (leader_ij - x_ij)
///
/// The velocity is converted into assignment probabilities through a sigmoid
/// function. A repair operator then constructs a feasible assignment while
/// respecting every worker's remaining capacity.
///
/// The current application model does not expose explicit MobiTest values for
/// output-data size, FLOPs, or a global energy budget. Therefore this class
/// uses the quantities actually available through [FleetModel]:
///
///   - completion time: current queue wait + transfer + processing
///   - energy: current marginal per-unit energy estimate
///
/// This class intentionally does not invent additional task parameters.
///
/// [random] is used for all stochastic operations so that supplying a seeded
/// Random instance produces deterministic scheduling behavior.
class MOMPSOScheduler extends DynamicScheduler {
  /// Number of particles in the swarm.
  final int particles;

  /// Number of PSO iterations.
  final int iterations;

  /// Inertia coefficient.
  final double inertia;

  /// Cognitive coefficient.
  final double c1;

  /// Social coefficient.
  final double c2;

  /// Maximum absolute velocity.
  final double maxVelocity;

  /// Maximum number of solutions retained in the Pareto archive.
  final int archiveSize;

  MOMPSOScheduler({
    super.random,
    super.config,
    this.particles = 12,
    this.iterations = 12,
    this.inertia = 0.72,
    this.c1 = 1.49,
    this.c2 = 1.49,
    this.maxVelocity = 4.0,
    this.archiveSize = 30,
  }) : assert(particles > 0),
       assert(iterations >= 0),
       assert(inertia >= 0),
       assert(c1 >= 0),
       assert(c2 >= 0),
       assert(maxVelocity > 0),
       assert(archiveSize > 0);

  @override
  String get id => 'mompso';

  @override
  String get label => 'MOMPSO';

  /// Optimizes the current feasible batch and returns the assignment of the
  /// first remaining unit.
  ///
  /// DynamicScheduler performs the actual assignment incrementally. Therefore
  /// we optimize the largest currently feasible subset, then return only the
  /// assignment for [remaining.first].
  @override
  UnitPick? pickPair(
    FleetModel fleet,
    List<Unit> remaining,
    List<String> open,
  ) {
    if (remaining.isEmpty || open.isEmpty) return null;

    final clientIds = List<String>.of(open)..sort();

    final capacities = <int>[
      for (final id in clientIds)
        max(0, fleet.capFor(id) - fleet.views[id]!.assigned),
    ];

    final totalCapacity = capacities.fold<int>(
      0,
      (sum, capacity) => sum + capacity,
    );

    if (totalCapacity <= 0) return null;

    // DynamicScheduler may legitimately have more remaining units than the
    // currently available aggregate worker capacity. MOMPSO must therefore
    // optimize only a feasible subset.
    final taskCount = min(remaining.length, totalCapacity);

    final problem = _MOMPSOProblem(
      fleet: fleet,
      units: remaining.take(taskCount).toList(),
      clientIds: clientIds,
      capacities: capacities,
    );

    final best = _optimize(problem);

    if (best.assignments.isEmpty) return null;

    return UnitPick(remaining.first, clientIds[best.assignments.first]);
  }

  /// Optimizes a single unit.
  ///
  /// This method is retained for compatibility with DynamicScheduler and
  /// provides the same multi-objective decision process for a one-task
  /// problem.
  @override
  String pick(FleetModel fleet, List<String> open, Unit unit) {
    if (open.isEmpty) {
      throw StateError('MOMPSO cannot select a worker from an empty set.');
    }

    final clientIds = List<String>.of(open)..sort();

    final capacities = <int>[
      for (final id in clientIds)
        max(0, fleet.capFor(id) - fleet.views[id]!.assigned),
    ];

    final availableWorkers = <int>[
      for (var i = 0; i < capacities.length; i++)
        if (capacities[i] > 0) i,
    ];

    if (availableWorkers.isEmpty) {
      throw StateError('MOMPSO has no worker with remaining capacity.');
    }

    final problem = _MOMPSOProblem(
      fleet: fleet,
      units: [unit],
      clientIds: clientIds,
      capacities: capacities,
    );

    final best = _optimize(problem);

    return clientIds[best.assignments.first];
  }

  ParetoSolution _optimize(_MOMPSOProblem problem) {
    final taskCount = problem.units.length;
    final workerCount = problem.clientIds.length;

    if (taskCount == 0) {
      return ParetoSolution(
        assignments: <int>[],
        objectives: const ParetoObjectives(completionTime: 0, energy: 0),
      );
    }

    if (workerCount == 1) {
      final assignment = List<int>.filled(taskCount, 0);

      return ParetoSolution(
        assignments: assignment,
        objectives: problem.evaluate(assignment),
      );
    }

    final swarm = <_MOMPSOParticle>[];

    for (var p = 0; p < particles; p++) {
      final position = _randomFeasibleAssignment(problem);

      final velocity = List.generate(
        taskCount,
        (_) => List<double>.generate(
          workerCount,
          (_) => (random.nextDouble() * 2.0 - 1.0) * maxVelocity,
        ),
      );

      final objectives = problem.evaluate(position);

      swarm.add(
        _MOMPSOParticle(
          position: position,
          velocity: velocity,
          personalBestPosition: List<int>.of(position),
          personalBestObjectives: objectives,
        ),
      );
    }

    final archive = ParetoArchive(capacity: archiveSize);

    // Initial population contributes to the Pareto archive.
    for (final particle in swarm) {
      archive.add(
        ParetoSolution(
          assignments: List<int>.of(particle.position),
          objectives: particle.personalBestObjectives,
        ),
      );
    }

    for (var iteration = 0; iteration < iterations; iteration++) {
      for (final particle in swarm) {
        final leader = archive.selectLeader(random);

        final probabilities = List.generate(
          taskCount,
          (_) => List<double>.filled(workerCount, 0.0),
        );

        for (var task = 0; task < taskCount; task++) {
          for (var worker = 0; worker < workerCount; worker++) {
            final current = particle.position[task] == worker ? 1.0 : 0.0;

            final personalBest = particle.personalBestPosition[task] == worker
                ? 1.0
                : 0.0;

            final leaderPosition = leader.assignments[task] == worker
                ? 1.0
                : 0.0;

            var velocity =
                inertia * particle.velocity[task][worker] +
                c1 * random.nextDouble() * (personalBest - current) +
                c2 * random.nextDouble() * (leaderPosition - current);

            velocity = velocity.clamp(-maxVelocity, maxVelocity).toDouble();

            particle.velocity[task][worker] = velocity;

            probabilities[task][worker] = _sigmoid(velocity);
          }
        }

        final nextPosition = _repair(probabilities, problem);

        final nextObjectives = problem.evaluate(nextPosition);

        particle.position = nextPosition;

        if (ParetoArchive.dominates(
          nextObjectives,
          particle.personalBestObjectives,
        )) {
          particle.personalBestPosition = List<int>.of(nextPosition);
          particle.personalBestObjectives = nextObjectives;
        } else if (!ParetoArchive.dominates(
              particle.personalBestObjectives,
              nextObjectives,
            ) &&
            _sameObjectiveValues(
              nextObjectives,
              particle.personalBestObjectives,
            )) {
          // Deterministic tie-breaking.
          if (_lexicographicallySmaller(
            nextPosition,
            particle.personalBestPosition,
          )) {
            particle.personalBestPosition = List<int>.of(nextPosition);
            particle.personalBestObjectives = nextObjectives;
          }
        }

        archive.add(
          ParetoSolution(
            assignments: List<int>.of(nextPosition),
            objectives: nextObjectives,
          ),
        );

        // The personal best is also a candidate for the archive.
        archive.add(
          ParetoSolution(
            assignments: List<int>.of(particle.personalBestPosition),
            objectives: particle.personalBestObjectives,
          ),
        );
      }
    }

    if (archive.isEmpty) {
      final fallback = _randomFeasibleAssignment(problem);

      return ParetoSolution(
        assignments: fallback,
        objectives: problem.evaluate(fallback),
      );
    }

    // Choose the final schedule from the Pareto archive.
    //
    // There is no mathematically unique solution on a Pareto front.
    // For a deterministic application-level decision, use normalized
    // distance to the ideal point and select the closest solution.
    return _selectFinalSolution(archive.solutions);
  }

  /// Creates a random feasible assignment.
  ///
  /// Unlike the old implementation, this method never assumes that all
  /// remaining units can be assigned. The caller has already limited the
  /// problem to:
  ///
  ///   taskCount <= sum(worker capacities)
  ///
  /// so a feasible solution always exists.
  List<int> _randomFeasibleAssignment(_MOMPSOProblem problem) {
    final assignment = List<int>.filled(problem.units.length, -1);

    final remainingCapacity = List<int>.of(problem.capacities);

    final taskOrder = List<int>.generate(problem.units.length, (i) => i);

    // Randomize the initial swarm while retaining deterministic behavior
    // under a seeded Random.
    for (var i = taskOrder.length - 1; i > 0; i--) {
      final j = random.nextInt(i + 1);
      final tmp = taskOrder[i];
      taskOrder[i] = taskOrder[j];
      taskOrder[j] = tmp;
    }

    for (final task in taskOrder) {
      final availableWorkers = <int>[
        for (var worker = 0; worker < problem.clientIds.length; worker++)
          if (remainingCapacity[worker] > 0) worker,
      ];

      if (availableWorkers.isEmpty) {
        throw StateError('MOMPSO could not construct a feasible particle.');
      }

      final worker = availableWorkers[random.nextInt(availableWorkers.length)];

      assignment[task] = worker;
      remainingCapacity[worker]--;
    }

    return assignment;
  }

  /// Converts continuous PSO velocities into a feasible discrete assignment.
  ///
  /// Tasks with the strongest worker preference are assigned first.
  /// Capacity is consumed as assignments are made.
  List<int> _repair(List<List<double>> probabilities, _MOMPSOProblem problem) {
    final taskOrder = List<int>.generate(probabilities.length, (i) => i);

    taskOrder.sort((a, b) {
      final aMax = probabilities[a].reduce(max);
      final bMax = probabilities[b].reduce(max);

      final maxComparison = bMax.compareTo(aMax);

      if (maxComparison != 0) {
        return maxComparison;
      }

      return a.compareTo(b);
    });

    final assignment = List<int>.filled(probabilities.length, -1);

    final remainingCapacity = List<int>.of(problem.capacities);

    for (final task in taskOrder) {
      var bestWorker = -1;
      var bestProbability = double.negativeInfinity;

      for (var worker = 0; worker < problem.clientIds.length; worker++) {
        if (remainingCapacity[worker] <= 0) {
          continue;
        }

        final probability = probabilities[task][worker];

        if (probability > bestProbability) {
          bestProbability = probability;
          bestWorker = worker;
        } else if (probability == bestProbability && bestWorker >= 0) {
          // Deterministic tie-break.
          if (problem.clientIds[worker].compareTo(
                problem.clientIds[bestWorker],
              ) <
              0) {
            bestWorker = worker;
          }
        }
      }

      if (bestWorker < 0) {
        throw StateError('MOMPSO repair produced an infeasible assignment.');
      }

      assignment[task] = bestWorker;
      remainingCapacity[bestWorker]--;
    }

    return assignment;
  }

  /// Selects the final Pareto solution using normalized distance to the ideal
  /// point.
  ///
  /// This does not alter the optimization process. It only converts the
  /// resulting Pareto set into one schedule because DynamicScheduler requires
  /// one worker assignment at each scheduling step.
  ParetoSolution _selectFinalSolution(List<ParetoSolution> archive) {
    if (archive.length == 1) {
      return archive.first;
    }

    var minTime = double.infinity;
    var maxTime = double.negativeInfinity;
    var minEnergy = double.infinity;
    var maxEnergy = double.negativeInfinity;

    for (final solution in archive) {
      minTime = min(minTime, solution.objectives.completionTime);
      maxTime = max(maxTime, solution.objectives.completionTime);

      minEnergy = min(minEnergy, solution.objectives.energy);
      maxEnergy = max(maxEnergy, solution.objectives.energy);
    }

    final timeRange = maxTime - minTime;
    final energyRange = maxEnergy - minEnergy;

    ParetoSolution? best;
    var bestDistance = double.infinity;

    for (final solution in archive) {
      final normalizedTime = timeRange > 0
          ? (solution.objectives.completionTime - minTime) / timeRange
          : 0.0;

      final normalizedEnergy = energyRange > 0
          ? (solution.objectives.energy - minEnergy) / energyRange
          : 0.0;

      final distance = sqrt(
        normalizedTime * normalizedTime + normalizedEnergy * normalizedEnergy,
      );

      if (distance < bestDistance) {
        bestDistance = distance;
        best = solution;
      } else if (distance == bestDistance &&
          best != null &&
          _lexicographicallySmaller(solution.assignments, best.assignments)) {
        best = solution;
      }
    }

    return best!;
  }

  bool _sameObjectiveValues(ParetoObjectives a, ParetoObjectives b) {
    const epsilon = 1e-12;

    return (a.completionTime - b.completionTime).abs() <= epsilon &&
        (a.energy - b.energy).abs() <= epsilon;
  }

  bool _lexicographicallySmaller(List<int> a, List<int> b) {
    final length = min(a.length, b.length);

    for (var i = 0; i < length; i++) {
      if (a[i] != b[i]) {
        return a[i] < b[i];
      }
    }

    return a.length < b.length;
  }

  double _sigmoid(double value) {
    // Numerically stable sigmoid implementation.
    if (value >= 0) {
      final z = exp(-value);
      return 1.0 / (1.0 + z);
    }

    final z = exp(value);
    return z / (1.0 + z);
  }
}

/// Optimization problem presented to MOMPSO.
class _MOMPSOProblem {
  final FleetModel fleet;
  final List<Unit> units;
  final List<String> clientIds;
  final List<int> capacities;

  _MOMPSOProblem({
    required this.fleet,
    required this.units,
    required this.clientIds,
    required this.capacities,
  });

  /// Evaluates a complete assignment vector.
  ///
  /// Objective 1:
  ///
  ///   T(X) = max_i { W_i + sum_j assigned_to_i S_ij }
  ///
  /// where S_ij is the current modeled transfer + processing service time.
  ///
  /// Objective 2:
  ///
  ///   E(X) = sum_j E_ij
  ///
  /// using FleetModel's current marginal per-unit energy estimate.
  ParetoObjectives evaluate(List<int> assignment) {
    final loads = <String, double>{
      for (final clientId in clientIds) clientId: fleet.waitMs(clientId),
    };

    var energy = 0.0;

    for (var task = 0; task < units.length; task++) {
      final workerIndex = assignment[task];
      final clientId = clientIds[workerIndex];

      final initialWait = fleet.waitMs(clientId);

      final service = fleet.etaMs(clientId, units[task]) - initialWait;

      loads[clientId] = loads[clientId]! + max(0.0, service);

      energy += fleet.energyJ(clientId);
    }

    var completionTime = 0.0;

    for (final load in loads.values) {
      completionTime = max(completionTime, load);
    }

    return ParetoObjectives(completionTime: completionTime, energy: energy);
  }
}

/// A single MOMPSO particle.
class _MOMPSOParticle {
  List<int> position;

  final List<List<double>> velocity;

  List<int> personalBestPosition;

  ParetoObjectives personalBestObjectives;

  _MOMPSOParticle({
    required this.position,
    required this.velocity,
    required this.personalBestPosition,
    required this.personalBestObjectives,
  });
}