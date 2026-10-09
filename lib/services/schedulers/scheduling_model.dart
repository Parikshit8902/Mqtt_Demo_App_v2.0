import 'dart:math';
import '../models/assignment.dart';
import '../models/device_health.dart';
import '../models/result_dto.dart';

// =============================================================================
// The shared "dynamic" model behind Greedy, PSO, MOMPSO and MOMPSO-GA.
//
// Every observed parameter (CPU load, RAM, battery, charging, thermal state,
// Wi-Fi signal, bandwidth, queue depth, recent latency, device power class) is
// turned into a handful of derived quantities here, once, so the four
// algorithms differ only in HOW THEY CHOOSE, never in what they can see.
//
// The health score is the formula from the DetectNet reference implementation
// (Parikshit8902/detectnet_v2.0, `hScore`); the objective terms of MOMPSO and
// MOMPSO-GA are its latency / queue-depth terms plus an energy term.
// =============================================================================

/// Tunable constants. Everything the policy treats as a threshold lives here.
class SchedulingConfig {
  /// Below this battery % (and not charging) a phone gets no new work.
  final int minBatteryPct;

  /// At or above this thermal status (4 = critical) a phone gets no new work.
  final int gateThermalStatus;

  /// With the OS low-memory flag set and less than this free, no new work.
  final double minMemFreeMb;

  /// This many recently failed units (lease expiries or reported errors) on a
  /// phone take it out of rotation.
  final int gateFailures;

  /// DetectNet uses `latency / 500 ms` and `pending / 5` as objective terms.
  final double latencyRefMs;
  final double queueRef;

  /// CPU utilisation assumed while inferring, when no better figure is known.
  final double nominalUtilization;

  /// Weight of measured recent latency vs the modelled service time (0..1).
  final double measuredLatencyBlend;

  const SchedulingConfig({
    this.minBatteryPct = 5,
    this.gateThermalStatus = 4,
    this.minMemFreeMb = 150,
    this.gateFailures = 3,
    this.latencyRefMs = 500,
    this.queueRef = 5,
    this.nominalUtilization = 0.7,
    this.measuredLatencyBlend = 0.5,
  });

  static const SchedulingConfig defaults = SchedulingConfig();
}

/// How device health changes what a phone can do. Factors multiply into a
/// single capacity in (0, 1]; a phone at capacity 0.5 is treated as taking
/// twice as long per unit.
class HealthPolicy {
  HealthPolicy._();

  /// Android PowerManager scale: 0 none, 1 light, 2 moderate, 3 severe,
  /// 4 critical, 5 emergency, 6 shutdown. Throttling bites from "moderate".
  static double thermalFactor(int? status) {
    if (status == null || status <= 0) return 1.0;
    switch (status) {
      case 1:
        return 0.95;
      case 2:
        return 0.8;
      case 3:
        return 0.55;
      case 4:
        return 0.3;
      default:
        return 0.15;
    }
  }

  /// A phone on a charger, or one whose battery is unknown, is not derated.
  static double batteryFactor(int? pct, bool? charging) {
    if (charging == true || pct == null) return 1.0;
    if (pct <= 15) return 0.7;
    if (pct <= 30) return 0.9;
    return 1.0;
  }

  static double memoryFactor(DeviceHealth h) {
    if (h.lowMemory == true) return 0.6;
    final free = h.memFreeFraction;
    if (free != null && free < 0.10) return 0.8;
    return 1.0;
  }

  /// Wi-Fi signal: -60 dBm or better is full speed, -85 dBm or worse halves it.
  static double linkFactor(int? rssiDbm) {
    if (rssiDbm == null) return 1.0;
    if (rssiDbm >= -60) return 1.0;
    if (rssiDbm <= -85) return 0.5;
    return 0.5 + 0.5 * (rssiDbm + 85) / 25.0;
  }

  /// Each recently failed unit (lease expiry or reported error) makes a phone
  /// look less reliable.
  static double failureFactor(int failures) => 1.0 / (1.0 + 0.5 * max(0, failures));

  /// Combined compute capacity (thermal x battery x memory x reliability).
  static double capacity(ClientEstimate c) {
    final h = c.health;
    final f = thermalFactor(h.thermalStatus) *
        batteryFactor(h.batteryPct, h.charging) *
        memoryFactor(h) *
        failureFactor(c.failures);
    return f.clamp(0.05, 1.0);
  }

  /// Hard exclusions: a phone in one of these states should not be given new work.
  static bool isGated(ClientEstimate c, SchedulingConfig cfg) {
    final h = c.health;
    if (h.batteryPct != null && h.charging != true && h.batteryPct! <= cfg.minBatteryPct) return true;
    if (h.thermalStatus != null && h.thermalStatus! >= cfg.gateThermalStatus) return true;
    if (h.lowMemory == true && (h.memFreeMb == null || h.memFreeMb! < cfg.minMemFreeMb)) return true;
    if (c.failures >= cfg.gateFailures) return true;
    return false;
  }

  /// Short human-readable reason a phone is gated, or null.
  static String? gateReason(ClientEstimate c, SchedulingConfig cfg) {
    final h = c.health;
    if (h.batteryPct != null && h.charging != true && h.batteryPct! <= cfg.minBatteryPct) return 'battery ${h.batteryPct}%';
    if (h.thermalStatus != null && h.thermalStatus! >= cfg.gateThermalStatus) return 'thermal ${h.thermalStatus}';
    if (h.lowMemory == true && (h.memFreeMb == null || h.memFreeMb! < cfg.minMemFreeMb)) return 'low memory';
    if (c.failures >= cfg.gateFailures) return '${c.failures} failed units';
    return null;
  }
}

// -----------------------------------------------------------------------------
// Energy: Fan et al. linear utilisation model + a Wi-Fi tail-energy term.
// Same method and constants as DetectNet's ENERGY_MODEL.md, so numbers are
// comparable with the web app. Modelled, not measured.
// -----------------------------------------------------------------------------

class DevicePower {
  final double idleW;
  final double maxW;
  final double capacityWh;
  const DevicePower(this.idleW, this.maxW, this.capacityWh);
}

class DevicePowerTable {
  DevicePowerTable._();

  static final List<_PowerRow> _rows = [
    _PowerRow(r'pixel\s*8a', const DevicePower(1.3, 4.4, 16.6)),
    _PowerRow(r'pixel\s*8', const DevicePower(1.4, 4.6, 17.0)),
    _PowerRow(r'pixel\s*7', const DevicePower(1.4, 4.6, 16.1)),
    _PowerRow(r'pixel', const DevicePower(1.35, 4.5, 15.5)),
    _PowerRow(r'galaxy\s*a14|sm-a14|samsung.*a14', const DevicePower(1.5, 4.8, 18.5)),
    _PowerRow(r'galaxy\s*a5[0-9]|sm-a5', const DevicePower(1.6, 5.2, 18.5)),
    _PowerRow(r'galaxy\s*s2[3-5]|sm-s9', const DevicePower(1.9, 6.3, 18.0)),
    _PowerRow(r'samsung|galaxy', const DevicePower(1.5, 4.9, 17.0)),
    _PowerRow(r'redmi|xiaomi|poco', const DevicePower(1.4, 4.6, 18.5)),
    _PowerRow(r'oneplus|oppo|vivo|realme', const DevicePower(1.4, 4.7, 18.0)),
    _PowerRow(r'lava', const DevicePower(1.2, 4.0, 14.0)),
    _PowerRow(r'iphone\s*1[5-6]', const DevicePower(1.7, 5.5, 13.0)),
    _PowerRow(r'iphone\s*1[3-4]', const DevicePower(1.6, 5.2, 12.0)),
    _PowerRow(r'iphone|ipad', const DevicePower(1.4, 4.6, 12.0)),
    _PowerRow(r'android', const DevicePower(1.4, 4.6, 15.0)),
  ];

  /// Generic phone prior used when the model is unknown.
  static const DevicePower fallback = DevicePower(1.4, 4.6, 15.0);

  static DevicePower lookup(String deviceName) {
    for (final row in _rows) {
      if (row.pattern.hasMatch(deviceName)) return row.power;
    }
    return fallback;
  }
}

class _PowerRow {
  final RegExp pattern;
  final DevicePower power;
  _PowerRow(String pattern, this.power) : pattern = RegExp(pattern, caseSensitive: false);
}

class EnergyEstimator {
  EnergyEstimator._();

  // Wi-Fi radio: a new high-power cycle costs ramp + transfer + tail; while the
  // radio is still in its tail window only the transfer is charged.
  static const double wifiRampJ = 0.005;
  static const double wifiXferJ = 0.002;
  static const double wifiTailJ = 0.015;

  /// Marginal energy (joules) for one unit: compute over the inference window
  /// plus the radio cost of one download and one result upload.
  /// [radioWarm] is true when the phone already has work queued (radio busy).
  static double unitEnergyJ({
    required DevicePower power,
    required double procMs,
    required double cpuUtil,
    required bool radioWarm,
  }) {
    final u = cpuUtil.clamp(0.0, 1.0);
    final compute = (power.idleW + (power.maxW - power.idleW) * u) * (procMs / 1000.0);
    final network = 2 * wifiXferJ + (radioWarm ? 0.0 : wifiRampJ + wifiTailJ);
    return compute + network;
  }
}

// -----------------------------------------------------------------------------
// Objective weights shared by MOMPSO and MOMPSO-GA.
// -----------------------------------------------------------------------------

class ObjectiveWeights {
  final double health;
  final double latency;
  final double queue;
  final double energy;
  const ObjectiveWeights({
    required this.health,
    required this.latency,
    required this.queue,
    required this.energy,
  });

  /// DetectNet's original three-term weights (no energy term).
  static const ObjectiveWeights detectnetMompso = ObjectiveWeights(health: 0.50, latency: 0.30, queue: 0.20, energy: 0.0);
  static const ObjectiveWeights detectnetGa = ObjectiveWeights(health: 0.45, latency: 0.30, queue: 0.25, energy: 0.0);

  /// Defaults used here: the original weights scaled by 0.8, with the remaining
  /// 0.2 given to energy (DetectNet's README says MOMPSO balances latency,
  /// energy and CPU; its code only used the other terms).
  static const ObjectiveWeights dynamicMompso = ObjectiveWeights(health: 0.40, latency: 0.24, queue: 0.16, energy: 0.20);
  static const ObjectiveWeights dynamicGa = ObjectiveWeights(health: 0.36, latency: 0.24, queue: 0.20, energy: 0.20);
}

// -----------------------------------------------------------------------------
// Per-client derived state for ONE scheduling call.
// -----------------------------------------------------------------------------

class ClientView {
  final String id;
  final ClientEstimate est;

  /// Combined health derating in (0, 1].
  final double capacity;
  final bool gated;
  final String? gateReason;

  /// Effective processing ms per unit (EMA divided by capacity).
  final double procMs;

  /// Effective download kB/s (EMA scaled by Wi-Fi signal quality).
  final double bwKBps;
  final DevicePower power;

  /// Queue depth. Starts as the real queue and grows as units are assigned
  /// during this call, so later picks see the effect of earlier ones.
  int pending;

  /// Units given to this client during this call.
  int assigned = 0;

  ClientView({
    required this.id,
    required this.est,
    required this.capacity,
    required this.gated,
    required this.gateReason,
    required this.procMs,
    required this.bwKBps,
    required this.power,
    required this.pending,
  });
}

/// Everything an algorithm needs to compare the phones, as of this instant.
class FleetModel {
  final SchedulingConfig cfg;
  final int maxUnitPerAssign;
  final double avgUnitBytes;
  final Map<String, ClientView> views = {};
  late final List<String> eligibleIds;
  late final Set<String> _eligible;

  // Best values across the eligible phones; 0 until the constructor fills them.
  double _maxBw = 0;
  double _maxProcRate = 0;
  double _maxServiceRate = 0;

  FleetModel(
    Map<String, ClientEstimate> clients,
    List<Unit> units,
    this.maxUnitPerAssign, {
    this.cfg = SchedulingConfig.defaults,
  }) : avgUnitBytes = units.isEmpty ? 0 : units.fold<double>(0, (a, u) => a + unitBytes(u)) / units.length {
    for (final e in clients.entries) {
      final est = e.value;
      final capacity = HealthPolicy.capacity(est);
      views[e.key] = ClientView(
        id: e.key,
        est: est,
        capacity: capacity,
        gated: HealthPolicy.isGated(est, cfg),
        gateReason: HealthPolicy.gateReason(est, cfg),
        procMs: max(1.0, est.ttprocMs) / capacity,
        bwKBps: max(1.0, est.bandwidthKbps) * HealthPolicy.linkFactor(est.health.rssiDbm),
        power: DevicePowerTable.lookup(est.deviceName),
        pending: max(0, est.pending),
      );
    }

    // Never starve the job: if every phone is gated, schedule across all of them.
    final open = views.keys.where((id) => !views[id]!.gated).toList();
    eligibleIds = open.isEmpty ? views.keys.toList() : open;
    _eligible = eligibleIds.toSet();

    for (final id in eligibleIds) {
      final v = views[id]!;
      _maxBw = max(_maxBw, v.bwKBps);
      _maxProcRate = max(_maxProcRate, 1000.0 / v.procMs);
      _maxServiceRate = max(_maxServiceRate, 1000.0 / perUnitServiceMs(id));
    }
  }

  /// Bytes a unit represents. start/end == 0/0 means "size unknown" and counts as 1.
  static int unitBytes(Unit u) => max(1, u.end - u.start + 1);

  List<String> get ids => views.keys.toList();

  double _txMs(ClientView v, double bytes) => (bytes / 1024.0) / v.bwKBps * 1000.0;

  double _modelServiceMs(ClientView v, double bytes) => _txMs(v, bytes) + v.procMs;

  /// Service time for an average unit: the model, blended with what the phone
  /// actually achieved recently when that is known.
  double perUnitServiceMs(String id) {
    final v = views[id]!;
    final model = _modelServiceMs(v, avgUnitBytes);
    final measured = v.est.recentLatencyMs;
    if (measured <= 0) return model;
    final w = cfg.measuredLatencyBlend.clamp(0.0, 1.0);
    return w * measured + (1 - w) * model;
  }

  /// Time to drain what is already queued on this phone.
  double waitMs(String id) => views[id]!.pending * perUnitServiceMs(id);

  /// Estimated finish time of [unit] if given to [id] now.
  double etaMs(String id, Unit unit) {
    final v = views[id]!;
    return waitMs(id) + _modelServiceMs(v, unitBytes(unit).toDouble());
  }

  /// Expected latency of the next unit on this phone (queue wait + service).
  double latencyMs(String id) => waitMs(id) + perUnitServiceMs(id);

  bool isEligible(String id) => _eligible.contains(id);

  /// Units this phone may receive in one round. Faster phones get the full
  /// `maxUnitPerAssign`; slower ones fewer (at least 1); gated phones 0.
  int capFor(String id) {
    if (!_eligible.contains(id)) return 0;
    final share = _maxServiceRate > 0 ? (1000.0 / perUnitServiceMs(id)) / _maxServiceRate : 1.0;
    return (maxUnitPerAssign * share.clamp(0.0, 1.0)).round().clamp(1, max(1, maxUnitPerAssign));
  }

  /// DetectNet's `hScore`, driven by live data:
  ///   battery 0.20 (its weight is shared out when battery is unknown, as on iOS),
  ///   CPU free 0.28, throughput 0.32, processing rate 0.22, 1/(1+pending) 0.18.
  /// Throughput and processing rate are relative to the best phone in the fleet.
  /// Thermal, memory, signal and reliability act through [capacity] / [bwKBps],
  /// so they reduce the processing-rate and throughput terms.
  double healthScore(String id) {
    final v = views[id]!;
    final h = v.est.health;
    final batKnown = h.batteryPct != null;
    final batW = batKnown ? 0.20 : 0.0;
    final rest = 1.0 - batW;
    final batSc = batKnown ? ((h.charging == true ? 100 : h.batteryPct!) / 100.0) * batW : 0.0;
    final cpuFree = (1.0 - (h.cpuPct ?? 50.0) / 100.0).clamp(0.0, 1.0);
    final throughput = _maxBw > 0 ? (v.bwKBps / _maxBw).clamp(0.0, 1.0) : 1.0;
    final procRate = _maxProcRate > 0 ? ((1000.0 / v.procMs) / _maxProcRate).clamp(0.0, 1.0) : 1.0;
    final queue = 1.0 / (1.0 + v.pending);
    return batSc + rest * (0.28 * cpuFree + 0.32 * throughput + 0.22 * procRate + 0.18 * queue);
  }

  /// Marginal energy (J) of giving this phone one more unit.
  double energyJ(String id) {
    final v = views[id]!;
    return EnergyEstimator.unitEnergyJ(
      power: v.power,
      procMs: v.procMs,
      cpuUtil: max(cfg.nominalUtilization, (v.est.health.cpuPct ?? 0) / 100.0),
      radioWarm: v.pending > 0,
    );
  }

  /// Objective terms, each roughly 0..1 (latency and queue capped at 2, as the
  /// DetectNet forms `lat/500` and `pend/5` are unbounded).
  double latencyTerm(String id) => (latencyMs(id) / cfg.latencyRefMs).clamp(0.0, 2.0);

  double queueTerm(String id) => (views[id]!.pending / cfg.queueRef).clamp(0.0, 2.0);

  /// Energy relative to the most expensive eligible phone right now.
  double energyTerm(String id) {
    var maxE = 0.0;
    for (final other in eligibleIds) {
      maxE = max(maxE, energyJ(other));
    }
    return maxE > 0 ? energyJ(id) / maxE : 0.0;
  }

  /// Weighted multi-objective score (higher is better).
  double objective(String id, ObjectiveWeights w) =>
      w.health * healthScore(id) -
      w.latency * latencyTerm(id) -
      w.queue * queueTerm(id) -
      w.energy * energyTerm(id);

  /// Record that [id] was given a unit in this call, so subsequent picks see its
  /// longer queue (this is what spreads a batch across phones).
  void recordAssignment(String id) {
    final v = views[id]!;
    v.pending++;
    v.assigned++;
  }

  /// A readable account of why each phone looks the way it does (for logs/UI).
  Map<String, dynamic> explain() {
    double r(double v) => double.parse(v.toStringAsFixed(3));
    return {
      for (final v in views.values)
        v.id: {
          'eligible': isEligible(v.id),
          if (v.gateReason != null) 'gated_by': v.gateReason,
          'capacity': r(v.capacity),
          'cap': capFor(v.id),
          'pending': v.pending,
          'assigned': v.assigned,
          'health': r(healthScore(v.id)),
          'latency_ms': r(latencyMs(v.id)),
          'energy_j': r(energyJ(v.id)),
          'proc_ms': r(v.procMs),
          'bw_kBps': r(v.bwKBps),
        },
    };
  }
}
