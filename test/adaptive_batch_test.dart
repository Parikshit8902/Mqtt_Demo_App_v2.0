import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/distribution_manager.dart';
import 'package:mqtt_demo/services/models/assignment.dart';
import 'package:mqtt_demo/services/models/result_dto.dart';
import 'package:mqtt_demo/services/schedulers/scheduler_type.dart';

List<Unit> units(int n) =>
    [for (var i = 0; i < n; i++) Unit(unitIndex: i, start: 0, end: 100 * 1024 - 1, fileUrl: 'http://h/$i')];

void main() {
  const a = 'mqtt_client_PixelA_10-0-0-1_10-0-0-11';
  const b = 'mqtt_client_PixelB_10-0-0-1_10-0-0-12';
  late DistributionManager dm;
  var now = 0;

  setUp(() {
    now = 1000;
    dm = DistributionManager(nowMs: () => now);
    dm.setSchedulerType(SchedulerType.greedy);
    dm.registerJob('j', units(40));
    dm.registerClient(a, ClientEstimate(ttprocMs: 200, bandwidthKbps: 2000));
    dm.registerClient(b, ClientEstimate(ttprocMs: 200, bandwidthKbps: 2000));
  });

  test('large batches while plenty is left, capped by the configured size', () {
    // 40 left, 2 phones: 40 / 4 = 10, capped at 8.
    expect(dm.adaptiveBatchSize('j', 8, a), 8);
    expect(dm.adaptiveBatchSize('j', 20, a), 10);
  });

  test('shrinks to one unit near the end', () {
    for (var i = 0; i < 37; i++) {
      dm.markUnitComplete('j', i);
    }
    // 3 left, 2 phones: ceil(3 / 4) = 1.
    expect(dm.adaptiveBatchSize('j', 8, a), 1);
  });

  test('a cap of one, or an unknown job, never goes below one', () {
    expect(dm.adaptiveBatchSize('j', 1, a), 1);
    expect(dm.adaptiveBatchSize('nope', 4, a), 4);
  });

  test('phones the host has not heard from lately do not count', () {
    now += 60000; // both silent past the active window
    dm.touchClient(a);
    // only a is active: 40 / 2 = 20, capped at 16
    expect(dm.adaptiveBatchSize('j', 16, a), 16);
    expect(dm.adaptiveBatchSize('j', 30, a), 20);
  });
}
