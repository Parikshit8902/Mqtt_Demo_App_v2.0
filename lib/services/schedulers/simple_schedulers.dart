import 'dart:math';
import 'scheduler.dart';
import '../models/assignment.dart';
import '../models/result_dto.dart';

/// Baseline: deal units to clients in turn, ignoring speed and bandwidth.
class RoundRobinScheduler implements Scheduler {
  @override
  String get id => 'round_robin';
  @override
  String get label => 'Round robin';

  @override
  Map<String, List<Unit>> schedule(List<Unit> availableUnits, Map<String, ClientEstimate> clients, int maxUnitPerAssign) {
    final assignments = <String, List<Unit>>{for (final id in clients.keys) id: <Unit>[]};
    if (clients.isEmpty) return assignments;
    final ids = clients.keys.toList();
    var next = 0;
    for (final u in availableUnits) {
      var placed = false;
      for (var tries = 0; tries < ids.length && !placed; tries++) {
        final id = ids[(next + tries) % ids.length];
        if (assignments[id]!.length < maxUnitPerAssign) {
          assignments[id]!.add(u);
          next = (next + tries + 1) % ids.length;
          placed = true;
        }
      }
      if (!placed) break; // every client is at capacity
    }
    return assignments;
  }
}

/// Baseline: shuffle the units, then deal them out. Seeded so runs are repeatable.
class RandomScheduler implements Scheduler {
  final Random _rng;
  RandomScheduler({int seed = 42}) : _rng = Random(seed);

  @override
  String get id => 'random';
  @override
  String get label => 'Random';

  @override
  Map<String, List<Unit>> schedule(List<Unit> availableUnits, Map<String, ClientEstimate> clients, int maxUnitPerAssign) {
    final shuffled = List<Unit>.from(availableUnits)..shuffle(_rng);
    return RoundRobinScheduler().schedule(shuffled, clients, maxUnitPerAssign);
  }
}
