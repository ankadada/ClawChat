import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/models/model_capabilities.dart';
import 'package:clawchat/services/model_capability_registry.dart';
import 'package:clawchat/services/llm_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CapabilityRegistry.instance.clearRuntimeOverridesForTesting();
  });

  group('LlmService error sanitization', () {
    test('returns short body unchanged', () async {
      const msg = 'Rate limit exceeded. Please retry after 60s.';
      expect(await sanitizedErrorBody(msg), msg);
    });

    test('truncates body longer than 500 chars', () async {
      final long = 'a' * 1000;
      final result = await sanitizedErrorBody(long);
      expect(result.length, 503); // 500 chars + '...'
      expect(result, endsWith('...'));
      expect(result.startsWith('a' * 500), isTrue);
    });

    test('truncates exactly at 500 boundary', () async {
      final exact500 = 'b' * 500;
      expect(await sanitizedErrorBody(exact500), exact500);

      final exact501 = 'c' * 501;
      final result = await sanitizedErrorBody(exact501);
      expect(result.length, 503);
    });

    test('redacts sk- prefixed API keys', () async {
      final result =
          await sanitizedErrorBody('Invalid key: sk-ant-api03-xxxxxxxxxxxx');
      expect(result, contains('[REDACTED]'));
      expect(result, isNot(contains('sk-ant-api03-xxxxxxxxxxxx')));
    });

    test('redacts key- prefixed tokens', () async {
      final result =
          await sanitizedErrorBody('Error with key-abcdefghijklmnop');
      expect(result, contains('[REDACTED]'));
      expect(result, isNot(contains('key-abcdefghijklmnop')));
    });

    test('redacts api- prefixed tokens', () async {
      final result = await sanitizedErrorBody('Token: api-1234567890abcdef');
      expect(result, contains('[REDACTED]'));
      expect(result, isNot(contains('api-1234567890abcdef')));
    });

    test('does not redact short key-like strings (less than 10 chars)',
        () async {
      final result = await sanitizedErrorBody('sk-short');
      expect(result, 'sk-short');
    });

    test('redacts multiple keys in same body', () async {
      const input = 'Keys: sk-aaaaaaaaaa and api-bbbbbbbbbb found';
      final result = await sanitizedErrorBody(input);
      expect(result, isNot(contains('sk-aaaaaaaaaa')));
      expect(result, isNot(contains('api-bbbbbbbbbb')));
      expect('[REDACTED]'.allMatches(result).length, 2);
    });

    test('redacts broad sensitive values from API error messages', () async {
      const bearer = 'abcdefghijklmnopqrstuvwxyz1234567890';
      const githubPat = 'github_pat_abcdefghijklmnopqrstuvwxyz123456';
      const body = 'Authorization: Bearer $bearer\n'
          'password=hunter2\n'
          'github token $githubPat\n'
          'client_secret=client-secret-value';

      final error = await openAiChatError(400, body);

      expect(error, contains('[redacted: bearer_token]'));
      expect(error, contains('password=[redacted: password]'));
      expect(error, contains('[redacted: token]'));
      expect(error, contains('client_secret=[redacted: secret]'));
      expect(error, isNot(contains(bearer)));
      expect(error, isNot(contains('hunter2')));
      expect(error, isNot(contains(githubPat)));
      expect(error, isNot(contains('client-secret-value')));
    });

    test('handles empty body', () async {
      expect(await sanitizedErrorBody(''), '');
    });

    test('preserves non-key content around redacted keys', () async {
      final result = await sanitizedErrorBody(
        'Error 401: key-abcdefghijklmnop is invalid',
      );
      expect(result, contains('Error 401:'));
      expect(result, contains('is invalid'));
      expect(result, contains('[REDACTED]'));
    });

    test('redacts keys with underscores and dashes', () async {
      final result =
          await sanitizedErrorBody('sk-ant_api03-key_with-dashes_123');
      expect(result, contains('[REDACTED]'));
    });

    test('truncation happens before redaction', () async {
      final body = '${'x' * 510}sk-aaaaaaaaaa';
      final result = await sanitizedErrorBody(body);
      expect(result.length, 503);
      expect(result, isNot(contains('sk-aaaaaaaaaa')));
    });
  });

  group('LlmService retryable HTTP status handling', () {
    test('matches 429 rate limit', () async {
      expect(await requestCountWhenFirstStatusIs(429), 2);
    });

    test('matches 500 internal server error', () async {
      expect(await requestCountWhenFirstStatusIs(500), 2);
    });

    test('matches 502 bad gateway', () async {
      expect(await requestCountWhenFirstStatusIs(502), 2);
    });

    test('matches 503 service unavailable', () async {
      expect(await requestCountWhenFirstStatusIs(503), 2);
    });

    test('matches 504 gateway timeout', () async {
      expect(await requestCountWhenFirstStatusIs(504), 2);
    });

    test('does not match 400 bad request', () async {
      expect(await requestCountForAlwaysStatus(400), 1);
    });

    test('does not match 401 unauthorized', () async {
      expect(await requestCountForAlwaysStatus(401), 1);
    });

    test('does not match 403 forbidden', () async {
      expect(await requestCountForAlwaysStatus(403), 1);
    });

    test('does not match 404 not found', () async {
      expect(await requestCountForAlwaysStatus(404), 1);
    });

    test('does not match plain text without status code', () async {
      expect(await requestCountForAlwaysStatus(418), 1);
    });

    test('does not match empty string', () async {
      expect(await sanitizedErrorBody(''), '');
    });
  });

  group('LlmService non-stream foreground timeout', () {
    test('does not time out while app is backgrounded', () async {
      var isInBackground = true;
      final responseFuture = delayedOpenAiChat(
        isInBackground: () => isInBackground,
        responseDelay: const Duration(milliseconds: 80),
        requestTimeout: const Duration(milliseconds: 40),
      );

      await Future<void>.delayed(const Duration(milliseconds: 55));
      isInBackground = false;

      final response = await responseFuture.timeout(const Duration(seconds: 2));

      expect(response.content.single.text, 'ok after background');
    });

    test('pauses elapsed timeout during temporary backgrounding', () async {
      var isInBackground = false;
      final responseFuture = delayedOpenAiChat(
        isInBackground: () => isInBackground,
        responseDelay: const Duration(milliseconds: 110),
        requestTimeout: const Duration(milliseconds: 80),
      );

      await Future<void>.delayed(const Duration(milliseconds: 30));
      isInBackground = true;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      isInBackground = false;

      final response = await responseFuture.timeout(const Duration(seconds: 2));

      expect(response.content.single.text, 'ok after background');
    });

    test('fails at max wall clock across repeated backgrounding', () async {
      var isInBackground = false;
      final toggler = Timer.periodic(const Duration(milliseconds: 20), (timer) {
        isInBackground = !isInBackground;
      });
      addTearDown(toggler.cancel);

      await expectLater(
        delayedOpenAiChat(
          isInBackground: () => isInBackground,
          responseDelay: const Duration(seconds: 2),
          requestTimeout: const Duration(milliseconds: 80),
          requestMaxWallClock: const Duration(milliseconds: 140),
        ),
        throwsA(isA<TimeoutException>().having(
          (error) => error.message,
          'message',
          contains('maximum wall-clock timeout'),
        )),
      );
    });
  });

  group('LlmService OpenAI reasoning_content 400 fallback', () {
    const reasoningMessages = [
      {
        'role': 'assistant',
        'content': 'answer',
        'reasoning_content': 'internal reasoning',
      },
    ];

    test('non-stream unsupported reasoning_content retries stripped', () async {
      final bodies = await captureOpenAiChatBodiesForReasoning400(
        model: 'deepseek-reasoner',
        firstErrorBody: jsonEncode({
          'error': {
            'message': 'unrecognized extra field: reasoning_content',
          },
        }),
        messages: reasoningMessages,
      );

      expect(bodies, hasLength(2));
      expect(bodyContainsReasoningContent(bodies.first), isTrue);
      expect(bodyContainsReasoningContent(bodies.last), isFalse);
    });

    test(
        'non-stream unsupported reasoning_content does not enable stripped model',
        () async {
      final bodies = await captureOpenAiChatBodiesForReasoning400(
        model: 'gpt-test',
        firstErrorBody: jsonEncode({
          'error': {
            'message': 'unknown field: reasoning_content',
          },
        }),
        messages: reasoningMessages,
        expectSuccess: false,
      );

      expect(bodies, hasLength(1));
      expect(bodyContainsReasoningContent(bodies.single), isFalse);
    });

    test('non-stream missing required reasoning_content enables fallback',
        () async {
      final bodies = await captureOpenAiChatBodiesForReasoning400(
        model: 'gpt-test',
        firstErrorBody: jsonEncode({
          'error': {
            'message': 'Missing required field: reasoning_content',
          },
        }),
        messages: reasoningMessages,
      );

      expect(bodies, hasLength(2));
      expect(bodyContainsReasoningContent(bodies.first), isFalse);
      expect(bodyContainsReasoningContent(bodies.last), isTrue);
    });

    test('stream unsupported reasoning_content retries stripped', () async {
      final bodies = <Map<String, dynamic>>[];
      final events = await collectOpenAiStreamEventsWithHandler(
        (request) async {
          if (bodies.length == 1) {
            request.response.statusCode = 400;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({
              'error': {
                'message': 'reasoning_content is not permitted',
              },
            }));
            await request.response.close();
            return;
          }

          request.response.write(sseData({
            'choices': [
              {
                'delta': {'content': 'ok'},
                'finish_reason': null,
              }
            ],
          }));
          request.response.write(sseData({
            'choices': [
              {
                'delta': {},
                'finish_reason': 'stop',
              }
            ],
          }, delimiter: false));
          await request.response.close();
        },
        model: 'deepseek-reasoner',
        messages: reasoningMessages,
        onRequestBody: bodies.add,
      );

      expect(events.whereType<StreamError>(), isEmpty);
      expect(bodies, hasLength(2));
      expect(bodyContainsReasoningContent(bodies.first), isTrue);
      expect(bodyContainsReasoningContent(bodies.last), isFalse);
    });

    test('stream unsupported reasoning_content does not enable stripped model',
        () async {
      final bodies = <Map<String, dynamic>>[];
      final events = await collectOpenAiStreamEventsWithHandler(
        (request) async {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'error': {
              'message': 'reasoning_content is unsupported',
            },
          }));
          await request.response.close();
        },
        messages: reasoningMessages,
        onRequestBody: bodies.add,
      );

      expect(events.whereType<StreamError>(), hasLength(1));
      expect(bodies, hasLength(1));
      expect(bodyContainsReasoningContent(bodies.single), isFalse);
    });

    test('stream missing required reasoning_content enables fallback',
        () async {
      final bodies = <Map<String, dynamic>>[];
      final events = await collectOpenAiStreamEventsWithHandler(
        (request) async {
          if (bodies.length == 1) {
            request.response.statusCode = 400;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({
              'error': {
                'message': 'reasoning_content is required',
              },
            }));
            await request.response.close();
            return;
          }

          request.response.write(sseData({
            'choices': [
              {
                'delta': {'content': 'ok'},
                'finish_reason': null,
              }
            ],
          }));
          request.response.write(sseData({
            'choices': [
              {
                'delta': {},
                'finish_reason': 'stop',
              }
            ],
          }, delimiter: false));
          await request.response.close();
        },
        messages: reasoningMessages,
        onRequestBody: bodies.add,
      );

      expect(events.whereType<StreamError>(), isEmpty);
      expect(bodies, hasLength(2));
      expect(bodyContainsReasoningContent(bodies.first), isFalse);
      expect(bodyContainsReasoningContent(bodies.last), isTrue);
    });
  });

  group('LlmService Anthropic invalid encrypted content handling', () {
    test('throws EncryptedContentError for invalid_encrypted_content 400',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'type': 'error',
          'error': {
            'type': 'invalid_request_error',
            'code': 'invalid_encrypted_content',
            'message':
                'The encrypted content lite...dhmz could not be verified.',
          },
        }));
        await request.response.close();
      });

      final service = LlmService(LlmConfig.anthropic(
        apiKey: 'sk-test',
        model: 'claude-sonnet-4-20250514',
        baseUrl: 'http://127.0.0.1:${server.port}',
      ));

      try {
        await expectLater(
          service.chat(
            system: '',
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
            tools: const [],
          ),
          throwsA(isA<EncryptedContentError>()
              .having((e) => e.code, 'code', 'invalid_encrypted_content')
              .having((e) => e.statusCode, 'statusCode', 400)),
        );
      } finally {
        service.dispose();
        await server.close(force: true);
      }
    });
  });

  group('LlmConfig equality', () {
    test('ContentBlock.toJson produces correct text block', () {
      const block = ContentBlock(type: 'text', text: 'hello');
      final json = block.toJson();
      expect(json['type'], 'text');
      expect(json['text'], 'hello');
    });

    test('ContentBlock.toJson preserves reasoning_content for text blocks', () {
      const block = ContentBlock(
        type: 'text',
        text: 'hello',
        reasoningContent: 'private reasoning',
      );
      final json = block.toJson();
      expect(json['type'], 'text');
      expect(json['text'], 'hello');
      expect(json['reasoning_content'], 'private reasoning');
    });

    test('ContentBlock.toJson produces correct tool_use block', () {
      const block = ContentBlock(
        type: 'tool_use',
        toolUseId: 'call_123',
        toolName: 'bash',
        toolInput: {'command': 'ls'},
      );
      final json = block.toJson();
      expect(json['type'], 'tool_use');
      expect(json['id'], 'call_123');
      expect(json['name'], 'bash');
      expect(json['input'], {'command': 'ls'});
    });

    test('ToolDefinition.toAnthropicJson format', () {
      const tool = ToolDefinition(
        name: 'bash',
        description: 'Run a command',
        inputSchema: {
          'type': 'object',
          'properties': {
            'command': {'type': 'string'}
          }
        },
      );
      final json = tool.toAnthropicJson();
      expect(json['name'], 'bash');
      expect(json['description'], 'Run a command');
      expect(json['input_schema'], isNotNull);
    });

    test('ToolDefinition.toOpenAIJson format', () {
      const tool = ToolDefinition(
        name: 'bash',
        description: 'Run a command',
        inputSchema: {
          'type': 'object',
          'properties': {
            'command': {'type': 'string'}
          }
        },
      );
      final json = tool.toOpenAIJson();
      expect(json['type'], 'function');
      expect(json['function']['name'], 'bash');
      expect(json['function']['description'], 'Run a command');
      expect(json['function']['parameters'], isNotNull);
    });
  });

  group('LlmService request body compatibility', () {
    test('modelIdFromDisplay preserves slash-prefixed raw model ids', () {
      const models = ['gpt-5.5', 'codex/gpt-5.5'];

      expect(LlmService.modelIdFromDisplay(models[0]), 'gpt-5.5');
      expect(LlmService.modelIdFromDisplay(models[1]), 'codex/gpt-5.5');
    });

    test('strips Anthropic preset display suffix from request model', () async {
      final body = await captureAnthropicBody(
        model: 'claude-sonnet-4-20250514${LlmService.presetModelSuffix}',
      );

      expect(body['model'], 'claude-sonnet-4-20250514');
    });

    test('strips OpenAI-compatible preset display suffix from request model',
        () async {
      final body = await captureOpenAiBody(
        model: 'gpt-test${LlmService.presetModelSuffix}',
      );

      expect(body['model'], 'gpt-test');
    });

    test(
        'generic OpenAI-compatible requests use max_tokens for non-reasoning models',
        () async {
      final body = await captureOpenAiBody(model: 'gpt-test');
      expect(body['max_tokens'], 8192);
    });

    test('reasoning models use max_completion_tokens regardless of provider',
        () async {
      final body = await captureOpenAiBody(model: 'gpt-5.5');
      expect(body['max_completion_tokens'], 8192);
    });

    test('token key fallback is scoped per model on the same proxy', () async {
      final bodies = await captureTokenFallbackBodiesForTwoModels();

      expect(bodies[0]['model'], 'legacy-model');
      expect(bodies[0], contains('max_tokens'));
      expect(bodies[1]['model'], 'legacy-model');
      expect(bodies[1], contains('max_completion_tokens'));
      expect(bodies[2]['model'], 'gpt-test');
      expect(bodies[2], contains('max_tokens'));
      expect(bodies[2], isNot(contains('max_completion_tokens')));
    });

    test('token key fallback override can be cleared', () async {
      final bodies = await captureTokenFallbackBodiesWithManualClear();

      expect(bodies.map((body) => body['model']), [
        'legacy-model',
        'legacy-model',
        'legacy-model',
        'legacy-model',
      ]);
      expect(bodies[0], contains('max_tokens'));
      expect(bodies[1], contains('max_completion_tokens'));
      expect(bodies[2], contains('max_tokens'));
      expect(bodies[3], contains('max_completion_tokens'));
    });

    test('builds valid Anthropic simple text request body', () async {
      final captured = await captureAnthropicRequest(
        model: 'claude-sonnet-4-20250514${LlmService.presetModelSuffix}',
        system: 'You are concise.',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        baseUrlForPort: (port) => 'http://127.0.0.1:$port/v1/messages',
      );

      expect(captured.uri.path, '/v1/messages');
      expect(captured.body['model'], 'claude-sonnet-4-20250514');
      expect(captured.body['system'], 'You are concise.');
      expect(captured.body['messages'], [
        {'role': 'user', 'content': 'hi'},
      ]);
      expect(captured.body['max_tokens'], 8192);
      expect(jsonDecode(jsonEncode(captured.body)), captured.body);
    });

    test('builds valid OpenAI-compatible simple text request body', () async {
      final captured = await captureOpenAiRequest(
        model: 'gpt-test${LlmService.presetModelSuffix}',
        system: 'You are concise.',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        baseUrlForPort: (port) => 'http://127.0.0.1:$port/v1/chat/completions',
      );

      expect(captured.uri.path, '/v1/chat/completions');
      expect(captured.body['model'], 'gpt-test');
      expect(captured.body['messages'], [
        {'role': 'system', 'content': 'You are concise.'},
        {'role': 'user', 'content': 'hi'},
      ]);
      expect(captured.body['max_tokens'], 8192);
      expect(jsonDecode(jsonEncode(captured.body)), captured.body);
    });

    test('omits OpenAI tool definitions when capabilities disable tools',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'gpt-test',
        capabilityRegistry: const _NoToolsCapabilityRegistry(),
        tools: const [
          ToolDefinition(
            name: 'echo',
            description: 'Echo text',
            inputSchema: {
              'type': 'object',
              'properties': {
                'text': {'type': 'string'},
              },
            },
          ),
        ],
      );

      expect(captured.body, isNot(contains('tools')));
    });

    test('downgrades historical tool payloads when tools are unsupported',
        () async {
      const toolDefinitions = [
        ToolDefinition(
          name: 'echo',
          description: 'Echo text',
          inputSchema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
            },
          },
        ),
      ];
      const messages = [
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'call:1',
              'name': 'bash',
              'input': {'command': 'pwd'},
            },
          ],
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'call:1',
              'for_llm': 'compact safe result',
              'output': 'FULL OUTPUT THAT MUST NOT LEAK',
            },
          ],
        },
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call:2',
              'type': 'function',
              'function': {
                'name': 'web_fetch',
                'arguments': '{"url":"https://example.test"}',
              },
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 'call:2',
          'content': 'fetch complete',
        },
      ];

      final openai = await captureOpenAiRequest(
        model: 'gpt-test',
        messages: messages,
        tools: toolDefinitions,
        capabilityRegistry: const _NoToolsCapabilityRegistry(),
      );
      final anthropic = await captureAnthropicRequest(
        model: 'claude-sonnet-4-20250514',
        messages: messages,
        tools: toolDefinitions,
        capabilityRegistry: const _NoToolsCapabilityRegistry(),
      );

      expect(openai.body, isNot(contains('tools')));
      expect(anthropic.body, isNot(contains('tools')));
      expectNoProviderToolSyntax(openai.body);
      expectNoProviderToolSyntax(anthropic.body);
      expect(openai.body.toString(), contains('[Tool call]'));
      expect(anthropic.body.toString(), contains('[Tool call]'));
      expect(openai.body.toString(), contains('for_llm: compact safe result'));
      expect(
          anthropic.body.toString(), contains('for_llm: compact safe result'));
      expect(
        openai.body.toString(),
        isNot(contains('FULL OUTPUT THAT MUST NOT LEAK')),
      );
      expect(
        anthropic.body.toString(),
        isNot(contains('FULL OUTPUT THAT MUST NOT LEAK')),
      );
    });

    test('redacts secrets from system prompts in request bodies', () async {
      final anthropic = await captureAnthropicRequest(
        model: 'claude-sonnet-4-20250514',
        system:
            'Use api_key=sk-proj-abcdefghijklmnopqrstuvwxyz123456 carefully.',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        baseUrlForPort: (port) => 'http://127.0.0.1:$port/v1/messages',
      );
      final openai = await captureOpenAiRequest(
        model: 'gpt-test',
        system:
            'Use api_key=sk-proj-abcdefghijklmnopqrstuvwxyz123456 carefully.',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        baseUrlForPort: (port) => 'http://127.0.0.1:$port/v1/chat/completions',
      );

      expect(anthropic.body['system'], contains('[redacted: api_key]'));
      expect(anthropic.body['system'], isNot(contains('sk-proj-')));
      expect(
        openai.body['messages'].first['content'],
        contains('[redacted: api_key]'),
      );
      expect(openai.body['messages'].first['content'],
          isNot(contains('sk-proj-')));
    });

    test(
        'passes assistant reasoning_content back to DeepSeek-style OpenAI-compatible APIs',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'deepseek-reasoner',
        system: 'You are concise.',
        messages: const [
          {
            'role': 'assistant',
            'content': 'answer',
            'reasoning_content': 'internal reasoning',
          },
        ],
        baseUrlForPort: (port) => 'http://127.0.0.1:$port/v1/chat/completions',
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': 'You are concise.'},
        {
          'role': 'assistant',
          'content': 'answer',
          'reasoning_content': 'internal reasoning',
        },
      ]);
    });

    test(
        'strips assistant reasoning_content from non-reasoning OpenAI requests',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'gpt-test',
        messages: const [
          {
            'role': 'assistant',
            'content': 'answer',
            'reasoning_content': 'internal reasoning',
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {'role': 'assistant', 'content': 'answer'},
      ]);
    });

    test('strips reasoning_content from non-reasoning DeepSeek chat models',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'deepseek-chat',
        messages: const [
          {
            'role': 'assistant',
            'content': 'answer',
            'reasoning_content': 'internal reasoning',
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {'role': 'assistant', 'content': 'answer'},
      ]);
    });

    test('strips reasoning_content from non-DeepSeek reasoner models',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'other-reasoner',
        messages: const [
          {
            'role': 'assistant',
            'content': 'answer',
            'reasoning_content': 'internal reasoning',
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {'role': 'assistant', 'content': 'answer'},
      ]);
    });

    test('allows bare r1 OpenAI-compatible reasoning_content', () async {
      final captured = await captureOpenAiRequest(
        model: 'r1',
        messages: const [
          {
            'role': 'assistant',
            'content': 'answer',
            'reasoning_content': 'internal reasoning',
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {
          'role': 'assistant',
          'content': 'answer',
          'reasoning_content': 'internal reasoning',
        },
      ]);
    });

    test('does not send reasoning_content to official OpenAI reasoning models',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'gpt-5.5',
        messages: const [
          {
            'role': 'assistant',
            'content': 'answer',
            'reasoning_content': 'internal reasoning',
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {'role': 'assistant', 'content': 'answer'},
      ]);
    });

    test('adds empty reasoning_content for old assistant messages on DeepSeek',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'deepseek-reasoner',
        messages: const [
          {'role': 'assistant', 'content': 'old answer'},
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {
          'role': 'assistant',
          'content': 'old answer',
          'reasoning_content': '',
        },
      ]);
    });

    test('parses Anthropic non-stream usage including cache fields', () async {
      final response = await anthropicChatResponseWithBody({
        'stop_reason': 'end_turn',
        'content': [
          {'type': 'text', 'text': 'ok'}
        ],
        'usage': {
          'input_tokens': 100,
          'output_tokens': 20,
          'cache_read_input_tokens': 30,
          'cache_creation_input_tokens': 40,
        },
      });

      expect(response.inputTokens, 100);
      expect(response.outputTokens, 20);
      expect(response.usage?.cacheReadInputTokens, 30);
      expect(response.usage?.cacheCreationInputTokens, 40);
      expect(response.usage?.totalInputTokens, 170);
    });

    test('parses OpenAI non-stream usage including cached tokens', () async {
      final response = await openAiChatResponseWithBody({
        'choices': [
          {
            'message': {'content': 'ok'},
            'finish_reason': 'stop',
          }
        ],
        'usage': {
          'prompt_tokens': 100,
          'completion_tokens': 20,
          'prompt_tokens_details': {
            'cached_tokens': 30,
          },
        },
      });

      expect(response.inputTokens, 100);
      expect(response.outputTokens, 20);
      expect(response.usage?.cacheReadInputTokens, 30);
      expect(response.usage?.cacheCreationInputTokens, isNull);
      expect(response.usage?.totalInputTokens, 100);
    });

    test('strips assistant reasoning_content from Anthropic request bodies',
        () async {
      final captured = await captureAnthropicRequest(
        model: 'claude-sonnet-4-20250514',
        messages: const [
          {
            'role': 'assistant',
            'content': 'answer',
            'reasoning_content': 'internal reasoning',
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'assistant', 'content': 'answer'},
      ]);
    });

    test('converts raw OpenAI tool history to Anthropic tool blocks', () async {
      final captured = await captureAnthropicRequest(
        model: 'claude-sonnet-4-20250514',
        messages: const [
          {
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              {
                'id': 'call_1',
                'type': 'function',
                'function': {
                  'name': 'bash',
                  'arguments': '{"command":"pwd"}',
                },
              },
            ],
          },
          {
            'role': 'tool',
            'tool_call_id': 'call_1',
            'content': '/root/workspace',
          },
        ],
      );

      expect(captured.body['messages'], [
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'call_1',
              'name': 'bash',
              'input': {'command': 'pwd'},
            },
          ],
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'call_1',
              'content': '/root/workspace',
            },
          ],
        },
      ]);
    });

    test('converts OpenAI image_url blocks to Anthropic image blocks',
        () async {
      final captured = await captureAnthropicRequest(
        model: 'claude-sonnet-4-20250514',
        messages: const [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'describe'},
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:image/png;base64,abc123',
                },
              },
            ],
          },
        ],
      );

      expect(captured.body['messages'], [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'describe'},
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': 'image/png',
                'data': 'abc123',
              },
            },
          ],
        },
      ]);
    });

    test('preserves raw OpenAI tool messages when building OpenAI bodies',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'gpt-test',
        messages: const [
          {
            'role': 'tool',
            'tool_call_id': 'call_1',
            'content': 'done',
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {
          'role': 'tool',
          'content': 'done',
          'tool_call_id': 'call_1',
        },
      ]);
    });

    test('prefers content-block tool_use over top-level tool_calls', () async {
      final captured = await captureOpenAiRequest(
        model: 'gpt-test',
        messages: const [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'call_content',
                'name': 'bash',
                'input': {'command': 'pwd'},
              },
            ],
            'tool_calls': [
              {
                'id': 'call_top',
                'type': 'function',
                'function': {
                  'name': 'bash',
                  'arguments': '{"command":"ignored"}',
                },
              },
            ],
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call_content',
              'type': 'function',
              'function': {
                'name': 'bash',
                'arguments': '{"command":"pwd"}',
              },
            },
          ],
        },
      ]);
    });

    test('builds golden Anthropic payload for mixed multimodal tool history',
        () async {
      final captured = await captureAnthropicRequest(
        model: 'claude-sonnet-4-20250514',
        system: 'You are concise.',
        messages: const [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'describe'},
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': 'abc123',
                },
              },
            ],
          },
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'text',
                'text': 'thinking answer',
                'reasoning_content': 'anthropic should strip this',
              },
            ],
            'reasoning_content': 'top level hidden',
          },
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'call:1',
                'name': 'bash',
                'input': {'command': 'pwd'},
              },
            ],
          },
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'call:1',
                'content': '/root/workspace',
              },
            ],
          },
        ],
      );

      expect(captured.body['messages'], [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'describe'},
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': 'image/png',
                'data': 'abc123',
              },
            },
          ],
        },
        {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'thinking answer'},
          ],
        },
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'call_1',
              'name': 'bash',
              'input': {'command': 'pwd'},
            },
          ],
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'call_1',
              'content': '/root/workspace',
            },
          ],
        },
      ]);
      expect(jsonDecode(jsonEncode(captured.body)), captured.body);
    });

    test('builds golden OpenAI payload for mixed multimodal tool history',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'gpt-test',
        system: 'You are concise.',
        messages: const [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'describe'},
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': 'abc123',
                },
              },
            ],
          },
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'call:1',
                'name': 'bash',
                'input': {'command': 'pwd'},
              },
            ],
          },
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'call:1',
                'content': '/root/workspace',
              },
            ],
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': 'You are concise.'},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'describe'},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,abc123'},
            },
          ],
        },
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {
                'name': 'bash',
                'arguments': '{"command":"pwd"}',
              },
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 'call_1',
          'content': '/root/workspace',
        },
      ]);
      expect(jsonDecode(jsonEncode(captured.body)), captured.body);
    });

    test('builds golden OpenAI payload preserving supported reasoning_content',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'deepseek-reasoner',
        system: 'You are concise.',
        messages: const [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'text',
                'text': 'answer',
                'reasoning_content': 'block reasoning',
              },
            ],
            'reasoning_content': 'top reasoning',
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': 'You are concise.'},
        {
          'role': 'assistant',
          'content': 'answer',
          'reasoning_content': 'top reasoning\nblock reasoning',
        },
      ]);
    });

    test('replaces images with text warning for known text-only models',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'codex/gpt-5.5',
        messages: const [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'inspect'},
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': 'abc123',
                },
              },
            ],
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {
          'role': 'user',
          'content':
              'inspect\n[Attachment omitted: images are not supported by this provider]',
        },
      ]);
    });
  });

  group('LlmService streaming compatibility', () {
    test('returns sanitized EncryptedContentError for Anthropic SSE error',
        () async {
      final events = await collectAnthropicStreamEvents([
        sseData({
          'type': 'error',
          'error': {
            'type': 'invalid_request_error',
            'code': 'invalid_encrypted_content',
            'message': 'The encrypted content ${'x' * 800}',
          },
        }),
      ]);

      final error = events.whereType<StreamError>().single;
      expect(error.cause, isA<EncryptedContentError>());
      expect((error.cause as EncryptedContentError).code,
          'invalid_encrypted_content');
      expect(error.message, contains('invalid_encrypted_content'));
      expect(error.message.length, lessThan(620));
      expect(error.message, endsWith('...'));
    });

    test('rejects Anthropic stream ending without message_stop event',
        () async {
      final events = await collectAnthropicStreamEvents([
        sseData({
          'type': 'message_start',
          'message': {
            'usage': {
              'input_tokens': 1,
              'cache_read_input_tokens': 2,
              'cache_creation_input_tokens': 3,
            },
          },
        }),
        sseData({
          'type': 'content_block_start',
          'content_block': {'type': 'text'},
        }),
        sseData({
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'ok'},
        }),
        sseData({'type': 'content_block_stop'}),
        sseData({
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
          'usage': {'output_tokens': 1},
        }, delimiter: false),
      ]);

      final error = events.whereType<StreamError>().single;
      expect(error.message, contains('without message_stop'));
      expect(events.whereType<StreamDone>(), isEmpty);
    });

    test('rejects Anthropic done sentinel without message_stop', () async {
      final events = await collectAnthropicStreamEvents([
        sseData({'type': 'message_start', 'message': {}}),
        sseData({
          'type': 'content_block_start',
          'content_block': {'type': 'text'},
        }),
        sseData({
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'ok'},
        }),
        sseData({'type': 'content_block_stop'}),
        'data: [DONE]\n\n',
      ]);

      final error = events.whereType<StreamError>().single;
      expect(error.message, contains('without message_stop'));
      expect(events.whereType<StreamDone>(), isEmpty);
    });

    test('rejects malformed Anthropic SSE JSON frame', () async {
      final events = await collectAnthropicStreamEvents([
        sseData({'type': 'message_start', 'message': {}}),
        'data: {"type":\n\n',
      ]);

      final error = events.whereType<StreamError>().single;
      expect(error.message, contains('malformed SSE JSON frame'));
      expect(events.whereType<StreamDone>(), isEmpty);
    });

    test('streams Anthropic thinking deltas separately from answer text',
        () async {
      final events = await collectAnthropicStreamEvents([
        sseData({'type': 'message_start', 'message': {}}),
        sseData({
          'type': 'content_block_start',
          'content_block': {'type': 'thinking'},
        }),
        sseData({
          'type': 'content_block_delta',
          'delta': {'type': 'thinking_delta', 'thinking': 'step one\n'},
        }),
        sseData({
          'type': 'content_block_delta',
          'delta': {'type': 'thinking_delta', 'thinking': 'step two'},
        }),
        sseData({'type': 'content_block_stop'}),
        sseData({
          'type': 'content_block_start',
          'content_block': {'type': 'text'},
        }),
        sseData({
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'answer'},
        }),
        sseData({'type': 'content_block_stop'}),
        sseData({
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
        }),
        sseData({'type': 'message_stop'}, delimiter: false),
      ]);

      expect(events.whereType<ReasoningDelta>().map((e) => e.text), [
        'step one\n',
        'step two',
      ]);
      expect(events.whereType<TextDelta>().map((e) => e.text), ['answer']);
      final done = events.whereType<StreamDone>().single;
      expect(done.response.content.single.text, 'answer');
      expect(
        done.response.content.single.reasoningContent,
        'step one\nstep two',
      );
    });

    test('accepts OpenAI stream ending without final delimiter or done marker',
        () async {
      final events = await collectOpenAiStreamEvents([
        sseData({
          'choices': [
            {
              'delta': {'content': 'ok'},
              'finish_reason': null,
            }
          ],
        }),
        sseData({
          'choices': [
            {
              'delta': {},
              'finish_reason': 'stop',
            }
          ],
          'usage': {
            'prompt_tokens': 1,
            'completion_tokens': 1,
            'prompt_tokens_details': {
              'cached_tokens': 2,
            },
          },
        }, delimiter: false),
      ]);

      expect(events.whereType<StreamError>().map((e) => e.message), isEmpty);
      final done = events.whereType<StreamDone>().single;
      expect(done.response.content.single.text, 'ok');
      expect(done.response.stopReason, 'end_turn');
      expect(done.response.inputTokens, 1);
      expect(done.response.outputTokens, 1);
      expect(done.response.usage?.cacheReadInputTokens, 2);
    });

    test('rejects OpenAI stream ending without finish_reason', () async {
      final events = await collectOpenAiStreamEvents([
        sseData({
          'choices': [
            {
              'delta': {'content': 'partial'},
              'finish_reason': null,
            }
          ],
        }),
      ]);

      expect(events.whereType<TextDelta>().map((event) => event.text),
          ['partial']);
      final error = events.whereType<StreamError>().single;
      expect(error.message, contains('without finish_reason'));
      expect(events.whereType<StreamDone>(), isEmpty);
    });

    test('rejects malformed OpenAI SSE JSON frame', () async {
      final events = await collectOpenAiStreamEvents([
        sseData({
          'choices': [
            {
              'delta': {'content': 'partial'},
              'finish_reason': null,
            }
          ],
        }),
        'data: {"choices":\n\n',
      ]);

      expect(events.whereType<TextDelta>().map((event) => event.text),
          ['partial']);
      final error = events.whereType<StreamError>().single;
      expect(error.message, contains('malformed SSE JSON frame'));
      expect(events.whereType<StreamDone>(), isEmpty);
    });

    test('rejects OpenAI incomplete tool call JSON before StreamDone',
        () async {
      final events = await collectOpenAiStreamEvents([
        sseData({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_1',
                    'function': {'name': 'echo', 'arguments': '{"text":'},
                  }
                ],
              },
              'finish_reason': null,
            }
          ],
        }),
        sseData({
          'choices': [
            {
              'delta': {},
              'finish_reason': 'tool_calls',
            }
          ],
        }),
        'data: [DONE]\n\n',
      ]);

      expect(events.whereType<ToolUseStart>(), hasLength(1));
      expect(events.whereType<ToolInputDelta>(), hasLength(1));
      final error = events.whereType<StreamError>().single;
      expect(error.message, contains('incomplete tool call JSON'));
      expect(events.whereType<StreamDone>(), isEmpty);
    });

    test('retries OpenAI stream without stream_options when unsupported',
        () async {
      LlmService.clearStreamUsageUnsupportedHostsForTesting();
      final bodies = <Map<String, dynamic>>[];
      final events = await collectOpenAiStreamEventsWithHandler(
        (request) async {
          if (bodies.length == 1) {
            request.response.statusCode = 400;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({
              'error': {
                'message': 'unknown field: stream_options.include_usage',
              },
            }));
            await request.response.close();
            return;
          }

          request.response.write(sseData({
            'choices': [
              {
                'delta': {'content': 'ok'},
                'finish_reason': null,
              }
            ],
          }));
          request.response.write(sseData({
            'choices': [
              {
                'delta': {},
                'finish_reason': 'stop',
              }
            ],
          }, delimiter: false));
          await request.response.close();
        },
        onRequestBody: bodies.add,
      );

      expect(events.whereType<StreamError>(), isEmpty);
      expect(events.whereType<StreamDone>().single.response.content.single.text,
          'ok');
      expect(bodies, hasLength(2));
      expect(bodies.first, contains('stream_options'));
      expect(bodies.last, isNot(contains('stream_options')));

      final nextBodies = await captureOpenAiStreamBodies();
      expect(nextBodies.single, isNot(contains('stream_options')));
      LlmService.clearStreamUsageUnsupportedHostsForTesting();
    });

    test('captures OpenAI streaming reasoning_content without displaying it',
        () async {
      final events = await collectOpenAiStreamEvents([
        sseData({
          'choices': [
            {
              'delta': {'reasoning_content': 'hidden '},
              'finish_reason': null,
            }
          ],
        }),
        sseData({
          'choices': [
            {
              'delta': {'content': 'visible'},
              'finish_reason': null,
            }
          ],
        }),
        sseData({
          'choices': [
            {
              'delta': {'reasoning_content': 'state'},
              'finish_reason': null,
            }
          ],
        }),
        sseData({
          'choices': [
            {
              'delta': {},
              'finish_reason': 'stop',
            }
          ],
        }, delimiter: false),
      ]);

      expect(events.whereType<TextDelta>().map((e) => e.text), ['visible']);
      expect(events.whereType<ReasoningDelta>().map((e) => e.text), [
        'hidden ',
        'state',
      ]);
      final done = events.whereType<StreamDone>().single;
      final textBlock = done.response.content.single;
      expect(textBlock.text, 'visible');
      expect(textBlock.reasoningContent, 'hidden state');
    });

    test('reconnects OpenAI streams by resetting emitted text', () async {
      var requestCount = 0;
      final events = await collectOpenAiStreamEventsWithHandler(
        (request) async {
          requestCount++;
          if (requestCount == 1) {
            request.response.contentLength = 1024;
            request.response.write(sseData({
              'choices': [
                {
                  'delta': {'content': 'old partial'},
                  'finish_reason': null,
                }
              ],
            }));
            await request.response.flush();
            await closeIncompleteResponse(request.response);
            return;
          }

          request.response.write(sseData({
            'choices': [
              {
                'delta': {'content': 'new '},
                'finish_reason': null,
              }
            ],
          }));
          request.response.write(sseData({
            'choices': [
              {
                'delta': {'content': 'answer'},
                'finish_reason': null,
              }
            ],
          }));
          request.response.write(sseData({
            'choices': [
              {
                'delta': {},
                'finish_reason': 'stop',
              }
            ],
            'usage': {
              'prompt_tokens': 1,
              'completion_tokens': 1,
            },
          }));
          request.response.write('data: [DONE]\n\n');
          await request.response.close();
        },
      );

      expect(requestCount, 2);
      expect(events.whereType<StreamError>().map((e) => e.message), isEmpty);
      final resetIndex = events.indexWhere((event) => event is StreamReset);
      expect(resetIndex, isNonNegative);
      if (resetIndex > 0) {
        expect(
          events
              .take(resetIndex)
              .whereType<TextDelta>()
              .map((e) => e.text)
              .join(),
          'old partial',
        );
      }
      expect(
        events
            .skip(resetIndex + 1)
            .whereType<TextDelta>()
            .map((e) => e.text)
            .join(),
        'new answer',
      );
      final done = events.whereType<StreamDone>().single;
      expect(done.response.content.single.text, 'new answer');
    });

    test('reconnects Anthropic streams by resetting emitted text', () async {
      var requestCount = 0;
      final events = await collectAnthropicStreamEventsWithHandler(
        (request) async {
          requestCount++;
          if (requestCount == 1) {
            request.response.contentLength = 1024;
          }
          request.response.write(sseData({
            'type': 'message_start',
            'message': {
              'usage': {'input_tokens': 1},
            },
          }));
          request.response.write(sseData({
            'type': 'content_block_start',
            'content_block': {'type': 'text'},
          }));
          request.response.write(sseData({
            'type': 'content_block_delta',
            'delta': {
              'type': 'text_delta',
              'text': requestCount == 1 ? 'old partial' : 'new answer',
            },
          }));
          await request.response.flush();

          if (requestCount == 1) {
            await closeIncompleteResponse(request.response);
            return;
          }

          request.response.write(sseData({'type': 'content_block_stop'}));
          request.response.write(sseData({
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
            'usage': {'output_tokens': 1},
          }));
          request.response.write(sseData({'type': 'message_stop'}));
          await request.response.close();
        },
      );

      expect(requestCount, 2);
      expect(events.whereType<StreamError>().map((e) => e.message), isEmpty);
      final resetIndex = events.indexWhere((event) => event is StreamReset);
      expect(resetIndex, isNonNegative);
      if (resetIndex > 0) {
        expect(
          events
              .take(resetIndex)
              .whereType<TextDelta>()
              .map((e) => e.text)
              .join(),
          'old partial',
        );
      }
      expect(
        events
            .skip(resetIndex + 1)
            .whereType<TextDelta>()
            .map((e) => e.text)
            .join(),
        'new answer',
      );
      final done = events.whereType<StreamDone>().single;
      expect(done.response.content.single.text, 'new answer');
    });

    test('reconnect reset prevents Anthropic tool input splicing', () async {
      var requestCount = 0;
      final events = await collectAnthropicStreamEventsWithHandler(
        (request) async {
          requestCount++;
          if (requestCount == 1) {
            request.response.contentLength = 1024;
          }
          request.response.write(sseData({
            'type': 'message_start',
            'message': {
              'usage': {'input_tokens': 1},
            },
          }));
          request.response.write(sseData({
            'type': 'content_block_start',
            'content_block': {
              'type': 'tool_use',
              'id': requestCount == 1 ? 'tool-old' : 'tool-new',
              'name': 'lookup',
            },
          }));
          request.response.write(sseData({
            'type': 'content_block_delta',
            'delta': {
              'type': 'input_json_delta',
              'partial_json': requestCount == 1 ? '{"q":"old' : '{"q":"new"}',
            },
          }));
          await request.response.flush();
          if (requestCount == 1) {
            await closeIncompleteResponse(request.response);
            return;
          }
          request.response.write(sseData({'type': 'content_block_stop'}));
          request.response.write(sseData({
            'type': 'message_delta',
            'delta': {'stop_reason': 'tool_use'},
          }));
          request.response.write(sseData({'type': 'message_stop'}));
          await request.response.close();
        },
      );

      expect(requestCount, 2);
      final resetIndex = events.indexWhere((event) => event is StreamReset);
      expect(resetIndex, isNonNegative);
      expect(
        events
            .skip(resetIndex + 1)
            .whereType<ToolInputDelta>()
            .map((e) => e.json)
            .join(),
        '{"q":"new"}',
      );
      final done = events.whereType<StreamDone>().single;
      final toolBlock = done.response.content.single;
      expect(toolBlock.toolUseId, 'tool-new');
      expect(toolBlock.rawToolInputJson, '{"q":"new"}');
      expect(toolBlock.toolInput, {'q': 'new'});
    });
  });
}

Future<void> closeIncompleteResponse(HttpResponse response) async {
  try {
    await response.close();
  } on HttpException {
    // The incomplete response is intentional: it simulates a dropped stream.
  }
}

Future<String> sanitizedErrorBody(String responseBody) async {
  final error = await openAiChatError(400, responseBody);
  const marker = 'OpenAI API error (400): ';
  final start = error.indexOf(marker);
  expect(start, isNonNegative);
  return error.substring(start + marker.length);
}

Future<String> openAiChatError(int statusCode, String responseBody) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.statusCode = statusCode;
    request.response.write(responseBody);
    await request.response.close();
  });

  final service = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: 'gpt-test',
    baseUrl: 'http://127.0.0.1:${server.port}',
  ));
  try {
    await service.chat(system: '', messages: const [], tools: const []);
  } catch (e) {
    return e.toString();
  } finally {
    service.dispose();
    await server.close(force: true);
  }
  fail('Expected chat request to fail');
}

Future<LlmResponse> delayedOpenAiChat({
  required bool Function() isInBackground,
  required Duration responseDelay,
  required Duration requestTimeout,
  Duration? requestMaxWallClock,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await utf8.decoder.bind(request).join();
    await Future<void>.delayed(responseDelay);
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'choices': [
        {
          'message': {'content': 'ok after background'},
          'finish_reason': 'stop',
        }
      ],
    }));
    await request.response.close();
  });

  final service = LlmService(
    LlmConfig.openai(
      apiKey: 'sk-test',
      model: 'gpt-test',
      baseUrl: 'http://127.0.0.1:${server.port}',
    ),
    isInBackground: isInBackground,
    requestTimeout: requestTimeout,
    requestMaxWallClock: requestMaxWallClock,
  );
  try {
    return await service.chat(system: '', messages: const [], tools: const []);
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

bool bodyContainsReasoningContent(Map<String, dynamic> body) {
  return jsonEncode(body).contains('reasoning_content');
}

Future<List<Map<String, dynamic>>> captureOpenAiChatBodiesForReasoning400({
  required String model,
  required String firstErrorBody,
  required List<Map<String, dynamic>> messages,
  bool expectSuccess = true,
}) async {
  final bodies = <Map<String, dynamic>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join())
        as Map<String, dynamic>;
    bodies.add(body);

    if (bodies.length == 1) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(firstErrorBody);
    } else {
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'choices': [
          {
            'message': {'content': 'ok'},
            'finish_reason': 'stop',
          }
        ],
      }));
    }
    await request.response.close();
  });

  final service = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: model,
    baseUrl: 'http://127.0.0.1:${server.port}',
  ));
  try {
    await service.chat(system: '', messages: messages, tools: const []);
    if (!expectSuccess) fail('Expected chat request to fail');
    return bodies;
  } catch (_) {
    if (expectSuccess) rethrow;
    return bodies;
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

Future<int> requestCountWhenFirstStatusIs(int statusCode) async {
  var count = 0;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    count++;
    if (count == 1) {
      request.response.statusCode = statusCode;
      request.response.write('retry me');
    } else {
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'choices': [
          {
            'message': {'content': 'ok'},
            'finish_reason': 'stop',
          }
        ],
      }));
    }
    await request.response.close();
  });

  final service = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: 'gpt-test',
    baseUrl: 'http://127.0.0.1:${server.port}',
  ));
  try {
    await service.chat(system: '', messages: const [], tools: const []);
    return count;
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

Future<int> requestCountForAlwaysStatus(int statusCode) async {
  var count = 0;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    count++;
    request.response.statusCode = statusCode;
    request.response.write('do not retry');
    await request.response.close();
  });

  final service = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: 'gpt-test',
    baseUrl: 'http://127.0.0.1:${server.port}',
  ));
  try {
    await service.chat(system: '', messages: const [], tools: const []);
  } catch (_) {
    return count;
  } finally {
    service.dispose();
    await server.close(force: true);
  }
  fail('Expected chat request to fail');
}

Future<List<Map<String, dynamic>>>
    captureTokenFallbackBodiesForTwoModels() async {
  LlmService.clearTokenKeyOverrides();
  final bodies = <Map<String, dynamic>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join())
        as Map<String, dynamic>;
    bodies.add(body);

    if (body['model'] == 'legacy-model' && body.containsKey('max_tokens')) {
      request.response.statusCode = 400;
      request.response.write('use max_completion_tokens instead of max_tokens');
    } else if (body['model'] == 'gpt-test' &&
        body.containsKey('max_completion_tokens')) {
      request.response.statusCode = 400;
      request.response.write('use max_tokens instead of max_completion_tokens');
    } else {
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'choices': [
          {
            'message': {'content': 'ok'},
            'finish_reason': 'stop',
          }
        ],
      }));
    }
    await request.response.close();
  });

  final baseUrl = 'http://127.0.0.1:${server.port}';
  final legacyService = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: 'legacy-model',
    baseUrl: baseUrl,
  ));
  final currentService = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: 'gpt-test',
    baseUrl: baseUrl,
  ));
  try {
    await legacyService.chat(system: '', messages: const [], tools: const []);
    await currentService.chat(system: '', messages: const [], tools: const []);
    return bodies;
  } finally {
    legacyService.dispose();
    currentService.dispose();
    await server.close(force: true);
    LlmService.clearTokenKeyOverrides();
  }
}

Future<List<Map<String, dynamic>>>
    captureTokenFallbackBodiesWithManualClear() async {
  LlmService.clearTokenKeyOverrides();
  final bodies = <Map<String, dynamic>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join())
        as Map<String, dynamic>;
    bodies.add(body);

    if (body.containsKey('max_tokens')) {
      request.response.statusCode = 400;
      request.response.write('use max_completion_tokens instead of max_tokens');
    } else {
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'choices': [
          {
            'message': {'content': 'ok'},
            'finish_reason': 'stop',
          }
        ],
      }));
    }
    await request.response.close();
  });

  Future<void> sendLegacyRequest() async {
    final service = LlmService(LlmConfig.openai(
      apiKey: 'sk-test',
      model: 'legacy-model',
      baseUrl: 'http://127.0.0.1:${server.port}',
    ));
    try {
      await service.chat(system: '', messages: const [], tools: const []);
    } finally {
      service.dispose();
    }
  }

  try {
    await sendLegacyRequest();
    LlmService.clearTokenKeyOverrides();
    await sendLegacyRequest();
    return bodies;
  } finally {
    await server.close(force: true);
    LlmService.clearTokenKeyOverrides();
  }
}

class CapturedLlmRequest {
  final Uri uri;
  final Map<String, dynamic> body;

  const CapturedLlmRequest({
    required this.uri,
    required this.body,
  });
}

Future<Map<String, dynamic>> captureAnthropicBody({
  required String model,
}) async =>
    (await captureAnthropicRequest(model: model)).body;

Future<CapturedLlmRequest> captureAnthropicRequest({
  required String model,
  String system = '',
  List<Map<String, dynamic>> messages = const [],
  List<ToolDefinition> tools = const [],
  String Function(int port)? baseUrlForPort,
  CapabilityRegistry capabilityRegistry = CapabilityRegistry.instance,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final capturedRequest = Completer<CapturedLlmRequest>();
  server.listen((request) async {
    final body = await utf8.decoder.bind(request).join();
    if (!capturedRequest.isCompleted) {
      capturedRequest.complete(CapturedLlmRequest(
        uri: request.uri,
        body: jsonDecode(body) as Map<String, dynamic>,
      ));
    }
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'stop_reason': 'end_turn',
      'content': [
        {'type': 'text', 'text': 'ok'}
      ],
    }));
    await request.response.close();
  });

  final service = LlmService(
      LlmConfig.anthropic(
        apiKey: 'sk-test',
        model: model,
        baseUrl: baseUrlForPort?.call(server.port) ??
            'http://127.0.0.1:${server.port}',
      ),
      capabilityRegistry: capabilityRegistry);
  try {
    await service.chat(system: system, messages: messages, tools: tools);
    return await capturedRequest.future;
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

Future<LlmResponse> anthropicChatResponseWithBody(
  Map<String, dynamic> responseBody,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await utf8.decoder.bind(request).join();
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(responseBody));
    await request.response.close();
  });

  final service = LlmService(LlmConfig.anthropic(
    apiKey: 'sk-test',
    model: 'claude-sonnet-4-20250514',
    baseUrl: 'http://127.0.0.1:${server.port}',
  ));
  try {
    return await service.chat(
      system: '',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
      tools: const [],
    );
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

Future<Map<String, dynamic>> captureOpenAiBody({
  required String model,
}) async =>
    (await captureOpenAiRequest(model: model)).body;

Future<CapturedLlmRequest> captureOpenAiRequest({
  required String model,
  String system = '',
  List<Map<String, dynamic>> messages = const [],
  List<ToolDefinition> tools = const [],
  String Function(int port)? baseUrlForPort,
  CapabilityRegistry capabilityRegistry = CapabilityRegistry.instance,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final capturedRequest = Completer<CapturedLlmRequest>();
  server.listen((request) async {
    final body = await utf8.decoder.bind(request).join();
    if (!capturedRequest.isCompleted) {
      capturedRequest.complete(CapturedLlmRequest(
        uri: request.uri,
        body: jsonDecode(body) as Map<String, dynamic>,
      ));
    }
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'choices': [
        {
          'message': {'content': 'ok'},
          'finish_reason': 'stop',
        }
      ],
    }));
    await request.response.close();
  });

  final service = LlmService(
      LlmConfig.openai(
        apiKey: 'sk-test',
        model: model,
        baseUrl: baseUrlForPort?.call(server.port) ??
            'http://127.0.0.1:${server.port}',
      ),
      capabilityRegistry: capabilityRegistry);
  try {
    await service.chat(system: system, messages: messages, tools: tools);
    return await capturedRequest.future;
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

Future<LlmResponse> openAiChatResponseWithBody(
  Map<String, dynamic> responseBody,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await utf8.decoder.bind(request).join();
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(responseBody));
    await request.response.close();
  });

  final service = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: 'gpt-test',
    baseUrl: 'http://127.0.0.1:${server.port}',
  ));
  try {
    return await service.chat(
      system: '',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
      tools: const [],
    );
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

class _NoToolsCapabilityRegistry extends CapabilityRegistry {
  const _NoToolsCapabilityRegistry();

  @override
  ResolvedModelProfile resolve({
    required ApiFormat apiFormat,
    required String baseUrl,
    required String model,
    CapabilityOverride? override,
  }) {
    final resolved = CapabilityRegistry.instance.resolve(
      apiFormat: apiFormat,
      baseUrl: baseUrl,
      model: model,
      override: override,
    );
    return ResolvedModelProfile(
      modelId: resolved.modelId,
      providerKey: resolved.providerKey,
      provider: resolved.provider,
      capabilities: resolved.capabilities.copyWith(
        supportsTools: false,
      ),
    );
  }
}

void expectNoProviderToolSyntax(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      expect(entry.key, isNot('tool_calls'));
      expect(entry.key, isNot('tool_call_id'));
      if (entry.key == 'role') {
        expect(entry.value, isNot('tool'));
      }
      if (entry.key == 'type') {
        expect(entry.value, isNot('tool_use'));
        expect(entry.value, isNot('tool_result'));
      }
      expectNoProviderToolSyntax(entry.value);
    }
  } else if (value is Iterable) {
    for (final item in value) {
      expectNoProviderToolSyntax(item);
    }
  }
}

String sseData(Map<String, dynamic> data, {bool delimiter = true}) {
  return 'data: ${jsonEncode(data)}${delimiter ? '\n\n' : '\n'}';
}

Future<List<StreamEvent>> collectAnthropicStreamEvents(
  List<String> responseChunks,
) async {
  return collectAnthropicStreamEventsWithHandler((request) async {
    for (final chunk in responseChunks) {
      request.response.write(chunk);
      await request.response.flush();
    }
    await request.response.close();
  });
}

Future<List<StreamEvent>> collectAnthropicStreamEventsWithHandler(
  Future<void> Function(HttpRequest request) handleRequest,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await utf8.decoder.bind(request).join();
    request.response.statusCode = 200;
    request.response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    await handleRequest(request);
  });

  final service = LlmService(LlmConfig.anthropic(
    apiKey: 'sk-test',
    model: 'claude-sonnet-4-20250514',
    baseUrl: 'http://127.0.0.1:${server.port}',
  ));
  try {
    return await service.chatStream(
      system: '',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
      tools: const [],
    ).toList();
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

Future<List<StreamEvent>> collectOpenAiStreamEvents(
  List<String> responseChunks,
) async {
  return collectOpenAiStreamEventsWithHandler((request) async {
    for (final chunk in responseChunks) {
      request.response.write(chunk);
      await request.response.flush();
    }
    await request.response.close();
  });
}

Future<List<StreamEvent>> collectOpenAiStreamEventsWithHandler(
  Future<void> Function(HttpRequest request) handleRequest, {
  String model = 'gpt-test',
  List<Map<String, dynamic>> messages = const [
    {'role': 'user', 'content': 'hi'},
  ],
  void Function(Map<String, dynamic> body)? onRequestBody,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final body = await utf8.decoder.bind(request).join();
    if (onRequestBody != null) {
      onRequestBody(jsonDecode(body) as Map<String, dynamic>);
    }
    request.response.statusCode = 200;
    request.response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    await handleRequest(request);
  });

  final service = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: model,
    baseUrl: 'http://127.0.0.1:${server.port}',
  ));
  try {
    return await service.chatStream(
      system: '',
      messages: messages,
      tools: const [],
    ).toList();
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

Future<List<Map<String, dynamic>>> captureOpenAiStreamBodies() async {
  final bodies = <Map<String, dynamic>>[];
  await collectOpenAiStreamEventsWithHandler(
    (request) async {
      request.response.write(sseData({
        'choices': [
          {
            'delta': {'content': 'ok'},
            'finish_reason': null,
          }
        ],
      }));
      request.response.write(sseData({
        'choices': [
          {
            'delta': {},
            'finish_reason': 'stop',
          }
        ],
      }, delimiter: false));
      await request.response.close();
    },
    onRequestBody: bodies.add,
  );
  return bodies;
}
