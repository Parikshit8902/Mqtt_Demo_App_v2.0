import 'dart:math';

/// Rough, *uncalibrated* power model for the app's own consumption.
///
/// Phones don't expose per-app power, so we estimate:
///   P = cpuCores * wattsPerCore + (any traffic ? wifiActiveW : 0) + wifiWattsPerMBps * MB/s
///
/// Limitations worth remembering when reading results:
///  * Inference on the GPU/NPU (`InferenceService.useGpu`) is NOT visible in
///    process CPU time, so the model under-reports compute energy in that mode.
///  * Defaults are ballpark figures. On Android we also record *measured*
///    whole-device power (battery current x voltage) - use that to calibrate
///    these constants for each phone model.
class PowerModel {
  final double wattsPerCore;
  final double wifiActiveW;
  final double wifiWattsPerMBps;

  const PowerModel({
    this.wattsPerCore = 1.2,
    this.wifiActiveW = 0.05,
    this.wifiWattsPerMBps = 0.8,
  });

  static const PowerModel defaults = PowerModel();

  /// [cpuCores] is process CPU time / wall time (1.0 == one fully busy core).
  /// [bytesPerSec] is on-wire rx+tx throughput. Returns milliwatts.
  double estimateMw({required double cpuCores, required double bytesPerSec}) {
    final cpuW = max(0.0, cpuCores) * wattsPerCore;
    final mbps = max(0.0, bytesPerSec) / (1024 * 1024);
    final netW = bytesPerSec > 512 ? wifiActiveW + wifiWattsPerMBps * mbps : 0.0;
    return (cpuW + netW) * 1000.0;
  }
}
