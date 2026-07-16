import 'dart:async';
import 'dart:convert';

import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/tools/tool_registry.dart';
import 'package:clawchat/services/tools/tool_policy.dart';
import 'package:clawchat/services/tools/xds_agent_tool.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late PreferencesService preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async {
      if (call.method == 'readAll') return <String, String>{};
      return null;
    });
    preferences = PreferencesService();
    await preferences.init();
    preferences.envVars = {'XDS_AGENT_TOKEN': 'token-not-for-output'};
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null);
    PreferencesService.resetForTesting();
  });

  test('list uses the fixed origin and redacts token-like response data',
      () async {
    late http.BaseRequest request;
    final tool = XdsAgentTool(
      preferences,
      requestSender: (incoming) async {
        request = incoming;
        return _jsonResponse(incoming, {
          'skills': [
            {'name': 'tapdb-data-analysis'},
          ],
          'echo': 'token-not-for-output',
        });
      },
    );

    final output = await tool.execute(
      const {'operation': 'list', 'app_id': '123'},
    );

    expect(request.method, 'GET');
    expect(
      request.url.toString(),
      'https://ai-xds.tapdb.net/open-skills?app_id=123',
    );
    expect(request.headers['authorization'], 'Bearer token-not-for-output');
    expect(output, contains('tapdb-data-analysis'));
    expect(output, isNot(contains('token-not-for-output')));
  });

  test('cold start loads the XDS token from secure preferences before dispatch',
      () async {
    PreferencesService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async {
      if (call.method == 'read' &&
          (call.arguments as Map?)?['key'] == 'env_vars') {
        return jsonEncode({'XDS_AGENT_TOKEN': 'cold-start-token'});
      }
      if (call.method == 'readAll') return <String, String>{};
      return null;
    });
    final coldPreferences = PreferencesService();
    late http.BaseRequest request;
    final tool = XdsAgentTool(
      coldPreferences,
      requestSender: (incoming) async {
        request = incoming;
        return _jsonResponse(incoming, {'ok': true});
      },
    );

    final output = await tool.execute(const {'operation': 'list'});

    expect(request.headers['authorization'], 'Bearer cold-start-token');
    expect(output, contains('"ok":true'));
    expect(output, isNot(contains('cold-start-token')));
  });

  test('exec sends only the strict protocol fields and never runs local shell',
      () async {
    late http.BaseRequest request;
    final tool = XdsAgentTool(
      preferences,
      requestSender: (incoming) async {
        request = incoming;
        return _jsonResponse(incoming, {'output': 'ok'});
      },
    );

    final output = await tool.execute({
      'operation': 'exec',
      'skill': 'xds-user-auth',
      'command': 'list',
      'user_query': '查项目',
      'intent': '列出项目供用户选择',
    });

    expect(request.method, 'POST');
    expect(
        request.url.toString(), 'https://ai-xds.tapdb.net/open-skills/execute');
    final body = jsonDecode((request as http.Request).body) as Map;
    expect(body.keys, {
      'session_id',
      'skill',
      'command',
      'user_query',
      'intent',
    });
    expect(body['skill'], 'xds-user-auth');
    expect(body['command'], 'list');
    expect(body['session_id'], startsWith('clawchat-'));
    expect(body.values, isNot(contains('token-not-for-output')));
    expect(output, contains('"output":"ok"'));
  });

  test('rejects unknown fields, traversal, and missing token before dispatch',
      () async {
    var calls = 0;
    final tool = XdsAgentTool(
      preferences,
      requestSender: (request) async {
        calls++;
        return _jsonResponse(request, {'ok': true});
      },
    );

    expect(
      await tool.execute(const {'operation': 'list', 'url': 'https://evil'}),
      contains('invalid operation arguments'),
    );
    expect(
      await tool.execute({
        'operation': 'files',
        'skill': 'tapdb-data-analysis',
        'path': '../secret.md',
      }),
      contains('invalid operation arguments'),
    );
    preferences.envVars = {};
    expect(
      await tool.execute(const {'operation': 'list'}),
      contains('not configured'),
    );
    expect(calls, 0);
  });

  test('schema is closed and response size is bounded', () async {
    final registry = ToolRegistry()..register(XdsAgentTool(preferences));
    final schema = registry.inputSchemaFor('xds_agent');
    expect(schema?['additionalProperties'], isFalse);
    expect(schema?['properties'], containsPair('operation', isNotNull));

    final tool = XdsAgentTool(
      preferences,
      requestSender: (request) async => http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            '{"data":"${List.filled(XdsAgentTool.maxResponseBytes, 'x').join()}"}',
          ),
        ),
        200,
        request: request,
      ),
    );
    expect(
      await tool.execute(const {'operation': 'list'}),
      contains('exceeds the app limit'),
    );
  });

  test('XDS schema is exposed only after the Agent has an active skill', () {
    final registry = ToolRegistry.withDefaults(prefs: preferences);
    expect(
      registry.getToolDefinitions().any((tool) => tool.name == 'xds_agent'),
      isFalse,
    );
    expect(
      registry
          .getToolDefinitions(includeXds: true)
          .any((tool) => tool.name == 'xds_agent'),
      isTrue,
    );
    expect(registry.riskFor('xds_agent'), ToolRisk.dangerous);
  });
}

http.StreamedResponse _jsonResponse(
  http.BaseRequest request,
  Map<String, dynamic> body,
) =>
    http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
      200,
      request: request,
    );
