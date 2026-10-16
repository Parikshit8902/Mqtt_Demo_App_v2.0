import 'dart:math';
import '../models/assignment.dart';
import '../models/result_dto.dart';
import 'scheduler.dart';
import 'scheduling_model.dart';

/// A unit paired with the client chosen for it.
class UnitPick {
  final Unit unit;
  final String client;
  const UnitPick(this.unit, this.client);
}

/// Shared skeleton for the four live-data schedulers.
///
/// Contract with `DistributionManager`: `schedule` is called with a *snapshot*
/// of the active clients (live health, queue depth, recent latency filled in),
/// and only the requesting client's slice of the result is committed.
///
/// What the base class guarantees, so subclasses can't get it wrong:
///  * every client appears in the result (empty list if it gets nothing);
///  * no unit is assigned twice and no client exceeds its per-round cap;
///  * phones in a gated state (very low battery, critical thermal, ...) get
///    nothing, unless every phone is gated, in which case none is excluded;
///  * each assignment is visible to the next pick (queue depth grows), which is
///    what spreads a batch across phones instead of piling it on the best one.
///
/// Subclasses implement only [pick] (and, for Greedy, [pickPair]).
abstract class DynamicScheduler implements Scheduler {
  /// Injectable so tests can be deterministic. Production uses an unseeded one.
  final Random random;
  final SchedulingConfig config;

  DynamicScheduler({Random? random, this.config = SchedulingConfig.defaults}) : random = random ?? Random();

  /// Why each phone looked the way it did in the most recent call.
  /// `{scheduler: id, clients: {clientId: {health, latency_ms, ...}}}`
  Map<String, dynamic> lastTrace = const {};

  /// Choose which of [open] (clients with room, never empty) gets [unit].
  String pick(FleetModel fleet, List<String> open, Unit unit);

  /// Optional: choose a unit and its client together. Return null to take
  /// units in the order given and use [pick].
  UnitPick? pickPair(FleetModel fleet, List<Unit> remaining, List<String> open) => null;

  /// Optional whole-batch plan. The plan is computed once from the initial
  /// fleet snapshot; the base class still validates every pair and records
  /// assignments through [FleetModel]. Returning null preserves incremental
  /// scheduling for existing schedulers.
  List<UnitPick>? planBatch(
    FleetModel fleet,
    List<Unit> remaining,
    List<String> open,
  ) => null;

  @override
  Map<String, List<Unit>> schedule(
    List<Unit> availableUnits,
    Map<String, ClientEstimate> clients,
    int maxUnitPerAssign,
  ) {
    final assignments = <String, List<Unit>>{for (final id in clients.keys) id: <Unit>[]};
    if (availableUnits.isEmpty || clients.isEmpty || maxUnitPerAssign <= 0) {
      lastTrace = {'scheduler': id, 'clients': const {}};
      return assignments;
    }

    final fleet = FleetModel(clients, availableUnits, maxUnitPerAssign, cfg: config);
    final remaining = List<Unit>.from(availableUnits);
    final initialOpen = fleet.eligibleIds
        .where((c) => assignments[c]!.length < fleet.capFor(c))
        .toList();
    final batchPlan = planBatch(
      fleet,
      List<Unit>.unmodifiable(remaining),
      List<String>.unmodifiable(initialOpen),
    );
    if (batchPlan != null) {
      _validateBatchPlan(batchPlan, remaining, initialOpen, fleet);
    }
    var batchPlanIndex = 0;

    while (remaining.isNotEmpty) {
      final open = fleet.eligibleIds.where((c) => assignments[c]!.length < fleet.capFor(c)).toList();
      if (open.isEmpty) break; // every eligible phone is at its cap

      final Unit unit;
      final String winner;
      UnitPick? pair;
      if (batchPlan != null) {
        // A non-null batch plan is an explicit optimizer decision. Never
        // silently switch to a different algorithm when that plan is spent.
        if (batchPlanIndex >= batchPlan.length) {
          throw StateError(
            '$id returned an incomplete batch plan: '
            '${batchPlan.length} picks for ${min(remaining.length, open.fold<int>(0, (sum, client) => sum + fleet.capFor(client) - assignments[client]!.length))} remaining schedulable slots.',
          );
        }
        pair = batchPlan[batchPlanIndex++];
        unit = pair.unit;
        winner = pair.client;
        if (!remaining.remove(unit)) {
          throw StateError('$id batch plan reused a unit that is no longer available.');
        }
      } else {
        pair = pickPair(fleet, remaining, open);
        if (pair != null && remaining.contains(pair.unit) && open.contains(pair.client)) {
          unit = pair.unit;
          winner = pair.client;
          remaining.remove(unit);
        } else {
          unit = remaining.removeAt(0);
          winner = open.length == 1 ? open.first : pick(fleet, open, unit);
        }
      }

      assignments[winner]!.add(unit);
      fleet.recordAssignment(winner);
    }

    lastTrace = {'scheduler': id, 'clients': fleet.explain()};
    return assignments;
  }

  /// Validate a whole-batch plan before committing any of it. A planner must
  /// cover every slot that can be filled under the shared scheduler's caps;
  /// otherwise the base class would silently mix algorithms or leave work
  /// unassigned. The plan may omit units only when aggregate capacity is lower
  /// than the number of available units.
  void _validateBatchPlan(
    List<UnitPick> plan,
    List<Unit> available,
    List<String> open,
    FleetModel fleet,
  ) {
    final capacityByClient = <String, int>{
      for (final client in open) client: fleet.capFor(client),
    };
    final totalCapacity = capacityByClient.values.fold<int>(0, (a, b) => a + b);
    final expectedLength = min(available.length, totalCapacity);
    if (plan.length != expectedLength) {
      throw StateError(
        '$id returned ${plan.length} picks; expected $expectedLength '
        'to fill all schedulable slots.',
      );
    }

    final availableSet = available.toSet();
    final plannedUnits = <Unit>{};
    final counts = <String, int>{};
    for (final pick in plan) {
      if (!availableSet.contains(pick.unit)) {
        throw StateError('$id batch plan contains a unit outside the available batch.');
      }
      if (!plannedUnits.add(pick.unit)) {
        throw StateError('$id batch plan assigns the same unit more than once.');
      }
      final cap = capacityByClient[pick.client];
      if (cap == null) {
        throw StateError('$id batch plan assigns work to an ineligible client: ${pick.client}.');
      }
      final count = (counts[pick.client] ?? 0) + 1;
      if (count > cap) {
        throw StateError('$id batch plan exceeds ${pick.client} capacity ($cap).');
      }
      counts[pick.client] = count;
    }
  }

  /// Best-scoring id, ties broken by id so results don't depend on map order.
  static String argmax(Iterable<String> ids, double Function(String) score) {
    String? best;
    double bestScore = double.negativeInfinity;
    for (final id in ids) {
      final s = score(id);
      if (best == null || s > bestScore || (s == bestScore && id.compareTo(best) < 0)) {
        best = id;
        bestScore = s;
      }
    }
    return best!;
  }
}