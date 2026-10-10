import 'dynamic_scheduler.dart';
import 'scheduling_model.dart';
import '../models/assignment.dart';

/// Greedy heterogeneous task scheduler.
///
/// The scheduler follows a direct greedy list-scheduling rule:
///
///   (i*, j*) = argmin C(i, j)
///
/// where:
///
///   C(i, j) = W_i + T_in(i, j) + T_proc(i, j)
///
/// and:
///
///   i     = worker/client
///   j     = available task/unit
///   W_i   = predicted time required to drain the worker's current queue
///   T_in  = predicted time to transfer the input unit to the worker
///   T_proc = predicted processing time on the worker
///
/// At every iteration, the currently best (unit, worker) pair is selected.
/// Once the assignment is made, the worker's queue is updated through
/// DynamicScheduler/FleetModel and the next greedy decision sees the updated
/// system state.
///
/// This is a greedy heuristic for heterogeneous-machine scheduling. It does
/// not claim global optimality.
///
/// The implementation deliberately does NOT use:
///   - health-score maximisation,
///   - weighted objective functions,
///   - PSO,
///   - random mutation,
///   - arbitrary scan windows.
///
/// Device health remains relevant because FleetModel incorporates thermal,
/// battery, memory, reliability and Wi-Fi effects into the effective processing
/// and communication estimates used to calculate completion time.
///
/// The hard scheduling constraints implemented by DynamicScheduler remain:
///   - gated devices are excluded when another eligible device exists;
///   - every unit is assigned at most once;
///   - a client cannot exceed its per-round capacity;
///   - assignments made earlier in the greedy construction affect later
///     decisions through the updated queue depth.
class GreedyScheduler extends DynamicScheduler {
  GreedyScheduler({
    super.random,
    super.config,
  });

  @override
  String get id => 'greedy';

  @override
  String get label => 'Greedy';

  /// Select the globally best currently available (unit, client) pair.
  ///
  /// The greedy rule is:
  ///
  ///     min over clients and units:
  ///
  ///         estimated completion time
  ///
  /// For every client we first find that client's best remaining unit.
  /// We then compare those candidates globally.
  ///
  /// Since [FleetModel.etaMs] already incorporates:
  ///
  ///     queue waiting time
  ///     + input transfer time
  ///     + processing time
  ///
  /// this is exactly the local completion-time criterion used here.
  ///
  /// There is intentionally no bounded scan window. Every available unit is
  /// considered, so the result is not dependent on an arbitrary constant such
  /// as "first 256 units".
  @override
  UnitPick? pickPair(
    FleetModel fleet,
    List<Unit> remaining,
    List<String> open,
  ) {
    if (remaining.isEmpty || open.isEmpty) {
      return null;
    }

    String? bestClient;
    Unit? bestUnit;
    double bestCompletion = double.infinity;

    for (final clientId in open) {
      for (final unit in remaining) {
        final completion = fleet.etaMs(clientId, unit);

        if (_isBetterCandidate(
          fleet: fleet,
          clientId: clientId,
          unit: unit,
          completion: completion,
          bestClient: bestClient,
          bestUnit: bestUnit,
          bestCompletion: bestCompletion,
        )) {
          bestClient = clientId;
          bestUnit = unit;
          bestCompletion = completion;
        }
      }
    }

    if (bestClient == null || bestUnit == null) {
      return null;
    }

    return UnitPick(bestUnit, bestClient);
  }

  /// Fallback required by [DynamicScheduler].
  ///
  /// The normal path for this scheduler is [pickPair], because the greedy
  /// decision is made jointly over the available units and clients.
  ///
  /// If only a single unit is supplied, this becomes the conventional
  /// earliest-completion-time assignment:
  ///
  ///     i* = argmin_i C(i, j)
  @override
  String pick(
    FleetModel fleet,
    List<String> open,
    Unit unit,
  ) {
    var bestClient = open.first;
    var bestCompletion = fleet.etaMs(bestClient, unit);

    for (final clientId in open.skip(1)) {
      final completion = fleet.etaMs(clientId, unit);

      if (_isBetterClient(
        fleet: fleet,
        clientId: clientId,
        completion: completion,
        bestClient: bestClient,
        bestCompletion: bestCompletion,
      )) {
        bestClient = clientId;
        bestCompletion = completion;
      }
    }

    return bestClient;
  }

  /// Determines whether a complete (client, unit) candidate is better than
  /// the current greedy candidate.
  ///
  /// Primary criterion:
  ///
  ///     minimum predicted completion time.
  ///
  /// Secondary criteria are deterministic tie-breakers only. They do not alter
  /// the mathematical greedy objective.
  ///
  /// 1. Earlier completion time.
  /// 2. Lower marginal energy.
  /// 3. Higher health score.
  /// 4. Smaller client id.
  /// 5. Smaller unit index.
  bool _isBetterCandidate({
    required FleetModel fleet,
    required String clientId,
    required Unit unit,
    required double completion,
    required String? bestClient,
    required Unit? bestUnit,
    required double bestCompletion,
  }) {
    const epsilon = 1e-9;

    if (bestClient == null || bestUnit == null) {
      return true;
    }

    if (completion < bestCompletion - epsilon) {
      return true;
    }

    if ((completion - bestCompletion).abs() > epsilon) {
      return false;
    }

    final energy = fleet.energyJ(clientId);
    final bestEnergy = fleet.energyJ(bestClient);

    if (energy < bestEnergy - epsilon) {
      return true;
    }

    if ((energy - bestEnergy).abs() > epsilon) {
      return false;
    }

    final health = fleet.healthScore(clientId);
    final bestHealth = fleet.healthScore(bestClient);

    if (health > bestHealth + epsilon) {
      return true;
    }

    if ((health - bestHealth).abs() > epsilon) {
      return false;
    }

    final clientComparison = clientId.compareTo(bestClient);

    if (clientComparison != 0) {
      return clientComparison < 0;
    }

    return unit.unitIndex < bestUnit.unitIndex;
  }

  /// Compare two clients for one fixed unit.
  ///
  /// Completion time remains the only optimization criterion. Energy,
  /// health and client id are deterministic tie-breakers.
  bool _isBetterClient({
    required FleetModel fleet,
    required String clientId,
    required double completion,
    required String bestClient,
    required double bestCompletion,
  }) {
    const epsilon = 1e-9;

    if (completion < bestCompletion - epsilon) {
      return true;
    }

    if ((completion - bestCompletion).abs() > epsilon) {
      return false;
    }

    final energy = fleet.energyJ(clientId);
    final bestEnergy = fleet.energyJ(bestClient);

    if (energy < bestEnergy - epsilon) {
      return true;
    }

    if ((energy - bestEnergy).abs() > epsilon) {
      return false;
    }

    final health = fleet.healthScore(clientId);
    final bestHealth = fleet.healthScore(bestClient);

    if (health > bestHealth + epsilon) {
      return true;
    }

    if ((health - bestHealth).abs() > epsilon) {
      return false;
    }

    return clientId.compareTo(bestClient) < 0;
  }
}