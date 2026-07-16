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

  test('maps every fixed operation and normalizes numeric project IDs',
      () async {
    final requests = <http.BaseRequest>[];
    final tool = XdsAgentTool(
      preferences,
      requestSender: (incoming) async {
        requests.add(incoming);
        return _jsonResponse(incoming, {'ok': true});
      },
    );

    await tool.execute(const {'operation': 'list', 'app_id': 10005388});
    await tool.execute(const {
      'operation': 'get',
      'skill': 'tapdb-data-analysis',
    });
    await tool.execute(const {
      'operation': 'files',
      'skill': 'tapdb-data-analysis',
      'path': 'references/sql_schema_guide.md',
    });
    await tool.execute(const {
      'operation': 'kb',
      'skill': 'tapdb-data-analysis',
      'project_id': 10005388,
      'path': 'ssrpg 5/gacha_recruitment.md',
    });
    await tool.execute(const {
      'operation': 'exec',
      'skill': 'xds-user-auth',
      'command': 'list',
    });

    expect(requests, hasLength(5));
    expect(requests[0].url.toString(),
        'https://ai-xds.tapdb.net/open-skills?app_id=10005388');
    expect(requests[1].url.toString(),
        'https://ai-xds.tapdb.net/open-skills/tapdb-data-analysis');
    expect(requests[2].url.toString(),
        'https://ai-xds.tapdb.net/open-skills/tapdb-data-analysis/files/references/sql_schema_guide.md');
    expect(requests[3].url.toString(),
        'https://ai-xds.tapdb.net/open-skills/tapdb-data-analysis/kb/10005388/ssrpg%205/gacha_recruitment.md');

    final execBody = jsonDecode((requests[4] as http.Request).body) as Map;
    expect(execBody['skill'], 'xds-user-auth');
    expect(execBody['command'], 'list');
    expect(execBody['user_query'], 'User-requested XDS skill operation.');
    expect(execBody['intent'], 'Execute the requested XDS skill command.');
  });

  test('supports the published project-selection and DAU command forms',
      () async {
    final bodies = <Map>[];
    final tool = XdsAgentTool(
      preferences,
      requestSender: (incoming) async {
        bodies.add(jsonDecode((incoming as http.Request).body) as Map);
        return _jsonResponse(incoming, {'ok': true});
      },
    );

    await tool.execute(const {
      'operation': 'exec',
      'skill': 'xds-user-auth',
      'command': 'list',
    });
    await tool.execute(const {
      'operation': 'exec',
      'skill': 'xds-user-auth',
      'command': 'use 17',
    });
    await tool.execute(const {
      'operation': 'exec',
      'skill': 'tapdb-data-analysis',
      'command': 'list_projects --search 铃兰',
      'app_id': 10005388,
    });
    await tool.execute(const {
      'operation': 'exec',
      'skill': 'tapdb-data-analysis',
      'command':
          'active -p 10005388 -s 2026-04-15 -e 2026-04-21 --quota dau -g time',
      'app_id': 10005388,
    });

    expect(bodies, hasLength(4));
    expect(bodies[0]['command'], 'list');
    expect(bodies[1]['command'], 'use 17');
    expect(bodies[2]['command'], startsWith('list_projects'));
    expect(bodies[2]['app_id'], '10005388');
    expect(bodies[3]['command'], startsWith('active -p 10005388'));
    expect(bodies[3]['app_id'], '10005388');
    for (final body in bodies) {
      expect(body['user_query'], isNotEmpty);
      expect(body['intent'], isNotEmpty);
    }
  });

  test('HTTP and malformed JSON failures are fixed and redact response data',
      () async {
    var response = 0;
    final tool = XdsAgentTool(
      preferences,
      requestSender: (incoming) async {
        response++;
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(response == 1
              ? '{"error":"token-not-for-output"}'
              : '{"token":"token-not-for-output"')),
          response == 1 ? 403 : 200,
          request: incoming,
        );
      },
    );

    final httpFailure = await tool.execute(const {'operation': 'list'});
    final jsonFailure = await tool.execute(const {'operation': 'list'});

    expect(httpFailure, 'XDS request failed (HTTP 403).');
    expect(jsonFailure, 'XDS response rejected: invalid bounded JSON.');
    expect(httpFailure, isNot(contains('token-not-for-output')));
    expect(jsonFailure, isNot(contains('token-not-for-output')));
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
    final operationVariants = schema?['oneOf'] as List;
    expect(
      operationVariants,
      contains(predicate<Map>((variant) {
        final properties = variant['properties'] as Map;
        final operation = properties['operation'] as Map;
        return (operation['enum'] as List).contains('exec') &&
            (variant['required'] as List)
                .toSet()
                .containsAll(['skill', 'command']);
      })),
    );

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
