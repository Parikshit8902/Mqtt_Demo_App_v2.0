
import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/models/assignment.dart';
import 'package:mqtt_demo/services/models/device_health.dart';
import 'package:mqtt_demo/services/models/result_dto.dart';
import 'package:mqtt_demo/services/schedulers/scheduling_model.dart';

Unit unit(int index, int bytes) => Unit(
      unitIndex: index,
      start: 0,
      end: bytes - 1,
      fileUrl: 'http://host/$index',
    );

ClientEstimate client({
  double procMs = 200,
  double bandwidthKbps = 1000,
  double recentLatencyMs = 0,
  int pending = 0,
}) =>
    ClientEstimate(
      ttprocMs: procMs,
      bandwidthKbps: bandwidthKbps,
      recentLatencyMs: recentLatencyMs,
      pending: pending,
      health: const DeviceHealth(
        batteryPct: 80,
        charging: false,
        cpuPct: 20,
      ),
    );

FleetModel fleet({
  required List<Unit> units,
  required ClientEstimate estimate,
  double blend = 0.5,
}) =>
    FleetModel(
      {'phone': estimate},
      units,
      10,
      cfg: SchedulingConfig(measuredLatencyBlend: blend),
    );

void main() {
  group('recent latency calibration', () {
    final small = unit(0, 512 * 1024);
    final large = unit(1, 1024 * 1024);
    final units = [small, large];

    // The model calculates transfer time using bytes / 1024 / KBps * 1000.
    // At 1000 KB/s, the average 768 KiB unit takes 768 ms to transfer.
    const averageModelMs = 968.0; // 768 ms transfer + 200 ms processing
    const smallModelMs = 712.0; // 512 ms transfer + 200 ms processing
    const largeModelMs = 1224.0; // 1024 ms transfer + 200 ms processing

    test('zero measurement uses modeled service time', () {
      final model = fleet(
        units: units,
        estimate: client(recentLatencyMs: 0),
      );

      expect(
        model.perUnitServiceMs('phone'),
        closeTo(averageModelMs, 1e-9),
      );
      expect(
        model.etaMs('phone', large),
        closeTo(largeModelMs, 1e-9),
      );
    });

    test('blend zero ignores measured latency', () {
      final model = fleet(
        units: units,
        estimate: client(recentLatencyMs: 600),
        blend: 0,
      );

      expect(
        model.perUnitServiceMs('phone'),
        closeTo(averageModelMs, 1e-9),
      );
      expect(
        model.etaMs('phone', large),
        closeTo(largeModelMs, 1e-9),
      );
    });

    test('blend one calibrates average-unit service to measured duration', () {
      final model = fleet(
        units: units,
        estimate: client(recentLatencyMs: 600),
        blend: 1,
      );

      expect(
        model.perUnitServiceMs('phone'),
        closeTo(600, 1e-9),
      );

      // Calibration preserves the modeled large/small service-time ratio.
      expect(
        model.etaMs('phone', large),
        closeTo(largeModelMs * 600 / averageModelMs, 1e-9),
      );
      expect(
        model.etaMs('phone', small),
        closeTo(smallModelMs * 600 / averageModelMs, 1e-9),
      );
    });

    test('intermediate blend calibrates queue and task service consistently', () {
      final model = fleet(
        units: units,
        estimate: client(recentLatencyMs: 600, pending: 2),
        blend: 0.5,
      );

      // Average service = 0.5 * 600 + 0.5 * 968 = 784 ms.
      const blendedAverageMs = 784.0;

      expect(
        model.perUnitServiceMs('phone'),
        closeTo(blendedAverageMs, 1e-9),
      );

      // Two queued average units plus the calibrated large task.
      expect(
        model.etaMs('phone', large),
        closeTo(
          2 * blendedAverageMs +
              largeModelMs * blendedAverageMs / averageModelMs,
          1e-9,
        ),
      );
    });

    test('different unit sizes retain different modeled service durations', () {
      final model = fleet(
        units: units,
        estimate: client(recentLatencyMs: 600),
        blend: 0.5,
      );

      expect(
        model.etaMs('phone', large),
        greaterThan(model.etaMs('phone', small)),
      );
    });
  });
}