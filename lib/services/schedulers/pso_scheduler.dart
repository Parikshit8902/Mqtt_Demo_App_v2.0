import 'dart:math';

import '../models/assignment.dart';
import 'dynamic_scheduler.dart';
import 'scheduling_model.dart';

/// Particle Swarm Optimization scheduler for heterogeneous task allocation.
///
/// The scheduling problem is represented using binary assignment variables:
///
///   x_ij = 1  iff task j is assigned to worker i
///
/// with the integral-association constraint:
///
///   sum_i x_ij = 1,  for every task j.
///
/// The objective follows the structure of the MobiTest formulation:
///
///   F(x) = alpha * T(x) / T_ref
///        + beta  * E(x) / E_ref
///
/// where:
///
///   T(x) = batch makespan
///   E(x) = total estimated energy
///
/// The current application does not expose every physical quantity used in
/// the paper's full equation (for example, explicit output size and MFLOP
/// requirements). Therefore this implementation uses the quantities actually
/// available through FleetModel:
///
///   - current queue/waiting time
///   - input transfer time
///   - processing time
///   - estimated device energy
///
/// The paper specifies the optimization formulation and constraints, but does
/// not specify the exact particle representation, PSO coefficients,
/// initialization procedure, or constraint-repair operator. Those details are
/// therefore explicit implementation choices here rather than claims about
/// the paper's hidden implementation.
///
/// Binary PSO update:
///
///   v_ij(t+1) =
///       w * v_ij(t)
///       + c1*r1*(pbest_ij - x_ij)
///       + c2*r2*(gbest_ij - x_ij)
///
/// The velocity is transformed through a sigmoid function:
///
///   P(x_ij = 1) = 1 / (1 + exp(-v_ij))
///
/// The resulting binary position is then repaired into a valid assignment so
/// that every task has exactly one worker and no worker exceeds its remaining
/// capacity.
class PSOScheduler extends DynamicScheduler {
  final int particles;
  final int iterations;

  /// Inertia coefficient.
  final double inertia;

  /// Cognitive coefficient.
  final double c1;

  /// Social coefficient.
  final double c2;

  /// Relative importance of completion time.
  ///
  /// These are implementation-level weights because the paper states that
  /// alpha and beta are derived from boundary conditions but does not provide
  /// their numerical values.
  final double timeWeight;

  /// Relative importance of energy consumption.
  final double energyWeight;

  /// Velocity clamp used by Binary PSO.
  final double maxVelocity;

  PSOScheduler({
    super.random,
    super.config,
    this.particles = 12,
    this.iterations = 12,
    this.inertia = 0.72,
    this.c1 = 1.49,
    this.c2 = 1.49,
    this.timeWeight = 0.80,
    this.energyWeight = 0.20,
    this.maxVelocity = 4.0,
  })  : assert(particles > 0),
        assert(iterations >= 0),
        assert(inertia >= 0),
        assert(c1 >= 0),
        assert(c2 >= 0),
        assert(timeWeight >= 0),
        assert(energyWeight >= 0),
        assert(timeWeight + energyWeight > 0),
        assert(maxVelocity > 0);

  @override
  String get id => 'pso';

  @override
  String get label => 'PSO';

  /// Optimize the complete remaining batch and return the first assignment
  /// from the best schedule discovered by the swarm.
  ///
  /// DynamicScheduler records the returned assignment immediately. The next
  /// call therefore sees the updated queue state and PSO is rerun against the
  /// remaining work.
  @override
  UnitPick? pickPair(
    FleetModel fleet,
    List<Unit> remaining,
    List<String> open,
  ) {
    if (remaining.isEmpty || open.isEmpty) return null;

    final clientIds = List<String>.of(open)..sort();

    final capacities = [
      for (final id in clientIds)
        max(0, fleet.capFor(id) - fleet.views[id]!.assigned),
    ];

    final totalCapacity = capacities.fold<int>(0, (sum, c) => sum + c);

    if (totalCapacity <= 0) return null;

    final taskCount = min(remaining.length, totalCapacity);

    final problem = _PSOProblem(
      fleet: fleet,
      units: remaining.take(taskCount).toList(),
      clientIds: clientIds,
      timeWeight: timeWeight,
      energyWeight: energyWeight,
    );

    final best = _optimize(problem);

    return UnitPick(
      remaining.first,
      clientIds[best.assignments.first],
    );
  }

  /// Fallback for callers that request a worker for a single unit.
  @override
  String pick(
    FleetModel fleet,
    List<String> open,
    Unit unit,
  ) {
    final clientIds = List<String>.of(open)..sort();

    final problem = _PSOProblem(
      fleet: fleet,
      units: [unit],
      clientIds: clientIds,
      timeWeight: timeWeight,
      energyWeight: energyWeight,
    );

    final best = _optimize(problem);

    return clientIds[best.assignments.first];
  }

  _PSOSolution _optimize(_PSOProblem problem) {
    final workerCount = problem.clientIds.length;
    final taskCount = problem.units.length;

    if (taskCount == 0) {
      return const _PSOSolution(
        assignments: <int>[],
        fitness: 0,
      );
    }

    if (workerCount == 1) {
      final assignments = List<int>.filled(taskCount, 0);

      return _PSOSolution(
        assignments: assignments,
        fitness: problem.fitness(assignments),
      );
    }

    final swarm = <_PSOParticle>[];

    // -----------------------------------------------------------------------
    // Swarm initialization
    // -----------------------------------------------------------------------

    for (var p = 0; p < particles; p++) {
      final position = _randomFeasibleAssignment(problem);

      final velocity = List.generate(
        taskCount,
        (_) => List<double>.generate(
          workerCount,
          (_) =>
              (random.nextDouble() * 2.0 - 1.0) *
              maxVelocity,
        ),
      );

      final fitness = problem.fitness(position);

      swarm.add(
        _PSOParticle(
          position: position,
          velocity: velocity,
          bestPosition: List<int>.of(position),
          bestFitness: fitness,
        ),
      );
    }

    // -----------------------------------------------------------------------
    // Initial global best
    // -----------------------------------------------------------------------

    var globalBestParticle = _bestParticle(swarm);

    var globalBestPosition =
        List<int>.of(globalBestParticle.bestPosition);

    var globalBestFitness =
        globalBestParticle.bestFitness;

    // -----------------------------------------------------------------------
    // PSO iterations
    // -----------------------------------------------------------------------

    for (var iteration = 0;
        iteration < iterations;
        iteration++) {
      for (final particle in swarm) {
        final probabilities = List.generate(
          taskCount,
          (_) => List<double>.filled(workerCount, 0.0),
        );

        for (var task = 0; task < taskCount; task++) {
          for (var worker = 0;
              worker < workerCount;
              worker++) {
            final currentBit =
                particle.position[task] == worker ? 1.0 : 0.0;

            final personalBestBit =
                particle.bestPosition[task] == worker ? 1.0 : 0.0;

            final globalBestBit =
                globalBestPosition[task] == worker ? 1.0 : 0.0;

            var velocity =
                inertia * particle.velocity[task][worker] +
                c1 *
                    random.nextDouble() *
                    (personalBestBit - currentBit) +
                c2 *
                    random.nextDouble() *
                    (globalBestBit - currentBit);

            velocity =
                velocity.clamp(-maxVelocity, maxVelocity).toDouble();

            particle.velocity[task][worker] = velocity;

            probabilities[task][worker] =
                _sigmoid(velocity);
          }
        }

        // Binary PSO gives a potentially invalid assignment matrix.
        // Repair it before evaluating fitness.
        final nextPosition =
            _repair(probabilities, problem);

        final fitness =
            problem.fitness(nextPosition);

        particle.position = nextPosition;

        // ---------------------------------------------------------------
        // Personal best
        // ---------------------------------------------------------------

        if (_better(
          candidateFitness: fitness,
          currentFitness: particle.bestFitness,
          candidate: nextPosition,
          current: particle.bestPosition,
          clientIds: problem.clientIds,
        )) {
          particle.bestFitness = fitness;
          particle.bestPosition =
              List<int>.of(nextPosition);
        }

        // ---------------------------------------------------------------
        // Global best
        // ---------------------------------------------------------------

        if (_better(
          candidateFitness: fitness,
          currentFitness: globalBestFitness,
          candidate: nextPosition,
          current: globalBestPosition,
          clientIds: problem.clientIds,
        )) {
          globalBestFitness = fitness;
          globalBestPosition =
              List<int>.of(nextPosition);
        }
      }
    }

    return _PSOSolution(
      assignments: globalBestPosition,
      fitness: globalBestFitness,
    );
  }

  // =========================================================================
  // Swarm initialization
  // =========================================================================

  /// Creates a random assignment satisfying all worker capacities.
  List<int> _randomFeasibleAssignment(
    _PSOProblem problem,
  ) {
    final assignment =
        List<int>.filled(problem.units.length, -1);

    final remainingCapacity =
        List<int>.of(problem.capacities);

    for (var task = 0;
        task < problem.units.length;
        task++) {
      final availableWorkers = <int>[];

      for (var worker = 0;
          worker < problem.clientIds.length;
          worker++) {
        if (remainingCapacity[worker] > 0) {
          availableWorkers.add(worker);
        }
      }

      if (availableWorkers.isEmpty) {
        throw StateError(
          'PSO could not construct a feasible particle.',
        );
      }

      final worker = availableWorkers[
          random.nextInt(availableWorkers.length)];

      assignment[task] = worker;
      remainingCapacity[worker]--;
    }

    return assignment;
  }

  // =========================================================================
  // Constraint repair
  // =========================================================================

  /// Converts Binary-PSO probabilities into a valid categorical assignment.
  ///
  /// Each task receives exactly one worker.
  ///
  /// Worker capacities are respected by processing the most confident tasks
  /// first and assigning each one to the highest-probability worker that still
  /// has capacity.
  List<int> _repair(
    List<List<double>> probabilities,
    _PSOProblem problem,
  ) {
    final taskOrder =
        List<int>.generate(probabilities.length, (i) => i);

    taskOrder.sort((a, b) {
      final aMax =
          probabilities[a].reduce(max);

      final bMax =
          probabilities[b].reduce(max);

      final confidenceComparison =
          bMax.compareTo(aMax);

      if (confidenceComparison != 0) {
        return confidenceComparison;
      }

      // Deterministic tie-break.
      return a.compareTo(b);
    });

    final assignment =
        List<int>.filled(probabilities.length, -1);

    final remainingCapacity =
        List<int>.of(problem.capacities);

    for (final task in taskOrder) {
      var bestWorker = -1;
      var bestProbability =
          double.negativeInfinity;

      for (var worker = 0;
          worker < problem.clientIds.length;
          worker++) {
        if (remainingCapacity[worker] <= 0) {
          continue;
        }

        final probability =
            probabilities[task][worker];

        if (probability > bestProbability) {
          bestProbability = probability;
          bestWorker = worker;
        } else if (probability == bestProbability &&
            bestWorker >= 0 &&
            problem.clientIds[worker]
                    .compareTo(
                      problem.clientIds[bestWorker],
                    ) <
                0) {
          bestWorker = worker;
        }
      }

      if (bestWorker < 0) {
        throw StateError(
          'PSO repair produced an infeasible assignment.',
        );
      }

      assignment[task] = bestWorker;
      remainingCapacity[bestWorker]--;
    }

    return assignment;
  }

  // =========================================================================
  // Global-best selection
  // =========================================================================

  _PSOParticle _bestParticle(
    List<_PSOParticle> swarm,
  ) {
    var best = swarm.first;

    for (var i = 1; i < swarm.length; i++) {
      final candidate = swarm[i];

      if (_better(
        candidateFitness: candidate.bestFitness,
        currentFitness: best.bestFitness,
        candidate: candidate.bestPosition,
        current: best.bestPosition,
        clientIds: const [],
      )) {
        best = candidate;
      }
    }

    return best;
  }

  /// Lower fitness is better.
  ///
  /// If fitness is equal within numerical precision, the assignment vector
  /// itself is used only as a deterministic tie-breaker.
  bool _better({
    required double candidateFitness,
    required double currentFitness,
    required List<int> candidate,
    required List<int> current,
    required List<String> clientIds,
  }) {
    const epsilon = 1e-12;

    if (candidateFitness <
        currentFitness - epsilon) {
      return true;
    }

    if ((candidateFitness - currentFitness).abs() >
        epsilon) {
      return false;
    }

    final length =
        min(candidate.length, current.length);

    for (var i = 0; i < length; i++) {
      if (candidate[i] != current[i]) {
        return candidate[i] < current[i];
      }
    }

    return candidate.length < current.length;
  }

  // =========================================================================
  // Binary PSO transfer function
  // =========================================================================

  double _sigmoid(double x) {
    if (x >= 0.0) {
      final z = exp(-x);
      return 1.0 / (1.0 + z);
    }

    final z = exp(x);
    return z / (1.0 + z);
  }
}

// =============================================================================
// PSO problem definition
// =============================================================================

class _PSOProblem {
  final FleetModel fleet;
  final List<Unit> units;
  final List<String> clientIds;

  /// Remaining assignment capacity for every worker.
  final List<int> capacities;

  /// Reference used to normalize completion time.
  final double timeReference;

  /// Reference used to normalize energy.
  final double energyReference;

  /// Normalized objective weights.
  final double alpha;
  final double beta;

  _PSOProblem({
    required this.fleet,
    required this.units,
    required this.clientIds,
    required double timeWeight,
    required double energyWeight,
  })  : capacities = [
          for (final id in clientIds)
            max(
              0,
              fleet.capFor(id) -
                  fleet.views[id]!.assigned,
            ),
        ],
        timeReference = _computeTimeReference(
          fleet,
          units,
          clientIds,
        ),
        energyReference = _computeEnergyReference(
          fleet,
          units.length,
          clientIds,
        ),
        alpha =
            timeWeight /
            (timeWeight + energyWeight),
        beta =
            energyWeight /
            (timeWeight + energyWeight);

  /// Evaluate:
  ///
  ///   F = alpha * T/Tref + beta * E/Eref
  ///
  /// Lower is better.
  double fitness(List<int> assignment) {
    final loads = <String, double>{
      for (final id in clientIds)
        id: fleet.waitMs(id),
    };

    var totalEnergy = 0.0;

    for (var task = 0;
        task < units.length;
        task++) {
      final worker =
          clientIds[assignment[task]];

      final initialWait =
          fleet.waitMs(worker);

      // eta = current queue wait + service time.
      //
      // Subtracting the current wait gives the service component for this
      // particular unit, including its actual input-transfer size.
      final serviceTime =
          fleet.etaMs(
                worker,
                units[task],
              ) -
              initialWait;

      loads[worker] =
          loads[worker]! + serviceTime;

      totalEnergy +=
          fleet.energyJ(worker);
    }

    var makespan = 0.0;

    for (final load in loads.values) {
      makespan = max(makespan, load);
    }

    final normalizedTime =
        makespan / timeReference;

    final normalizedEnergy =
        totalEnergy / energyReference;

    return alpha * normalizedTime +
        beta * normalizedEnergy;
  }

  /// A normalization scale obtained by considering the case where the whole
  /// remaining batch executes serially on each eligible worker and taking the
  /// largest resulting time.
  ///
  /// This is only a dimensional normalization factor; it is not another
  /// optimization objective.
  static double _computeTimeReference(
    FleetModel fleet,
    List<Unit> units,
    List<String> clientIds,
  ) {
    if (units.isEmpty || clientIds.isEmpty) {
      return 1.0;
    }

    var reference =
        double.negativeInfinity;

    for (final id in clientIds) {
      var total = fleet.waitMs(id);

      for (final unit in units) {
        final initialWait =
            fleet.waitMs(id);

        final service =
            fleet.etaMs(id, unit) -
                initialWait;

        total += service;
      }

      reference =
          max(reference, total);
    }

    return max(reference, 1.0);
  }

  /// Energy normalization scale.
  ///
  /// Uses the maximum per-unit energy among eligible workers multiplied by
  /// the number of remaining tasks. This provides a positive common scale
  /// without introducing another preference between workers.
  static double _computeEnergyReference(
    FleetModel fleet,
    int taskCount,
    List<String> clientIds,
  ) {
    if (taskCount <= 0 || clientIds.isEmpty) {
      return 1.0;
    }

    var maximumEnergy = 0.0;

    for (final id in clientIds) {
      maximumEnergy =
          max(
            maximumEnergy,
            fleet.energyJ(id),
          );
    }

    return max(
      maximumEnergy * taskCount,
      1.0,
    );
  }
}

// =============================================================================
// PSO particle
// =============================================================================

class _PSOParticle {
  List<int> position;

  /// velocity[task][worker]
  ///
  /// This is the Binary-PSO velocity associated with x_ij.
  final List<List<double>> velocity;

  List<int> bestPosition;
  double bestFitness;

  _PSOParticle({
    required this.position,
    required this.velocity,
    required this.bestPosition,
    required this.bestFitness,
  });
}

// =============================================================================
// PSO solution
// =============================================================================

class _PSOSolution {
  final List<int> assignments;
  final double fitness;

  const _PSOSolution({
    required this.assignments,
    required this.fitness,
  });
}