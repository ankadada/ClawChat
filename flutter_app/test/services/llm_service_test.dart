import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/services/llm_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
      final input = 'Keys: sk-aaaaaaaaaa and api-bbbbbbbbbb found';
      final result = await sanitizedErrorBody(input);
      expect(result, isNot(contains('sk-aaaaaaaaaa')));
      expect(result, isNot(contains('api-bbbbbbbbbb')));
      expect('[REDACTED]'.allMatches(result).length, 2);
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

  group('LlmConfig equality', () {
    test('ContentBlock.toJson produces correct text block', () {
      const block = ContentBlock(type: 'text', text: 'hello');
      final json = block.toJson();
      expect(json['type'], 'text');
      expect(json['text'], 'hello');
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

    test('OpenAI-compatible requests use max_completion_tokens', () async {
      final body = await captureOpenAiBody(model: 'gpt-test');

      expect(body['max_completion_tokens'], 8192);
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
      expect(captured.body['max_completion_tokens'], 8192);
      expect(jsonDecode(jsonEncode(captured.body)), captured.body);
    });
  });

  group('LlmService streaming compatibility', () {
    test(
        'accepts Anthropic stream ending without final delimiter or stop event',
        () async {
      final events = await collectAnthropicStreamEvents([
        sseData({
          'type': 'message_start',
          'message': {
            'usage': {'input_tokens': 1},
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

      expect(events.whereType<StreamError>().map((e) => e.message), isEmpty);
      final done = events.whereType<StreamDone>().single;
      expect(done.response.content.single.text, 'ok');
      expect(done.response.inputTokens, 1);
      expect(done.response.outputTokens, 1);
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
          },
        }, delimiter: false),
      ]);

      expect(events.whereType<StreamError>().map((e) => e.message), isEmpty);
      final done = events.whereType<StreamDone>().single;
      expect(done.response.content.single.text, 'ok');
      expect(done.response.stopReason, 'end_turn');
      expect(done.response.inputTokens, 1);
      expect(done.response.outputTokens, 1);
    });
  });
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
  String Function(int port)? baseUrlForPort,
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

  final service = LlmService(LlmConfig.anthropic(
    apiKey: 'sk-test',
    model: model,
    baseUrl:
        baseUrlForPort?.call(server.port) ?? 'http://127.0.0.1:${server.port}',
  ));
  try {
    await service.chat(system: system, messages: messages, tools: const []);
    return await capturedRequest.future;
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
  String Function(int port)? baseUrlForPort,
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

  final service = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: model,
    baseUrl:
        baseUrlForPort?.call(server.port) ?? 'http://127.0.0.1:${server.port}',
  ));
  try {
    await service.chat(system: system, messages: messages, tools: const []);
    return await capturedRequest.future;
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

String sseData(Map<String, dynamic> data, {bool delimiter = true}) {
  return 'data: ${jsonEncode(data)}${delimiter ? '\n\n' : '\n'}';
}

Future<List<StreamEvent>> collectAnthropicStreamEvents(
  List<String> responseChunks,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await utf8.decoder.bind(request).join();
    request.response.statusCode = 200;
    request.response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    for (final chunk in responseChunks) {
      request.response.write(chunk);
      await request.response.flush();
    }
    await request.response.close();
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
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await utf8.decoder.bind(request).join();
    request.response.statusCode = 200;
    request.response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    for (final chunk in responseChunks) {
      request.response.write(chunk);
      await request.response.flush();
    }
    await request.response.close();
  });

  final service = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: 'gpt-test',
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
