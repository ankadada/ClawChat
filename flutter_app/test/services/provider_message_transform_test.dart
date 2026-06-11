import 'package:clawchat/services/provider_message_transform.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const transform = ProviderMessageTransform();

  group('ProviderMessageTransform canonical cleanup', () {
    test('filters empty content blocks and messages', () {
      final result = transform.transformCanonical(
        [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': ''},
              {'type': 'text', 'text': 'hello'},
            ],
          },
          {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': ''},
            ],
          },
        ],
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude',
        ),
      );

      expect(result.messages, [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hello'},
          ],
        },
      ]);
    });

    test('removes unsafe metadata recursively in recovery mode', () {
      final result = transform.transformCanonical(
        [
          {
            'role': 'assistant',
            'reasoning_content': 'hidden',
            'content': [
              {
                'type': 'text',
                'text': 'answer',
                'cache_control': {'type': 'ephemeral'},
                'nested': {
                  'encrypted': 'blob',
                  'safe': 'value',
                },
              },
            ],
          },
        ],
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude',
          mode: ProviderTransformMode.recovery,
        ),
      );

      expect(result.messages.toString(), isNot(contains('cache_control')));
      expect(result.messages.toString(), isNot(contains('encrypted')));
      expect(result.messages.toString(), isNot(contains('reasoning_content')));
      expect(result.messages.single['content'], [
        {'type': 'text', 'text': 'answer'},
      ]);
    });

    test('preserves reasoning content only when capability is enabled', () {
      final withoutReasoning = transform.transformCanonical(
        [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'text',
                'text': 'answer',
                'reasoning_content': 'hidden',
              },
            ],
          },
        ],
        const ProviderTransformOptions(
          apiFormat: 'openai',
          modelId: 'gpt-test',
          supportsReasoningContent: false,
        ),
      );
      final withReasoning = transform.transformCanonical(
        [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'text',
                'text': 'answer',
                'reasoning_content': 'hidden',
              },
            ],
          },
        ],
        const ProviderTransformOptions(
          apiFormat: 'openai',
          modelId: 'deepseek-reasoner',
          supportsReasoningContent: true,
        ),
      );

      expect(withoutReasoning.messages.toString(),
          isNot(contains('reasoning_content')));
      expect(withReasoning.messages.toString(), contains('reasoning_content'));
    });

    test('scrubs tool ids consistently across use and result blocks', () {
      final result = transform.transformCanonical(
        [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'call:1/unsafe',
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
                'tool_use_id': 'call:1/unsafe',
                'content': 'done',
              },
            ],
          },
        ],
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude',
        ),
      );

      expect(result.toolIdMap['call:1/unsafe'], 'call_1_unsafe');
      expect(result.messages.first['content'], [
        {
          'type': 'tool_use',
          'id': 'call_1_unsafe',
          'name': 'bash',
          'input': {'cmd': 'pwd'},
        },
      ]);
      expect(result.messages.last['content'], [
        {
          'type': 'tool_result',
          'tool_use_id': 'call_1_unsafe',
          'content': 'done',
        },
      ]);
    });

    test('avoids collisions when scrubbed tool ids match', () {
      final result = transform.transformCanonical(
        [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'call:1',
                'name': 'bash',
                'input': {'cmd': 'pwd'},
              },
              {
                'type': 'tool_use',
                'id': 'call/1',
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
                'tool_use_id': 'call:1',
                'content': 'pwd',
              },
              {
                'type': 'tool_result',
                'tool_use_id': 'call/1',
                'content': 'ls',
              },
            ],
          },
        ],
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude',
        ),
      );

      final first = result.toolIdMap['call:1'];
      final second = result.toolIdMap['call/1'];
      expect(first, 'call_1');
      expect(second, isNot(first));
      expect(second, startsWith('call_1_'));
      expect(result.messages.first['content'][0]['id'], first);
      expect(result.messages.first['content'][1]['id'], second);
      expect(result.messages.last['content'][0]['tool_use_id'], first);
      expect(result.messages.last['content'][1]['tool_use_id'], second);
    });

    test('warns about orphan tools in normal mode but keeps them', () {
      final result = transform.transformCanonical(
        [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'orphan',
                'name': 'bash',
                'input': {'cmd': 'pwd'},
              },
            ],
          },
        ],
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude',
        ),
      );

      expect(result.messages, hasLength(1));
      expect(result.warnings, contains('found orphan tool_use block'));
    });

    test('drops orphan tools in recovery mode', () {
      final result = transform.transformCanonical(
        [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'orphan',
                'name': 'bash',
                'input': {'cmd': 'pwd'},
              },
            ],
          },
        ],
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude',
          mode: ProviderTransformMode.recovery,
        ),
      );

      expect(result.messages, isEmpty);
      expect(result.warnings, contains('dropped orphan tool_use block'));
    });

    test('turns unsupported image content into explicit text warning', () {
      final result = transform.transformCanonical(
        [
          {
            'role': 'user',
            'content': [
              {'type': 'image', 'data': 'abc'},
            ],
          },
        ],
        const ProviderTransformOptions(
          apiFormat: 'openai',
          modelId: 'text-only',
          supportsImages: false,
        ),
      );

      expect(result.messages.single['content'], [
        {
          'type': 'text',
          'text':
              '[Attachment omitted: images are not supported by this provider]',
        },
      ]);
      expect(result.warnings,
          contains('image content replaced because provider lacks support'));
    });

    test('removes cache control in recovery mode', () {
      final result = transform.transformCanonical(
        [
          {
            'role': 'user',
            'content': [
              {
                'type': 'text',
                'text': 'cached',
                'cache_control': {'type': 'ephemeral'},
              },
            ],
          },
        ],
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude',
          mode: ProviderTransformMode.recovery,
        ),
      );

      expect(result.messages.toString(), isNot(contains('cache_control')));
    });

    test('keeps empty assistant content when top-level tool calls exist', () {
      final result = transform.transformCanonical(
        [
          {
            'role': 'assistant',
            'content': [],
            'tool_calls': [
              {
                'id': 'call:1',
                'type': 'function',
                'function': {
                  'name': 'bash',
                  'arguments': '{"cmd":"pwd"}',
                },
              },
            ],
          },
        ],
        const ProviderTransformOptions(
          apiFormat: 'openai',
          modelId: 'gpt-test',
        ),
      );

      expect(result.messages, [
        {
          'role': 'assistant',
          'content': <Map<String, dynamic>>[],
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {
                'name': 'bash',
                'arguments': '{"cmd":"pwd"}',
              },
            },
          ],
        },
      ]);
    });
  });

  group('ProviderMessageTransform payload conversion', () {
    const mixedMessages = [
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
    ];

    test('builds Anthropic payload from canonical messages', () {
      final payload = transform.toProviderPayload(
        mixedMessages,
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude',
        ),
      );

      expect(payload, [
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

    test('builds OpenAI payload from canonical messages', () {
      final payload = transform.toProviderPayload(
        mixedMessages,
        const ProviderTransformOptions(
          apiFormat: 'openai',
          modelId: 'gpt-test',
        ),
      );

      expect(payload, [
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
    });
  });
}
