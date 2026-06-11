import 'package:clawchat/services/chat_context_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TokenEstimator', () {
    const estimator = TokenEstimator();

    test('estimates ascii text more cheaply than cjk text', () {
      final ascii = estimator.estimateText('a' * 100);
      final cjk = estimator.estimateText('中' * 100);

      expect(ascii, greaterThanOrEqualTo(35));
      expect(ascii, lessThan(60));
      expect(cjk, greaterThan(120));
      expect(cjk, greaterThan(ascii));
    });

    test('estimates mixed text and empty text', () {
      expect(estimator.estimateText(''), 0);
      expect(estimator.estimateText('hello 世界'), greaterThan(0));
    });

    test('estimates tool json content using serialized structure', () {
      final tokens = estimator.estimateBlock({
        'type': 'tool_use',
        'id': 'call_1',
        'name': 'bash',
        'input': {
          'cmd': 'printf hello',
          'nested': {'enabled': true},
        },
      });

      expect(tokens, greaterThan(estimator.estimateText('printf hello')));
    });

    test('estimates tool definitions from serialized schema', () {
      final tokens = estimator.estimateToolDefinitions([
        {
          'name': 'bash',
          'description': 'Run a shell command',
          'input_schema': {
            'type': 'object',
            'properties': {
              'cmd': {'type': 'string'},
            },
          },
        },
      ]);

      expect(tokens, greaterThan(estimator.estimateText('bash')));
    });

    test('estimates image blocks with conservative defaults and dimensions',
        () {
      expect(estimator.estimateImage({'type': 'image'}), 1500);
      expect(
        estimator.estimateImage({
          'type': 'image',
          'width': 1600,
          'height': 800,
        }),
        greaterThan(1500),
      );
    });

    test('estimates image blocks with Anthropic vision formula', () {
      expect(
        estimator.estimateImage({
          'type': 'image',
          'width': 56,
          'height': 56,
        }),
        7,
      );
      expect(
        estimator.estimateImage({
          'type': 'image',
          'width': 750,
          'height': 750,
        }),
        732,
      );
    });

    test('applies calibration multiplier to public estimate methods', () {
      const doubled = TokenEstimator(calibrationMultiplier: 2);
      final text = 'a' * 100;
      final image = {
        'type': 'image',
        'width': 56,
        'height': 56,
      };
      final block = {'type': 'text', 'text': text};
      final message = {'role': 'user', 'content': text};

      expect(doubled.estimateText(text), estimator.estimateText(text) * 2);
      expect(doubled.estimateImage(image), estimator.estimateImage(image) * 2);
      expect(doubled.estimateBlock(block), estimator.estimateBlock(block) * 2);
      expect(
        doubled.estimateMessages([message]),
        estimator.estimateMessages([message]) * 2,
      );
    });

    test('calibration multiplier supports half estimates', () {
      const half = TokenEstimator(calibrationMultiplier: 0.5);
      final base = estimator.estimateText('a' * 100);

      expect(half.estimateText('a' * 100), (base * 0.5).ceil());
    });

    test('calibration multiplier clamps below 0.25', () {
      const clamped = TokenEstimator(calibrationMultiplier: 0.1);
      final base = estimator.estimateText('a' * 100);

      expect(clamped.estimateText('a' * 100), (base * 0.25).ceil());
    });

    test('calibration multiplier clamps above 4.0', () {
      const clamped = TokenEstimator(calibrationMultiplier: 10);
      final base = estimator.estimateText('a' * 100);

      expect(clamped.estimateText('a' * 100), base * 4);
    });

    test('diagnoses message token categories', () {
      final diagnostics = estimator.diagnoseMessages([
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hello'},
            {'type': 'image'},
            {
              'type': 'tool_result',
              'tool_use_id': 'call_1',
              'content': 'done',
            },
          ],
        },
      ]);

      expect(diagnostics.totalTokens, greaterThan(0));
      expect(diagnostics.textTokens, greaterThan(0));
      expect(diagnostics.imageTokens, greaterThanOrEqualTo(1500));
      expect(diagnostics.toolTokens, greaterThan(0));
      expect(diagnostics.largestBlockTokens, greaterThanOrEqualTo(1500));
    });
  });

  group('truncateToFit token-aware behavior', () {
    const estimator = TokenEstimator();

    test('returns truncation metadata when removing old messages', () {
      final result = ChatContextUtils.truncateToFit(
        [
          {'role': 'user', 'content': 'old ${'中' * 2000}'},
          {'role': 'assistant', 'content': 'old assistant ${'中' * 2000}'},
          {'role': 'user', 'content': 'latest'},
        ],
        maxTokens: 1000,
        estimator: estimator,
      );

      expect(result.wasTruncated, isTrue);
      expect(result.droppedMessageCount, 1);
      expect(result.messages, hasLength(2));
      expect(result.messages.first['content'], contains('old assistant'));
      expect(
          result.estimatedTokens, estimator.estimateMessages(result.messages));
    });

    test('keeps tool use and result pair together when dropping from front',
        () {
      final result = ChatContextUtils.truncateToFit(
        [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'call_1',
                'name': 'bash',
                'input': {'cmd': 'echo ${'x' * 3000}'},
              },
            ],
          },
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'call_1',
                'content': 'result ${'x' * 3000}',
              },
            ],
          },
          {'role': 'user', 'content': 'keep'},
        ],
        maxTokens: 1000,
        estimator: estimator,
        preserveLastMessages: 1,
      );

      expect(result.wasTruncated, isTrue);
      expect(result.droppedMessageCount, 2);
      expect(result.messages, hasLength(1));
      expect(result.messages.single['content'], 'keep');
    });

    test(
        'does not leave a leading orphan tool result to preserve message count',
        () {
      final result = ChatContextUtils.truncateToFit(
        [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'call_1',
                'name': 'bash',
                'input': {'cmd': 'echo ${'x' * 3000}'},
              },
            ],
          },
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'call_1',
                'content': 'result ${'x' * 3000}',
              },
            ],
          },
          {'role': 'user', 'content': 'keep'},
        ],
        maxTokens: 1000,
        estimator: estimator,
      );

      expect(result.wasTruncated, isTrue);
      expect(result.droppedMessageCount, 2);
      expect(result.messages, hasLength(1));
      expect(result.messages.single['content'], 'keep');
    });

    test('does not truncate below preserveLastMessages', () {
      final result = ChatContextUtils.truncateToFit(
        [
          {'role': 'user', 'content': 'x' * 10000},
        ],
        maxTokens: 10,
        estimator: estimator,
      );

      expect(result.wasTruncated, isFalse);
      expect(result.messages, hasLength(1));
      expect(result.maxTokens, 10);
      expect(result.originalEstimatedTokens, result.estimatedTokens);
      expect(result.overBudgetAfterTruncation, isTrue);
    });

    test('autoCompact false returns metadata without dropping messages', () {
      final messages = [
        {'role': 'user', 'content': 'x' * 10000},
        {'role': 'assistant', 'content': 'y' * 10000},
      ];
      final result = ChatContextUtils.truncateToFit(
        messages,
        maxTokens: 10,
        estimator: estimator,
        autoCompact: false,
      );

      expect(result.wasTruncated, isFalse);
      expect(result.droppedMessageCount, 0);
      expect(result.messages, hasLength(2));
      expect(result.maxTokens, 10);
      expect(result.originalEstimatedTokens, result.estimatedTokens);
      expect(result.overBudgetAfterTruncation, isTrue);
    });

    test('drops orphan tool blocks by id after truncation', () {
      final result = ChatContextUtils.truncateToFit(
        [
          {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'kept text'},
              {
                'type': 'tool_use',
                'id': 'call_a',
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
                'tool_use_id': 'call_b',
                'content': '/tmp',
              },
            ],
          },
          {'role': 'user', 'content': 'latest'},
        ],
        maxTokens: 10000,
        estimator: estimator,
      );

      expect(result.wasTruncated, isTrue);
      expect(result.droppedMessageCount, 1);
      expect(result.droppedBlockCount, 2);
      expect(result.messages, [
        {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'kept text'},
          ],
        },
        {'role': 'user', 'content': 'latest'},
      ]);
    });

    test('keeps non-adjacent tool pairs when ids match', () {
      final result = ChatContextUtils.truncateToFit(
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
          {'role': 'assistant', 'content': 'intermediate text'},
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'call_1',
                'content': '/tmp',
              },
            ],
          },
        ],
        maxTokens: 10000,
        estimator: estimator,
      );

      expect(result.wasTruncated, isFalse);
      expect(result.messages, hasLength(3));
      expect(ChatContextUtils.hasToolUseContent(result.messages.first), isTrue);
      expect(
          ChatContextUtils.hasToolResultContent(result.messages.last), isTrue);
    });

    test('does not drop adjacent mismatched tool result as a pair', () {
      final result = ChatContextUtils.truncateToFit(
        [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'call_a',
                'name': 'bash',
                'input': {'cmd': 'echo ${'x' * 3000}'},
              },
            ],
          },
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'call_b',
                'content': 'result ${'x' * 3000}',
              },
            ],
          },
          {'role': 'user', 'content': 'keep'},
        ],
        maxTokens: 1000,
        estimator: estimator,
        preserveLastMessages: 2,
      );

      expect(result.droppedMessageCount, 2);
      expect(result.droppedBlockCount, 1);
      expect(result.messages, [
        {'role': 'user', 'content': 'keep'},
      ]);
    });

    test('reports block cleanup when orphan tool block is removed in place',
        () {
      final result = ChatContextUtils.truncateToFit(
        [
          {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'kept text'},
              {
                'type': 'tool_use',
                'id': 'orphan',
                'name': 'bash',
                'input': {'cmd': 'pwd'},
              },
            ],
          },
          {'role': 'user', 'content': 'latest'},
        ],
        maxTokens: 10000,
        estimator: estimator,
      );

      expect(result.wasTruncated, isTrue);
      expect(result.droppedMessageCount, 0);
      expect(result.droppedBlockCount, 1);
      expect(
          result.messages.singleWhere(
            (message) => message['role'] == 'assistant',
          ),
          {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'kept text'},
            ],
          });
    });

    test('preserveLastMessages zero does not read past available messages', () {
      final result = ChatContextUtils.truncateToFit(
        [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'orphan',
                'name': 'bash',
                'input': {'cmd': 'echo ${'x' * 3000}'},
              },
            ],
          },
        ],
        maxTokens: 1,
        estimator: estimator,
        preserveLastMessages: 0,
      );

      expect(result.wasTruncated, isTrue);
      expect(result.messages, isEmpty);
      expect(result.droppedMessageCount, 1);
    });
  });

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
