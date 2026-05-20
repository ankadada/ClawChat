import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/services/chat_context_utils.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int _maxContextChars = 100000; // ~25k tokens

int charCount(Map<String, dynamic> msg) => ChatContextUtils.charCount(msg);

List<Map<String, dynamic>> truncateToFit(List<Map<String, dynamic>> messages) {
  return ChatContextUtils.truncateToFit(
    messages,
    maxChars: _maxContextChars,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('alternative navigation', () {
    const pathProviderChannel =
        MethodChannel('plugins.flutter.io/path_provider');
    const secureStorageChannel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    const nativeChannel = MethodChannel(AppConstants.channelName);

    late Directory tempDir;
    late Map<String, String> secureStorage;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      PreferencesService.resetForTesting();
      secureStorage = {};
      tempDir = await Directory.systemTemp.createTemp('clawchat_alt_nav_test_');

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return tempDir.path;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(secureStorageChannel, (call) async {
        final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
        final key = args['key']?.toString();
        switch (call.method) {
          case 'read':
            return key == null ? null : secureStorage[key];
          case 'write':
            if (key != null) {
              secureStorage[key] = args['value']?.toString() ?? '';
            }
            return null;
          case 'delete':
            if (key != null) secureStorage.remove(key);
            return null;
          case 'deleteAll':
            secureStorage.clear();
            return null;
          case 'containsKey':
            return key != null && secureStorage.containsKey(key);
          case 'readAll':
            return Map<String, String>.from(secureStorage);
        }
        return null;
      });
      messenger.setMockMethodCallHandler(nativeChannel, (call) async {
        switch (call.method) {
          case 'runInProot':
            return '';
          case 'readRootfsFile':
            return null;
          case 'writeRootfsFile':
            return true;
        }
        return true;
      });
    });

    tearDown(() async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(pathProviderChannel, null);
      messenger.setMockMethodCallHandler(secureStorageChannel, null);
      messenger.setMockMethodCallHandler(nativeChannel, null);
      PreferencesService.resetForTesting();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('switches 2 to 1 to 2 to 1 without reordering versions', () async {
      final provider = ChatProvider();
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));

      provider.currentSession = ChatSession(
        id: 'alt_nav',
        messages: [
          ChatMessage.user('prompt'),
          ChatMessage(
            role: 'assistant',
            content: [TextContent('v2')],
            alternatives: ['v1'],
          ),
        ],
      );

      provider.switchAlternative(1, 0);
      var message = provider.currentSession!.messages[1];
      expect(message.textContent, 'v1');
      expect(message.displayIndex, 1);
      expect((message.content.single as TextContent).text, 'v2');
      expect(message.alternatives, ['v1']);

      provider.switchAlternative(1, 1);
      message = provider.currentSession!.messages[1];
      expect(message.textContent, 'v2');
      expect(message.displayIndex, 2);
      expect((message.content.single as TextContent).text, 'v2');
      expect(message.alternatives, ['v1']);

      provider.switchAlternative(1, 0);
      message = provider.currentSession!.messages[1];
      expect(message.textContent, 'v1');
      expect(message.displayIndex, 1);
      expect((message.content.single as TextContent).text, 'v2');
      expect(message.alternatives, ['v1']);

      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
  });

  group('charCount - string content', () {
    test('counts simple string content', () {
      expect(charCount({'role': 'user', 'content': 'hello'}), 5);
    });

    test('counts top-level reasoning_content with string content', () {
      expect(
        charCount({
          'role': 'assistant',
          'content': 'hello',
          'reasoning_content': 'thinking',
        }),
        13,
      );
    });

    test('counts empty string as 0', () {
      expect(charCount({'role': 'user', 'content': ''}), 0);
    });

    test('counts long string accurately', () {
      final long = 'x' * 5000;
      expect(charCount({'role': 'user', 'content': long}), 5000);
    });
  });

  group('charCount - list content', () {
    test('counts text in list items', () {
      expect(
        charCount({
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'hello world'},
          ],
        }),
        11,
      );
    });

    test('counts reasoning_content in list text items', () {
      expect(
        charCount({
          'role': 'assistant',
          'content': [
            {
              'type': 'text',
              'text': 'hello',
              'reasoning_content': 'thinking',
            },
          ],
        }),
        13,
      );
    });

    test('counts content field in list items (tool_result)', () {
      expect(
        charCount({
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'call_1',
              'content': 'output text',
            },
          ],
        }),
        11,
      );
    });

    test('sums text and content across multiple items', () {
      expect(
        charCount({
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'abc'}, // 3
            {'type': 'text', 'text': 'de'}, // 2
          ],
        }),
        5,
      );
    });

    test('handles mixed text and tool_result items', () {
      expect(
        charCount({
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'hello'}, // 5
            {
              'type': 'tool_result',
              'tool_use_id': 'x',
              'content': '1234567890',
            }, // 10
          ],
        }),
        15,
      );
    });

    test('counts empty list as 0', () {
      expect(charCount({'role': 'user', 'content': <dynamic>[]}), 0);
    });

    test('ignores non-Map items in list', () {
      expect(
        charCount({
          'role': 'user',
          'content': ['plain string', 42],
        }),
        0,
      );
    });

    test('handles items without text or content keys', () {
      expect(
        charCount({
          'role': 'assistant',
          'content': [
            {'type': 'tool_use', 'id': 'call_1', 'name': 'bash'},
          ],
        }),
        0,
      );
    });
  });

  group('charCount - edge cases', () {
    test('returns 0 when content key is missing', () {
      expect(charCount({'role': 'user'}), 0);
    });

    test('returns 0 when content is null', () {
      expect(charCount({'role': 'user', 'content': null}), 0);
    });

    test('returns 0 when content is a number', () {
      expect(charCount({'role': 'user', 'content': 42}), 0);
    });

    test('returns 0 for empty map', () {
      expect(charCount({}), 0);
    });
  });

  group('truncateToFit - basic behavior', () {
    test('preserves all messages when under the limit', () {
      final msgs = [
        {'role': 'user', 'content': 'hi'},
        {'role': 'assistant', 'content': 'hello'},
      ];
      final result = truncateToFit(msgs);
      expect(result.length, 2);
      expect(result[0]['content'], 'hi');
      expect(result[1]['content'], 'hello');
    });

    test('does not modify original list', () {
      final msgs = List.generate(
        10,
        (i) => {
          'role': i.isEven ? 'user' : 'assistant',
          'content': 'x' * 20000,
        },
      );
      final originalLength = msgs.length;
      truncateToFit(msgs);
      expect(msgs.length, originalLength);
    });
  });

  group('truncateToFit - truncation behavior', () {
    test('removes oldest messages first when over limit', () {
      final msgs = List.generate(
        10,
        (i) => {
          'role': i.isEven ? 'user' : 'assistant',
          'content': 'msg_$i ${'x' * 20000}',
        },
      );
      final result = truncateToFit(msgs);
      expect(result.length, lessThan(10));
      expect(result.last['content'], contains('msg_9'));
    });

    test('always keeps at least 2 messages even if over limit', () {
      final msgs = [
        {'role': 'user', 'content': 'x' * 200000},
        {'role': 'assistant', 'content': 'y' * 200000},
        {'role': 'user', 'content': 'z' * 200000},
      ];
      final result = truncateToFit(msgs);
      expect(result.length, 2);
    });

    test('keeps exactly 2 when 3 messages exceed limit', () {
      final msgs = [
        {'role': 'user', 'content': 'a' * 50000},
        {'role': 'assistant', 'content': 'b' * 50000},
        {'role': 'user', 'content': 'c' * 50000},
      ];
      final result = truncateToFit(msgs);
      expect(result.length, 2);
      expect(result[0]['content'], startsWith('b'));
      expect(result[1]['content'], startsWith('c'));
    });

    test('does not truncate when exactly at limit', () {
      final msgs = [
        {'role': 'user', 'content': 'a' * 50000},
        {'role': 'assistant', 'content': 'b' * 50000},
      ];
      final result = truncateToFit(msgs);
      expect(result.length, 2);
    });

    test('handles single message (does not truncate below 2)', () {
      final msgs = [
        {'role': 'user', 'content': 'x' * 200000},
      ];
      final result = truncateToFit(msgs);
      expect(result.length, 1);
    });

    test('handles empty list', () {
      final result = truncateToFit([]);
      expect(result, isEmpty);
    });
  });

  group('truncateToFit - with list content', () {
    test('correctly counts and truncates list content messages', () {
      final msgs = List.generate(
        8,
        (i) => <String, dynamic>{
          'role': i.isEven ? 'user' : 'assistant',
          'content': [
            {'type': 'text', 'text': 'message_$i ${'y' * 20000}'},
          ],
        },
      );
      final result = truncateToFit(msgs);
      expect(result.length, lessThan(8));
      expect(result.length, greaterThanOrEqualTo(2));
    });
  });
}
