// Small helpers to compute bandwidth and time-based metrics used across services.
double computeBandwidthKbpsFromSeconds(int bytes, double seconds) {
  final sec = seconds > 0 ? seconds : 1.0;
  return (bytes / 1024.0) / sec;
}

double computeBandwidthKbpsFromMs(int bytes, int ms) {
  return computeBandwidthKbpsFromSeconds(bytes, ms / 1000.0);
}

double safeSecondsFromMs(int ms) => (ms / 1000.0) > 0 ? (ms / 1000.0) : 1.0;
