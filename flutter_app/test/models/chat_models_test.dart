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
