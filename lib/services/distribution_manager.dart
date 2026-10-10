import 'metrics/metrics_store.dart'
    show deviceKeyFromClientId, deviceNameFromClientId;
import 'models/assignment.dart';
import 'models/device_health.dart';
import 'models/result_dto.dart';
import 'schedulers/dynamic_scheduler.dart';
import 'schedulers/scheduler.dart';
import 'schedulers/scheduler_type.dart';
import 'schedulers/scheduler_factory.dart';
import 'schedulers/scheduler_registry.dart';
import 'schedulers/scheduling_model.dart';

class DistributionManager {
  /// How long a unit may stay assigned without a result before it is handed
  /// back to the pool. A phone that crashes or drops off Wi-Fi would otherwise
  /// strand its units (and its queue depth) forever.

  final int leaseMs;

  /// A phone the host has not heard from for longer than this is left out of
  /// scheduling decisions, so a dead phone cannot keep winning picks and
  /// starve the phone that is actually asking for work.

  final int activeWindowMs;

  /// Optional sink for notable events (a unit reclaimed after its lease
  /// expired). The file server points it at the host log.

  void Function(String message)? onLog;

  final int Function() _nowMs;
  // Size of the per-client latency window, and how far back a lease expiry
  // still counts as a recent failure.
  static const int _latencyWindow = 5;
  static const int _failureWindowMs = 5 * 60 * 1000;
  Scheduler _scheduler;

  SchedulerType _schedulerType = SchedulerType.greedy;

  /// [nowMs] is injectable so tests can drive the clock.
  DistributionManager({
    int Function()? nowMs,
    this.leaseMs = 60000,
    this.activeWindowMs = 30000,
  }) : _nowMs = nowMs ?? _wallClockMs,
       _scheduler = SchedulerFactory.create(SchedulerType.greedy);

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  /// Currently selected scheduling algorithm.

  SchedulerType get schedulerType => _schedulerType;

  /// Human-readable scheduler name.

  String get schedulerName => _schedulerType.displayName;

  /// Stable id of the active algorithm (used in logs, exports and REST).

  String get schedulerId => _schedulerType.id;

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
      scheduleCalls == 0 ? 0 : scheduleTotalUs / scheduleCalls / 1000.0;

  Map<String, List<Unit>> _runScheduler(
    List<Unit> available,
    int maxUnits,
    String requesterId,
  ) {
    // Built before the stopwatch starts: bookkeeping is not part of the
    // algorithm's own cost.

    final snapshot = _snapshotFor(requesterId);

    final sw = Stopwatch()..start();

    final result = _scheduler.schedule(available, snapshot, maxUnits);
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

  void setSchedulerType(SchedulerType type) {
    if (_schedulerType == type) {
      return;
    }
    _schedulerType = type;
    _scheduler = SchedulerFactory.create(type);
    scheduleCalls = 0;
    scheduleTotalUs = 0;
  }

  /// Why the active scheduler decided what it did on its most recent call
  /// (per-phone health, latency, queue depth, ...), or null when the active
  /// algorithm does not produce a trace.

  Map<String, dynamic>? get lastDecisionTrace {
    final scheduler = _scheduler;
    return scheduler is DynamicScheduler ? scheduler.lastTrace : null;
  }
  // jobId -> units

  final Map<String, List<Unit>> _jobs = {};
  // jobId -> unitIndex -> status:
  // 'available'|'assigned'|'completed'

  final Map<String, Map<int, String>> _unitStatus = {};
  // clientId -> estimate

  final Map<String, ClientEstimate> _clientEstimates = {};
  // clientId -> live state (last seen, health, recent latency, failures)

  final Map<String, _ClientState> _clientStates = {};
  // All outstanding units assigned to each client (used by Job Status).

  final Map<String, List<Unit>> _clientQueues = {};
  // Units already reserved for a client but not yet returned by its next poll.
  // Scheduling is global: a request can create work for several clients, so
  // those clients must receive their reserved units on their own next poll.

  final Map<String, List<Unit>> _pendingDelivery = {};
  // jobId -> unitIndex -> who holds the unit and since when

  final Map<String, Map<int, _Lease>> _leases = {};
  // Units reclaimed after a lease expires, waiting to be reassigned.

  final Map<String, List<Unit>> _reclaimedUnits = {};
  // Jobs that have been reset and must not issue new
  // assignments until the next experiment activates them.

  final Set<String> _inactiveJobs = {};
  // ---------------------------------------------------------------------------
  // JOB MANAGEMENT
  // ---------------------------------------------------------------------------

  /// Register a job and its units.
  ///
  /// A newly registered job is active by default.

  void registerJob(String jobId, List<Unit> units) {
    _jobs[jobId] = List<Unit>.from(units);
    _unitStatus[jobId] = {for (var u in units) u.unitIndex: 'available'};
    _reclaimedUnits.remove(jobId);
    _leases.remove(jobId);
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
  /// - live client state (health, recent latency, failure history)
  /// - registered job/dataset definitions
  /// - selected scheduling algorithm
  ///
  /// It resets:
  /// - unit status
  /// - client assignment queues
  /// - outstanding unit leases
  ///
  /// Jobs are marked inactive until the next experiment
  /// explicitly activates them.

  void resetExperiment() {
    // Reset every registered unit to the available state.
    for (final statusMap in _unitStatus.values) {
      statusMap.updateAll((unitIndex, status) => 'available');
    }
    // Remove all outstanding client assignments.
    for (final queue in _clientQueues.values) {
      queue.clear();
    }
    for (final pending in _pendingDelivery.values) {
      pending.clear();
    }
    // Nothing is assigned any more, so nothing can time out.
    _leases.clear();
    _reclaimedUnits.clear();
    // Prevent clients from receiving assignments until
    // the next experiment starts.
    _inactiveJobs
      ..clear()
      ..addAll(_jobs.keys);
  }
  // ---------------------------------------------------------------------------
  // CLIENT MANAGEMENT
  // ---------------------------------------------------------------------------

  void registerClient(String clientId, ClientEstimate initial) {
    _clientEstimates[clientId] = initial;
    // A repeated warmup/registration must not erase units already assigned.
    _clientQueues.putIfAbsent(clientId, () => <Unit>[]);
    _pendingDelivery.putIfAbsent(clientId, () => <Unit>[]);
    // A phone that re-registers (for example after a new warmup) keeps what
    // the host has learned about its health and recent behaviour.

    final state = _stateOf(clientId);
    state.deviceName = deviceNameFromClientId(clientId);
    state.lastSeenMs = _nowMs();
  }

  List<Unit> getClientQueue(String clientId) {
    return List<Unit>.from(_clientQueues[clientId] ?? []);
  }

  /// Return registered client ids.

  List<String> get registeredClientIds => _clientEstimates.keys.toList();

  /// Record that the host just heard from a registered client.

  void touchClient(String clientId) {
    _clientStates[clientId]?.lastSeenMs = _nowMs();
  }

  /// Apply a live health reading.
  ///
  /// [key] is either a full client id or a device key: the periodic MQTT
  /// metrics are keyed by device IP while assignments use the full client id,
  /// so every registered client matching either spelling is updated. An
  /// unknown key is ignored.

  void updateClientHealth(String key, DeviceHealth health) {
    final now = _nowMs();
    for (final clientId in _clientEstimates.keys) {
      if (clientId != key && deviceKeyFromClientId(clientId) != key) {
        continue;
      }

      final state = _clientStates[clientId];
      if (state == null) {
        continue;
      }
      _applyHealth(state, health, now);
      state.lastSeenMs = now;
    }
  }

  /// Fold one finished unit into the client's state: its estimate, its recent
  /// latency and the health it reported.
  ///
  /// This does not mark the unit complete; callers still use
  /// [markUnitComplete].

  void recordResult(ResultReport rr) {
    touchClient(rr.clientId);
    // A zero from a failed inference or an empty download, or a non-finite
    // throughput, would drag the moving averages towards nonsense, and a phone
    // that looks impossibly fast then wins every pick.
    if (rr.ttprocMs > 0 && rr.bandwidthKbps > 0 && rr.bandwidthKbps.isFinite) {
      updateClientEstimate(
        rr.clientId,
        rr.ttprocMs.toDouble(),
        rr.bandwidthKbps,
      );
    }

    final state = _clientStates[rr.clientId];
    if (state == null) {
      return;
    }

    final latencyMs = rr.totalMs > 0 ? rr.totalMs : rr.downloadMs + rr.ttprocMs;
    if (latencyMs > 0) {
      state.latenciesMs.add(latencyMs);
      if (state.latenciesMs.length > _latencyWindow) {
        state.latenciesMs.removeAt(0);
      }
    }

    final health = rr.health;
    if (health != null) {
      _applyHealth(state, health, _nowMs());
    }
  }

  void updateClientEstimate(
    String clientId,
    double ttprocMs,
    double bandwidthKbps, {
    double alpha = 0.2,
  }) {
    final prev = _clientEstimates[clientId];
    if (prev == null) {
      _clientEstimates[clientId] = ClientEstimate(
        ttprocMs: ttprocMs,
        bandwidthKbps: bandwidthKbps,
      );
      // A phone first seen through a result is a full participant from now
      // on, so it needs the same bookkeeping as a registered one.
      _clientQueues.putIfAbsent(clientId, () => []);
      _stateOf(clientId);
      return;
    }
    // EMA
    prev.ttprocMs = alpha * ttprocMs + (1 - alpha) * prev.ttprocMs;
    prev.bandwidthKbps =
        alpha * bandwidthKbps + (1 - alpha) * prev.bandwidthKbps;
  }

  _ClientState _stateOf(String clientId) {
    return _clientStates.putIfAbsent(
      clientId,
      () => _ClientState(
        deviceName: deviceNameFromClientId(clientId),
        lastSeenMs: _nowMs(),
      ),
    );
  }

  void _applyHealth(_ClientState state, DeviceHealth incoming, int now) {
    // Fields the new reading lacks keep their old value; the empty merge only
    // restamps updatedAtMs with the host's clock.
    state.health = state.health
        .merge(incoming)
        .merge(DeviceHealth(updatedAtMs: now));
  }

  /// What the scheduler gets to see: every client heard from within
  /// [activeWindowMs] (plus the requester, who is by definition alive), each
  /// as a fresh copy carrying its live state, so the scheduler sees the
  /// situation as it is right now and cannot mutate the stored estimates.

  Map<String, ClientEstimate> _snapshotFor(String? requesterId) {
    final now = _nowMs();

    final snapshot = <String, ClientEstimate>{};
    for (final entry in _clientEstimates.entries) {
      final clientId = entry.key;

      final state = _clientStates[clientId];
      if (state == null) {
        continue;
      }

      final ageMs = now - state.lastSeenMs;
      if (ageMs > activeWindowMs && clientId != requesterId) {
        continue;
      }

      final est = entry.value.copy();
      est.health = state.health;
      est.pending = _clientQueues[clientId]?.length ?? 0;
      est.recentLatencyMs = state.recentLatencyMs;
      est.ageMs = ageMs < 0 ? 0 : ageMs;
      est.failures = state.failuresAt(now);
      est.deviceName = state.deviceName;
      snapshot[clientId] = est;
    }
    return snapshot;
  }

  /// Per-phone account of how the host currently sees each active client
  /// (health score, queue, latency, energy, gating) plus the raw readings, for
  /// the host UI. Unknown readings are null.

  Map<String, Map<String, dynamic>> clientViews({int maxUnits = 2}) {
    final snapshot = _snapshotFor(null);

    final scheduler = _scheduler;

    final fleet = FleetModel(
      snapshot,
      const [],
      maxUnits,
      cfg: scheduler is DynamicScheduler
          ? scheduler.config
          : SchedulingConfig.defaults,
    );

    final explained = fleet.explain();

    final views = <String, Map<String, dynamic>>{};
    for (final entry in explained.entries) {
      final est = snapshot[entry.key]!;

      final health = est.health;
      views[entry.key] = {
        ...Map<String, dynamic>.from(entry.value as Map),
        'age_ms': est.ageMs,
        'device': est.deviceName,
        'battery_pct': health.batteryPct,
        'thermal': health.thermalStatus,
        'rssi_dbm': health.rssiDbm,
        'charging': health.charging,
      };
    }
    return views;
  }
  // ---------------------------------------------------------------------------
  // UNIT MANAGEMENT
  // ---------------------------------------------------------------------------

  /// Mark a unit as completed and update internal state.
  ///
  /// A result that arrives after its unit was re-queued (or even re-assigned
  /// to another phone) is still accepted: the unit completes and leaves every
  /// queue.

  void markUnitComplete(String jobId, int unitIndex) {
    final statusMap = _unitStatus[jobId];
    if (statusMap == null) {
      return;
    }
    statusMap[unitIndex] = 'completed';
    _leases[jobId]?.remove(unitIndex);
    _reclaimedUnits[jobId]?.removeWhere((u) => u.unitIndex == unitIndex);
    // Remove the completed unit from any client queue.
    _clientQueues.forEach((_, q) {
      q.removeWhere((u) => u.unitIndex == unitIndex);
    });
    _pendingDelivery.forEach((_, pending) {
      pending.removeWhere((u) => u.unitIndex == unitIndex);
    });
  }

  /// Hand back every unit of [jobId] that has been assigned for longer than
  /// [leaseMs] without a result, so it can go to any phone. Each reclaimed
  /// unit leaves its holder's queue and counts as a failure for that phone.
  ///
  /// Returns how many units were re-queued.

  int requeueExpired(String jobId) {
    final leases = _leases[jobId];

    final statusMap = _unitStatus[jobId];
    if (leases == null || statusMap == null) {
      return 0;
    }

    final now = _nowMs();

    final reclaimedByClient = <String, int>{};
    for (final entry in leases.entries.toList()) {
      final unitIndex = entry.key;

      final lease = entry.value;
      if (now - lease.assignedAtMs <= leaseMs) {
        continue;
      }
      leases.remove(unitIndex);
      // Completed or reset in the meantime: nothing is stranded.
      if (statusMap[unitIndex] != 'assigned') {
        continue;
      }
      statusMap[unitIndex] = 'available';
      Unit? unit;
      for (final candidate in _jobs[jobId] ?? const <Unit>[]) {
        if (candidate.unitIndex == unitIndex) {
          unit = candidate;
          break;
        }
      }
      if (unit != null) {
        final reclaimed = _reclaimedUnits.putIfAbsent(jobId, () => <Unit>[]);
        if (!reclaimed.any((u) => u.unitIndex == unitIndex)) {
          reclaimed.add(unit);
        }
      }
      _clientQueues[lease.clientId]?.removeWhere(
        (u) => u.unitIndex == unitIndex,
      );
      _pendingDelivery[lease.clientId]?.removeWhere(
        (u) => u.unitIndex == unitIndex,
      );
      _clientStates[lease.clientId]?.recordExpiry(now);
      reclaimedByClient[lease.clientId] =
          (reclaimedByClient[lease.clientId] ?? 0) + 1;
    }

    final requeued = reclaimedByClient.values.fold<int>(0, (a, b) => a + b);
    if (requeued > 0) {
      final holders = reclaimedByClient.entries
          .map((e) => '${e.key} x${e.value}')
          .join(', ');
      onLog?.call(
        'Job $jobId: re-queued $requeued '
        'unit(s) with no result after '
        '${leaseMs ~/ 1000}s ($holders)',
      );
    }
    return requeued;
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
  ///
  /// Units whose lease has expired are re-queued first, so a phone that went
  /// quiet does not hold them back from the phone that is asking now.

  List<Unit> assignNext(String jobId, String clientId, {int maxUnits = 2}) {
    if (_inactiveJobs.contains(jobId) || maxUnits <= 0) {
      return [];
    }

    final units = _jobs[jobId];
    if (units == null) return [];
    requeueExpired(jobId);

    final queue = _clientQueues[clientId];

    final pendingDelivery = _pendingDelivery[clientId];
    if (queue == null || pendingDelivery == null) {
      // An unregistered requester has no state to schedule against.
      return [];
    }
    // Expired units are offered to the next requester before any still-pending
    // delivery. Their old holder's queue and lease were removed by
    // requeueExpired(), so a unit cannot be held by two phones simultaneously.

    final reclaimed = _reclaimedUnits[jobId];
    if (reclaimed != null && reclaimed.isNotEmpty) {
      final reassigned = <Unit>[];

      final statusMap = _unitStatus[jobId]!;

      final leases = _leases.putIfAbsent(jobId, () => <int, _Lease>{});

      final now = _nowMs();
      while (reclaimed.isNotEmpty && reassigned.length < maxUnits) {
        final unit = reclaimed.removeAt(0);
        // A late result or reset may have changed its state since reclamation.
        if (statusMap[unit.unitIndex] != 'available') continue;
        statusMap[unit.unitIndex] = 'assigned';
        queue.add(unit);
        leases[unit.unitIndex] = _Lease(clientId, now);
        reassigned.add(unit);
      }
      if (reclaimed.isEmpty) _reclaimedUnits.remove(jobId);
      if (reassigned.isNotEmpty) return reassigned;
    }
    // A previous scheduling decision may already have reserved work for this
    // client while responding to another phone's poll. Deliver that work first
    // instead of running the scheduler again and discarding other clients' picks.
    if (pendingDelivery.isNotEmpty) {
      final count = pendingDelivery.length < maxUnits
          ? pendingDelivery.length
          : maxUnits;

      final delivered = pendingDelivery.sublist(0, count);
      pendingDelivery.removeRange(0, count);
      return delivered;
    }

    final statusMap = _unitStatus[jobId]!;

    final available = units
        .where((u) => statusMap[u.unitIndex] == 'available')
        .toList();
    if (available.isEmpty) return [];
    // Run one global scheduling decision and COMMIT every client's slice.
    // Previously only assignments[clientId] was committed; the other slices
    // were thrown away, which made polling order determine who did the work.

    final assignments = _runScheduler(available, maxUnits, clientId);

    final now = _nowMs();

    final leases = _leases.putIfAbsent(jobId, () => <int, _Lease>{});
    for (final entry in assignments.entries) {
      final targetId = entry.key;

      final targetQueue = _clientQueues[targetId];

      final targetPending = _pendingDelivery[targetId];
      if (targetQueue == null || targetPending == null) continue;
      for (final unit in entry.value) {
        if (statusMap[unit.unitIndex] != 'available') continue;
        statusMap[unit.unitIndex] = 'assigned';
        targetQueue.add(unit);
        targetPending.add(unit);
        leases[unit.unitIndex] = _Lease(targetId, now);
      }
    }
    // This caller receives only its own slice. Other clients collect their
    // already-reserved units when they poll; no unit is assigned twice.
    if (pendingDelivery.isEmpty) return [];

    final count = pendingDelivery.length < maxUnits
        ? pendingDelivery.length
        : maxUnits;

    final delivered = pendingDelivery.sublist(0, count);
    pendingDelivery.removeRange(0, count);
    return delivered;
  }

  /// Produce a scheduling suggestion without mutating internal state.
  ///
  /// Useful for logging or previewing assignments.
  ///
  /// If the job has been reset and has not yet been activated
  /// for a new experiment, no suggestions are returned.

  List<Unit> suggestNext(String jobId, String clientId, {int maxUnits = 2}) {
    // Do not provide assignments while the experiment is reset.
    if (_inactiveJobs.contains(jobId)) {
      return [];
    }

    final units = _jobs[jobId];
    if (units == null) {
      return [];
    }
    if (!_clientEstimates.containsKey(clientId)) {
      return [];
    }

    final available = units
        .where((u) => _unitStatus[jobId]![u.unitIndex] == 'available')
        .toList();
    if (available.isEmpty) {
      return [];
    }

    final assignments = _runScheduler(available, maxUnits, clientId);

    final assignedForClient = assignments[clientId] ?? [];
    // Do not change _unitStatus or client queues.
    return assignedForClient;
  }
  // ---------------------------------------------------------------------------
  // JOB PROGRESS
  // ---------------------------------------------------------------------------

  /// Return simple progress information for a job.

  Map<String, int> jobProgress(String jobId) {
    final status = _unitStatus[jobId];
    if (status == null) {
      return {'total': 0, 'completed': 0, 'assigned': 0, 'available': 0};
    }

    final total = status.length;

    final completed = status.values.where((v) => v == 'completed').length;

    final assigned = status.values.where((v) => v == 'assigned').length;

    final available = status.values.where((v) => v == 'available').length;
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

  bool hasJob(String jobId) => _jobs.containsKey(jobId);

  /// Return the file URL for a specific unit in a job,
  /// or null if the unit is not found.
  String? getUnitFileUrl(String jobId, int unitIndex) {
    final units = _jobs[jobId];
    if (units == null) {
      return null;
    }
    try {
      final u = units.firstWhere((e) => e.unitIndex == unitIndex);
      return u.fileUrl;
    } catch (_) {
      return null;
    }
  }
}

/// A unit handed to a client and not yet reported back.
class _Lease {
  final String clientId;

  final int assignedAtMs;
  _Lease(this.clientId, this.assignedAtMs);
}

/// What the host has observed about one client, beyond its speed estimates.
class _ClientState {
  String deviceName;

  int lastSeenMs;
  DeviceHealth health = DeviceHealth.unknown;

  /// Total ms (download + inference) of the last few finished units.

  final List<int> latenciesMs = [];

  /// When this client's leases expired, oldest first.

  final List<int> _expiriesMs = [];
  _ClientState({required this.deviceName, required this.lastSeenMs});

  /// Mean of the latency window; 0 until a unit has finished.
  double get recentLatencyMs => latenciesMs.isEmpty
      ? 0
      : latenciesMs.fold<int>(0, (a, b) => a + b) / latenciesMs.length;

  void recordExpiry(int now) {
    _expiriesMs.removeWhere(
      (t) => now - t > DistributionManager._failureWindowMs,
    );
    _expiriesMs.add(now);
  }

  /// Lease expiries within the recent failure window.

  int failuresAt(int now) {
    return _expiriesMs
        .where((t) => now - t <= DistributionManager._failureWindowMs)
        .length;
  }
}