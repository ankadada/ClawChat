import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/tools/env_var_tool.dart';
import 'package:clawchat/services/tools/tool_policy.dart';
import 'package:clawchat/services/tools/tool_registry.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> secureStorage;
  late PreferencesService prefs;
  late EnvVarTool tool;

  setUp(() async {
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
          if (key != null) {
            secureStorage[key] = args['value']?.toString() ?? '';
          }
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

    prefs = PreferencesService();
    await prefs.init();
    tool = EnvVarTool(prefs);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    PreferencesService.resetForTesting();
  });

  test('sets an environment variable without echoing the value', () async {
    final result = await tool.execute({
      'name': 'GITHUB_TOKEN',
      'value': 'ghp_secret_token_value',
    });

    expect(result, '已设置环境变量 GITHUB_TOKEN');
    expect(result, isNot(contains('ghp_secret_token_value')));
    expect(prefs.envVars['GITHUB_TOKEN'], 'ghp_secret_token_value');
  });

  test('deletes an environment variable with delete action', () async {
    prefs.envVars = {'GITHUB_TOKEN': 'ghp_secret_token_value'};

    final result = await tool.execute({
      'name': 'GITHUB_TOKEN',
      'action': 'delete',
    });

    expect(result, '已删除环境变量 GITHUB_TOKEN');
    expect(prefs.envVars.containsKey('GITHUB_TOKEN'), isFalse);
  });

  test('rejects invalid variable names', () async {
    final result = await tool.execute({
      'name': 'GITHUB_TOKEN; rm -rf /',
      'value': 'secret',
    });

    expect(result, startsWith('Error:'));
    expect(prefs.envVars, isEmpty);
  });

  test('set with empty value deletes the variable', () async {
    prefs.envVars = {'GITHUB_TOKEN': 'ghp_secret_token_value'};

    final result = await tool.execute({
      'name': 'GITHUB_TOKEN',
      'value': '',
    });

    expect(result, '已删除环境变量 GITHUB_TOKEN');
    expect(prefs.envVars.containsKey('GITHUB_TOKEN'), isFalse);
  });

  test('does not allow protected internal environment keys', () async {
    final result = await tool.execute({
      'name': 'PATH',
      'value': '/tmp',
    });

    expect(result, startsWith('Error:'));
    expect(prefs.envVars, isEmpty);
  });

  test('registers with moderate risk in default tool registry', () {
    final registry = ToolRegistry.withDefaults(prefs: prefs);

    expect(registry.hasTool('set_env_var'), isTrue);
    expect(registry.riskFor('set_env_var'), ToolRisk.moderate);
  });
}
