import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/services/current_session_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CurrentSessionSearch', () {
    const search = CurrentSessionSearch();

    test('finds text matches with original message indexes', () {
      final messages = [
        ChatMessage.systemNotice('internal notice'),
        ChatMessage.user('hello project notes'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('final answer with target phrase')],
        ),
      ];

      final results = search.search(messages, 'target');

      expect(results, hasLength(1));
      expect(results.single.messageIndex, 2);
      expect(results.single.role, 'assistant');
      expect(results.single.preview, contains('target phrase'));
    });

    test('searches tool names and summaries without raw input or output', () {
      final messages = [
        ChatMessage(
          role: 'assistant',
          content: [
            ToolUseContent(
              id: 'call_1',
              name: 'bash',
              input: const {
                'command': 'grep needle file.txt',
                'api_key': 'sk-placeholder-placeholder',
              },
            ),
          ],
        ),
        ChatMessage(
          role: 'user',
          content: [
            ToolResultContent(
              toolUseId: 'call_1',
              output: 'full output includes archived needle and token value',
              forLlm: 'compact result',
              summary: 'grep summary api_key=synthetic-value',
            ),
          ],
        ),
      ];

      final toolNameResults = search.search(messages, 'bash');
      final summaryResults = search.search(messages, 'grep summary');

      expect(toolNameResults.single.messageIndex, 0);
      expect(summaryResults.single.messageIndex, 1);
      expect(summaryResults.single.preview, contains('grep summary'));
      expect(summaryResults.single.preview, isNot(contains('synthetic-value')));
      expect(search.search(messages, 'grep needle'), isEmpty);
      expect(search.search(messages, 'archived needle'), isEmpty);
    });

    test('returns empty list for blank or missing query', () {
      final messages = [ChatMessage.user('hello')];

      expect(search.search(messages, '  '), isEmpty);
      expect(search.search(messages, 'missing'), isEmpty);
    });
  });
}
