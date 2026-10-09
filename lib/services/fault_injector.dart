import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// A fault the host applies to one worker phone, to test how a scheduler
/// copes without needing a phone that really misbehaves.
class PhoneFault {
  /// The phone looks dead: it gets no new work, and the host refuses its
  /// results, metrics uploads and health samples. Its units come back to the
  /// pool when their leases expire, as for a phone that crashed.
  final bool dropped;

  /// Added before the host answers the phone's assignment requests and file
  /// downloads, like a slow or congested link.
  final int extraDelayMs;

  /// Cap on the speed of file downloads to the phone, kB/s; null = no cap.
  final double? bandwidthKBps;

  const PhoneFault({this.dropped = false, this.extraDelayMs = 0, this.bandwidthKBps});

  bool get isNone => !dropped && extraDelayMs <= 0 && bandwidthKBps == null;

  String describe() {
    final parts = [
      if (dropped) 'dropped',
      if (extraDelayMs > 0) '+$extraDelayMs ms delay',
      if (bandwidthKBps != null) 'capped at ${bandwidthKBps!.toStringAsFixed(0)} kB/s',
    ];
    return parts.isEmpty ? 'none' : parts.join(', ');
  }

  Map<String, dynamic> toJson() => {
        'drop': dropped,
        'delay_ms': extraDelayMs,
        if (bandwidthKBps != null) 'bandwidth_kBps': bandwidthKBps,
      };

  factory PhoneFault.fromJson(Map<String, dynamic> j) {
    final cap = (j['bandwidth_kBps'] as num?)?.toDouble();
    return PhoneFault(
      dropped: j['drop'] == true,
      extraDelayMs: max(0, (j['delay_ms'] as num?)?.toInt() ?? 0),
      bandwidthKBps: cap != null && cap > 0 ? cap : null,
    );
  }
}

/// One change to a phone's fault, for the experiment report.
class FaultEvent {
  final int t; // host clock, epoch ms
  final String deviceKey;
  final PhoneFault fault;

  const FaultEvent(this.t, this.deviceKey, this.fault);

  Map<String, dynamic> toJson() => {'t': t, 'device': deviceKey, ...fault.toJson()};
}

/// The faults currently applied on the host, keyed by device key (the
/// phone's IP), with the history of changes for this experiment.
class FaultInjector extends ChangeNotifier {
  FaultInjector({int Function()? nowMs}) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);
  static final FaultInjector instance = FaultInjector();

  final int Function() _nowMs;
  final Map<String, PhoneFault> _faults = {};
  final List<FaultEvent> history = [];

  Map<String, PhoneFault> get active => Map.unmodifiable(_faults);

  PhoneFault faultFor(String? deviceKey) => (deviceKey == null ? null : _faults[deviceKey]) ?? const PhoneFault();

  bool isDropped(String? deviceKey) => faultFor(deviceKey).dropped;

  void set(String deviceKey, PhoneFault fault) {
    if (fault.isNone) {
      if (_faults.remove(deviceKey) == null) return;
    } else {
      _faults[deviceKey] = fault;
    }
    history.add(FaultEvent(_nowMs(), deviceKey, fault));
    notifyListeners();
  }

  void clear(String deviceKey) => set(deviceKey, const PhoneFault());

  /// Removes every fault and forgets the history (a new experiment).
  void reset() {
    _faults.clear();
    history.clear();
    notifyListeners();
  }

  /// Waits out the phone's extra delay, if it has one.
  Future<void> delayFor(String? deviceKey) async {
    final ms = faultFor(deviceKey).extraDelayMs;
    if (ms > 0) await Future.delayed(Duration(milliseconds: ms));
  }

  Map<String, dynamic> toJson() => {
        'active': {for (final e in _faults.entries) e.key: e.value.toJson()},
        'history': history.map((e) => e.toJson()).toList(),
      };
}

/// Paces [source] to about [kBps] kilobytes per second by sending it in
/// small slices and waiting after each one.
Stream<List<int>> throttleStream(
  Stream<List<int>> source,
  double kBps, {
  int sliceBytes = 16 * 1024,
}) async* {
  final bytesPerMs = kBps * 1024 / 1000;
  final sw = Stopwatch()..start();
  var sent = 0;
  await for (final chunk in source) {
    for (var i = 0; i < chunk.length; i += sliceBytes) {
      final slice = chunk.sublist(i, min(i + sliceBytes, chunk.length));
      yield slice;
      sent += slice.length;
      // Wait until the elapsed time matches what the cap allows for `sent`.
      final dueMs = sent / bytesPerMs;
      final waitMs = dueMs - sw.elapsedMilliseconds;
      if (waitMs > 0) await Future.delayed(Duration(milliseconds: waitMs.ceil()));
    }
  }
}
