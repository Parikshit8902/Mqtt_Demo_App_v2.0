import 'models/assignment.dart';
import 'models/result_dto.dart';
import 'schedulers/scheduler.dart';
import 'schedulers/scheduler_type.dart';
import 'schedulers/scheduler_factory.dart';
import 'schedulers/scheduler_registry.dart';

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

  /// Stable id of the active algorithm (used in logs, exports and REST).
  String get schedulerId =>
      _schedulerType.id;

  /// Select an algorithm by id (see [SchedulerRegistry]).
  void setScheduler(String id) {
    final type = SchedulerTypeExtension.tryFromId(id);

    if (type == null) {
      throw ArgumentError('Unknown scheduler: $id');
    }

    setSchedulerType(type);
  }

  /// Cost of the scheduling decision itself. It matters on a phone host:
  /// a PSO run is far heavier than greedy.
  int scheduleCalls = 0;
  int scheduleTotalUs = 0;

  double get avgScheduleMs =>
      scheduleCalls == 0
          ? 0
          : scheduleTotalUs / scheduleCalls / 1000.0;

  Map<String, List<Unit>> _runScheduler(
    List<Unit> available,
    int maxUnits,
  ) {
    final sw = Stopwatch()..start();

    final result = _scheduler.schedule(
      available,
      _clientEstimates,
      maxUnits,
    );

    sw.stop();
    scheduleCalls++;
    scheduleTotalUs += sw.elapsedMicroseconds;

    return result;
  }

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
    scheduleCalls = 0;
    scheduleTotalUs = 0;
  }

  // jobId -> units
  final Map<String, List<Unit>> _jobs = {};

  // jobId -> unitIndex -> status:
  // 'available'|'assigned'|'completed'
  final Map<String, Map<int, String>> _unitStatus = {};

  // clientId -> estimate
  final Map<String, ClientEstimate> _clientEstimates = {};

  // simple in-memory assignment queue per client
  final Map<String, List<Unit>> _clientQueues = {};

  // Jobs that have been reset and must not issue new
  // assignments until the next experiment activates them.
  final Set<String> _inactiveJobs = {};

  // ---------------------------------------------------------------------------
  // JOB MANAGEMENT
  // ---------------------------------------------------------------------------

  /// Register a job and its units.
  ///
  /// A newly registered job is active by default.
  void registerJob(
    String jobId,
    List<Unit> units,
  ) {
    _jobs[jobId] = List<Unit>.from(units);

    _unitStatus[jobId] = {
      for (var u in units) u.unitIndex: 'available'
    };

    // A newly registered job is active.
    _inactiveJobs.remove(jobId);
  }

  /// Reactivate a job for a new experiment.
  ///
  /// This is called when a new distribution is submitted after
  /// an experiment has previously been reset.
  void activateJob(String jobId) {
    if (_jobs.containsKey(jobId)) {
      _inactiveJobs.remove(jobId);
    }
  }

  /// Reset the scheduling state for a new experiment.
  ///
  /// This intentionally preserves:
  /// - connected clients
  /// - client performance estimates
  /// - registered job/dataset definitions
  /// - selected scheduling algorithm
  ///
  /// It resets:
  /// - unit status
  /// - client assignment queues
  ///
  /// Jobs are marked inactive until the next experiment
  /// explicitly activates them.
  void resetExperiment() {
    // Reset every registered unit to the available state.
    for (final statusMap in _unitStatus.values) {
      statusMap.updateAll(
        (unitIndex, status) => 'available',
      );
    }

    // Remove all outstanding client assignments.
    for (final queue in _clientQueues.values) {
      queue.clear();
    }

    // Prevent clients from receiving assignments until
    // the next experiment starts.
    _inactiveJobs
      ..clear()
      ..addAll(_jobs.keys);
  }

  // ---------------------------------------------------------------------------
  // CLIENT MANAGEMENT
  // ---------------------------------------------------------------------------

  void registerClient(
    String clientId,
    ClientEstimate initial,
  ) {
    _clientEstimates[clientId] = initial;
    _clientQueues[clientId] = [];
  }

  List<Unit> getClientQueue(
    String clientId,
  ) {
    return List<Unit>.from(
      _clientQueues[clientId] ?? [],
    );
  }

  /// Return registered client ids.
  List<String> get registeredClientIds =>
      _clientEstimates.keys.toList();

  void updateClientEstimate(
    String clientId,
    double ttprocMs,
    double bandwidthKbps, {
    double alpha = 0.2,
  }) {
    final prev =
        _clientEstimates[clientId];

    if (prev == null) {
      _clientEstimates[clientId] =
          ClientEstimate(
        ttprocMs: ttprocMs,
        bandwidthKbps: bandwidthKbps,
      );
      return;
    }

    // EMA
    prev.ttprocMs =
        alpha * ttprocMs +
        (1 - alpha) * prev.ttprocMs;

    prev.bandwidthKbps =
        alpha * bandwidthKbps +
        (1 - alpha) * prev.bandwidthKbps;
  }

  // ---------------------------------------------------------------------------
  // UNIT MANAGEMENT
  // ---------------------------------------------------------------------------

  /// Mark a unit as completed and update internal state.
  void markUnitComplete(
    String jobId,
    int unitIndex,
  ) {
    final statusMap =
        _unitStatus[jobId];

    if (statusMap == null) {
      return;
    }

    statusMap[unitIndex] = 'completed';

    // Remove the completed unit from any client queue.
    _clientQueues.forEach(
      (_, q) {
        q.removeWhere(
          (u) => u.unitIndex == unitIndex,
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // SCHEDULING
  // ---------------------------------------------------------------------------

  /// Assign the next units for a client.
  ///
  /// This is a wrapper around the currently selected scheduler.
  ///
  /// If the job has been reset and has not yet been activated
  /// for a new experiment, no assignments are returned.
  List<Unit> assignNext(
    String jobId,
    String clientId, {
    int maxUnits = 2,
  }) {
    // Do not issue assignments while the experiment is reset.
    if (_inactiveJobs.contains(jobId)) {
      return [];
    }

    final units = _jobs[jobId];

    if (units == null) {
      return [];
    }

    final available = units
        .where(
          (u) =>
              _unitStatus[jobId]![
                  u.unitIndex] ==
              'available',
        )
        .toList();

    if (available.isEmpty) {
      return [];
    }

    final assignments =
        _runScheduler(available, maxUnits);

    final assignedForClient =
        assignments[clientId] ?? [];

    for (final u in assignedForClient) {
      _unitStatus[jobId]![u.unitIndex] =
          'assigned';

      _clientQueues[clientId]!.add(u);
    }

    return assignedForClient;
  }

  /// Produce a scheduling suggestion without mutating internal state.
  ///
  /// Useful for logging or previewing assignments.
  ///
  /// If the job has been reset and has not yet been activated
  /// for a new experiment, no suggestions are returned.
  List<Unit> suggestNext(
    String jobId,
    String clientId, {
    int maxUnits = 2,
  }) {
    // Do not provide assignments while the experiment is reset.
    if (_inactiveJobs.contains(jobId)) {
      return [];
    }

    final units = _jobs[jobId];

    if (units == null) {
      return [];
    }

    final available = units
        .where(
          (u) =>
              _unitStatus[jobId]![
                  u.unitIndex] ==
              'available',
        )
        .toList();

    if (available.isEmpty) {
      return [];
    }

    final assignments =
        _runScheduler(available, maxUnits);

    final assignedForClient =
        assignments[clientId] ?? [];

    // Do not change _unitStatus or client queues.
    return assignedForClient;
  }

  // ---------------------------------------------------------------------------
  // JOB PROGRESS
  // ---------------------------------------------------------------------------

  /// Return simple progress information for a job.
  Map<String, int> jobProgress(
    String jobId,
  ) {
    final status =
        _unitStatus[jobId];

    if (status == null) {
      return {
        'total': 0,
        'completed': 0,
        'assigned': 0,
        'available': 0,
      };
    }

    final total = status.length;

    final completed = status.values
        .where(
          (v) => v == 'completed',
        )
        .length;

    final assigned = status.values
        .where(
          (v) => v == 'assigned',
        )
        .length;

    final available = status.values
        .where(
          (v) => v == 'available',
        )
        .length;

    return {
      'total': total,
      'completed': completed,
      'assigned': assigned,
      'available': available,
    };
  }

  // ---------------------------------------------------------------------------
  // JOB QUERIES
  // ---------------------------------------------------------------------------

  /// Return whether a job is registered.
  bool hasJob(
    String jobId,
  ) =>
      _jobs.containsKey(jobId);

  /// Return the file URL for a specific unit in a job,
  /// or null if the unit is not found.
  String? getUnitFileUrl(
    String jobId,
    int unitIndex,
  ) {
    final units = _jobs[jobId];

    if (units == null) {
      return null;
    }

    try {
      final u = units.firstWhere(
        (e) => e.unitIndex == unitIndex,
      );

      return u.fileUrl;
    } catch (_) {
      return null;
    }
  }
}