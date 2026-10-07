import '../models/assignment.dart';
import '../models/result_dto.dart';
import 'scheduler.dart';
import 'scheduler_utils.dart';

class MOMPSOScheduler implements Scheduler {
  @override
  String get id => 'mompso';
  @override
  String get label => 'MOMPSO';

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

    // Current objective:
    //
    // 50% -> overall health/performance
    // 30% -> processing efficiency
    // 20% -> bandwidth efficiency
    //
    // Later this can be extended to:
    // battery + CPU + latency + queue depth + energy.

    final minTtproc = clients.values
        .map((e) => e.ttprocMs)
        .reduce((a, b) => a < b ? a : b);

    final maxTtproc = clients.values
        .map((e) => e.ttprocMs)
        .reduce((a, b) => a > b ? a : b);

    final minBandwidth = clients.values
        .map((e) => e.bandwidthKbps)
        .reduce((a, b) => a < b ? a : b);

    final maxBandwidth = clients.values
        .map((e) => e.bandwidthKbps)
        .reduce((a, b) => a > b ? a : b);

    final objectiveScores = <String, double>{};

    for (final clientId in clientIds) {
      final estimate = clients[clientId]!;

      final processingScore =
          _inverseNormalize(
        estimate.ttprocMs,
        minTtproc,
        maxTtproc,
      );

      final bandwidthScore =
          _normalize(
        estimate.bandwidthKbps,
        minBandwidth,
        maxBandwidth,
      );

      final healthScore =
          healthScores[clientId] ?? 0.0;

      objectiveScores[clientId] =
          (healthScore * 0.5) +
          (processingScore * 0.3) +
          (bandwidthScore * 0.2);
    }

    final ranking = clientIds.toList();

    ranking.sort(
      (a, b) => objectiveScores[b]!
          .compareTo(objectiveScores[a]!),
    );

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
            (rankingIndex + attempt) % ranking.length;

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

  double _normalize(
    double value,
    double min,
    double max,
  ) {
    if ((max - min).abs() < 0.000001) {
      return 1.0;
    }

    return ((value - min) / (max - min))
        .clamp(0.0, 1.0);
  }

  double _inverseNormalize(
    double value,
    double min,
    double max,
  ) {
    return 1.0 -
        _normalize(value, min, max);
  }
}