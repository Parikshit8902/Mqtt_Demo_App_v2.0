import 'scheduler.dart';
import 'scheduler_type.dart';
import 'greedy_scheduler.dart';
import 'pso_scheduler.dart';
import 'mompso_scheduler.dart';
import 'mompso_ga_scheduler.dart';

class SchedulerFactory {
  SchedulerFactory._();

  static Scheduler create(
    SchedulerType type,
  ) {
    switch (type) {
      case SchedulerType.greedy:
        return GreedyScheduler();

      case SchedulerType.pso:
        return PSOScheduler();

      case SchedulerType.mompso:
        return MOMPSOScheduler();

      case SchedulerType.mompsoGa:
        return MOMPSOGAScheduler();
    }
  }
}