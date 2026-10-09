import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/fault_injector.dart';

void main() {
  test('faults are set, described, cleared and logged', () {
    var now = 1000;
    final f = FaultInjector(nowMs: () => now);
    expect(f.faultFor('10.0.0.2').isNone, isTrue);

    f.set('10.0.0.2', const PhoneFault(dropped: true, extraDelayMs: 250));
    expect(f.isDropped('10.0.0.2'), isTrue);
    expect(f.faultFor('10.0.0.2').describe(), 'dropped, +250 ms delay');

    now = 5000;
    f.clear('10.0.0.2');
    expect(f.isDropped('10.0.0.2'), isFalse);
    expect(f.active, isEmpty);
    expect(f.history.map((e) => e.t), [1000, 5000]);
    expect(f.history.last.fault.describe(), 'none');

    f.clear('10.0.0.9'); // nothing set: nothing logged
    expect(f.history.length, 2);

    f.reset();
    expect(f.history, isEmpty);
  });

  test('JSON round trip ignores nonsense values', () {
    final p = PhoneFault.fromJson({'drop': true, 'delay_ms': -5, 'bandwidth_kBps': 0});
    expect(p.dropped, isTrue);
    expect(p.extraDelayMs, 0);
    expect(p.bandwidthKBps, isNull);
    final q = PhoneFault.fromJson(const PhoneFault(bandwidthKBps: 200).toJson());
    expect(q.bandwidthKBps, 200);
    expect(q.describe(), 'capped at 200 kB/s');
  });

  test('throttled stream keeps every byte and takes about size / cap', () async {
    final data = List<int>.generate(100 * 1024, (i) => i % 251);
    final sw = Stopwatch()..start();
    final out = <int>[];
    await for (final c in throttleStream(Stream.value(data), 500)) {
      out.addAll(c);
    }
    sw.stop();
    expect(out, data);
    // 100 kB at 500 kB/s = 200 ms
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(180));
    expect(sw.elapsedMilliseconds, lessThan(1500));
  });
}
