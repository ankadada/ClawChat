import 'dart:convert';

import 'package:clawchat/models/workspace.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> secureStorage;

  setUp(() {
    secureStorage = {};
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    PreferencesService.resetForTesting();
  });

  test('a fresh install gets the default workspace without touching sessions',
      () async {
    final prefs = PreferencesService();
    await prefs.init();

    expect(prefs.workspaces, hasLength(1));
    expect(prefs.activeWorkspace.isDefault, isTrue);
    expect(prefs.activeWorkspace.rootPath, kDefaultWorkspaceRoot);

    // The choice is persisted, so the next launch resolves the same workspace.
    PreferencesService.resetForTesting();
    final reloaded = PreferencesService();
    await reloaded.init();
    expect(reloaded.activeWorkspaceId, WorkspaceMetadata.defaultWorkspaceId);
  });

  test('sessions that predate workspaces resolve to the active one', () async {
    SharedPreferences.setMockInitialValues({
      'sessions': jsonEncode([]),
    });
    final prefs = PreferencesService();
    await prefs.init();

    // No stored workspace id at all.
    expect(prefs.workspaceForSession(null).isDefault, isTrue);
    // A dangling id (workspace later deleted) also falls back.
    expect(prefs.workspaceForSession('gone').isDefault, isTrue);
  });

  test('saves, activates and renames workspaces', () async {
    final prefs = PreferencesService();
    await prefs.init();

    await prefs.saveWorkspace(id: 'ws-a', name: ' 项目 ');
    await prefs.saveWorkspace(
      id: 'ws-b',
      name: 'Docs',
      rootPath: '/root/workspace/docs',
    );
    expect(prefs.workspaces, hasLength(3));

    await prefs.setActiveWorkspace('ws-b');
    expect(prefs.activeWorkspaceId, 'ws-b');
    expect(prefs.workspaceById('ws-b')!.rootPath, '/root/workspace/docs');

    await prefs.saveWorkspace(id: 'ws-b', name: 'Docs v2');
    final renamed = prefs.workspaceById('ws-b')!;
    expect(renamed.name, 'Docs v2');
    expect(prefs.workspaces, hasLength(3));

    // An invalid root is coerced back into the agent tree.
    await prefs.saveWorkspace(id: 'ws-c', name: 'Bad', rootPath: '/etc');
    expect(prefs.workspaceById('ws-c')!.rootPath, kDefaultWorkspaceRoot);
  });

  test('deleting the active workspace falls back to the default', () async {
    final prefs = PreferencesService();
    await prefs.init();
    await prefs.saveWorkspace(id: 'ws-temp', name: 'Temp');
    await prefs.setActiveWorkspace('ws-temp');

    expect(await prefs.deleteWorkspace('ws-temp'), isTrue);
    expect(prefs.workspaceById('ws-temp'), isNull);
    expect(prefs.activeWorkspace.isDefault, isTrue);

    // The default workspace is not removable, and unknown ids are a no-op.
    expect(
      await prefs.deleteWorkspace(WorkspaceMetadata.defaultWorkspaceId),
      isFalse,
    );
    expect(await prefs.deleteWorkspace('missing'), isFalse);
  });

  test('corrupt or partially invalid stored lists recover safely', () async {
    SharedPreferences.setMockInitialValues({
      'workspaces': 'not json',
      'active_workspace_id': 'whatever',
    });
    final prefs = PreferencesService();
    await prefs.init();

    expect(prefs.workspaces, hasLength(1));
    expect(prefs.activeWorkspace.isDefault, isTrue);

    SharedPreferences.setMockInitialValues({
      'workspaces': jsonEncode([
        {'id': 'good', 'name': 'Good'},
        {'id': 'bad id', 'name': 'Bad'},
        'nonsense',
        {'id': 'good', 'name': 'Duplicate'},
      ]),
      'active_workspace_id': 'gone',
    });
    PreferencesService.resetForTesting();
    final second = PreferencesService();
    await second.init();

    expect(second.workspaces.map((item) => item.id), contains('good'));
    expect(second.workspaces.where((item) => item.id == 'good'), hasLength(1));
    expect(second.workspaces.any((item) => item.id == 'bad id'), isFalse);
    // Dangling active id resolves to the default instead of throwing.
    expect(second.activeWorkspace.isDefault, isTrue);
  });
}
