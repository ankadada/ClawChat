import 'dart:async';
import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:clawchat/services/startup_restore_guard.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Deterministic dispose races.
///
/// A session read (selection, navigation callback, or startup) is blocked, the
/// provider is disposed, and only then is the storage released. The production
/// fix must stop the in-flight path before it records a startup failure, writes
/// session state, or calls `notifyListeners` on a disposed `ChangeNotifier`,
/// and no path may leak an unhandled future.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const nativeChannel = MethodChannel(AppConstants.channelName);
  const agentCallbackChannel =
      MethodChannel('${AppConstants.channelName}/agent_callbacks');

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    tempDir = await Directory.systemTemp.createTemp('chat_provider_dispose_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (_) async => tempDir.path);
    messenger.setMockMethodCallHandler(secureChannel, (call) async {
      if (call.method == 'readAll') return <String, String>{};
      if (call.method == 'containsKey') return false;
      return null;
    });
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'consumePendingNavigateToSession') return null;
      return true;
    });
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(secureChannel, null);
    messenger.setMockMethodCallHandler(nativeChannel, null);
    PreferencesService.resetForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('a session read released after dispose records no failure and no notify',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final storage = _BlockedSessionReadStorage(
      entered: entered,
      release: release,
      result: () => throw StateError('session read failed after dispose'),
    );
    await storage.init();
    final provider = ChatProvider(storage: storage);
    await provider.initialized;

    final guard = StartupRestoreGuard();
    final before = await guard.state();
    var notifications = 0;
    provider.addListener(() => notifications++);

    final pending = provider.selectSession('race-session');
    await entered.future;

    provider.dispose();
    release.complete();

    // The released read throws, the catch runs after disposal, and the future
    // must still complete normally instead of surfacing the disposed-notifier
    // assertion or an unhandled future.
    await pending;

    final after = await guard.state();
    expect(after.failureCount, before.failureCount);
    expect(after.safeMode, isFalse);
    expect(provider.safeMode, isFalse);
    expect(provider.startupFailureCount, 0);
    expect(provider.currentSession, isNull);
    expect(notifications, 0);
  });

  test('a session read that succeeds after dispose writes no session state',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final storage = _BlockedSessionReadStorage(
      entered: entered,
      release: release,
      result: () => ChatSession(id: 'race-session'),
    );
    await storage.init();
    final provider = ChatProvider(storage: storage);
    await provider.initialized;

    var notifications = 0;
    provider.addListener(() => notifications++);

    final pending = provider.selectSession('race-session');
    await entered.future;

    provider.dispose();
    release.complete();
    await pending;

    expect(provider.currentSession, isNull);
    expect(notifications, 0);
  });

  test('a navigation callback released after dispose leaks no unhandled future',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final storage = _BlockedSessionReadStorage(
      entered: entered,
      release: release,
      result: () => throw StateError('navigation read failed after dispose'),
    );
    await storage.init();
    final provider = ChatProvider(storage: storage);
    await provider.initialized;

    final guard = StartupRestoreGuard();
    final before = await guard.state();

    // Dispatch the platform navigation callback while the provider is live.
    const codec = StandardMethodCodec();
    final response = Completer<ByteData?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      agentCallbackChannel.name,
      codec.encodeMethodCall(
        const MethodCall('navigateToSession', {'sessionId': 'race-session'}),
      ),
      response.complete,
    );
    await response.future;
    await entered.future;

    provider.dispose();
    release.complete();

    // Let the fire-and-forget selection settle; an unhandled error would be
    // reported by the test zone and fail this test.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final after = await guard.state();
    expect(after.failureCount, before.failureCount);
    expect(after.safeMode, isFalse);
    expect(provider.currentSession, isNull);
  });

  test('an init failure released after dispose records no startup failure',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final storage = _BlockedInitStorage(entered: entered, release: release);
    final provider = ChatProvider(storage: storage);

    await entered.future;
    final guard = StartupRestoreGuard();
    final before = await guard.state();

    provider.dispose();
    release.complete();
    await provider.initialized;

    final after = await guard.state();
    expect(after.failureCount, before.failureCount);
    expect(after.safeMode, isFalse);
    expect(provider.safeMode, isFalse);
    expect(provider.startupFailureCount, 0);
  });
}

/// Blocks the first [getSession] call, then runs [result] once released.
final class _BlockedSessionReadStorage extends SessionStorage {
  _BlockedSessionReadStorage({
    required this.entered,
    required this.release,
    required this.result,
  });

  final Completer<void> entered;
  final Completer<void> release;
  final ChatSession Function() result;
  var readCount = 0;

  @override
  Future<ChatSession?> getSession(String id) async {
    readCount++;
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return result();
  }
}

/// Blocks [init], then fails once released.
final class _BlockedInitStorage extends SessionStorage {
  _BlockedInitStorage({required this.entered, required this.release});

  final Completer<void> entered;
  final Completer<void> release;

  @override
  Future<void> init() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    throw StateError('storage init failed after dispose');
  }
}
