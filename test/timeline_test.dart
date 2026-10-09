import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/metrics/metrics_store.dart';
import 'package:mqtt_demo/services/metrics/timeline.dart';

UnitRecord unit(String device, int index, {required int t, required int dl, required int infer}) => UnitRecord(
      deviceKey: device,
      jobId: 'j',
      unitIndex: index,
      bytes: 1,
      downloadMs: dl,
      inferMs: infer,
      totalMs: dl + infer,
      downloadKBps: 1,
      scheduler: '',
      t: t,
    );

void main() {
  test('bars run back from the finish time, download then inference', () {
    final a = DeviceMetrics('10.0.0.2', 'A');
    final b = DeviceMetrics('10.0.0.3', 'B');
    final host = DeviceMetrics('10.0.0.1', 'Host', isLocal: true);
    a.units['j:1'] = unit('10.0.0.2', 1, t: 5000, dl: 200, infer: 800);
    a.units['j:0'] = unit('10.0.0.2', 0, t: 3000, dl: 100, infer: 900);
    b.units['j:2'] = unit('10.0.0.3', 2, t: 4500, dl: 500, infer: 500);

    final tl = Timeline.build([host, a, b], originMs: 1000);
    expect(tl.rows.map((r) => r.name), ['A', 'B'], reason: 'the host did no work');
    final first = tl.rows.first.bars.first;
    expect(first.unitIndex, 0, reason: 'sorted by finish time');
    expect([first.startMs, first.inferStartMs, first.endMs], [1000, 1100, 2000]);
    expect(tl.spanMs, 4000);
  });

  test('without an origin the earliest start is zero', () {
    final a = DeviceMetrics('10.0.0.2', 'A');
    a.units['j:0'] = unit('10.0.0.2', 0, t: 3000, dl: 100, infer: 900);
    final tl = Timeline.build([a]);
    expect(tl.rows.single.bars.single.startMs, 0);
    expect(tl.spanMs, 1000);
  });

  test('no work, no rows', () {
    final tl = Timeline.build([DeviceMetrics('x', 'X')]);
    expect(tl.rows, isEmpty);
    expect(tl.spanMs, 0);
  });
}
