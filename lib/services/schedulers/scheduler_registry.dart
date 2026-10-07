import 'scheduler.dart';
import 'greedy_scheduler.dart';
import 'simple_schedulers.dart';

/// Single place that knows which scheduling algorithms exist.
///
/// To add one (PSO, the published algorithm, ...): implement [Scheduler] and add
/// a line to [_factories] (or call [register] at startup). It then shows up in
/// the metrics screen's scheduler picker and in `POST /admin/scheduler`.
class SchedulerRegistry {
  static const String defaultId = 'greedy';

  static final Map<String, Scheduler Function()> _factories = {
    'greedy': () => GreedyScheduler(),
    'round_robin': () => RoundRobinScheduler(),
    'random': () => RandomScheduler(),
  };

  static List<String> get ids => _factories.keys.toList();

  static bool contains(String id) => _factories.containsKey(id);

  static void register(String id, Scheduler Function() factory) => _factories[id] = factory;

  /// Unknown ids fall back to the default so a bad setting can't stop the job.
  static Scheduler create(String id) => (_factories[id] ?? _factories[defaultId]!)();

  static String labelFor(String id) => create(id).label;
}
