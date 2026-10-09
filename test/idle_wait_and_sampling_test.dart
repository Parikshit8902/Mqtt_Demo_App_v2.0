import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/performance_service.dart';
import 'package:mqtt_demo/services/utils/idle_wait.dart';

void main() {
  group('IdleBackoff', () {
    test('doubles up to the cap and starts over after reset', () {
      final b = IdleBackoff(min: const Duration(seconds: 2), max: const Duration(seconds: 16));
      expect([for (var i = 0; i < 6; i++) b.next().inSeconds], [2, 4, 8, 16, 16, 16]);
      b.reset();
      expect(b.next().inSeconds, 2);
    });
  });

  group('WakeableDelay', () {
    test('sleeps the full delay when nobody wakes it', () async {
      final d = WakeableDelay();
      final sw = Stopwatch()..start();
      await d.sleep(const Duration(milliseconds: 50));
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(45));
    });

    test('wake cuts a sleep short', () async {
      final d = WakeableDelay();
      final sw = Stopwatch()..start();
      Future.delayed(const Duration(milliseconds: 20), d.wake);
      await d.sleep(const Duration(seconds: 10));
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });

    test('a wake while awake is kept for the next sleep, once', () async {
      final d = WakeableDelay();
      d.wake();
      final sw = Stopwatch()..start();
      await d.sleep(const Duration(seconds: 10));
      expect(sw.elapsedMilliseconds, lessThan(2000));
      sw.reset();
      await d.sleep(const Duration(milliseconds: 50));
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(45), reason: 'the remembered wake is used up');
    });
  });

  group('sampling across app lifecycle', () {
    test('transient interruptions never stop sampling', () {
      for (final run in [true, false]) {
        expect(PerformanceService.samplesIn(AppLifecycleState.resumed, runActive: run), isTrue);
        expect(PerformanceService.samplesIn(AppLifecycleState.inactive, runActive: run), isTrue);
      }
    });

    test('backgrounding stops sampling only when no experiment is running', () {
      for (final s in [AppLifecycleState.hidden, AppLifecycleState.paused, AppLifecycleState.detached]) {
        expect(PerformanceService.samplesIn(s, runActive: true), isTrue);
        expect(PerformanceService.samplesIn(s, runActive: false), isFalse);
      }
    });
  });
}
