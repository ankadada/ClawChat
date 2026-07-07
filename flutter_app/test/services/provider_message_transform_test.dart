import 'package:clawchat/models/model_capabilities.dart';
import 'package:clawchat/services/prompt_cache_settings.dart';
import 'package:clawchat/services/provider_message_transform.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const transform = ProviderMessageTransform();

  setUp(() {
    PromptCacheSettings.setAnthropicPromptCacheEnabledForProcess(true);
  });

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
          capabilities: ModelCapabilities(supportsReasoningContent: false),
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
          capabilities: ModelCapabilities(supportsReasoningContent: true),
        ),
      );

      expect(withoutReasoning.messages.toString(),
          isNot(contains('reasoning_content')));
      expect(withReasoning.messages.toString(), contains('reasoning_content'));
    });

    test('redacts secrets from final canonical payload fields', () {
      final result = transform.transformCanonical(
        [
          {
            'role': 'assistant',
            'reasoning_content':
                'internal password=hunter2 should not leave process',
            'content': [
              {
                'type': 'text',
                'text':
                    'Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456',
                'reasoning_content':
                    'api_key=sk-proj-abcdefghijklmnopqrstuvwxyz123456',
              },
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
                'for_llm': 'github_pat_abcdefghijklmnopqrstuvwxyz1234567890',
                'output':
                    'FULL github_pat_abcdefghijklmnopqrstuvwxyz1234567890',
              },
            ],
          },
        ],
        const ProviderTransformOptions(
          apiFormat: 'openai',
          modelId: 'deepseek-reasoner',
          capabilities: ModelCapabilities(supportsReasoningContent: true),
        ),
      );

      final serialized = result.messages.toString();
      expect(serialized, contains('[redacted: bearer_token]'));
      expect(serialized, contains('[redacted: password]'));
      expect(serialized, contains('[redacted: api_key]'));
      expect(serialized, contains('[redacted: token]'));
      expect(serialized, contains('[redacted: authorization]'));
      expect(serialized, isNot(contains('hunter2')));
      expect(serialized, isNot(contains('github_pat_')));
      expect(serialized, isNot(contains('query-secret')));
      expect(result.sensitiveDataStats.totalCount, greaterThanOrEqualTo(5));
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

    test('tool_result canonical projection keeps only ForLLM fields', () {
      final result = transform.transformCanonical(
        [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'call_1',
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
                'tool_use_id': 'call_1',
                'content': 'compact content',
                'output': 'FULL OUTPUT THAT MUST NOT LEAK',
                'for_llm': 'safe compact payload',
                'summary': 'summary only',
                'metadata': {
                  'raw': 'FULL OUTPUT THAT MUST NOT LEAK',
                  'safe': 'kept only outside provider payload',
                },
              },
            ],
          },
        ],
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude',
        ),
      );

      final serialized = result.messages.toString();
      expect(serialized, contains('safe compact payload'));
      expect(serialized, isNot(contains('FULL OUTPUT THAT MUST NOT LEAK')));
      expect(serialized, isNot(contains('metadata')));
      expect(result.messages.last['content'], [
        {
          'type': 'tool_result',
          'tool_use_id': 'call_1',
          'content': 'safe compact payload',
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
          capabilities: ModelCapabilities(supportsImages: false),
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

    test('keeps Anthropic ephemeral cache control only with capability', () {
      final result = transform.transformCanonical(
        [
          {
            'role': 'user',
            'content': [
              {
                'type': 'text',
                'text': 'stable prefix',
                'cache_control': {'type': 'ephemeral'},
              },
            ],
          },
        ],
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude',
          capabilities: ModelCapabilities(supportsPromptCache: true),
        ),
      );

      expect(result.messages.toString(), contains('cache_control'));
      expect(result.messages.toString(), contains('ephemeral'));
    });

    test('adds Anthropic prompt cache breakpoint before latest user turn', () {
      final payload = transform.toProviderPayload(
        [
          {'role': 'user', 'content': 'old question'},
          {'role': 'assistant', 'content': 'stable answer'},
          {'role': 'user', 'content': 'latest question'},
        ],
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude',
          capabilities: ModelCapabilities(supportsPromptCache: true),
        ),
      );

      expect(payload[1]['content'], isA<List>());
      expect(
        (payload[1]['content'] as List).single,
        containsPair('cache_control', {'type': 'ephemeral'}),
      );
      expect(payload.last.toString(), isNot(contains('cache_control')));
    });

    test('does not add cache_control for non-Anthropic providers', () {
      final payload = transform.toProviderPayload(
        [
          {
            'role': 'user',
            'content': [
              {
                'type': 'text',
                'text': 'stable prefix',
                'cache_control': {'type': 'ephemeral'},
              },
            ],
          },
          {'role': 'assistant', 'content': 'stable answer'},
          {'role': 'user', 'content': 'latest question'},
        ],
        const ProviderTransformOptions(
          apiFormat: 'openai',
          modelId: 'gpt-test',
          capabilities: ModelCapabilities(supportsPromptCache: true),
        ),
      );

      expect(payload.toString(), isNot(contains('cache_control')));
    });

    test('Anthropic prompt cache setting disables cache_control passthrough',
        () {
      PromptCacheSettings.setAnthropicPromptCacheEnabledForProcess(false);

      final payload = transform.toProviderPayload(
        [
          {'role': 'user', 'content': 'old question'},
          {'role': 'assistant', 'content': 'stable answer'},
          {'role': 'user', 'content': 'latest question'},
        ],
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude',
          capabilities: ModelCapabilities(supportsPromptCache: true),
        ),
      );

      expect(payload.toString(), isNot(contains('cache_control')));
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
                  'arguments':
                      '{"cmd":"pwd","api_key":"sk-proj-abcdefghijklmnopqrstuvwxyz123456"}',
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
                'arguments': '{"cmd":"pwd","api_key":"[redacted: api_key]"}',
              },
            },
          ],
        },
      ]);
      expect(result.sensitiveDataStats.countByType['api_key'], 1);
    });

    test('converts tool history to text when tools are unsupported', () {
      final result = transform.transformCanonical(
        [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'call:block',
                'name': 'bash',
                'input': {
                  'command': 'echo ok',
                  'api_key': 'sk-proj-abcdefghijklmnopqrstuvwxyz123456',
                },
              },
            ],
          },
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'call:block',
                'for_llm': 'compact safe result',
                'output': 'FULL OUTPUT THAT MUST NOT LEAK',
                'is_error': true,
              },
            ],
          },
          {
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              {
                'id': 'call:top',
                'type': 'function',
                'function': {
                  'name': 'web_fetch',
                  'arguments':
                      '{"url":"https://example.test?token=query-secret"}',
                },
              },
            ],
          },
          {
            'role': 'tool',
            'tool_call_id': 'call:top',
            'content': 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456',
          },
        ],
        const ProviderTransformOptions(
          apiFormat: 'openai',
          modelId: 'gpt-test',
          capabilities: ModelCapabilities(supportsTools: false),
        ),
      );

      expectNoProviderToolSyntax(result.messages);
      final serialized = result.messages.toString();
      expect(serialized, contains('[Tool call]'));
      expect(serialized, contains('id: call_block'));
      expect(serialized, contains('name: bash'));
      expect(serialized, contains('status: requested'));
      expect(serialized, contains('[Tool result]'));
      expect(serialized, contains('status: error'));
      expect(serialized, contains('for_llm: compact safe result'));
      expect(serialized, contains('[redacted: api_key]'));
      expect(serialized, contains('[redacted: token]'));
      expect(serialized, contains('[redacted: bearer_token]'));
      expect(serialized, isNot(contains('FULL OUTPUT THAT MUST NOT LEAK')));
      expect(serialized, isNot(contains('sk-proj-')));
      expect(result.messages.last['role'], 'user');
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

    test('provider payloads use ForLLM and exclude full output', () {
      final messages = [
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'call_1',
              'name': 'bash',
              'input': {'command': 'cat huge.log'},
            },
          ],
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'call_1',
              'content': 'legacy compact',
              'for_llm': 'structured compact result',
              'output': 'FULL OUTPUT THAT MUST NOT LEAK',
              'metadata': {'raw': 'FULL OUTPUT THAT MUST NOT LEAK'},
            },
          ],
        },
      ];

      final anthropicPayload = transform.toProviderPayload(
        messages,
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude',
        ),
      );
      final openAiPayload = transform.toProviderPayload(
        messages,
        const ProviderTransformOptions(
          apiFormat: 'openai',
          modelId: 'gpt-test',
        ),
      );

      expect(
          anthropicPayload.toString(), contains('structured compact result'));
      expect(openAiPayload.toString(), contains('structured compact result'));
      expect(
        anthropicPayload.toString(),
        isNot(contains('FULL OUTPUT THAT MUST NOT LEAK')),
      );
      expect(
        openAiPayload.toString(),
        isNot(contains('FULL OUTPUT THAT MUST NOT LEAK')),
      );
      expect(openAiPayload.last, {
        'role': 'tool',
        'tool_call_id': 'call_1',
        'content': 'structured compact result',
      });
    });

    test('converted provider payloads do not contain secrets', () {
      final messages = [
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'call_1',
              'name': 'bash',
              'input': {
                'command': 'echo ok',
                'api_key': 'sk-proj-abcdefghijklmnopqrstuvwxyz123456',
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
              'content':
                  'Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456',
            },
          ],
        },
      ];

      final anthropicPayload = transform.toProviderPayload(
        messages,
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude',
        ),
      );
      final openAiPayload = transform.toProviderPayload(
        messages,
        const ProviderTransformOptions(
          apiFormat: 'openai',
          modelId: 'gpt-test',
        ),
      );

      expect(anthropicPayload.toString(), contains('[redacted: api_key]'));
      expect(anthropicPayload.toString(), contains('[redacted: bearer_token]'));
      expect(openAiPayload.toString(), contains('[redacted: api_key]'));
      expect(openAiPayload.toString(), contains('[redacted: bearer_token]'));
      expect(anthropicPayload.toString(), isNot(contains('sk-proj-')));
      expect(openAiPayload.toString(), isNot(contains('sk-proj-')));
      expect(anthropicPayload.toString(),
          isNot(contains('abcdefghijklmnopqrstuvwxyz')));
      expect(openAiPayload.toString(),
          isNot(contains('abcdefghijklmnopqrstuvwxyz')));
    });

    test('provider payloads contain no tool syntax when tools unsupported', () {
      final messages = [
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
              'for_llm': 'structured compact result',
              'output': 'FULL OUTPUT THAT MUST NOT LEAK',
            },
          ],
        },
      ];

      final anthropicPayload = transform.toProviderPayload(
        messages,
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude',
          capabilities: ModelCapabilities(supportsTools: false),
        ),
      );
      final openAiPayload = transform.toProviderPayload(
        messages,
        const ProviderTransformOptions(
          apiFormat: 'openai',
          modelId: 'gpt-test',
          capabilities: ModelCapabilities(supportsTools: false),
        ),
      );

      expectNoProviderToolSyntax(anthropicPayload);
      expectNoProviderToolSyntax(openAiPayload);
      expect(anthropicPayload.toString(), contains('[Tool call]'));
      expect(openAiPayload.toString(), contains('[Tool call]'));
      expect(
          anthropicPayload.toString(), contains('structured compact result'));
      expect(openAiPayload.toString(), contains('structured compact result'));
      expect(
        anthropicPayload.toString(),
        isNot(contains('FULL OUTPUT THAT MUST NOT LEAK')),
      );
      expect(
        openAiPayload.toString(),
        isNot(contains('FULL OUTPUT THAT MUST NOT LEAK')),
      );
    });
  });
}

void expectNoProviderToolSyntax(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      expect(entry.key, isNot('tool_calls'));
      expect(entry.key, isNot('tool_call_id'));
      if (entry.key == 'role') {
        expect(entry.value, isNot('tool'));
      }
      if (entry.key == 'type') {
        expect(entry.value, isNot('tool_use'));
        expect(entry.value, isNot('tool_result'));
      }
      expectNoProviderToolSyntax(entry.value);
    }
  } else if (value is Iterable) {
    for (final item in value) {
      expectNoProviderToolSyntax(item);
    }
  }
}
