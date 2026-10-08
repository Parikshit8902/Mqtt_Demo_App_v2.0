import 'dart:async';

/// Delay between polls while the host has no work: doubles from [min] up to
/// [max], and starts again from [min] once work arrives.
class IdleBackoff {
  final Duration min;
  final Duration max;
  Duration _next;

  IdleBackoff({
    this.min = const Duration(seconds: 2),
    this.max = const Duration(seconds: 16),
  }) : _next = min;

  /// The delay to wait now; the one after it is twice as long, up to [max].
  Duration next() {
    final d = _next;
    final doubled = _next * 2;
    _next = doubled > max ? max : doubled;
    return d;
  }

  void reset() => _next = min;
}

/// A sleep that can be cut short. A [wake] that arrives while nobody is
/// sleeping is remembered, so the next [sleep] returns at once and the signal
/// is not lost while a poll is in flight.
class WakeableDelay {
  Completer<void>? _waiter;
  bool _pending = false;

  Future<void> sleep(Duration d) async {
    if (_pending) {
      _pending = false;
      return;
    }
    final waiter = _waiter = Completer<void>();
    final timer = Timer(d, () {
      if (!waiter.isCompleted) waiter.complete();
    });
    await waiter.future;
    timer.cancel();
    _waiter = null;
    _pending = false;
  }

  void wake() {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    } else {
      _pending = true;
    }
  }
}
