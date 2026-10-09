import 'dart:math';

import 'metrics_store.dart';

/// One image on a phone's row: when its download started, when inference
/// started, and when it finished, in ms since the timeline's origin.
class TimelineBar {
  final int unitIndex;
  final int startMs;
  final int inferStartMs;
  final int endMs;

  const TimelineBar(this.unitIndex, this.startMs, this.inferStartMs, this.endMs);
}

class TimelineRow {
  final String deviceKey;
  final String name;
  final List<TimelineBar> bars;

  const TimelineRow(this.deviceKey, this.name, this.bars);
}

/// Which phone handled which image and when, on the host's clock.
class Timeline {
  final List<TimelineRow> rows;

  /// Length of the drawn span, ms (0 when there are no bars).
  final int spanMs;

  const Timeline(this.rows, this.spanMs);

  /// A row per phone with finished images (the host is left out unless it
  /// did work itself). A unit record's time is when it finished, so its bar
  /// runs back by its total time: download first, then inference. Times are
  /// relative to [originMs] (the experiment start) or else the earliest bar.
  factory Timeline.build(List<DeviceMetrics> devices, {int? originMs}) {
    final raw = <(DeviceMetrics, List<UnitRecord>)>[
      for (final d in devices)
        if (d.units.isNotEmpty) (d, d.units.values.toList()..sort((a, b) => a.t.compareTo(b.t))),
    ];
    int startOf(UnitRecord u) => u.t - (u.totalMs > 0 ? u.totalMs : u.downloadMs + u.inferMs);
    final earliest = raw.expand((r) => r.$2).map(startOf).fold<int?>(null, (a, b) => a == null ? b : min(a, b));
    final origin = originMs ?? earliest ?? 0;

    var span = 0;
    final rows = <TimelineRow>[
      for (final (d, units) in raw)
        TimelineRow(d.key, d.name, [
          for (final u in units)
            () {
              final start = startOf(u) - origin;
              final end = u.t - origin;
              span = max(span, end);
              return TimelineBar(u.unitIndex, start, min(end, start + u.downloadMs), end);
            }(),
        ]),
    ];
    return Timeline(rows, span);
  }
}
