import 'package:clawchat/models/chat_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ContextSummary', () {
    test('persists through ChatSession JSON', () {
      final summary = ContextSummary(
        version: 1,
        text: '## Goal\nKeep context',
        coveredMessageCount: 3,
        coveredDigest: 'abc123',
        sourceEstimatedTokens: 1200,
        summaryEstimatedTokens: 180,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
        model: 'claude-test',
        apiFormat: 'anthropic',
      );
      final session = ChatSession(
        id: 'summary_session',
        messages: [ChatMessage.user('hello')],
        contextSummary: summary,
      );

      final restored = ChatSession.fromJson(session.toJson());

      expect(restored.contextSummary, isNotNull);
      expect(restored.contextSummary!.text, summary.text);
      expect(restored.contextSummary!.coveredMessageCount, 3);
      expect(restored.contextSummary!.coveredDigest, 'abc123');
      expect(restored.contextSummary!.sourceEstimatedTokens, 1200);
      expect(restored.contextSummary!.summaryEstimatedTokens, 180);
      expect(restored.contextSummary!.model, 'claude-test');
      expect(restored.contextSummary!.apiFormat, 'anthropic');
    });

    test('loads legacy session without context summary', () {
      final restored = ChatSession.fromJson({
        'id': 'legacy',
        'title': 'Legacy',
        'createdAt': DateTime(2026).toIso8601String(),
        'updatedAt': DateTime(2026).toIso8601String(),
        'messages': [
          ChatMessage.user('old').toJson(),
        ],
      });

      expect(restored.contextSummary, isNull);
      expect(restored.messages.single.textContent, 'old');
    });
  });

  group('ChatMessage reasoning_content', () {
    test('persists assistant text reasoning content through JSON', () {
      final message = ChatMessage.assistant([
        {
          'type': 'text',
          'text': 'answer',
          'reasoning_content': 'internal reasoning',
        },
      ]);

      final restored = ChatMessage.fromJson(message.toJson());

      expect(restored.textContent, 'answer');
      expect(
        (restored.content.single as TextContent).reasoningContent,
        'internal reasoning',
      );
    });

    test('preserves very long reasoning content through session JSON', () {
      final longReasoning = List.generate(
        2000,
        (index) => 'reasoning step $index',
      ).join('\n');
      final session = ChatSession(
        id: 'long_reasoning_session',
        messages: [
          ChatMessage.assistant([
            {
              'type': 'text',
              'text': 'final answer',
              'reasoning_content': longReasoning,
            },
          ]),
        ],
      );

      final restored = ChatSession.fromJson(session.toJson());
      final textContent = restored.messages.single.content.single;

      expect(restored.messages.single.textContent, 'final answer');
      expect(textContent, isA<TextContent>());
      expect((textContent as TextContent).reasoningContent, longReasoning);
    });

    test('loads legacy string content with top-level reasoning content', () {
      final restored = ChatMessage.fromJson({
        'role': 'assistant',
        'timestamp': DateTime(2026).toIso8601String(),
        'content': 'answer',
        'reasoning_content': 'internal reasoning',
      });

      expect(restored.textContent, 'answer');
      expect(
        (restored.content.single as TextContent).reasoningContent,
        'internal reasoning',
      );
    });

    test('includes reasoning_content in assistant API messages only', () {
      final assistant = ChatMessage(
        role: 'assistant',
        content: [
          TextContent(
            'answer',
            reasoningContent: 'internal reasoning',
          ),
        ],
      );
      final user = ChatMessage(
        role: 'user',
        content: [
          TextContent(
            'question',
            reasoningContent: 'should not be sent',
          ),
        ],
      );

      expect(assistant.toApiJson(), {
        'role': 'assistant',
        'content': 'answer',
        'reasoning_content': 'internal reasoning',
      });
      expect(user.toApiJson(), {
        'role': 'user',
        'content': 'question',
      });
    });
  });

  group('AssistantErrorMetadata', () {
    test('persists sanitized assistant error metadata through message JSON',
        () {
      final message = ChatMessage.assistantError(
        error: const AssistantErrorMetadata(
          message: 'OpenAI API error (503): temporarily unavailable',
          code: 'provider_unavailable',
          canRetry: true,
          source: 'provider_failure',
          fallbackReasonCode: 'no_configured_candidate',
        ),
        timestamp: DateTime.utc(2026, 1, 3),
      );

      final restored = ChatMessage.fromJson(message.toJson());

      expect(restored.hasAssistantError, isTrue);
      expect(restored.assistantError!.message, contains('503'));
      expect(restored.assistantError!.code, 'provider_unavailable');
      expect(restored.assistantError!.canRetry, isTrue);
      expect(restored.assistantError!.source, 'provider_failure');
      expect(
        restored.assistantError!.fallbackReasonCode,
        'no_configured_candidate',
      );
    });

    test('session API messages omit assistant error markers', () {
      final session = ChatSession(
        id: 'failed_session',
        messages: [
          ChatMessage.user('hello'),
          ChatMessage.assistantError(
            error: const AssistantErrorMetadata(
              message: 'provider failed',
              code: 'provider_unavailable',
              canRetry: true,
            ),
          ),
        ],
      );

      expect(session.toApiMessages(), [
        {'role': 'user', 'content': 'hello'},
      ]);
    });
  });

  group('ToolResultContent dual-track payload', () {
    test('round-trips new JSON while preserving ForUser output', () {
      final content = ToolResultContent(
        toolUseId: 'call_1',
        output: 'full user-visible output',
        forLlm: '{"output":"compact"}',
        summary: 'compact summary',
        metadata: const {
          'toolName': 'bash',
          'originalChars': 24,
        },
      );

      final restored = ToolResultContent.fromToolResultJson(content.toJson());

      expect(restored.output, 'full user-visible output');
      expect(restored.llmOutput, '{"output":"compact"}');
      expect(restored.summary, 'compact summary');
      expect(restored.metadata['toolName'], 'bash');
      expect(restored.toJson(), {
        'type': 'tool_result',
        'tool_use_id': 'call_1',
        'output': 'full user-visible output',
        'for_llm': '{"output":"compact"}',
        'summary': 'compact summary',
        'metadata': {
          'toolName': 'bash',
          'originalChars': 24,
        },
        'is_error': false,
      });
    });

    test('loads legacy output and API-like content fields', () {
      final legacy = ToolResultContent.fromToolResultJson({
        'type': 'tool_result',
        'tool_use_id': 'call_legacy',
        'output': 'legacy output',
      });
      final apiLike = ToolResultContent.fromToolResultJson({
        'type': 'tool_result',
        'tool_use_id': 'call_api',
        'content': ['line 1', 'line 2'],
      });

      expect(legacy.output, 'legacy output');
      expect(legacy.llmOutput, 'legacy output');
      expect(apiLike.output, 'line 1\nline 2');
      expect(apiLike.llmOutput, 'line 1\nline 2');
    });

    test('toApiJson sends ForLLM while toJson keeps ForUser', () {
      final message = ChatMessage.toolResults([
        {
          'type': 'tool_result',
          'tool_use_id': 'call_1',
          'content': 'compact for model',
          'output': 'complete user output',
          'for_llm': 'compact for model',
          'summary': 'short summary',
        },
      ]);

      expect(message.toApiJson(), {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'call_1',
            'content': 'compact for model',
          },
        ],
      });
      expect(message.toJson()['content'], [
        {
          'type': 'tool_result',
          'tool_use_id': 'call_1',
          'output': 'complete user output',
          'for_llm': 'compact for model',
          'summary': 'short summary',
          'is_error': false,
        },
      ]);
    });
  });

  group('ChatMessage alternatives', () {
    test('textContent follows active alternative without mutating latest text',
        () {
      final message = ChatMessage(
        role: 'assistant',
        content: [TextContent('latest')],
        alternatives: ['first'],
      );

      expect(message.textContent, 'latest');
      expect(message.displayIndex, 2);

      message.activeAlternative = 0;

      expect(message.textContent, 'first');
      expect(message.displayIndex, 1);
      expect((message.content.single as TextContent).text, 'latest');
    });

    test('API payload uses the active displayed alternative', () {
      final session = ChatSession(
        id: 'alt_api',
        messages: [
          ChatMessage(
            role: 'assistant',
            content: [TextContent('latest')],
            alternatives: ['first'],
            activeAlternative: 0,
          ),
        ],
      );

      expect(session.toApiMessages(), [
        {'role': 'assistant', 'content': 'first'},
      ]);
    });

    test('withNewAlternative preserves active alternative and latest text', () {
      final message = ChatMessage(
        role: 'assistant',
        content: [TextContent('latest')],
        alternatives: ['first'],
        activeAlternative: 0,
      );

      final updated = message.withNewAlternative([TextContent('new latest')]);

      expect(updated.textContent, 'new latest');
      expect(updated.alternatives, ['first', 'latest']);
    });
  });
}
