import 'package:shared_preferences/shared_preferences.dart';

class StartupRestoreGuardState {
  final int failureCount;
  final int? firstFailureAtMillis;
  final int? lastFailureAtMillis;
  final bool safeMode;

  const StartupRestoreGuardState({
    required this.failureCount,
    this.firstFailureAtMillis,
    this.lastFailureAtMillis,
    required this.safeMode,
  });

  bool get hasFailures => failureCount > 0;
}

class StartupRestoreGuard {
  static const failureThreshold = 2;
  static const failureWindow = Duration(minutes: 10);
  static const _failureCountKey = 'startup_restore_failure_count';
  static const _firstFailureAtKey = 'startup_restore_first_failure_at';
  static const _lastFailureAtKey = 'startup_restore_last_failure_at';

  final Future<SharedPreferences> Function() _prefsFactory;
  final DateTime Function() _now;
  StartupRestoreGuardState? _volatileState;

  StartupRestoreGuard({
    Future<SharedPreferences> Function()? prefsFactory,
    DateTime Function()? now,
  })  : _prefsFactory = prefsFactory ?? SharedPreferences.getInstance,
        _now = now ?? DateTime.now;

  Future<StartupRestoreGuardState> state() async {
    final prefs = await _prefsOrNull();
    if (prefs == null) {
      return _currentVolatileState();
    }
    final current = _preferVolatileState(_readState(prefs));
    if (_isExpired(current)) {
      await clear();
      return const StartupRestoreGuardState(
        failureCount: 0,
        safeMode: false,
      );
    }
    return current;
  }

  Future<StartupRestoreGuardState> recordStartupFailure() async {
    final prefs = await _prefsOrNull();
    final current = prefs == null
        ? _currentVolatileState()
        : _preferVolatileState(_readState(prefs));
    final nowMillis = _now().millisecondsSinceEpoch;
    final expired = _isExpired(current);
    final nextCount = expired ? 1 : current.failureCount + 1;
    final firstFailureAt =
        expired ? nowMillis : (current.firstFailureAtMillis ?? nowMillis);

    final nextState = StartupRestoreGuardState(
      failureCount: nextCount,
      firstFailureAtMillis: firstFailureAt,
      lastFailureAtMillis: nowMillis,
      safeMode: nextCount >= failureThreshold,
    );
    _volatileState = nextState;

    if (prefs != null) {
      try {
        await prefs.setInt(_failureCountKey, nextCount);
        await prefs.setInt(_firstFailureAtKey, firstFailureAt);
        await prefs.setInt(_lastFailureAtKey, nowMillis);
      } catch (_) {
        // Keep the volatile state so the current process can still safe-open.
      }
    }

    return nextState;
  }

  Future<void> recordStartupSuccess() async {
    final current = await state();
    if (!current.safeMode) {
      await clear();
    }
  }

  Future<void> clear() async {
    _volatileState = null;
    final prefs = await _prefsOrNull();
    if (prefs == null) return;
    try {
      await prefs.remove(_failureCountKey);
      await prefs.remove(_firstFailureAtKey);
      await prefs.remove(_lastFailureAtKey);
    } catch (_) {
      // Best-effort clear; volatile state is already cleared for this process.
    }
  }

  StartupRestoreGuardState _readState(SharedPreferences prefs) {
    final count = prefs.getInt(_failureCountKey) ?? 0;
    final firstFailureAt = prefs.getInt(_firstFailureAtKey);
    final lastFailureAt = prefs.getInt(_lastFailureAtKey);
    return StartupRestoreGuardState(
      failureCount: count,
      firstFailureAtMillis: firstFailureAt,
      lastFailureAtMillis: lastFailureAt,
      safeMode: count >= failureThreshold,
    );
  }

  bool _isExpired(StartupRestoreGuardState state) {
    final lastFailureAt = state.lastFailureAtMillis;
    if (state.failureCount <= 0 || lastFailureAt == null) return false;
    final lastFailure = DateTime.fromMillisecondsSinceEpoch(lastFailureAt);
    return _now().difference(lastFailure) > failureWindow;
  }

  Future<SharedPreferences?> _prefsOrNull() async {
    try {
      return await _prefsFactory();
    } catch (_) {
      return null;
    }
  }

  StartupRestoreGuardState _currentVolatileState() {
    final current = _volatileState;
    if (current == null) {
      return const StartupRestoreGuardState(
        failureCount: 0,
        safeMode: false,
      );
    }
    if (_isExpired(current)) {
      _volatileState = null;
      return const StartupRestoreGuardState(
        failureCount: 0,
        safeMode: false,
      );
    }
    return current;
  }

  StartupRestoreGuardState _preferVolatileState(
    StartupRestoreGuardState persisted,
  ) {
    final current = _volatileState;
    if (current == null) return persisted;
    if (_isExpired(current)) {
      _volatileState = null;
      return persisted;
    }
    if (current.failureCount > persisted.failureCount) {
      return current;
    }
    return persisted;
  }
}
