import 'package:clawchat/services/startup_restore_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('StartupRestoreGuard', () {
    late DateTime now;
    late StartupRestoreGuard guard;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      now = DateTime(2026, 1, 1, 10);
      guard = StartupRestoreGuard(now: () => now);
    });

    test('enters safe mode after repeated recent failures', () async {
      var state = await guard.recordStartupFailure();
      expect(state.safeMode, isFalse);
      expect(state.failureCount, 1);

      state = await guard.recordStartupFailure();
      expect(state.safeMode, isTrue);
      expect(state.failureCount, 2);
    });

    test('clears non-safe failures after success', () async {
      await guard.recordStartupFailure();
      await guard.recordStartupSuccess();

      final state = await guard.state();
      expect(state.failureCount, 0);
      expect(state.safeMode, isFalse);
    });

    test('keeps safe mode until explicitly cleared', () async {
      await guard.recordStartupFailure();
      await guard.recordStartupFailure();
      await guard.recordStartupSuccess();

      expect((await guard.state()).safeMode, isTrue);

      await guard.clear();
      expect((await guard.state()).safeMode, isFalse);
    });

    test('expires old failure windows', () async {
      await guard.recordStartupFailure();
      now = now
          .add(StartupRestoreGuard.failureWindow)
          .add(const Duration(seconds: 1));

      final state = await guard.state();
      expect(state.failureCount, 0);
      expect(state.safeMode, isFalse);
    });

    test('uses volatile failure state when prefs are unavailable', () async {
      final volatileGuard = StartupRestoreGuard(
        now: () => now,
        prefsFactory: () async => throw StateError('prefs unavailable'),
      );

      var state = await volatileGuard.recordStartupFailure();
      expect(state.failureCount, 1);
      expect(state.safeMode, isFalse);

      state = await volatileGuard.recordStartupFailure();
      expect(state.failureCount, 2);
      expect(state.safeMode, isTrue);
      expect((await volatileGuard.state()).safeMode, isTrue);

      await volatileGuard.clear();
      expect((await volatileGuard.state()).safeMode, isFalse);
    });
  });
}
