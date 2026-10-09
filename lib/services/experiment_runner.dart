import 'dart:async';

import 'package:flutter/foundation.dart';

/// One planned run: a scheduler and which repeat of it this is (1-based).
class PlannedRun {
  final String scheduler;
  final int repeat;

  const PlannedRun(this.scheduler, this.repeat);

  String get label => '${scheduler}_r$repeat';
}

/// What happened to a run.
class RunOutcome {
  final PlannedRun run;
  final bool finished; // false = stopped at the timeout
  final Duration took;
  final int completed, failed, total;

  const RunOutcome(this.run, {required this.finished, required this.took, required this.completed, required this.failed, required this.total});
}

enum RunnerState { idle, running, done, cancelled }

/// What the runner needs from the host; plain callbacks, so it can be
/// driven by a fake clock in tests.
class RunnerHooks {
  /// Clear the current experiment (archives the finished run's metrics).
  final Future<void> Function() reset;
  final void Function(String schedulerId) setScheduler;

  /// Make the job hand out work again and wake idle workers.
  final Future<void> Function() start;

  /// `total`, `completed`, `failed`, `available`, `assigned` for the job.
  final Map<String, int> Function() progress;

  /// Save this run's files; called while its metrics are still current.
  final Future<void> Function(PlannedRun run) export;

  /// After the last run: save files that cover every run (runs.csv).
  final Future<void> Function() exportSummary;

  final Future<void> Function(Duration) sleep;
  final DateTime Function() now;

  RunnerHooks({
    required this.reset,
    required this.setScheduler,
    required this.start,
    required this.progress,
    required this.export,
    required this.exportSummary,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
  })  : sleep = sleep ?? ((d) => Future.delayed(d)),
        now = now ?? DateTime.now;
}

/// Runs every scheduler [repeats] times on the shared dataset, one after
/// another: reset, select the scheduler, start, wait until every unit is
/// finished or given up (or [timeout] passes), then export that run's files.
/// The runs are interleaved (A B C A B C ...) rather than grouped, so slow
/// drift such as phones heating up affects every scheduler alike.
class ExperimentRunner extends ChangeNotifier {
  final RunnerHooks hooks;
  final List<PlannedRun> plan;
  final Duration timeout;
  final Duration pollEvery;

  /// Pause between runs, so phones finish uploads and cool down a little.
  final Duration gap;

  ExperimentRunner({
    required this.hooks,
    required List<String> schedulers,
    int repeats = 1,
    this.timeout = const Duration(minutes: 30),
    this.pollEvery = const Duration(seconds: 2),
    this.gap = const Duration(seconds: 5),
  }) : plan = [
          for (var r = 1; r <= repeats; r++)
            for (final s in schedulers) PlannedRun(s, r),
        ];

  RunnerState state = RunnerState.idle;
  int current = -1; // index into [plan] of the run in progress
  final List<RunOutcome> outcomes = [];
  Map<String, int> lastProgress = const {};
  Object? error;

  bool _cancel = false;

  PlannedRun? get running => current >= 0 && current < plan.length ? plan[current] : null;

  void cancel() {
    _cancel = true;
  }

  Future<void> run() async {
    if (state == RunnerState.running || plan.isEmpty) return;
    state = RunnerState.running;
    _cancel = false;
    notifyListeners();
    try {
      for (var i = 0; i < plan.length && !_cancel; i++) {
        current = i;
        notifyListeners();
        await _runOne(plan[i]);
        if (i < plan.length - 1 && !_cancel) await hooks.sleep(gap);
      }
      if (outcomes.isNotEmpty) await hooks.exportSummary();
      state = _cancel ? RunnerState.cancelled : RunnerState.done;
    } catch (e) {
      error = e;
      state = RunnerState.cancelled;
    } finally {
      current = -1;
      notifyListeners();
    }
  }

  Future<void> _runOne(PlannedRun r) async {
    await hooks.reset();
    hooks.setScheduler(r.scheduler);
    await hooks.start();
    final began = hooks.now();
    var finished = false;
    while (!_cancel) {
      lastProgress = hooks.progress();
      notifyListeners();
      final total = lastProgress['total'] ?? 0;
      final settled = (lastProgress['completed'] ?? 0) + (lastProgress['failed'] ?? 0);
      if (total > 0 && settled >= total) {
        finished = true;
        break;
      }
      if (hooks.now().difference(began) >= timeout) break;
      await hooks.sleep(pollEvery);
    }
    if (_cancel && !finished) return;
    await hooks.export(r);
    outcomes.add(RunOutcome(
      r,
      finished: finished,
      took: hooks.now().difference(began),
      completed: lastProgress['completed'] ?? 0,
      failed: lastProgress['failed'] ?? 0,
      total: lastProgress['total'] ?? 0,
    ));
    notifyListeners();
  }
}
