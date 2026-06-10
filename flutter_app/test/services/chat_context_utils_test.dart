import 'package:clawchat/services/chat_context_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeMessages', () {
    test('removes cache and encrypted metadata from safe content blocks', () {
      final result = ChatContextUtils.sanitizeMessages([
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
              'source': {
                'type': 'base64',
                'media_type': 'image/png',
                'data': 'abc',
                'cache_control': {'type': 'ephemeral'},
              },
            },
          ],
        },
      ]);

      final content = result.single['content'] as List;
      expect(content[0], {'type': 'text', 'text': 'hello'});
      expect(content[1], {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': 'image/png',
          'data': 'abc',
        },
      });
    });

    test('removes top-level reasoning content during recovery sanitization',
        () {
      final result = ChatContextUtils.sanitizeMessages([
        {
          'role': 'assistant',
          'content': 'visible',
          'reasoning_content': 'hidden',
        },
      ]);

      expect(result.single, {
        'role': 'assistant',
        'content': 'visible',
      });
    });

    test('drops thinking blocks and unpaired tool messages', () {
      final result = ChatContextUtils.sanitizeMessages([
        {
          'role': 'assistant',
          'content': [
            {'type': 'thinking', 'thinking': 'hidden'},
            {
              'type': 'tool_use',
              'id': 'paired',
              'name': 'bash',
              'input': {'cmd': 'pwd'},
            },
            {
              'type': 'tool_use',
              'id': 'orphan',
              'name': 'bash',
              'input': {'cmd': 'ls'},
            },
          ],
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'paired',
              'content': '/tmp',
              'signature': 'opaque',
            },
          ],
        },
      ]);

      expect(result, [
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'paired',
              'name': 'bash',
              'input': {'cmd': 'pwd'},
            },
          ],
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'paired',
              'content': '/tmp',
            },
          ],
        },
      ]);
    });
  });
}
