import 'dart:math';

import '../models/assignment.dart';
import '../models/result_dto.dart';
import 'scheduler.dart';
import 'scheduler_utils.dart';

class MOMPSOGAScheduler implements Scheduler {
  @override
  String get id => 'mompso-ga';
  @override
  String get label => 'MOMPSO-GA';

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

    final healthScores =
        SchedulerUtils.healthScores(clients);

    final clientIds = clients.keys.toList();

    final baseScores = <String, double>{};

    for (final clientId in clientIds) {
      final estimate = clients[clientId]!;

      final processingScore =
          _processingScore(
        estimate,
        clients,
      );

      final bandwidthScore =
          _bandwidthScore(
        estimate,
        clients,
      );

      final health =
          healthScores[clientId] ?? 0.0;

      baseScores[clientId] =
          (health * 0.45) +
          (processingScore * 0.30) +
          (bandwidthScore * 0.25);
    }

    // Genetic-style crossover:
    //
    // Find the two best candidates and create a
    // blended target score.
    final sortedClients = clientIds.toList()
      ..sort(
        (a, b) => baseScores[b]!
            .compareTo(baseScores[a]!),
      );

    final bestClient = sortedClients.first;

    final secondBestClient =
        sortedClients.length > 1
            ? sortedClients[1]
            : bestClient;

    final blendedScore =
        (baseScores[bestClient]! * 0.70) +
        (baseScores[secondBestClient]! * 0.30);

    // Mutation.
    final mutatedScores = <String, double>{};

    for (final clientId in clientIds) {
      final mutation =
          (_random.nextDouble() * 0.08) - 0.04;

      mutatedScores[clientId] =
          baseScores[clientId]! + mutation;
    }

    // The candidate closest to the blended genetic
    // target becomes the preferred client.
    String preferredClient = clientIds.first;

    double smallestDifference = double.infinity;

    for (final clientId in clientIds) {
      final difference =
          (mutatedScores[clientId]! -
                  blendedScore)
              .abs();

      if (difference < smallestDifference) {
        smallestDifference = difference;
        preferredClient = clientId;
      }
    }

    // Put preferred client first.
    final ranking = clientIds.toList();

    ranking.remove(preferredClient);
    ranking.insert(0, preferredClient);

    _assignUsingRanking(
      availableUnits,
      ranking,
      assignments,
      maxUnitPerAssign,
    );

    return assignments;
  }

  void _assignUsingRanking(
    List<Unit> units,
    List<String> ranking,
    Map<String, List<Unit>> assignments,
    int maxUnits,
  ) {
    int rankingIndex = 0;

    for (final unit in units) {
      bool assigned = false;

      for (int attempt = 0;
          attempt < ranking.length;
          attempt++) {
        final index =
            (rankingIndex + attempt) %
                ranking.length;

        final clientId = ranking[index];

        if (assignments[clientId]!.length <
            maxUnits) {
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
  }

  double _processingScore(
    ClientEstimate estimate,
    Map<String, ClientEstimate> clients,
  ) {
    final minValue = clients.values
        .map((e) => e.ttprocMs)
        .reduce((a, b) => a < b ? a : b);

    final maxValue = clients.values
        .map((e) => e.ttprocMs)
        .reduce((a, b) => a > b ? a : b);

    if ((maxValue - minValue).abs() <
        0.000001) {
      return 1.0;
    }

    return 1.0 -
        ((estimate.ttprocMs - minValue) /
                (maxValue - minValue))
            .clamp(0.0, 1.0);
  }

  double _bandwidthScore(
    ClientEstimate estimate,
    Map<String, ClientEstimate> clients,
  ) {
    final minValue = clients.values
        .map((e) => e.bandwidthKbps)
        .reduce((a, b) => a < b ? a : b);

    final maxValue = clients.values
        .map((e) => e.bandwidthKbps)
        .reduce((a, b) => a > b ? a : b);

    if ((maxValue - minValue).abs() <
        0.000001) {
      return 1.0;
    }

    return ((estimate.bandwidthKbps -
                minValue) /
            (maxValue - minValue))
        .clamp(0.0, 1.0);
  }
}