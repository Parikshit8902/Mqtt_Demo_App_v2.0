import Flutter
import UIKit
import Darwin
import os

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let performance = PerformanceChannel()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "PerformanceChannel") {
      performance.register(with: registrar.messenger())
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// iOS counterpart of MainActivity.kt's `com.example.mqtt_demo/performance` channel.
///
/// What iOS can and cannot report (compared with Android):
///  - CPU:     process CPU time via getrusage. Reported in microseconds, so
///             `getClockTicksPerSecond` returns 1_000_000.
///  - Memory:  phys_footprint (what Xcode's memory gauge shows).
///  - Network: iOS has no per-app byte counters. We read the Wi-Fi interface (en0)
///             counters, which are WHOLE-DEVICE. On a dedicated test phone this is
///             close to the app's traffic; subtract a baseline if other apps run.
///  - Disk:    not available (keys omitted; Dart skips them).
///  - Battery: percentage only. No current/voltage API, so measured power is
///             unavailable and only the modelled estimate is produced.
///  - Health:  `getDeviceHealth` reports physical memory, headroom before the system
///             kills the app, thermal state and charging. Wi-Fi RSSI/link speed and
///             battery temperature are not exposed to apps on iOS, so those keys are omitted.
final class PerformanceChannel {
  // Below this headroom iOS is close to terminating the app, which is the nearest
  // equivalent of Android's lowMemory flag.
  private let lowMemoryHeadroomBytes = 100 * 1024 * 1024

  // en0 byte counters are 32-bit and wrap at 4 GiB; accumulate into 64-bit.
  private var lastRx: UInt32 = 0
  private var lastTx: UInt32 = 0
  private var totalRx: Int64 = 0
  private var totalTx: Int64 = 0
  private var haveBaseline = false

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.example.mqtt_demo/performance", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterMethodNotImplemented); return }
      switch call.method {
      case "getClockTicksPerSecond":
        result(1_000_000)
      case "getPerformanceMetrics":
        result(self.performanceMetrics())
      case "getAppMemoryUsageMB":
        result(self.memoryMB())
      case "getBatteryDetails":
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel // -1 when unknown (e.g. Simulator)
        // -1 = unknown (Simulator). Reporting 0 would make the scheduler think the battery is empty.
        result(level < 0 ? -1 : Int((level * 100).rounded()))
      case "getPowerDetails":
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        // No current/voltage on iOS: Dart treats a missing current as "unmeasured".
        result(["charging": state == .charging || state == .full])
      case "getDeviceHealth":
        result(self.deviceHealth())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Live device state for the dynamic schedulers. A key is omitted rather than guessed
  /// when iOS cannot report it; the Dart side treats an absent key as unknown.
  private func deviceHealth() -> [String: Any] {
    var health: [String: Any] = [:]
    let bytesPerMB = 1024.0 * 1024.0

    health["memTotalMb"] = Double(ProcessInfo.processInfo.physicalMemory) / bytesPerMB

    // iOS has no "free RAM" figure for apps; the headroom before the system kills this
    // app is the usable equivalent. It returns 0 both when it cannot answer (not an app)
    // and when the limit is already exceeded (the app would be dead), so 0 means unknown.
    if #available(iOS 13.0, *) {
      let headroom = os_proc_available_memory()
      if headroom > 0 {
        health["memFreeMb"] = Double(headroom) / bytesPerMB
        health["lowMemory"] = headroom < lowMemoryHeadroomBytes
      }
    }

    // Values follow Android's THERMAL_STATUS_* scale (which has MODERATE = 2 between
    // fair and serious), so the Dart side can interpret both platforms identically.
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: health["thermalStatus"] = 0
    case .fair: health["thermalStatus"] = 1
    case .serious: health["thermalStatus"] = 3
    case .critical: health["thermalStatus"] = 4
    @unknown default: break
    }

    UIDevice.current.isBatteryMonitoringEnabled = true
    let batteryState = UIDevice.current.batteryState
    if batteryState != .unknown {
      health["charging"] = batteryState == .charging || batteryState == .full
    }

    return health
  }

  private func performanceMetrics() -> [String: Int] {
    var metrics: [String: Int] = [:]

    var usage = rusage()
    if getrusage(RUSAGE_SELF, &usage) == 0 {
      let micros = Int(usage.ru_utime.tv_sec) * 1_000_000 + Int(usage.ru_utime.tv_usec)
                 + Int(usage.ru_stime.tv_sec) * 1_000_000 + Int(usage.ru_stime.tv_usec)
      metrics["cpuJiffies"] = micros
    }

    if let (rx, tx) = wifiCounters() {
      if haveBaseline {
        totalRx += Int64(rx &- lastRx) // wrapping subtraction handles the 32-bit rollover
        totalTx += Int64(tx &- lastTx)
      }
      lastRx = rx
      lastTx = tx
      haveBaseline = true
      metrics["netRxBytes"] = Int(totalRx)
      metrics["netTxBytes"] = Int(totalTx)
    }
    return metrics
  }

  private func wifiCounters() -> (UInt32, UInt32)? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let p = ptr {
      let ifa = p.pointee
      if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
         String(cString: ifa.ifa_name) == "en0", let data = ifa.ifa_data {
        let d = data.assumingMemoryBound(to: if_data.self).pointee
        return (d.ifi_ibytes, d.ifi_obytes)
      }
      ptr = ifa.ifa_next
    }
    return nil
  }

  private func memoryMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / (1024.0 * 1024.0) : 0
  }
}
