import 'scheduler.dart';
import 'scheduler_registry.dart';
import 'scheduler_type.dart';

class SchedulerFactory {
  SchedulerFactory._();

  static Scheduler create(
    SchedulerType type,
  ) {
    return SchedulerRegistry.create(type.id);
  }
}
