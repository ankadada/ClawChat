import 'dart:convert';

import 'package:clawchat/constants.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/screens/chat_screen.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const nativeChannel = MethodChannel(AppConstants.channelName);
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late _MemorySessionStorage storage;
  late ChatProvider provider;
  late Map<String, String> secureStorage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    storage = _MemorySessionStorage();
    secureStorage = {};

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      switch (call.method) {
        case 'consumePendingNavigateToSession':
          return null;
        case 'runInProot':
          return '';
        case 'stopRecording':
          return '';
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
    await testerPumpInitGap();
  });

  tearDown(() async {
    provider.dispose();
    await testerPumpInitGap();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeChannel, null);
    messenger.setMockMethodCallHandler(secureStorageChannel, null);
    PreferencesService.resetForTesting();
  });

  testWidgets('renders latest window and loads older messages on demand',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 40000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const totalMessages = 260;
    final session = _syntheticSession(totalMessages);
    await storage.saveSession(session);
    await provider.selectSession(session.id);

    await _pumpChatScreen(tester, provider);

    expect(find.text(_messageText(0)), findsNothing);
    expect(find.text(_messageText(79)), findsNothing);
    expect(find.text(_messageText(80)), findsOneWidget);
    expect(find.text(_messageText(259)), findsOneWidget);
    expect(find.text(AppStrings.loadOlderMessages(80)), findsOneWidget);
    expect(find.text(AppStrings.hiddenOlderMessages(80)), findsOneWidget);

    await tester.tap(find.text(AppStrings.loadOlderMessages(80)));
    await tester.pump();
    await tester.pump();

    expect(find.text(_messageText(0)), findsOneWidget);
    expect(find.text(_messageText(79)), findsOneWidget);
    expect(find.text(_messageText(80)), findsOneWidget);
    expect(find.text(_messageText(259)), findsOneWidget);
    expect(find.text(AppStrings.loadOlderMessages(80)), findsNothing);
  });
}

Future<void> testerPumpInitGap() {
  return Future<void>.delayed(const Duration(milliseconds: 20));
}

Future<void> _pumpChatScreen(WidgetTester tester, ChatProvider provider) async {
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

ChatSession _syntheticSession(int totalMessages) {
  return ChatSession(
    id: 'render_window_session',
    title: 'Render Window Session',
    messages: [
      for (var index = 0; index < totalMessages; index++)
        ChatMessage(
          role: index.isEven ? 'user' : 'assistant',
          content: [TextContent(_messageText(index))],
          timestamp: DateTime.utc(2026, 1, 1).add(Duration(seconds: index)),
        ),
    ],
  );
}

String _messageText(int index) => 'synthetic render window message $index';

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
  Future<void> saveSession(ChatSession session) async {
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
