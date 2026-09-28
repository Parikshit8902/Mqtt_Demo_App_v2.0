import '../models/assignment.dart';
import '../models/result_dto.dart';

abstract class Scheduler {
  /// Decide assignments for the given job state.
  /// Returns a map clientId -> list of Units to assign.
  Map<String, List<Unit>> schedule(List<Unit> availableUnits, Map<String, ClientEstimate> clients, int maxUnitPerAssign);
}
