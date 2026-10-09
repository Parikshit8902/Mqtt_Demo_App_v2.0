import 'dart:math';

import '../models/assignment.dart';
import 'dynamic_scheduler.dart';
import 'scheduling_model.dart';

/// Greedy (earliest finish): repeatedly hand the (unit, phone) pair that would
/// finish soonest to that phone, then let its queue grow before the next pick.
/// That growing queue is what spreads a batch over the phones, each in
/// proportion to how quickly it drains work.
///
/// "Soonest" is [FleetModel.etaMs], so the choice follows the phones' live
/// state: queue depth, recently measured latency, thermal / battery / memory
/// derating of processing speed, Wi-Fi signal and bandwidth for the transfer,
/// and recent lease expiries. Phones in a gated state are filtered out by
/// [DynamicScheduler] before this class is asked. CPU load and device power
/// class only matter when two phones would finish at exactly the same moment,
/// through the tie-breaks (lower energy, then higher health score).
///
/// This is a one-step heuristic: it never revisits an earlier assignment, so
/// the batch it produces is good, not provably optimal.
class GreedyScheduler extends DynamicScheduler {
  GreedyScheduler({super.random, super.config});

  /// Units examined per pick. Units are interchangeable apart from their size,
  /// so the earliest finish inside a bounded window is as good as one found
  /// across thousands of units, and the cost per pick stays
  /// O(window x phones) however large the job is. A smaller unit sitting past
  /// the window is not seen; for equal-sized units that costs nothing.
  static const int _scanWindow = 256;

  @override
  String get id => 'greedy';

  @override
  String get label => 'Greedy (earliest finish)';

  @override
  UnitPick? pickPair(FleetModel fleet, List<Unit> remaining, List<String> open) {
    if (remaining.isEmpty || open.isEmpty) return null;

    final scanned = min(remaining.length, _scanWindow);

    String? bestClient;
    Unit? bestUnit;
    double bestEta = double.infinity;

    // For one phone, finish time differs between units only through transfer
    // time, so its best unit is found on its own; the phones are then compared
    // with the full tie-break order. This is the same minimum a scan of every
    // (unit, phone) pair would give.
    for (final client in open) {
      Unit unit = remaining.first;
      double eta = fleet.etaMs(client, unit);
      for (var i = 1; i < scanned; i++) {
        final candidate = remaining[i];
        final candidateEta = fleet.etaMs(client, candidate);
        if (candidateEta < eta || (candidateEta == eta && candidate.unitIndex < unit.unitIndex)) {
          unit = candidate;
          eta = candidateEta;
        }
      }

      if (bestClient == null || _prefers(fleet, client, eta, bestClient, bestEta)) {
        bestClient = client;
        bestUnit = unit;
        bestEta = eta;
      }
    }

    return UnitPick(bestUnit!, bestClient!);
  }

  @override
  String pick(FleetModel fleet, List<String> open, Unit unit) {
    String best = open.first;
    double bestEta = fleet.etaMs(best, unit);

    for (final client in open.skip(1)) {
      final eta = fleet.etaMs(client, unit);
      if (_prefers(fleet, client, eta, best, bestEta)) {
        best = client;
        bestEta = eta;
      }
    }
    return best;
  }

  /// True when [client] beats [best] for the same work: earlier finish, then
  /// lower energy, then higher health score, then the smaller id so the result
  /// does not depend on map order.
  bool _prefers(FleetModel fleet, String client, double eta, String best, double bestEta) {
    if (eta != bestEta) return eta < bestEta;

    final energy = fleet.energyJ(client);
    final bestEnergy = fleet.energyJ(best);
    if (energy != bestEnergy) return energy < bestEnergy;

    final health = fleet.healthScore(client);
    final bestHealth = fleet.healthScore(best);
    if (health != bestHealth) return health > bestHealth;

    return client.compareTo(best) < 0;
  }
}
