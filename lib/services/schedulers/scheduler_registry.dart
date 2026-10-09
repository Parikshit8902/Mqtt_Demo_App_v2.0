import 'scheduler.dart';
import 'greedy_scheduler.dart';
import 'pso_scheduler.dart';
import 'mompso_scheduler.dart';
import 'mompso_ga_scheduler.dart';
import 'simple_schedulers.dart';

/// Single place that knows which scheduling algorithms exist.
///
/// `SchedulerType` / `SchedulerFactory` (used by the host UI) delegate here, and
/// `POST /admin/scheduler` selects by the same string ids.
///
/// To add one: implement [Scheduler] and add a line to [_factories].
class SchedulerRegistry {
  static const String defaultId = 'greedy';

  static final Map<String, Scheduler Function()> _factories = {
    'greedy': () => GreedyScheduler(),
    'pso': () => PSOScheduler(),
    'mompso': () => MOMPSOScheduler(),
    'mompso-ga': () => MOMPSOGAScheduler(),
    // Reference baselines for experiments.
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
