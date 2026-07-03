import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/services/usage_summary_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UsageSummaryService', () {
    const service = UsageSummaryService();

    test('aggregates persisted session token usage', () {
      final session = ChatSession(
        id: 'usage',
        messages: [
          ChatMessage.user('hello'),
          ChatMessage(
            role: 'assistant',
            content: [TextContent('world')],
            inputTokens: 100,
            outputTokens: 20,
            cacheReadInputTokens: 30,
            cacheCreationInputTokens: 40,
          ),
          ChatMessage.systemNotice('notice')
            ..inputTokens = 999
            ..outputTokens = 999,
        ],
      );

      final summary = service.forSession(session);

      expect(summary.messageCount, 2);
      expect(summary.messagesWithUsage, 1);
      expect(summary.inputTokens, 100);
      expect(summary.outputTokens, 20);
      expect(summary.cacheReadInputTokens, 30);
      expect(summary.cacheCreationInputTokens, 40);
      expect(summary.totalTokens, 190);
    });

    test('does not double count cached tokens when input includes cache', () {
      final session = ChatSession(
        id: 'openai_usage',
        messages: [
          ChatMessage(
            role: 'assistant',
            content: [TextContent('cached')],
            inputTokens: 100,
            outputTokens: 20,
            cacheReadInputTokens: 30,
            inputTokensIncludeCache: true,
          ),
        ],
      );

      final summary = service.forSession(session);

      expect(summary.cacheReadInputTokens, 30);
      expect(summary.totalTokens, 120);
    });
  });
}
