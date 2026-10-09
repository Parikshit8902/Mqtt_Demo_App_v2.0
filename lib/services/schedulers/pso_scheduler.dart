import '../models/assignment.dart';
import 'dynamic_scheduler.dart';
import 'scheduling_model.dart';

/// Particle swarm scheduler (DetectNet's `schedPSO`): for every unit a small
/// swarm searches for one weight per open phone, and the phone with the largest
/// weight in the final global best receives the unit.
///
/// A particle is a vector of weights in [0, 1] and its fitness is the weighted
/// average of the phones' health scores, sum(|w| * s) / sum(|w|). Each
/// iteration moves every weight by the usual velocity-style rule
///
///   x = inertia * x + c1 * r1 * (pbest - x) + c2 * r2 * (gbest - x)
///
/// and clamps it back into [0, 1].
///
/// What makes it dynamic is its input: the scores are
/// [FleetModel.healthScore], which is recomputed from live battery, CPU load,
/// bandwidth, processing rate (already derated for thermal state, memory and
/// Wi-Fi signal) and queue depth. The swarm is rebuilt for every pick and every
/// assignment lengthens the winner's queue before the next one, so a batch
/// spreads over the phones instead of piling onto whichever scored best first.
///
/// As in DetectNet this is a lightweight heuristic, not a converged discrete
/// task-assignment PSO. The fitness is a weighted average, so the swarm drifts
/// towards putting the most weight on the healthiest phone; in effect it ranks
/// phones by health, with some randomness left over from the short search.
class PSOScheduler extends DynamicScheduler {
  final int particles;
  final int iterations;
  final double inertia;
  final double c1;
  final double c2;

  PSOScheduler({
    super.random,
    super.config,
    this.particles = 8,
    this.iterations = 6,
    this.inertia = 0.72,
    this.c1 = 1.49,
    this.c2 = 1.49,
  }) : assert(particles > 0),
       assert(iterations >= 0);

  @override
  String get id => 'pso';

  @override
  String get label => 'PSO';

  @override
  String pick(FleetModel fleet, List<String> open, Unit unit) {
    // Sorted so a seeded Random gives the same weights to the same phones
    // whatever order the clients happen to be in the map.
    final clientIds = List<String>.of(open)..sort();

    final scores = [
      for (final clientId in clientIds) fleet.healthScore(clientId),
    ];

    final swarm = List.generate(
      particles,
      (_) => List.generate(clientIds.length, (_) => random.nextDouble()),
    );

    final personalBest = [
      for (final particle in swarm) List<double>.of(particle),
    ];

    final personalBestFitness = [
      for (final particle in swarm) _fitness(particle, scores),
    ];

    // The best of the initial swarm, not simply the first particle.
    var bestParticle = 0;
    for (int i = 1; i < swarm.length; i++) {
      if (personalBestFitness[i] > personalBestFitness[bestParticle]) {
        bestParticle = i;
      }
    }

    var globalBest = List<double>.of(swarm[bestParticle]);
    var globalBestFitness = personalBestFitness[bestParticle];

    for (int iteration = 0; iteration < iterations; iteration++) {
      for (int p = 0; p < swarm.length; p++) {
        final particle = swarm[p];

        for (int i = 0; i < particle.length; i++) {
          final r1 = random.nextDouble();
          final r2 = random.nextDouble();

          particle[i] =
              (inertia * particle[i]) +
              (c1 * r1 * (personalBest[p][i] - particle[i])) +
              (c2 * r2 * (globalBest[i] - particle[i]));

          particle[i] = particle[i].clamp(0.0, 1.0);
        }

        final fitness = _fitness(particle, scores);

        if (fitness > personalBestFitness[p]) {
          personalBest[p] = List<double>.of(particle);
          personalBestFitness[p] = fitness;
        }

        if (fitness > globalBestFitness) {
          globalBest = List<double>.of(particle);
          globalBestFitness = fitness;
        }
      }
    }

    // The ids are sorted, so the strict comparison leaves an exact tie with
    // the lexicographically smaller id.
    var winner = 0;
    for (int i = 1; i < globalBest.length; i++) {
      if (globalBest[i] > globalBest[winner]) {
        winner = i;
      }
    }

    return clientIds[winner];
  }

  double _fitness(List<double> weights, List<double> scores) {
    double weightSum = 0.0;
    double weighted = 0.0;

    for (int i = 0; i < weights.length; i++) {
      weightSum += weights[i].abs();
      weighted += weights[i].abs() * scores[i];
    }

    return weightSum == 0.0 ? 0.0 : weighted / weightSum;
  }
}
