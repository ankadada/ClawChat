import 'package:clawchat/constants.dart';
import 'package:clawchat/models/workspace.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/screens/chat_sessions_screen.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _PreviewStorage storage;
  late ChatProvider provider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    const native = MethodChannel(AppConstants.channelName);
    const secure =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(native, (call) async {
      switch (call.method) {
        case 'getArch':
          return 'arm64-v8a';
        case 'getBootstrapStatus':
          return <String, Object?>{'rootfsExists': true};
        case 'runInProot':
          return '';
      }
      return null;
    });
    messenger.setMockMethodCallHandler(secure, (call) async {
      switch (call.method) {
        case 'read':
          return null;
        case 'readAll':
          return <String, String>{};
        case 'containsKey':
          return false;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(native, null);
      messenger.setMockMethodCallHandler(secure, null);
    });
    storage = _PreviewStorage();
    provider = ChatProvider(storage: storage);
  });

  tearDown(() {
    provider.dispose();
    PreferencesService.resetForTesting();
  });

  SessionSummary summary(String id, String title, DateTime updatedAt) =>
      SessionSummary(
          id: id, title: title, createdAt: updatedAt, updatedAt: updatedAt);

  Future<void> pumpList(WidgetTester tester,
      {Size? size, double textScale = 1}) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          home: size == null
              ? ChatSessionsScreen(sessionStorage: storage)
              : MediaQuery(
                  data: MediaQueryData(
                    size: size,
                    textScaler: TextScaler.linear(textScale),
                  ),
                  child: ChatSessionsScreen(sessionStorage: storage),
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('each row names the workspace the session belongs to',
      (tester) async {
    final docs = await provider.createWorkspace(name: 'Docs');
    await provider.setActiveWorkspace(WorkspaceMetadata.defaultWorkspaceId);
    storage.previews['s-docs'] =
        SessionPreview(preview: 'docs preview', workspaceId: docs.id);
    storage.sessions['s-docs'] = ChatSession(
      id: 's-docs',
      title: 'Docs session',
      workspaceId: docs.id,
    );
    // A session written before workspaces existed has no id: it resolves to
    // the active workspace, which is the default one here.
    storage.previews['s-legacy'] =
        const SessionPreview(preview: 'legacy preview');
    storage.sessions['s-legacy'] = ChatSession(
      id: 's-legacy',
      title: 'Legacy session',
    );
    provider.sessions = [
      summary('s-docs', 'Docs session', DateTime.utc(2026, 1, 2)),
      summary('s-legacy', 'Legacy session', DateTime.utc(2026, 1, 1)),
    ];

    await pumpList(tester);

    expect(find.text('Docs'), findsOneWidget);
    expect(find.text('工作区'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a session that cannot be read keeps the row without a badge',
      (tester) async {
    // Missing session: the row must not claim the active workspace.
    provider.sessions = [
      summary('s-missing', 'Missing session', DateTime.utc(2026, 1, 2)),
    ];
    await pumpList(tester);

    expect(find.text('Missing session'), findsOneWidget);
    expect(find.text('工作区'), findsNothing);

    // Unreadable session (corrupt store): same, no invented workspace.
    storage.failSessionReads = true;
    provider.sessions = [
      summary('s-broken', 'Broken session', DateTime.utc(2026, 1, 2)),
    ];
    provider.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.text('Broken session'), findsOneWidget);
    expect(find.text('工作区'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching the active workspace refreshes the fallback badge',
      (tester) async {
    final docs = await provider.createWorkspace(name: 'Docs');
    await provider.setActiveWorkspace(WorkspaceMetadata.defaultWorkspaceId);
    // A session written before workspaces existed follows the active one.
    storage.sessions['s-legacy'] =
        ChatSession(id: 's-legacy', title: 'Legacy session');
    provider.sessions = [
      summary('s-legacy', 'Legacy session', DateTime.utc(2026, 1, 2)),
    ];

    await pumpList(tester);
    expect(find.text('工作区'), findsOneWidget);

    await provider.setActiveWorkspace(docs.id);
    await tester.pumpAndSettle();

    expect(find.text('Docs'), findsOneWidget);
    expect(find.text('工作区'), findsNothing);
  });

  testWidgets('deleting the session workspace falls back in the badge',
      (tester) async {
    final docs = await provider.createWorkspace(name: 'Docs');
    storage.sessions['s-docs'] = ChatSession(
      id: 's-docs',
      title: 'Docs session',
      workspaceId: docs.id,
    );
    provider.sessions = [
      summary('s-docs', 'Docs session', DateTime.utc(2026, 1, 2)),
    ];

    await pumpList(tester);
    expect(find.text('Docs'), findsOneWidget);

    // Deleting the workspace keeps the session record and falls back to the
    // active (default) workspace, and the badge follows.
    await provider.deleteWorkspace(docs.id);
    await tester.pumpAndSettle();

    expect(find.text('工作区'), findsOneWidget);
    expect(find.text('Docs'), findsNothing);
  });

  testWidgets('a failing preview read keeps the row and offers a retry',
      (tester) async {
    storage.failPreviewReads = true;
    provider.sessions = [
      summary('s-broken', 'Broken preview', DateTime.utc(2026, 1, 2)),
    ];

    await pumpList(tester);
    expect(find.text('Broken preview'), findsOneWidget);
    expect(find.text(AppStrings.previewUnavailable), findsOneWidget);

    storage.failPreviewReads = false;
    await tester.tap(find.text(AppStrings.previewUnavailable));
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.previewUnavailable), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a long workspace name stays inside the row at 320dp and 200 percent',
      (tester) async {
    final long = await provider.createWorkspace(
      name: 'Ein sehr langer Arbeitsbereichsname',
    );
    storage.previews['s-long'] =
        SessionPreview(preview: 'preview', workspaceId: long.id);
    storage.sessions['s-long'] = ChatSession(
      id: 's-long',
      title: 'Long session',
      workspaceId: long.id,
    );
    provider.sessions = [
      summary('s-long', 'Long workspace session', DateTime.utc(2026, 1, 2)),
    ];

    await pumpList(tester, size: const Size(320, 720), textScale: 2);

    expect(find.byType(ChatSessionsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final class _PreviewStorage extends SessionStorage {
  final Map<String, SessionPreview> previews = {};
  final Map<String, ChatSession> sessions = {};
  bool failSessionReads = false;
  bool failPreviewReads = false;

  @override
  Future<void> init() async {}

  @override
  Future<List<SessionSummary>> getSessionsSummary() async => const [];

  @override
  Future<SessionPreview?> getSessionPreview(String id) async {
    if (failPreviewReads) throw StateError('corrupt preview');
    return previews[id];
  }

  @override
  Future<ChatSession?> getSession(String id) async {
    if (failSessionReads) throw StateError('corrupt session');
    return sessions[id];
  }
}
