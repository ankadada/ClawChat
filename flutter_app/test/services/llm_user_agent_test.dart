import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/services/app_http.dart';
import 'package:clawchat/services/llm_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fixedUserAgent = AppRuntimeInfo.forTesting().userAgent;
  tearDown(AppHttpClientRegistry.resetForTesting);

  test('Anthropic and OpenAI native paths send the fixed User-Agent', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final userAgents = <String?>[];
    var anthropicMessages = 0;
    var openAiCompletions = 0;

    server.listen((request) async {
      userAgents.add(request.headers.value(HttpHeaders.userAgentHeader));
      await request.drain<void>();

      if (request.uri.path == '/v1/models') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'data': [
            {'id': 'dummy-model'},
          ],
        }));
      } else if (request.uri.path == '/v1/messages') {
        anthropicMessages += 1;
        if (anthropicMessages == 1) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'content': [
              {'type': 'text', 'text': 'ok'},
            ],
            'stop_reason': 'end_turn',
            'usage': {'input_tokens': 1, 'output_tokens': 1},
          }));
        } else {
          request.response.headers.contentType =
              ContentType('text', 'event-stream', charset: 'utf-8');
          request.response.write(
            'data: {"type":"message_start","message":{"usage":{"input_tokens":1}}}\n\n',
          );
          request.response.write('data: {"type":"message_stop"}\n\n');
        }
      } else if (request.uri.path == '/v1/chat/completions') {
        openAiCompletions += 1;
        if (openAiCompletions == 1) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
            'usage': {'prompt_tokens': 1, 'completion_tokens': 1},
          }));
        } else {
          request.response.headers.contentType =
              ContentType('text', 'event-stream', charset: 'utf-8');
          request.response.write(
            'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":null}]}\n\n',
          );
          request.response.write(
            'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n',
          );
          request.response.write('data: [DONE]\n\n');
        }
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final baseUrl = 'http://127.0.0.1:${server.port}';
    final anthropic = LlmService(LlmConfig.anthropic(
      apiKey: 'dummy-key',
      model: 'dummy-model',
      baseUrl: baseUrl,
    ));
    final openAi = LlmService(LlmConfig.openai(
      apiKey: 'dummy-key',
      model: 'dummy-model',
      baseUrl: baseUrl,
    ));

    try {
      await LlmService.fetchModels(
        apiFormat: 'anthropic',
        apiKey: 'dummy-key',
        baseUrl: baseUrl,
      );
      await anthropic.chat(system: '', messages: const [], tools: const []);
      await anthropic
          .chatStream(system: '', messages: const [], tools: const []).toList();

      await LlmService.fetchModels(
        apiFormat: 'openai',
        apiKey: 'dummy-key',
        baseUrl: baseUrl,
      );
      await openAi.chat(system: '', messages: const [], tools: const []);
      await openAi
          .chatStream(system: '', messages: const [], tools: const []).toList();
    } finally {
      anthropic.dispose();
      openAi.dispose();
      await server.close(force: true);
    }

    expect(userAgents, hasLength(6));
    expect(userAgents, everyElement(fixedUserAgent));
  });

  test('LLM services reuse the shared native connection pool', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final remotePorts = <int>[];
    server.listen((request) async {
      remotePorts.add(request.connectionInfo!.remotePort);
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': 'ok'},
            'finish_reason': 'stop',
          },
        ],
      }));
      await request.response.close();
    });

    final baseUrl = 'http://127.0.0.1:${server.port}';
    final first = _openAiService(baseUrl);
    final second = _openAiService(baseUrl);
    try {
      await first.chat(system: '', messages: const [], tools: const []);
      await second.chat(system: '', messages: const [], tools: const []);
    } finally {
      first.dispose();
      second.dispose();
      await server.close(force: true);
    }

    expect(remotePorts, hasLength(2));
    expect(remotePorts.toSet(), hasLength(1));
  });

  test('OpenAI retry keeps the fixed User-Agent', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final userAgents = <String?>[];
    server.listen((request) async {
      userAgents.add(request.headers.value(HttpHeaders.userAgentHeader));
      await request.drain<void>();
      if (userAgents.length == 1) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('retry');
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'ok'},
              'finish_reason': 'stop',
            },
          ],
        }));
      }
      await request.response.close();
    });

    final service = _openAiService('http://127.0.0.1:${server.port}');
    try {
      await service.chat(system: '', messages: const [], tools: const []);
    } finally {
      service.dispose();
      await server.close(force: true);
    }

    expect(userAgents, [fixedUserAgent, fixedUserAgent]);
  });

  test('OpenAI compatibility fallback keeps the fixed User-Agent', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final userAgents = <String?>[];
    server.listen((request) async {
      userAgents.add(request.headers.value(HttpHeaders.userAgentHeader));
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      if (userAgents.length == 1) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(jsonEncode({
          'error': {'message': 'max_tokens is unsupported'},
        }));
      } else {
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'ok'},
              'finish_reason': 'stop',
            },
          ],
        }));
      }
      await request.response.close();
    });

    final service = _openAiService('http://127.0.0.1:${server.port}');
    try {
      await service.chat(system: '', messages: const [], tools: const []);
    } finally {
      service.dispose();
      LlmService.clearTokenKeyOverrides();
      await server.close(force: true);
    }

    expect(userAgents, [fixedUserAgent, fixedUserAgent]);
  });

  test('cancelling and disposing one service leaves another request healthy',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    var requestCount = 0;

    server.listen((request) async {
      requestCount += 1;
      final current = requestCount;
      await request.drain<void>();
      if (current == 1) {
        request.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        request.response.write(
          'data: {"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}\n\n',
        );
        await request.response.flush();
        firstStarted.complete();
        await releaseFirst.future;
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'independent'},
              'finish_reason': 'stop',
            },
          ],
        }));
      }
      await request.response.close();
    });

    final baseUrl = 'http://127.0.0.1:${server.port}';
    final first = _openAiService(baseUrl);
    final second = _openAiService(baseUrl);
    final third = _openAiService(baseUrl);
    final subscription = first.chatStream(
        system: '', messages: const [], tools: const []).listen((_) {});

    try {
      await firstStarted.future;
      final cancelFuture = subscription.cancel();
      first.dispose();

      final response =
          await second.chat(system: '', messages: const [], tools: const []);
      expect(response.content.single.text, 'independent');

      releaseFirst.complete();
      await cancelFuture;

      final later =
          await third.chat(system: '', messages: const [], tools: const []);
      expect(later.content.single.text, 'independent');
    } finally {
      if (!releaseFirst.isCompleted) releaseFirst.complete();
      first.dispose();
      second.dispose();
      third.dispose();
      await server.close(force: true);
    }

    expect(requestCount, 3);
  });
}

LlmService _openAiService(String baseUrl) {
  return LlmService(LlmConfig.openai(
    apiKey: 'dummy-key',
    model: 'dummy-model',
    baseUrl: baseUrl,
  ));
}
