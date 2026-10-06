import '../models/assignment.dart';
import '../models/result_dto.dart';

class SchedulerUtils {
  SchedulerUtils._();

  /// Generates a normalized performance score for every client.
  ///
  /// Higher score = better client.
  ///
  /// Current available metrics:
  ///   - ttprocMs       -> lower is better
  ///   - bandwidthKbps  -> higher is better
  ///
  /// Later, this can be extended with:
  ///   - CPU usage
  ///   - battery
  ///   - FPS
  ///   - queue depth
  ///   - latency
  static Map<String, double> healthScores(
    Map<String, ClientEstimate> clients,
  ) {
    if (clients.isEmpty) {
      return {};
    }

    if (clients.length == 1) {
      return {
        clients.keys.first: 1.0,
      };
    }

    double minTtproc = double.infinity;
    double maxTtproc = double.negativeInfinity;

    double minBandwidth = double.infinity;
    double maxBandwidth = double.negativeInfinity;

    for (final estimate in clients.values) {
      minTtproc = _min(minTtproc, estimate.ttprocMs);
      maxTtproc = _max(maxTtproc, estimate.ttprocMs);

      minBandwidth = _min(minBandwidth, estimate.bandwidthKbps);
      maxBandwidth = _max(maxBandwidth, estimate.bandwidthKbps);
    }

    final scores = <String, double>{};

    for (final entry in clients.entries) {
      final estimate = entry.value;

      // Lower processing time is better.
      final processingScore = _inverseNormalize(
        estimate.ttprocMs,
        minTtproc,
        maxTtproc,
      );

      // Higher bandwidth is better.
      final bandwidthScore = _normalize(
        estimate.bandwidthKbps,
        minBandwidth,
        maxBandwidth,
      );

      // Equal weighting for now.
      //
      // This can later become a richer health function using
      // CPU, battery, FPS, queue depth, latency, etc.
      final score =
          (processingScore * 0.5) +
          (bandwidthScore * 0.5);

      scores[entry.key] = score;
    }

    return scores;
  }

  static double _normalize(
    double value,
    double min,
    double max,
  ) {
    if ((max - min).abs() < 0.000001) {
      return 1.0;
    }

    return ((value - min) / (max - min)).clamp(0.0, 1.0);
  }

  static double _inverseNormalize(
    double value,
    double min,
    double max,
  ) {
    return 1.0 - _normalize(value, min, max);
  }

  static double _min(double a, double b) {
    return a < b ? a : b;
  }

  static double _max(double a, double b) {
    return a > b ? a : b;
  }

  /// Returns client IDs ordered from best to worst.
  static List<String> rankClients(
    Map<String, ClientEstimate> clients,
  ) {
    final scores = healthScores(clients);

    final ids = scores.keys.toList();

    ids.sort(
      (a, b) => scores[b]!.compareTo(scores[a]!),
    );

    return ids;
  }

  /// Adds units to client assignments while respecting maxUnitsPerAssign.
  static Map<String, List<Unit>> initializeAssignments(
    Map<String, ClientEstimate> clients,
  ) {
    return {
      for (final clientId in clients.keys)
        clientId: <Unit>[],
    };
  }
}