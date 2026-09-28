import 'dart:math';
import 'scheduler.dart';
import '../models/assignment.dart';
import '../models/result_dto.dart';

class GreedyScheduler implements Scheduler {
  @override
  Map<String, List<Unit>> schedule(List<Unit> availableUnits, Map<String, ClientEstimate> clients, int maxUnitPerAssign) {
    // Simple greedy: assign units one-by-one to the client with smallest estimated finish time
    final assignments = <String, List<Unit>>{};

    // Make a mutable copy of availableUnits
    final units = List<Unit>.from(availableUnits);

    // initialize per-client ETA (seconds)
    final clientEta = <String, double>{};
    clients.forEach((id, est) {
      // Start with zero queued time
      clientEta[id] = 0.0;
      assignments[id] = [];
    });

    // Helper to compute transmit time (seconds) for a unit
    double ttransmit(Unit u, ClientEstimate e) {
      final bytes = (u.end - u.start + 1).toDouble();
      final kbps = max(1.0, e.bandwidthKbps); // avoid div0
      return (bytes / 1024.0) / kbps; // seconds
    }

    // Helper to compute processing time (seconds)
    double tprocess(ClientEstimate e) => max(0.0, e.ttprocMs) / 1000.0;

    while (units.isNotEmpty) {
      // For each unit, find best client (min eta + ttransmit + tprocess)
      Unit bestUnit = units.first;
      String bestClient = clients.keys.first;
      double bestScore = double.infinity;

      for (final u in units) {
        for (final entry in clients.entries) {
          final id = entry.key;
          final est = entry.value;
          final score = clientEta[id]! + ttransmit(u, est) + tprocess(est);
          if (score < bestScore) {
            bestScore = score;
            bestUnit = u;
            bestClient = id;
          }
        }
      }

      // assign bestUnit to bestClient if they haven't hit maxUnitPerAssign
      if (assignments[bestClient]!.length < maxUnitPerAssign) {
        assignments[bestClient]!.add(bestUnit);
        // advance client's eta
        final est = clients[bestClient]!;
        clientEta[bestClient] = clientEta[bestClient]! + ttransmit(bestUnit, est) + tprocess(est);
      } else {
        // If bestClient is saturated, try to find next-best client for this unit
        bool assigned = false;
        for (final entry in clients.entries) {
          final id = entry.key;
          if (assignments[id]!.length < maxUnitPerAssign) {
            assignments[id]!.add(bestUnit);
            final est = clients[id]!;
            clientEta[id] = clientEta[id]! + ttransmit(bestUnit, est) + tprocess(est);
            assigned = true;
            break;
          }
        }
        if (!assigned) break; // all clients saturated
      }

      units.remove(bestUnit);
    }

    return assignments;
  }
}
