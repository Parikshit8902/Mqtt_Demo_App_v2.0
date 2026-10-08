/// The numbers used to compare one run (one scheduler on one dataset) with
/// another: how long the job took, how fast images went through, how long
/// each image took, how evenly the phones were loaded, and the energy cost.
class RunMetrics {
  final String scheduler;

  /// How the host served the images (see ImageVariant.label).
  final String images;

  /// Host clock, epoch ms: first assignment and last result of the run.
  final int? startMs;
  final int? endMs;

  /// Distinct images finished (a unit finished twice after a requeue counts once).
  final int units;

  /// Phones that took part: every phone with a finished image, plus the
  /// workers that finished none.
  final int phones;

  /// Download + inference time per image, ms.
  final double meanLatencyMs;
  final double p50LatencyMs;
  final double p95LatencyMs;

  /// Jain's fairness index (1 = perfectly even, 1/n = one phone did it all)
  /// over images per phone and over busy time (summed latency) per phone.
  final double jainUnits;
  final double jainBusy;

  /// Modelled energy of every phone (host included) over its recording,
  /// divided by [units]. Null when no energy was recorded.
  final double? energyPerImageJ;

  const RunMetrics({
    required this.scheduler,
    this.images = 'original',
    required this.startMs,
    required this.endMs,
    required this.units,
    required this.phones,
    required this.meanLatencyMs,
    required this.p50LatencyMs,
    required this.p95LatencyMs,
    required this.jainUnits,
    required this.jainBusy,
    required this.energyPerImageJ,
  });

  /// Wall time from first assignment to last result, seconds (0 if unknown).
  double get makespanS =>
      (startMs != null && endMs != null && endMs! > startMs!) ? (endMs! - startMs!) / 1000.0 : 0;

  /// Images per second over the makespan (0 if unknown).
  double get throughput => makespanS > 0 ? units / makespanS : 0;

  /// [latencies] holds each finished image's id, phone and latency;
  /// [phonesWithNoWork] lists workers that finished nothing (they lower
  /// fairness); [totalEnergyJ] is the modelled energy of every phone.
  factory RunMetrics.compute({
    required String scheduler,
    String images = 'original',
    required int? startMs,
    required int? endMs,
    required List<({String unitId, String phone, int latencyMs})> latencies,
    Iterable<String> phonesWithNoWork = const [],
    double? totalEnergyJ,
  }) {
    final distinct = latencies.map((l) => l.unitId).toSet().length;
    final perPhoneUnits = <String, double>{for (final p in phonesWithNoWork) p: 0};
    final perPhoneBusy = <String, double>{for (final p in phonesWithNoWork) p: 0};
    for (final l in latencies) {
      perPhoneUnits[l.phone] = (perPhoneUnits[l.phone] ?? 0) + 1;
      perPhoneBusy[l.phone] = (perPhoneBusy[l.phone] ?? 0) + l.latencyMs;
    }
    final sorted = latencies.map((l) => l.latencyMs.toDouble()).toList()..sort();
    final mean = sorted.isEmpty ? 0.0 : sorted.reduce((a, b) => a + b) / sorted.length;
    return RunMetrics(
      scheduler: scheduler,
      images: images,
      startMs: startMs,
      endMs: endMs,
      units: distinct,
      phones: perPhoneUnits.length,
      meanLatencyMs: mean,
      p50LatencyMs: percentile(sorted, 50),
      p95LatencyMs: percentile(sorted, 95),
      jainUnits: jain(perPhoneUnits.values),
      jainBusy: jain(perPhoneBusy.values),
      energyPerImageJ: (totalEnergyJ != null && totalEnergyJ > 0 && distinct > 0) ? totalEnergyJ / distinct : null,
    );
  }

  /// Nearest-rank percentile of an ascending list (0 when empty).
  static double percentile(List<double> ascending, double p) {
    if (ascending.isEmpty) return 0;
    final rank = (p / 100 * ascending.length).ceil().clamp(1, ascending.length);
    return ascending[rank - 1];
  }

  /// Jain's fairness index: (sum x)^2 / (n * sum x^2). 1 when there is
  /// nothing to share out, so an empty run does not read as unfair.
  static double jain(Iterable<double> xs) {
    final list = xs.toList();
    final sum = list.fold(0.0, (a, b) => a + b);
    final sumSq = list.fold(0.0, (a, b) => a + b * b);
    if (list.isEmpty || sumSq == 0) return 1;
    return sum * sum / (list.length * sumSq);
  }

  static const csvHeader = [
    'scheduler', 'start_ms', 'end_ms', 'makespan_s', 'units', 'phones', 'throughput_per_s',
    'latency_mean_ms', 'latency_p50_ms', 'latency_p95_ms', 'jain_units', 'jain_busy', 'energy_per_image_j',
    'images',
  ];

  List<Object?> csvCells() => [
        scheduler, startMs, endMs, _r(makespanS), units, phones, _r(throughput, 4),
        _r(meanLatencyMs), _r(p50LatencyMs), _r(p95LatencyMs), _r(jainUnits, 4), _r(jainBusy, 4),
        energyPerImageJ == null ? null : _r(energyPerImageJ!, 3),
        images,
      ];

  Map<String, dynamic> toJson() => {
        for (var i = 0; i < csvHeader.length; i++) csvHeader[i]: csvCells()[i],
      };

  static double _r(double v, [int digits = 1]) => double.parse(v.toStringAsFixed(digits));
}
