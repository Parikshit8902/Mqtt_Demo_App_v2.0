/// Live health of one phone, as last observed.
///
/// Every field is optional: `null` means "unknown" (an old client, an OS that
/// doesn't expose it, or a sensor that failed). Schedulers must treat `null` as
/// neutral and never penalise a phone for something that wasn't measured.
///
/// The same short wire keys are used in three places, so a value has one
/// spelling everywhere: the periodic `clients/metrics` MQTT sample, the
/// `health` object attached to each `ResultReport`, and the metrics export.
///
/// | field          | key   | meaning                                              |
/// |----------------|-------|------------------------------------------------------|
/// | cpuPct         | `cn`  | app CPU as a share of the whole SoC, 0..100          |
/// | memFreeMb      | `fm`  | RAM the OS reports as available, MB                  |
/// | memTotalMb     | `tm`  | total RAM, MB                                        |
/// | lowMemory      | `lm`  | OS low-memory flag (1/0)                             |
/// | batteryPct     | `bp`  | 0..100                                               |
/// | charging       | `chg` | plugged in (1/0)                                     |
/// | batteryTempC   | `bt`  | battery temperature, deg C                           |
/// | thermalStatus  | `th`  | 0 none, 1 light, 2 moderate, 3 severe, 4 critical, 5 emergency, 6 shutdown |
/// | rssiDbm        | `rs`  | Wi-Fi signal strength, dBm (e.g. -55)                |
/// | linkMbps       | `ls`  | negotiated Wi-Fi link speed, Mbps                    |
/// | powerMw        | `pw`  | measured whole-device draw, mW (Android, unplugged)  |
///
/// Android reports `thermalStatus` from `PowerManager.getCurrentThermalStatus`.
/// iOS maps `ProcessInfo.thermalState` onto the same scale
/// (nominal 0, fair 1, serious 3, critical 4).
class DeviceHealth {
  final double? cpuPct;
  final double? memFreeMb;
  final double? memTotalMb;
  final bool? lowMemory;
  final int? batteryPct;
  final bool? charging;
  final double? batteryTempC;
  final int? thermalStatus;
  final int? rssiDbm;
  final int? linkMbps;
  final double? powerMw;

  /// Host-side epoch ms when this was received (0 = never).
  final int updatedAtMs;

  const DeviceHealth({
    this.cpuPct,
    this.memFreeMb,
    this.memTotalMb,
    this.lowMemory,
    this.batteryPct,
    this.charging,
    this.batteryTempC,
    this.thermalStatus,
    this.rssiDbm,
    this.linkMbps,
    this.powerMw,
    this.updatedAtMs = 0,
  });

  static const DeviceHealth unknown = DeviceHealth();

  bool get isUnknown =>
      cpuPct == null &&
      memFreeMb == null &&
      memTotalMb == null &&
      lowMemory == null &&
      batteryPct == null &&
      charging == null &&
      batteryTempC == null &&
      thermalStatus == null &&
      rssiDbm == null &&
      linkMbps == null &&
      powerMw == null;

  /// Fraction of RAM free (0..1), or null when either figure is unknown.
  double? get memFreeFraction {
    final free = memFreeMb;
    final total = memTotalMb;
    if (free == null || total == null || total <= 0) return null;
    return (free / total).clamp(0.0, 1.0);
  }

  /// Fields present in [newer] win; fields it lacks keep this value. This lets
  /// a partial update (e.g. a result report without RSSI) refine, not erase.
  DeviceHealth merge(DeviceHealth newer) => DeviceHealth(
        cpuPct: newer.cpuPct ?? cpuPct,
        memFreeMb: newer.memFreeMb ?? memFreeMb,
        memTotalMb: newer.memTotalMb ?? memTotalMb,
        lowMemory: newer.lowMemory ?? lowMemory,
        batteryPct: newer.batteryPct ?? batteryPct,
        charging: newer.charging ?? charging,
        batteryTempC: newer.batteryTempC ?? batteryTempC,
        thermalStatus: newer.thermalStatus ?? thermalStatus,
        rssiDbm: newer.rssiDbm ?? rssiDbm,
        linkMbps: newer.linkMbps ?? linkMbps,
        powerMw: newer.powerMw ?? powerMw,
        updatedAtMs: newer.updatedAtMs > updatedAtMs ? newer.updatedAtMs : updatedAtMs,
      );

  /// Only non-null fields are emitted, keeping MQTT payloads small.
  Map<String, dynamic> toWire() => {
        if (cpuPct != null) 'cn': double.parse(cpuPct!.toStringAsFixed(2)),
        if (memFreeMb != null) 'fm': double.parse(memFreeMb!.toStringAsFixed(1)),
        if (memTotalMb != null) 'tm': double.parse(memTotalMb!.toStringAsFixed(1)),
        if (lowMemory != null) 'lm': lowMemory! ? 1 : 0,
        if (batteryPct != null) 'bp': batteryPct,
        if (charging != null) 'chg': charging! ? 1 : 0,
        if (batteryTempC != null) 'bt': double.parse(batteryTempC!.toStringAsFixed(1)),
        if (thermalStatus != null) 'th': thermalStatus,
        if (rssiDbm != null) 'rs': rssiDbm,
        if (linkMbps != null) 'ls': linkMbps,
        if (powerMw != null) 'pw': double.parse(powerMw!.toStringAsFixed(0)),
      };

  /// Tolerant parser: unknown keys are ignored, wrong types become null, and a
  /// legacy `b` ("77%" or 77) is accepted when `bp` is absent. A negative
  /// battery/thermal/RSSI/link value is the native layers' "unavailable" and
  /// becomes null.
  factory DeviceHealth.fromWire(Map<String, dynamic> j, {int updatedAtMs = 0}) {
    double? d(dynamic v) => v is num ? v.toDouble() : null;
    int? i(dynamic v) => v is num ? v.toInt() : null;
    bool? b(dynamic v) {
      if (v is bool) return v;
      if (v is num) return v != 0;
      return null;
    }

    int? battery = i(j['bp']);
    if (battery == null) {
      final legacy = j['b'];
      if (legacy is num) {
        battery = legacy.toInt();
      } else if (legacy is String) {
        battery = int.tryParse(RegExp(r'-?\d+').firstMatch(legacy)?.group(0) ?? '');
      }
    }
    if (battery != null && (battery < 0 || battery > 100)) battery = null;

    int? thermal = i(j['th']);
    if (thermal != null && thermal < 0) thermal = null;

    int? link = i(j['ls']);
    if (link != null && link <= 0) link = null;

    int? rssi = i(j['rs']);
    // 0 and positive dBm are not real readings (Android uses -127 for "invalid").
    if (rssi != null && (rssi >= 0 || rssi <= -127)) rssi = null;

    return DeviceHealth(
      cpuPct: d(j['cn'])?.clamp(0.0, 100.0),
      memFreeMb: d(j['fm']),
      memTotalMb: d(j['tm']),
      lowMemory: b(j['lm']),
      batteryPct: battery,
      charging: b(j['chg']),
      batteryTempC: d(j['bt']),
      thermalStatus: thermal,
      rssiDbm: rssi,
      linkMbps: link,
      powerMw: d(j['pw']),
      updatedAtMs: updatedAtMs,
    );
  }
}
