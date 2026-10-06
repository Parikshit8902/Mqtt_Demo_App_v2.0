enum SchedulerType {
  greedy,
  pso,
  mompso,
  mompsoGa,
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
    }
  }

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
    }
  }

  static SchedulerType fromId(String id) {
    switch (id) {
      case 'pso':
        return SchedulerType.pso;

      case 'mompso':
        return SchedulerType.mompso;

      case 'mompso-ga':
        return SchedulerType.mompsoGa;

      case 'greedy':
      default:
        return SchedulerType.greedy;
    }
  }
}