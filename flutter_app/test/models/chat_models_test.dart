import 'package:clawchat/models/chat_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
