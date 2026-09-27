import 'dart:async';

import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// I6 — the Dynamic Island is developer tooling behind an explicit toggle.
/// A normal install and the first agent run must never ask for
/// SYSTEM_ALERT_WINDOW.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const nativeChannel = MethodChannel('com.anka.clawbot/native');
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  late Map<String, String> secureStorage;
  late List<String> nativeCalls;
  var overlayPermissionGranted = false;

  setUp(() {
    secureStorage = {};
    nativeCalls = [];
    overlayPermissionGranted = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
        case 'getApplicationSupportDirectory':
        case 'getTemporaryDirectory':
          return '/tmp/clawchat-island-test';
        case 'getExternalStorageDirectory':
          return null;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(secureStorageChannel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      final key = args['key']?.toString();
      switch (call.method) {
        case 'read':
          return key == null ? null : secureStorage[key];
        case 'write':
          if (key != null) secureStorage[key] = args['value']?.toString() ?? '';
          return null;
        case 'delete':
          if (key != null) secureStorage.remove(key);
          return null;
        case 'deleteAll':
          secureStorage.clear();
          return null;
        case 'containsKey':
          return key != null && secureStorage.containsKey(key);
        case 'readAll':
          return Map<String, String>.from(secureStorage);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      nativeCalls.add(call.method);
      switch (call.method) {
        case 'hasAgentOverlayPermission':
        case 'requestAgentOverlayPermissionIfNeeded':
          return overlayPermissionGranted;
        case 'consumePendingNavigateToSession':
          return null;
      }
      return true;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    messenger.setMockMethodCallHandler(secureStorageChannel, null);
    messenger.setMockMethodCallHandler(nativeChannel, null);
    PreferencesService.resetForTesting();
  });

  test('the island preference defaults off', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    final prefs = PreferencesService();
    await prefs.init();

    expect(prefs.agentIslandEnabled, isFalse);
  });

  test('enabling the island without Developer Mode is refused and never asks '
      'for overlay permission', () async {
    SharedPreferences.setMockInitialValues({'developer_mode': false});
    final provider = ChatProvider();
    addTearDown(provider.dispose);
    // Deterministic startup barrier instead of a sleep: the provider's async
    // init settles before the test drives it and stops on disposal.
    await provider.initialized;
    await provider.createSession(modelGroupId: 'probe');

    final granted = await provider.setAgentIslandEnabled(true);

    expect(granted, isFalse);
    expect(provider.agentIslandEnabled, isFalse);
    expect(
      nativeCalls,
      isNot(contains('requestAgentOverlayPermissionIfNeeded')),
    );
  });

  test('developer mode plus the toggle is the only path that asks for overlay '
      'permission, and a denial leaves the island off', () async {
    SharedPreferences.setMockInitialValues({'developer_mode': false});
    final provider = ChatProvider();
    addTearDown(provider.dispose);
    // Deterministic startup barrier instead of a sleep: the provider's async
    // init settles before the test drives it and stops on disposal.
    await provider.initialized;
    await provider.createSession(modelGroupId: 'probe');

    provider.setDeveloperMode(true);
    expect(provider.developerMode, isTrue);
    expect(
      nativeCalls,
      isNot(contains('requestAgentOverlayPermissionIfNeeded')),
    );

    overlayPermissionGranted = false;
    expect(await provider.setAgentIslandEnabled(true), isFalse);
    expect(
      nativeCalls,
      contains('requestAgentOverlayPermissionIfNeeded'),
    );
    expect(provider.agentIslandEnabled, isFalse);

    overlayPermissionGranted = true;
    expect(await provider.setAgentIslandEnabled(true), isTrue);
    expect(provider.agentIslandEnabled, isTrue);
  });

  test('turning Developer Mode off turns the island off', () async {
    SharedPreferences.setMockInitialValues({'developer_mode': true});
    PreferencesService.resetForTesting();
    final prefs = PreferencesService();
    await prefs.init();
    prefs.agentIslandEnabled = true;

    final provider = ChatProvider();
    addTearDown(provider.dispose);
    // Deterministic startup barrier instead of a sleep: the provider's async
    // init settles before the test drives it and stops on disposal.
    await provider.initialized;
    await provider.createSession(modelGroupId: 'probe');
    expect(provider.agentIslandEnabled, isTrue);

    provider.setDeveloperMode(false);

    expect(provider.agentIslandEnabled, isFalse);
  });

  test('preference round-trips through SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    final prefs = PreferencesService();
    await prefs.init();

    prefs.agentIslandEnabled = true;
    expect(prefs.agentIslandEnabled, isTrue);
    expect(
      (await SharedPreferences.getInstance()).getBool('agent_island_enabled'),
      isTrue,
    );
  });

  /// Blocks the overlay permission request, disposes the provider, then
  /// releases the platform answer. The released path must not write the
  /// preference, notify the disposed notifier, or leak an unhandled future.
  Future<void> runPermissionReleasedAfterDispose(bool granted) async {
    SharedPreferences.setMockInitialValues({'developer_mode': true});
    PreferencesService.resetForTesting();
    final prefs = PreferencesService();
    await prefs.init();
    prefs.agentIslandEnabled = false;

    final entered = Completer<void>();
    final release = Completer<bool>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      nativeCalls.add(call.method);
      if (call.method == 'consumePendingNavigateToSession') return null;
      if (call.method == 'requestAgentOverlayPermissionIfNeeded') {
        entered.complete();
        return release.future;
      }
      return true;
    });

    final provider = ChatProvider();
    var disposed = false;
    Future<void> disposeOnce() async {
      if (disposed) return;
      disposed = true;
      provider.dispose();
    }

    addTearDown(disposeOnce);
    await provider.initialized;

    final pending = provider.setAgentIslandEnabled(true);
    await entered.future;
    final valueAtDispose = prefs.agentIslandEnabled;

    await disposeOnce();
    release.complete(granted);

    expect(await pending, isFalse);
    // The post-dispose path must not have written the preference again; the
    // value stays whatever it was when the provider was disposed.
    expect(prefs.agentIslandEnabled, valueAtDispose);
  }

  test('a denied permission released after dispose writes nothing', () async {
    await runPermissionReleasedAfterDispose(false);
  });

  test('a granted permission released after dispose does not enable', () async {
    await runPermissionReleasedAfterDispose(true);
  });

  test('disabling that completes after dispose returns false', () async {
    SharedPreferences.setMockInitialValues({'developer_mode': true});
    PreferencesService.resetForTesting();
    final prefs = PreferencesService();
    await prefs.init();
    prefs.agentIslandEnabled = true;

    final entered = Completer<void>();
    final release = Completer<bool>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      nativeCalls.add(call.method);
      if (call.method == 'consumePendingNavigateToSession') return null;
      if (call.method == 'setAgentOverlayVisible') {
        entered.complete();
        return release.future;
      }
      return true;
    });

    final provider = ChatProvider();
    var disposed = false;
    Future<void> disposeOnce() async {
      if (disposed) return;
      disposed = true;
      provider.dispose();
    }

    addTearDown(disposeOnce);
    await provider.initialized;

    final pending = provider.setAgentIslandEnabled(false);
    await entered.future;
    await disposeOnce();
    release.complete(true);

    expect(await pending, isFalse);
    expect(prefs.agentIslandEnabled, isFalse);
  });
}
