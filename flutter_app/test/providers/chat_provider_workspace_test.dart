import 'dart:io';

import 'package:clawchat/models/workspace.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Map<String, String> secureStorage;
  late Directory tempDir;

  setUp(() async {
    secureStorage = {};
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    tempDir = await Directory.systemTemp.createTemp('clawchat_ws_test_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return tempDir.path;
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
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStorageChannel, null);
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    PreferencesService.resetForTesting();
  });

  test('a session can be bound to a workspace that is not the active one',
      () async {
    final provider = ChatProvider();
    await provider.initialized;
    await provider.createWorkspace(
      name: 'Docs',
      rootPath: '/root/workspace/docs',
    );
    final docs = provider.activeWorkspace;
    expect(docs.rootPath, '/root/workspace/docs');

    // Switch back to the default workspace, then create a session for Docs.
    await provider.setActiveWorkspace(WorkspaceMetadata.defaultWorkspaceId);
    expect(provider.activeWorkspace.isDefault, isTrue);

    final session = await provider.createSession(workspaceId: docs.id);

    expect(session.workspaceId, docs.id);
    expect(provider.workspaceForSession(session.workspaceId).rootPath,
        '/root/workspace/docs');
    // The active workspace did not change behind the caller's back.
    expect(provider.activeWorkspace.isDefault, isTrue);
    provider.dispose();
  });

  test('a session without an explicit workspace follows the active one',
      () async {
    final provider = ChatProvider();
    await provider.initialized;

    final session = await provider.createSession();

    expect(session.workspaceId, WorkspaceMetadata.defaultWorkspaceId);
    expect(provider.workspaceForSession(session.workspaceId).isDefault, isTrue);
    provider.dispose();
  });
}
