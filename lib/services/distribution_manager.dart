import 'models/assignment.dart';
import 'models/result_dto.dart';
import 'schedulers/scheduler.dart';
import 'schedulers/scheduler_type.dart';
import 'schedulers/scheduler_factory.dart';

class DistributionManager {
  Scheduler _scheduler;

  SchedulerType _schedulerType =
      SchedulerType.greedy;

  DistributionManager()
      : _scheduler =
            SchedulerFactory.create(
          SchedulerType.greedy,
        );

  /// Currently selected scheduling algorithm.
  SchedulerType get schedulerType =>
      _schedulerType;

  /// Human-readable scheduler name.
  String get schedulerName =>
      _schedulerType.displayName;

  /// Change the scheduling algorithm.
  ///
  /// This affects new assignments only.
  /// Units that have already been assigned are
  /// not moved between clients.
  void setSchedulerType(
    SchedulerType type,
  ) {
    if (_schedulerType == type) {
      return;
    }

    _schedulerType = type;
    _scheduler = SchedulerFactory.create(type);
  }

  // jobId -> units
  final Map<String, List<Unit>> _jobs = {};

  // jobId -> unitIndex -> status: 'available'|'assigned'|'completed'
  final Map<String, Map<int, String>> _unitStatus = {};

  // clientId -> estimate
  final Map<String, ClientEstimate> _clientEstimates = {};

  // simple in-memory assignment queue per client
  final Map<String, List<Unit>> _clientQueues = {};

  // register a job and its units
  void registerJob(String jobId, List<Unit> units) {
    _jobs[jobId] = List<Unit>.from(units);
    _unitStatus[jobId] = {for (var u in units) u.unitIndex: 'available'};
  }

  void registerClient(String clientId, ClientEstimate initial) {
    _clientEstimates[clientId] = initial;
    _clientQueues[clientId] = [];
  }

  List<Unit> getClientQueue(String clientId) => List<Unit>.from(_clientQueues[clientId] ?? []);

  /// Return registered client ids
  List<String> get registeredClientIds => _clientEstimates.keys.toList();

  void updateClientEstimate(String clientId, double ttprocMs, double bandwidthKbps, {double alpha = 0.2}) {
    final prev = _clientEstimates[clientId];
    if (prev == null) {
      _clientEstimates[clientId] = ClientEstimate(ttprocMs: ttprocMs, bandwidthKbps: bandwidthKbps);
      return;
    }
    // EMA
    prev.ttprocMs = alpha * ttprocMs + (1 - alpha) * prev.ttprocMs;
    prev.bandwidthKbps = alpha * bandwidthKbps + (1 - alpha) * prev.bandwidthKbps;
  }

  // mark unit complete and update internal state
  void markUnitComplete(String jobId, int unitIndex) {
    final statusMap = _unitStatus[jobId];
    if (statusMap == null) return;
    statusMap[unitIndex] = 'completed';
    // remove from any client queue
    _clientQueues.forEach((_, q) => q.removeWhere((u) => u.unitIndex == unitIndex));
  }

  // assign next units for a client (simple wrapper around scheduler)
  List<Unit> assignNext(String jobId, String clientId, {int maxUnits = 2}) {
    final units = _jobs[jobId];
    if (units == null) return [];

    final available = units.where((u) => _unitStatus[jobId]![u.unitIndex] == 'available').toList();
    if (available.isEmpty) return [];

    final assignments = _scheduler.schedule(available, _clientEstimates, maxUnits);
    final assignedForClient = assignments[clientId] ?? [];

    for (final u in assignedForClient) {
      _unitStatus[jobId]![u.unitIndex] = 'assigned';
      _clientQueues[clientId]!.add(u);
    }

    return assignedForClient;
  }

  /// Produce a scheduling suggestion without mutating internal state.
  /// Useful for logging or previewing assignments.
  List<Unit> suggestNext(String jobId, String clientId, {int maxUnits = 2}) {
    final units = _jobs[jobId];
    if (units == null) return [];

    final available = units.where((u) => _unitStatus[jobId]![u.unitIndex] == 'available').toList();
    if (available.isEmpty) return [];

    final assignments = _scheduler.schedule(available, _clientEstimates, maxUnits);
    final assignedForClient = assignments[clientId] ?? [];
    // Do not change _unitStatus or client queues - this is non-destructive
    return assignedForClient;
  }

  // simple getter for job progress
  Map<String, int> jobProgress(String jobId) {
    final status = _unitStatus[jobId];
    if (status == null) return {'total': 0, 'completed': 0, 'available': 0};
    final total = status.length;
    final completed = status.values.where((v) => v == 'completed').length;
  final assigned = status.values.where((v) => v == 'assigned').length;
  final available = status.values.where((v) => v == 'available').length;
  return {'total': total, 'completed': completed, 'assigned': assigned, 'available': available};
  }

  /// Return whether a job is registered
  bool hasJob(String jobId) => _jobs.containsKey(jobId);

  /// Return the fileUrl for a specific unit in a job, or null if not found.
  String? getUnitFileUrl(String jobId, int unitIndex) {
    final units = _jobs[jobId];
    if (units == null) return null;
    try {
      final u = units.firstWhere((e) => e.unitIndex == unitIndex);
      return u.fileUrl;
    } catch (_) {
      return null;
    }
  }
}
