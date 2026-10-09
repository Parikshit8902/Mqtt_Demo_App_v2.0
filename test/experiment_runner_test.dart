import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/experiment_runner.dart';

/// A fake host: each poll finishes [perPoll] units; time moves 2 s per sleep.
class FakeHost {
  final int total;
  final int perPoll;
  DateTime clock = DateTime(2026, 1, 1);
  int done = 0;
  final calls = <String>[];

  FakeHost({this.total = 10, this.perPoll = 4});

  RunnerHooks hooks() => RunnerHooks(
        reset: () async {
          calls.add('reset');
          done = 0;
        },
        setScheduler: (id) => calls.add('scheduler:$id'),
        start: () async => calls.add('start'),
        progress: () {
          final p = {'total': total, 'completed': done, 'failed': 0, 'available': total - done, 'assigned': 0};
          if (perPoll > 0) done = (done + perPoll).clamp(0, total);
          return p;
        },
        export: (r) async => calls.add('export:${r.label}'),
        exportSummary: () async => calls.add('summary'),
        sleep: (d) async => clock = clock.add(d),
        now: () => clock,
      );
}

void main() {
  test('runs are interleaved and each is exported before the next reset', () async {
    final host = FakeHost();
    final runner = ExperimentRunner(hooks: host.hooks(), schedulers: ['greedy', 'pso'], repeats: 2);
    expect(runner.plan.map((r) => r.label), ['greedy_r1', 'pso_r1', 'greedy_r2', 'pso_r2']);
    await runner.run();
    expect(runner.state, RunnerState.done);
    expect(runner.outcomes.length, 4);
    expect(runner.outcomes.every((o) => o.finished && o.completed == 10), isTrue);
    expect(host.calls.take(4), ['reset', 'scheduler:greedy', 'start', 'export:greedy_r1']);
    expect(host.calls.last, 'summary');
    expect(host.calls.where((c) => c == 'reset').length, 4);
  });

  test('a run that never finishes stops at the timeout and the batch goes on', () async {
    final host = FakeHost(perPoll: 0);
    final runner = ExperimentRunner(
      hooks: host.hooks(),
      schedulers: ['greedy', 'pso'],
      timeout: const Duration(seconds: 10),
    );
    await runner.run();
    expect(runner.outcomes.map((o) => o.finished), [false, false]);
    expect(runner.outcomes.first.took, greaterThanOrEqualTo(const Duration(seconds: 10)));
    expect(host.calls.where((c) => c.startsWith('export:')).length, 2, reason: 'a timed-out run is still saved');
  });

  test('failed units count as settled', () async {
    final host = FakeHost();
    final hooks = host.hooks();
    final runner = ExperimentRunner(
      hooks: RunnerHooks(
        reset: hooks.reset,
        setScheduler: hooks.setScheduler,
        start: hooks.start,
        progress: () => {'total': 5, 'completed': 3, 'failed': 2, 'available': 0, 'assigned': 0},
        export: hooks.export,
        exportSummary: hooks.exportSummary,
        sleep: hooks.sleep,
        now: hooks.now,
      ),
      schedulers: ['greedy'],
    );
    await runner.run();
    expect(runner.outcomes.single.finished, isTrue);
  });

  test('cancel stops the batch; an unfinished run is not exported', () async {
    final host = FakeHost(perPoll: 0);
    late ExperimentRunner runner;
    var sleeps = 0;
    final h = host.hooks();
    runner = ExperimentRunner(
      hooks: RunnerHooks(
        reset: h.reset,
        setScheduler: h.setScheduler,
        start: h.start,
        progress: h.progress,
        export: h.export,
        exportSummary: h.exportSummary,
        sleep: (d) async {
          if (++sleeps == 3) runner.cancel();
          await h.sleep(d);
        },
        now: h.now,
      ),
      schedulers: ['greedy', 'pso'],
    );
    await runner.run();
    expect(runner.state, RunnerState.cancelled);
    expect(runner.outcomes, isEmpty);
    expect(host.calls.where((c) => c.startsWith('export')), isEmpty);
  });
}
