import 'dart:convert';
import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/provider_profile.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/services/chat_context_utils.dart';
import 'package:clawchat/services/llm_service.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/token_calibration_service.dart';
import 'package:clawchat/services/tools/tool_policy.dart';
import 'package:clawchat/services/tools/tool_registry.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int _maxContextTokens = 25000;

int charCount(Map<String, dynamic> msg) {
  // ignore: deprecated_member_use_from_same_package
  return ChatContextUtils.charCount(msg);
}

List<Map<String, dynamic>> truncateToFit(List<Map<String, dynamic>> messages) {
  return ChatContextUtils.truncateToFit(
    messages,
    maxTokens: _maxContextTokens,
    estimator: const TokenEstimator(),
  ).messages;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const nativeChannel = MethodChannel(AppConstants.channelName);
  late Directory tempDir;
  late Map<String, String> secureStorage;

  Future<void> installPlatformMocks() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    secureStorage = {};
    tempDir = await Directory.systemTemp.createTemp('clawchat_provider_test_');

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
        case 'consumePendingNavigateToSession':
          return null;
        case 'runInProot':
          return '';
        case 'readRootfsFile':
          return null;
        case 'writeRootfsFile':
          return true;
      }
      return true;
    });
  }

  Future<void> clearPlatformMocks() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    messenger.setMockMethodCallHandler(secureStorageChannel, null);
    messenger.setMockMethodCallHandler(nativeChannel, null);
    PreferencesService.resetForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  }

  void configureAnthropicProfile({
    required String baseUrl,
  }) {
    final profile = ProviderProfile.defaults().copyWith(
      id: 'profile',
      apiKey: 'sk-test',
      apiFormat: ProviderProfile.anthropicFormat,
      baseUrl: baseUrl,
      model: 'claude-sonnet-4-20250514',
    );
    secureStorage['provider_profiles'] = jsonEncode([profile.toJson()]);
    SharedPreferences.setMockInitialValues({
      'active_provider_profile_id': 'profile',
      'context_token_budget': 65536,
    });
  }

  group('alternative navigation', () {
    setUp(() async {
      await installPlatformMocks();
    });

    tearDown(() async {
      await clearPlatformMocks();
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

  group('encrypted content recovery', () {
    setUp(() async {
      await installPlatformMocks();
      configureAnthropicProfile(baseUrl: 'http://127.0.0.1');
    });

    tearDown(() async {
      await clearPlatformMocks();
    });

    test('persists sanitized history so the next send does not recover again',
        () async {
      var requestCount = 0;
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            requestCount++;
            final serialized = messages.toString();
            if (serialized.contains('reasoning_content')) {
              return StreamError(
                'encrypted',
                cause: const EncryptedContentError(
                  'Anthropic API error: invalid_encrypted_content: encrypted',
                  code: 'invalid_encrypted_content',
                ),
              );
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final timestamp = DateTime(2026, 1, 2, 3, 4, 5);
      final session = await provider.createSession();
      session.messages.add(ChatMessage.systemNotice('before recovery'));
      session.messages.add(ChatMessage(
        role: 'assistant',
        content: [
          TextContent('cached', reasoningContent: 'hidden reasoning'),
          ImageContent(
            data: 'abc',
            mediaType: 'image/png',
            filename: 'screenshot.png',
          ),
        ],
        timestamp: timestamp,
        inputTokens: 11,
        outputTokens: 22,
        alternatives: ['previous answer'],
        activeAlternative: -1,
      ));

      await provider.sendMessage('first');
      expect(provider.errorMessage, isNull);
      expect(requestCount, 2);
      expect(provider.currentSession!.toApiMessages().toString(),
          isNot(contains('reasoning_content')));
      expect(
        provider.currentSession!.messages.any((m) =>
            m.isSystemNotice && m.textContent == '检测到缓存上下文失效，已自动恢复对话上下文'),
        isTrue,
      );
      expect(provider.currentSession!.messages.first.isSystemNotice, isTrue);
      expect(provider.currentSession!.messages.first.textContent,
          'before recovery');
      final sanitizedAssistant = provider.currentSession!.messages.firstWhere(
        (m) => m.role == 'assistant' && !m.isSystemNotice,
      );
      expect(sanitizedAssistant.timestamp, timestamp);
      expect(sanitizedAssistant.inputTokens, 11);
      expect(sanitizedAssistant.outputTokens, 22);
      expect(sanitizedAssistant.alternatives, ['previous answer']);
      expect(sanitizedAssistant.activeAlternative, -1);
      expect(
        sanitizedAssistant.content
            .whereType<TextContent>()
            .single
            .reasoningContent,
        isNull,
      );
      expect(
        sanitizedAssistant.content.whereType<ImageContent>().single.filename,
        'screenshot.png',
      );

      await provider.sendMessage('second');
      expect(provider.errorMessage, isNull);
      expect(requestCount, 3);
    });

    test('reports sanitized retry failure with retry details', () async {
      var requestCount = 0;
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            return StreamError(
              'encrypted',
              cause: const EncryptedContentError(
                'Anthropic API error: invalid_encrypted_content: encrypted',
                code: 'invalid_encrypted_content',
              ),
            );
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.add(ChatMessage(
        role: 'assistant',
        content: [TextContent('cached', reasoningContent: 'hidden')],
      ));

      await provider.sendMessage('first');

      expect(requestCount, 2);
      expect(provider.errorMessage, contains('自动恢复上下文失败'));
      expect(
        provider.errorMessage,
        contains('sanitized retry also failed:'),
      );
    });

    test(
        'does not retry when provider recovery sanitization leaves no messages',
        () async {
      var requestCount = 0;
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            return StreamError(
              'encrypted',
              cause: const EncryptedContentError(
                'Anthropic API error: invalid_encrypted_content: encrypted',
                code: 'invalid_encrypted_content',
              ),
            );
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await provider.createSession();

      await provider.sendMessage(
        '',
        attachments: [
          ToolUseContent(
            id: 'orphan',
            name: 'bash',
            input: const {'cmd': 'pwd'},
          ),
        ],
      );

      expect(requestCount, 1);
      expect(provider.errorMessage, contains('自动恢复上下文失败'));
    });

    test('returns failed recovery error when sanitization leaves no messages',
        () async {
      final provider = ChatProvider();
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final messages = [
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
      ];

      final recoveryMessages = ChatContextUtils.sanitizeMessages(messages);
      expect(recoveryMessages, isEmpty);
      final error = provider.encryptedRecoveryEmptyErrorForTesting(
        const EncryptedContentError(
          'Anthropic API error: invalid_encrypted_content: encrypted',
          code: 'invalid_encrypted_content',
        ),
        recoveryMessages,
      );
      expect(error, contains('自动恢复上下文失败'));
    });
  });

  group('token-aware context budgeting', () {
    setUp(() async {
      await installPlatformMocks();
      configureAnthropicProfile(baseUrl: 'http://127.0.0.1');
    });

    tearDown(() async {
      await clearPlatformMocks();
    });

    test('sendMessage uses token budget instead of raw character length',
        () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
      });
      final observedMessages = <List<Map<String, dynamic>>>[];
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('old-short-cjk-${'中' * 24000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'中' * 24000}')],
        ),
        ChatMessage.user('recent prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('recent reply')],
        ),
      ]);

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(1));
      final serialized = observedMessages.single.toString();
      expect(serialized, isNot(contains('old-short-cjk')));
      expect(serialized, contains('new prompt'));
      expect(
        provider.currentSession!.messages
            .where((m) => m.isSystemNotice)
            .map((m) => m.textContent)
            .join('\n'),
        contains('tokens'),
      );
    });

    test('sendMessage reports orphan tool block cleanup separately', () async {
      final observedMessages = <List<Map<String, dynamic>>>[];
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.add(ChatMessage(
        role: 'assistant',
        content: [
          TextContent('kept text'),
          ToolUseContent(
            id: 'orphan',
            name: 'bash',
            input: const {'cmd': 'pwd'},
          ),
        ],
      ));

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(1));
      expect(observedMessages.single.toString(), isNot(contains('orphan')));
      expect(
        provider.currentSession!.messages
            .where((m) => m.isSystemNotice)
            .map((m) => m.textContent)
            .join('\n'),
        contains('清理了 1 个不完整的工具调用'),
      );
    });

    test('large system prompt truncates history more aggressively', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
      });
      final observedMessages = <List<Map<String, dynamic>>>[];
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      Future<int> sentMessageCountForSystemPrompt(String systemPrompt) async {
        final session = await provider.createSession();
        session.systemPrompt = systemPrompt;
        session.messages.addAll([
          ChatMessage.user('old-1 ${'中' * 4000}'),
          ChatMessage(
            role: 'assistant',
            content: [TextContent('old-2 ${'中' * 4000}')],
          ),
          ChatMessage.user('mid-1 ${'中' * 4000}'),
          ChatMessage(
            role: 'assistant',
            content: [TextContent('mid-2 ${'中' * 4000}')],
          ),
          ChatMessage.user('recent prompt'),
          ChatMessage(
            role: 'assistant',
            content: [TextContent('recent reply')],
          ),
        ]);

        await provider.sendMessage('new prompt');

        expect(provider.errorMessage, isNull);
        return observedMessages.last.length;
      }

      final smallPromptCount = await sentMessageCountForSystemPrompt('small');
      final largePromptCount =
          await sentMessageCountForSystemPrompt('large ${'中' * 20000}');

      expect(largePromptCount, lessThan(smallPromptCount));
    });

    test('image-heavy history contributes to token budget', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
      });
      final observedMessages = <List<Map<String, dynamic>>>[];
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      for (var i = 0; i < 20; i++) {
        session.messages.add(ChatMessage.userContent([
          ImageContent(
            data: 'old-image-$i',
            mediaType: 'image/png',
          ),
        ]));
      }

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(1));
      final serialized = observedMessages.single.toString();
      expect(serialized, isNot(contains('old-image-0')));
      expect(serialized, contains('new prompt'));
    });

    test('encrypted recovery retry also uses token budget truncation',
        () async {
      final observedMessages = <List<Map<String, dynamic>>>[];
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            if (observedMessages.length == 1) {
              return StreamError(
                'encrypted',
                cause: const EncryptedContentError(
                  'Anthropic API error: invalid_encrypted_content: encrypted',
                  code: 'invalid_encrypted_content',
                ),
              );
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('old-cjk-${'中' * 24000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'中' * 24000}')],
        ),
        ChatMessage.user('recent prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('recent reply')],
        ),
      ]);

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(2));
      final retryPayload = observedMessages.last.toString();
      expect(retryPayload, isNot(contains('old-cjk')));
      expect(retryPayload, contains('new prompt'));
    });

    test('sendCompare uses token-aware truncation', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
      });
      final observedMessages = <List<Map<String, dynamic>>>[];
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
          )),
          onChat: (messages) {
            observedMessages.add(messages);
            return LlmResponse(
              stopReason: 'end_turn',
              content: [
                ContentBlock(
                    type: 'text', text: 'ok ${observedMessages.length}')
              ],
            );
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('old-compare-${'中' * 24000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'中' * 24000}')],
        ),
        ChatMessage.user('recent prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('recent reply')],
        ),
      ]);

      await provider.sendCompare('compare prompt', ['model-a', 'model-b']);

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(2));
      for (final messages in observedMessages) {
        final serialized = messages.toString();
        expect(serialized, isNot(contains('old-compare')));
        expect(serialized, contains('compare prompt'));
      }
    });

    test('successful send updates token calibration', () async {
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => StreamDone(const LlmResponse(
            stopReason: 'end_turn',
            content: [ContentBlock(type: 'text', text: 'ok')],
            usage: LlmUsage(inputTokens: 22000, outputTokens: 50),
          )),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      for (var i = 0; i < 12; i++) {
        session.messages.add(ChatMessage.user('history-$i ${'x' * 4000}'));
      }
      await provider.sendMessage('calibrate');

      expect(provider.errorMessage, isNull);
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(TokenCalibrationService.storageKey);
      expect(raw, isNotNull);
      final stored = jsonDecode(raw!) as Map<String, dynamic>;
      final entry = stored.values.single as Map<String, dynamic>;
      expect(entry['multiplier'] as double, greaterThan(1.0));
      expect(entry['sampleCount'], 1);
    });

    test('encrypted recovery does not update token calibration', () async {
      var requestCount = 0;
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) {
            requestCount++;
            if (requestCount == 1) {
              return StreamError(
                'encrypted',
                cause: const EncryptedContentError(
                  'Anthropic API error: invalid_encrypted_content: encrypted',
                  code: 'invalid_encrypted_content',
                ),
              );
            }
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
              usage: LlmUsage(inputTokens: 22000, outputTokens: 50),
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      for (var i = 0; i < 12; i++) {
        session.messages.add(ChatMessage.user('history-$i ${'x' * 4000}'));
      }
      await provider.sendMessage('recover');

      expect(provider.errorMessage, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(TokenCalibrationService.storageKey), isNull);
    });

    test('tool-call agent loops do not update token calibration', () async {
      var requestCount = 0;
      final tools = ToolRegistry()..register(_EchoTool(), risk: ToolRisk.safe);
      final provider = ChatProvider(
        toolRegistry: tools,
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (_) => throw UnimplementedError(),
          onMessageEvents: (_) {
            requestCount++;
            if (requestCount == 1) {
              return [
                StreamDone(const LlmResponse(
                  stopReason: 'tool_use',
                  content: [
                    ContentBlock(
                      type: 'tool_use',
                      toolUseId: 'call_1',
                      toolName: 'echo',
                      toolInput: {'text': 'hi'},
                    ),
                  ],
                )),
              ];
            }
            return [
              StreamDone(const LlmResponse(
                stopReason: 'end_turn',
                content: [ContentBlock(type: 'text', text: 'ok')],
                usage: LlmUsage(inputTokens: 22000, outputTokens: 50),
              )),
            ];
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final session = await provider.createSession();
      for (var i = 0; i < 12; i++) {
        session.messages.add(ChatMessage.user('history-$i ${'x' * 4000}'));
      }
      await provider.sendMessage('use tool');

      expect(provider.errorMessage, isNull);
      expect(requestCount, 2);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(TokenCalibrationService.storageKey), isNull);
    });

    test('next send uses persisted calibration multiplier', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
        TokenCalibrationService.storageKey: jsonEncode({
          'anthropic|127.0.0.1|profile|claude-sonnet-4-20250514': {
            'multiplier': 2.0,
            'sampleCount': 3,
            'updatedAtMillis': 1,
          },
        }),
      });
      final observedMessages = <List<Map<String, dynamic>>>[];
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('old-calibrated-${'x' * 30000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'x' * 30000}')],
        ),
        ChatMessage.user('recent prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('recent reply')],
        ),
      ]);

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedMessages, hasLength(1));
      final serialized = observedMessages.single.toString();
      expect(serialized, isNot(contains('old-calibrated')));
      expect(serialized, isNot(contains('old reply')));
      expect(serialized, contains('new prompt'));
    });

    test('tool definitions are subtracted from message budget', () async {
      SharedPreferences.setMockInitialValues({
        'active_provider_profile_id': 'profile',
        'context_token_budget': 32768,
      });
      final observedMessages = <List<Map<String, dynamic>>>[];
      final observedTools = <int>[];
      final provider = ChatProvider(
        llmServiceFactory: (config, {isInBackground}) => _ScriptedLlmService(
          config,
          onMessages: (messages) {
            observedMessages.add(messages);
            return StreamDone(const LlmResponse(
              stopReason: 'end_turn',
              content: [ContentBlock(type: 'text', text: 'ok')],
            ));
          },
          onTools: (tools) => observedTools.add(tools.length),
        ),
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        provider.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final session = await provider.createSession();
      session.messages.addAll([
        ChatMessage.user('old-tools-${'中' * 17000}'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('old reply ${'中' * 17000}')],
        ),
        ChatMessage.user('recent prompt'),
        ChatMessage(
          role: 'assistant',
          content: [TextContent('recent reply')],
        ),
      ]);

      await provider.sendMessage('new prompt');

      expect(provider.errorMessage, isNull);
      expect(observedTools.single, greaterThan(0));
      final serialized = observedMessages.single.toString();
      expect(serialized, isNot(contains('old-tools')));
      expect(serialized, isNot(contains('old reply')));
      expect(serialized, contains('new prompt'));
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

class _ScriptedLlmService extends LlmService {
  final StreamEvent Function(List<Map<String, dynamic>> messages) onMessages;
  final List<StreamEvent> Function(List<Map<String, dynamic>> messages)?
      onMessageEvents;
  final LlmResponse Function(List<Map<String, dynamic>> messages)? onChat;
  final void Function(List<ToolDefinition> tools)? onTools;

  _ScriptedLlmService(
    super.config, {
    required this.onMessages,
    this.onMessageEvents,
    this.onChat,
    this.onTools,
  });

  @override
  Future<LlmResponse> chat({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async {
    onTools?.call(tools);
    final handler = onChat;
    if (handler != null) return handler(messages);
    final eventsHandler = onMessageEvents;
    if (eventsHandler != null) {
      for (final event in eventsHandler(messages)) {
        if (event is StreamDone) return event.response;
        if (event is StreamError) throw Exception(event.message);
      }
    }
    final event = onMessages(messages);
    if (event is StreamDone) return event.response;
    if (event is StreamError) throw Exception(event.message);
    return const LlmResponse(
      stopReason: 'end_turn',
      content: [ContentBlock(type: 'text', text: 'ok')],
    );
  }

  @override
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async* {
    onTools?.call(tools);
    final eventsHandler = onMessageEvents;
    if (eventsHandler != null) {
      for (final event in eventsHandler(messages)) {
        if (event is StreamDone) {
          final text = event.response.content
              .where((block) => block.type == 'text')
              .map((block) => block.text ?? '')
              .join();
          if (text.isNotEmpty) yield TextDelta(text);
        }
        yield event;
      }
      return;
    }
    final event = onMessages(messages);
    if (event is StreamDone) {
      final text = event.response.content
          .where((block) => block.type == 'text')
          .map((block) => block.text ?? '')
          .join();
      if (text.isNotEmpty) yield TextDelta(text);
    }
    yield event;
  }
}

class _EchoTool extends Tool {
  @override
  String get name => 'echo';

  @override
  String get description => 'Echo text';

  @override
  Map<String, dynamic> get inputSchema => const {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
      };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    return input['text']?.toString() ?? '';
  }
}
