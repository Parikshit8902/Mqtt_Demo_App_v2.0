import '../models/assignment.dart';
import '../models/result_dto.dart';

abstract class Scheduler {
  /// Stable identifier used in settings, logs and exports (e.g. 'greedy').
  String get id;

  /// Human readable name for the UI.
  String get label;

  /// Decide assignments for the given job state.
  /// Returns a map clientId -> list of Units to assign.
  ///
  /// Contract: every client id in [clients] must appear as a key in the result
  /// (empty list if it gets nothing), no unit may be returned twice, and no
  /// client may receive more than [maxUnitPerAssign] units.
  ///
  /// Note the caller is pull-based: `DistributionManager.assignNext` invokes this
  /// each time one client asks for work and keeps only that client's slice. An
  /// algorithm that builds a global plan (e.g. particle swarm optimisation) can
  /// cache its plan internally and return the requesting client's share.
  Map<String, List<Unit>> schedule(List<Unit> availableUnits, Map<String, ClientEstimate> clients, int maxUnitPerAssign);
}
