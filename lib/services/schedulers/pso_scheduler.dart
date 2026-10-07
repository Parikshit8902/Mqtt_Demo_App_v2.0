import 'dart:math';

import '../models/assignment.dart';
import '../models/result_dto.dart';
import 'scheduler.dart';
import 'scheduler_utils.dart';

class PSOScheduler implements Scheduler {
  @override
  String get id => 'pso';
  @override
  String get label => 'PSO';

  final Random _random = Random();

  @override
  Map<String, List<Unit>> schedule(
    List<Unit> availableUnits,
    Map<String, ClientEstimate> clients,
    int maxUnitPerAssign,
  ) {
    final assignments =
        SchedulerUtils.initializeAssignments(clients);

    if (availableUnits.isEmpty || clients.isEmpty) {
      return assignments;
    }

    if (clients.length == 1) {
      final clientId = clients.keys.first;

      assignments[clientId]!.addAll(
        availableUnits.take(maxUnitPerAssign),
      );

      return assignments;
    }

    final clientIds = clients.keys.toList();

    final healthScores =
        SchedulerUtils.healthScores(clients);

    final scores = clientIds
        .map((id) => healthScores[id] ?? 0.0)
        .toList();

    const particleCount = 8;
    const iterations = 6;

    // Each particle represents a vector of weights,
    // one weight for every client.
    List<List<double>> particles = List.generate(
      particleCount,
      (_) => List.generate(
        clientIds.length,
        (_) => _random.nextDouble(),
      ),
    );

    List<List<double>> personalBest = particles
        .map((particle) => List<double>.from(particle))
        .toList();

    List<double> globalBest =
        List<double>.from(particles.first);

    double globalBestFitness =
        _fitness(globalBest, scores);

    for (int iteration = 0; iteration < iterations; iteration++) {
      for (int particleIndex = 0;
          particleIndex < particles.length;
          particleIndex++) {
        final particle = particles[particleIndex];
        final personal = personalBest[particleIndex];

        for (int i = 0; i < particle.length; i++) {
          final r1 = _random.nextDouble();
          final r2 = _random.nextDouble();

          particle[i] =
              (0.72 * particle[i]) +
              (1.49 * r1 * (personal[i] - particle[i])) +
              (1.49 * r2 * (globalBest[i] - particle[i]));

          particle[i] = particle[i].clamp(0.0, 1.0);
        }

        final currentFitness =
            _fitness(particle, scores);

        final personalFitness =
            _fitness(personal, scores);

        if (currentFitness > personalFitness) {
          personalBest[particleIndex] =
              List<double>.from(particle);
        }

        if (currentFitness > globalBestFitness) {
          globalBest =
              List<double>.from(particle);

          globalBestFitness = currentFitness;
        }
      }
    }

    // Rank clients using the final PSO global-best vector.
    final ranking = List<int>.generate(
      clientIds.length,
      (index) => index,
    );

    ranking.sort(
      (a, b) => globalBest[b].compareTo(globalBest[a]),
    );

    // Assign units to the best available client first,
    // then continue through the ranking.
    int rankingIndex = 0;

    for (final unit in availableUnits) {
      bool assigned = false;

      for (int attempt = 0;
          attempt < ranking.length;
          attempt++) {
        final index =
            (rankingIndex + attempt) % ranking.length;

        final clientId = clientIds[index];

        if (assignments[clientId]!.length <
            maxUnitPerAssign) {
          assignments[clientId]!.add(unit);

          rankingIndex =
              (index + 1) % ranking.length;

          assigned = true;
          break;
        }
      }

      if (!assigned) {
        break;
      }
    }

    return assignments;
  }

  double _fitness(
    List<double> weights,
    List<double> scores,
  ) {
    if (weights.isEmpty) {
      return 0.0;
    }

    double weightSum = 0.0;
    double fitness = 0.0;

    for (int i = 0; i < weights.length; i++) {
      weightSum += weights[i].abs();

      fitness +=
          weights[i].abs() * scores[i];
    }

    if (weightSum == 0.0) {
      return 0.0;
    }

    return fitness / weightSum;
  }
}