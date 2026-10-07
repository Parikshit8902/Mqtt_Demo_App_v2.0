enum SchedulerType {
  greedy,
  pso,
  mompso,
  mompsoGa,
  // Reference baselines (not shown in the host's algorithm picker).
  roundRobin,
  random,
}

extension SchedulerTypeExtension on SchedulerType {
  String get id {
    switch (this) {
      case SchedulerType.greedy:
        return 'greedy';

      case SchedulerType.pso:
        return 'pso';

      case SchedulerType.mompso:
        return 'mompso';

      case SchedulerType.mompsoGa:
        return 'mompso-ga';

      case SchedulerType.roundRobin:
        return 'round_robin';

      case SchedulerType.random:
        return 'random';
    }
  }

  /// Baselines exist for experiment comparison, not as primary algorithms.
  bool get isBaseline =>
      this == SchedulerType.roundRobin ||
      this == SchedulerType.random;

  String get displayName {
    switch (this) {
      case SchedulerType.greedy:
        return 'Greedy';

      case SchedulerType.pso:
        return 'PSO';

      case SchedulerType.mompso:
        return 'MOMPSO';

      case SchedulerType.mompsoGa:
        return 'MOMPSO-GA';

      case SchedulerType.roundRobin:
        return 'Round robin';

      case SchedulerType.random:
        return 'Random';
    }
  }

  String get description {
    switch (this) {
      case SchedulerType.greedy:
        return 'Selects the client with the best current estimated performance.';

      case SchedulerType.pso:
        return 'Particle Swarm Optimization based scheduling.';

      case SchedulerType.mompso:
        return 'Multi-objective scheduling using processing and bandwidth metrics.';

      case SchedulerType.mompsoGa:
        return 'MOMPSO with genetic-style adaptive selection.';

      case SchedulerType.roundRobin:
        return 'Baseline: deals units to clients in turn, ignoring speed.';

      case SchedulerType.random:
        return 'Baseline: random assignment (seeded, repeatable).';
    }
  }

  /// Returns null for an unknown id (unlike [fromId], which falls back to greedy).
  static SchedulerType? tryFromId(String id) {
    for (final t in SchedulerType.values) {
      if (t.id == id) return t;
    }
    return null;
  }

  static SchedulerType fromId(String id) {
    switch (id) {
      case 'pso':
        return SchedulerType.pso;

      case 'mompso':
        return SchedulerType.mompso;

      case 'mompso-ga':
        return SchedulerType.mompsoGa;

      case 'round_robin':
        return SchedulerType.roundRobin;

      case 'random':
        return SchedulerType.random;

      case 'greedy':
      default:
        return SchedulerType.greedy;
    }
  }
}