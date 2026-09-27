import 'dart:convert';

import 'package:clawchat/constants.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/screens/chat_screen.dart';
import 'package:clawchat/services/native_bridge.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The share save flow on a device: a write the broker refuses must never
/// leave a "saved" claim or an undo handle behind.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const nativeChannel = MethodChannel(AppConstants.channelName);
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const shareCallbackChannel =
      MethodChannel('${AppConstants.channelName}/share_callbacks');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _MemorySessionStorage storage;
  late ChatProvider provider;
  late Map<String, String> secureStorage;
  late bool writeResult;
  late List<String> writtenPaths;
  late List<String> createdDirectories;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    NativeBridge.resetShareIntentHandlerForTesting();
    storage = _MemorySessionStorage();
    secureStorage = {};
    writeResult = true;
    writtenPaths = [];
    createdDirectories = [];
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'consumePendingNavigateToSession':
          return null;
        case 'consumePendingShareIntent':
          return null;
        case 'runInProot':
          return '';
        case 'stopRecording':
          return '';
        case 'createRootfsDirectory':
          createdDirectories.add(args['path'] as String? ?? '');
          return true;
        case 'writeRootfsFile':
          writtenPaths.add(args['path'] as String? ?? '');
          return writeResult;
      }
      return true;
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
    provider = ChatProvider(storage: storage);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  tearDown(() async {
    provider.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    NativeBridge.resetShareIntentHandlerForTesting();
    messenger.setMockMethodCallHandler(nativeChannel, null);
    messenger.setMockMethodCallHandler(secureStorageChannel, null);
    PreferencesService.resetForTesting();
  });

  Future<void> pumpChat(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: const ChatScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Delivers a text share exactly like the native share callback does. The
  /// handler's future is not awaited: showing the sheet needs frames.
  Future<void> deliverShare(WidgetTester tester) async {
    messenger.handlePlatformMessage(
      shareCallbackChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onShareIntent', <String, Object?>{
          'text': 'device_test_share_note',
        }),
      ),
      (_) {},
    );
    await tester.pump();
    await tester.pumpAndSettle();
  }

  Future<void> chooseSaveAction(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const ValueKey('share-action-saveToWorkspace')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a refused save never claims success and offers no undo',
      (tester) async {
    writeResult = false;
    await pumpChat(tester);
    await deliverShare(tester);
    await chooseSaveAction(tester);

    // The write was attempted and refused.
    expect(writtenPaths, isNotEmpty);

    // No success claim in the composer and no undo for a file that does not
    // exist; the original share text stays where the user put it.
    expect(find.textContaining('已保存到工作区'), findsNothing);
    expect(find.text('撤销'), findsNothing);
    expect(find.textContaining('保存失败'), findsWidgets);
    expect(find.textContaining('device_test_share_note'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a successful save writes the shared file and offers undo',
      (tester) async {
    writeResult = true;
    await pumpChat(tester);
    await deliverShare(tester);
    await chooseSaveAction(tester);

    // The documented destination directory is created through the broker
    // before the file is written.
    expect(createdDirectories, contains('/root/workspace/shared'));
    expect(writtenPaths, hasLength(1));
    expect(writtenPaths.single, startsWith('/root/workspace/shared/'));

    // Only a real write puts the saved-path claim in the composer and offers
    // the undo action.
    expect(
      find.textContaining('已保存到工作区：/root/workspace/shared/'),
      findsWidgets,
    );
    expect(find.text('撤销'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _MemorySessionStorage extends SessionStorage {
  final Map<String, ChatSession> _sessions = {};

  @override
  Future<void> init() async {}

  @override
  Future<List<SessionSummary>> getSessionsSummary() async {
    return _sessions.values
        .map(
          (session) => SessionSummary(
            id: session.id,
            title: session.title,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            folder: session.folder,
          ),
        )
        .toList();
  }

  @override
  Future<ChatSession?> getSession(String id) async => _sessions[id];

  @override
  Future<void> saveSession(
    ChatSession session, {
    int? expectedGeneration,
    SessionCommitGuard? commitGuard,
  }) async {
    _sessions[session.id] = ChatSession.fromJson(
      jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> deleteSession(String id) async {
    _sessions.remove(id);
  }

  @override
  Future<ChatSession?> forkSession(
      String sessionId, int upToMessageIndex) async {
    final source = _sessions[sessionId];
    if (source == null ||
        upToMessageIndex < 0 ||
        upToMessageIndex >= source.messages.length) {
      return null;
    }
    final fork = ChatSession(
      id: 'fork_${_sessions.length}',
      title: AppStrings.forkedFromTitle(source.title),
      messages: source.messages.take(upToMessageIndex + 1).toList(),
    );
    await saveSession(fork);
    return fork;
  }

  @override
  Future<void> clearAll() async {
    _sessions.clear();
  }
}
