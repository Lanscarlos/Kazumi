/// Keeps one platform foreground service alive while any owner needs it.
///
/// Downloads and LAN sharing both rely on the same Android foreground
/// service, so neither may stop it while the other is still working.
class ForegroundServiceLease {
  ForegroundServiceLease({
    required Future<bool> Function() start,
    required Future<void> Function() stop,
  }) : _start = start,
       _stop = stop;

  final Future<bool> Function() _start;
  final Future<void> Function() _stop;
  final Set<String> _owners = {};
  Future<bool>? _starting;
  bool _running = false;

  bool get isRunning => _running;

  bool holds(String owner) => _owners.contains(owner);

  /// Registers [owner] and starts the service if needed. Returns whether the
  /// service is running for this owner.
  Future<bool> acquire(String owner) async {
    _owners.add(owner);
    if (_running) return true;
    final started = await (_starting ??= _startPlatform());
    if (!started) _owners.remove(owner);
    return started && _running;
  }

  /// Unregisters [owner]; the service stops when no owner remains.
  Future<void> release(String owner) async {
    if (!_owners.remove(owner)) return;
    if (_owners.isNotEmpty || !_running) return;
    _running = false;
    await _stop();
  }

  Future<bool> _startPlatform() async {
    try {
      final started = await _start();
      if (started && _owners.isEmpty) {
        // Every owner released while the platform was still starting.
        await _stop();
        return false;
      }
      _running = started;
      return started;
    } finally {
      _starting = null;
    }
  }
}
