import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/services/chat_context_utils.dart';
import 'package:clawchat/services/context_summary_service.dart';
import 'package:clawchat/services/llm_service.dart';
import 'package:clawchat/services/tools/tool_result_formatter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const estimator = TokenEstimator();
  const llmConfig = LlmConfig(
    format: ApiFormat.anthropic,
    apiKey: 'sk-test',
    model: 'claude-test',
    baseUrl: 'https://api.example.test',
  );

  ContextSummaryRequest request({
    List<Map<String, dynamic>> messages = const [
      {'role': 'user', 'content': 'Please inspect lib/main.dart'},
    ],
    ContextSummary? existingSummary,
    int summaryBudget = 400,
    int? maxInputTokens,
    LlmConfig config = llmConfig,
  }) {
    return ContextSummaryRequest(
      messages: messages,
      existingSummary: existingSummary,
      llmConfig: config,
      summaryBudget: summaryBudget,
      coveredDigest: ChatContextUtils.digestMessages(messages),
      coveredMessageCount: messages.length,
      sourceEstimatedTokens: estimator.estimateMessages(messages),
      estimator: estimator,
      maxInputTokens: maxInputTokens,
    );
  }

  test('builds rolling update prompt with existing summary', () {
    final service = ContextSummaryService(
      llmFactory: (config) => _FakeLlmService(config),
    );
    final prompt = service.buildSummaryUserPrompt(
      messages: const [
        {'role': 'assistant', 'content': 'New finding'},
      ],
      existingSummary: ContextSummary(
        version: 1,
        text: 'Old summary',
        coveredMessageCount: 1,
        coveredDigest: 'old',
        sourceEstimatedTokens: 100,
        summaryEstimatedTokens: 20,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    );

    expect(prompt, contains('Existing rolling summary'));
    expect(prompt, contains('Old summary'));
    expect(prompt, contains('New earlier conversation'));
    expect(prompt, contains('New finding'));
  });

  test('safe projection removes unsafe metadata and base64 image data', () {
    final projected = ContextSummaryService.safeProjectMessages([
      {
        'role': 'user',
        'content': [
          {
            'type': 'text',
            'text': 'hello',
            'cache_control': {'type': 'ephemeral'},
            'encrypted': 'opaque',
          },
          {
            'type': 'image',
            'filename': 'screen.png',
            'source': {
              'type': 'base64',
              'media_type': 'image/png',
              'data': 'base64-data',
            },
          },
          {
            'type': 'thinking',
            'thinking': 'hidden',
          },
        ],
      },
    ]);

    expect(projected.toString(), isNot(contains('base64-data')));
    expect(projected.toString(), isNot(contains('cache_control')));
    expect(projected.toString(), isNot(contains('encrypted')));
    expect(projected.toString(), isNot(contains('hidden')));
    expect(projected.toString(), contains('screen.png'));
  });

  test('truncates large tool results in safe projection', () {
    final projected = ContextSummaryService.safeProjectMessages([
      {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'call_1',
            'content': 'x' * 3000,
          },
        ],
      },
    ]);

    final content = (projected.single['content'] as List).single as Map;
    expect((content['content'] as String).length, lessThan(1400));
    expect(content['content'], contains('truncated'));
  });

  test('safe projection prefers summary and ForLLM over full output', () {
    final projected = ContextSummaryService.safeProjectMessages([
      {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'call_1',
            'summary': 'summary projection',
            'for_llm': 'compact model projection',
            'content': 'legacy compact projection',
            'output': 'FULL OUTPUT THAT MUST NOT LEAK',
          },
          {
            'type': 'tool_result',
            'tool_use_id': 'call_2',
            'for_llm': 'compact model projection 2',
            'output': 'FULL OUTPUT 2 THAT MUST NOT LEAK',
          },
        ],
      },
    ]);

    final blocks = projected.single['content'] as List;
    expect(blocks.first['content'], 'summary projection');
    expect(blocks.last['content'], 'compact model projection 2');
    expect(projected.toString(), isNot(contains('FULL OUTPUT')));
  });

  test('safe projection uses sanitized tool summary without raw output', () {
    final rawBase64 = 'a' * 900;
    final payload = ToolResultFormatter.generic(
      toolName: 'generic_tool',
      output: 'preview $rawBase64 tail',
    );

    final projected = ContextSummaryService.safeProjectMessages([
      {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'call_1',
            'summary': payload.summary,
            'for_llm': payload.forLlm,
            'output': payload.forUser,
          },
        ],
      },
    ]);

    final serialized = projected.toString();
    expect(serialized, contains('[base64 omitted'));
    expect(serialized, isNot(contains(rawBase64)));
  });

  test('safe projection recursively removes unsafe tool input metadata', () {
    final projected = ContextSummaryService.safeProjectMessages([
      {
        'role': 'assistant',
        'content': [
          {
            'type': 'tool_use',
            'id': 'call_1',
            'name': 'bash',
            'input': {
              'cmd': 'echo ok',
              'nested': {
                'cache_control': {'type': 'ephemeral'},
                'encrypted': 'secret',
                'safe': 'value',
              },
            },
          },
        ],
      },
    ]);

    final serialized = projected.toString();
    expect(serialized, contains('echo ok'));
    expect(serialized, contains('safe'));
    expect(serialized, isNot(contains('cache_control')));
    expect(serialized, isNot(contains('encrypted')));
    expect(serialized, isNot(contains('secret')));
  });

  test('safe projection redacts secrets from text tool input and result', () {
    final projected = ContextSummaryService.safeProjectMessages([
      {
        'role': 'user',
        'content': 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz',
      },
      {
        'role': 'assistant',
        'content': [
          {
            'type': 'tool_use',
            'id': 'call_1',
            'name': 'web_fetch',
            'input': {
              'url': 'https://example.test?token=query-secret',
              'headers': {
                'Authorization':
                    'Bearer header-secret-abcdefghijklmnopqrstuvwxyz',
              },
            },
          },
        ],
      },
      {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'call_1',
            'for_llm': 'api_key=sk-proj-abcdefghijklmnopqrstuvwxyz123456',
            'output': 'FULL OUTPUT sk-proj-abcdefghijklmnopqrstuvwxyz123456',
          },
        ],
      },
    ]);

    final serialized = projected.toString();
    expect(serialized, contains('[redacted: bearer_token]'));
    expect(serialized, contains('[redacted: token]'));
    expect(serialized, contains('[redacted: authorization]'));
    expect(serialized, contains('[redacted: api_key]'));
    expect(serialized, isNot(contains('abcdefghijklmnopqrstuvwxyz')));
    expect(serialized, isNot(contains('query-secret')));
  });

  test('extractive fallback redacts secrets', () {
    final service = ContextSummaryService(
      llmFactory: (config) => _FakeLlmService(config),
    );

    final summary = service.extractiveFallback(request(messages: [
      {
        'role': 'user',
        'content': 'Use api_key=sk-proj-abcdefghijklmnopqrstuvwxyz123456',
      },
      {
        'role': 'assistant',
        'content': [
          {
            'type': 'tool_use',
            'id': 'call_1',
            'name': 'bash',
            'input': {'command': 'echo password=hunter2'},
          },
        ],
      },
    ]));

    expect(summary.text, contains('[redacted: api_key]'));
    expect(summary.text, contains('[redacted: password]'));
    expect(summary.text, isNot(contains('sk-proj-')));
    expect(summary.text, isNot(contains('hunter2')));
  });

  test('sanitizes generated summary before persistence', () async {
    final service = ContextSummaryService(
      llmFactory: (config) => _FakeLlmService(
        config,
        responseText:
            '## Goal\nLeaked api_key=sk-proj-abcdefghijklmnopqrstuvwxyz123456',
      ),
    );

    final summary = await service.generateSummary(request());

    expect(summary.text, contains('[redacted: api_key]'));
    expect(summary.text, isNot(contains('sk-proj-')));
  });

  test('generates summary with LLM config capped to summary budget', () async {
    LlmConfig? observedConfig;
    final service = ContextSummaryService(
      llmFactory: (config) {
        observedConfig = config;
        return _FakeLlmService(
          config,
          responseText: '## Goal\nGenerated summary',
        );
      },
    );

    final summary = await service.generateSummary(request());

    expect(summary.text, contains('Generated summary'));
    expect(summary.version, ContextSummaryService.version);
    expect(summary.coveredMessageCount, 1);
    expect(summary.coveredDigest, isNotEmpty);
    expect(observedConfig!.maxTokens, 400);
    expect(observedConfig!.temperature, 0.2);
    expect(observedConfig!.thinkingBudget, 0);
  });

  test('generateSummary keeps slow LLM request alive while backgrounded',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'choices': [
          {
            'message': {
              'content': '## Goal\nSummary after background wait',
            },
            'finish_reason': 'stop',
          }
        ],
      }));
      await request.response.close();
    });

    var isInBackground = true;
    final service = ContextSummaryService(
      llmFactory: (config) => LlmService(
        config,
        isInBackground: () => isInBackground,
        requestTimeout: const Duration(milliseconds: 10),
        requestMaxWallClock: const Duration(seconds: 10),
      ),
    );

    final summaryFuture = service.generateSummary(request(
      config: LlmConfig.openai(
        apiKey: 'sk-test',
        model: 'gpt-test',
        baseUrl: 'http://127.0.0.1:${server.port}',
      ),
    ));

    final summary = await summaryFuture.timeout(const Duration(seconds: 10));
    isInBackground = false;

    expect(summary.text, contains('Summary after background wait'));
  });

  test('truncates huge summary input before LLM call', () async {
    List<Map<String, dynamic>>? observedMessages;
    final service = ContextSummaryService(
      llmFactory: (config) => _FakeLlmService(
        config,
        responseText: '## Goal\nGenerated summary',
        onChatMessages: (messages) => observedMessages = messages,
      ),
    );
    final messages = [
      {'role': 'user', 'content': 'drop-me ${'x' * 6000}'},
      {'role': 'assistant', 'content': 'keep-me ${'y' * 6000}'},
    ];

    await service.generateSummary(request(
      messages: messages,
      maxInputTokens: 350,
    ));

    final prompt = observedMessages!.single['content'] as String;
    expect(prompt, isNot(contains('drop-me')));
    expect(prompt, contains('keep-me'));
    expect(estimator.estimateText(prompt), lessThanOrEqualTo(350));
  });

  test('truncates overlong generated summary to summary budget', () async {
    final service = ContextSummaryService(
      llmFactory: (config) => _FakeLlmService(
        config,
        responseText: [
          '## Goal',
          'keep ${'x' * 200}',
          '## User Instructions',
          'drop ${'y' * 2000}',
          '## Warnings',
          'drop ${'z' * 2000}',
        ].join('\n'),
      ),
    );

    final summary = await service.generateSummary(request(summaryBudget: 80));

    expect(estimator.estimateText(summary.text), lessThanOrEqualTo(80));
    expect(summary.text, contains('## Goal'));
    expect(summary.text, isNot(contains('## Warnings')));
  });

  test('extractive fallback captures files and tool activity', () {
    final service = ContextSummaryService(
      llmFactory: (config) => _FakeLlmService(config),
    );

    final summary = service.extractiveFallback(request(messages: [
      {'role': 'user', 'content': 'Read lib/main.dart and fix the error'},
      {
        'role': 'assistant',
        'content': [
          {
            'type': 'tool_use',
            'id': 'call_1',
            'name': 'bash',
            'input': {'cmd': 'flutter test'},
          },
        ],
      },
      {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'call_1',
            'content': 'Error: failed',
            'is_error': true,
          },
        ],
      },
    ]));

    expect(summary.text, contains('lib/main.dart'));
    expect(summary.text, contains('flutter test'));
    expect(summary.text, contains('Error: failed'));
  });
}

class _FakeLlmService extends LlmService {
  final String responseText;
  final void Function(List<Map<String, dynamic>> messages)? onChatMessages;

  _FakeLlmService(
    super.config, {
    this.responseText = '## Goal\nSummary',
    this.onChatMessages,
  });

  @override
  Future<LlmResponse> chat({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async {
    onChatMessages?.call(messages);
    return LlmResponse(
      stopReason: 'end_turn',
      content: [
        ContentBlock(type: 'text', text: responseText),
      ],
    );
  }

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    yield StreamDone(await chat(
      system: system,
      messages: messages,
      tools: tools,
    ));
  }
}
