import 'dart:convert';

import 'package:clawchat/constants.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/model_capabilities.dart';
import 'package:clawchat/services/provider_message_transform.dart';
import 'package:clawchat/services/tool_result_images.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Smallest valid PNG/JPEG/WEBP headers, enough for the magic-byte check.
final Uint8List _pngBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  ...List<int>.filled(24, 0),
]);

final Uint8List _jpegBytes = Uint8List.fromList([
  0xFF, 0xD8, 0xFF, 0xE0,
  ...List<int>.filled(20, 0),
]);

final Uint8List _webpBytes = Uint8List.fromList([
  0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50,
  ...List<int>.filled(16, 0),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConstants.channelName);
  late Map<String, Uint8List> workspaceFiles;
  late List<String> readPaths;

  setUp(() {
    workspaceFiles = {};
    readPaths = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      if (call.method == 'readRootfsFileBytes') {
        final path = args['path']?.toString() ?? '';
        readPaths.add(path);
        final allowed = args['allowedRoots'] as List?;
        if (allowed != null && !allowed.contains('/root/workspace')) return null;
        final maxBytes = (args['maxBytes'] as num?)?.toInt() ?? 0;
        final bytes = workspaceFiles[path];
        if (bytes == null || bytes.length > maxBytes) return null;
        return bytes;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('tool-result images reach the model as image blocks', () {
    test('a data URL becomes one text block plus one image block', () {
      final dataUrl = 'data:image/png;base64,${base64Encode(_pngBytes)}';
      final content = ToolResultContent(
        toolUseId: 'tool-1',
        output: 'rendered $dataUrl',
      );

      final api = content.toApiJson();
      final blocks = api['content'] as List;

      expect(blocks, hasLength(2));
      expect(blocks.first, {'type': 'text', 'text': 'rendered $dataUrl'});
      final image = blocks[1] as Map;
      expect(image['type'], 'image');
      expect(image['source'], {
        'type': 'base64',
        'media_type': 'image/png',
        'data': base64Encode(_pngBytes),
      });
    });

    test('a local PNG under /root/workspace is read and sent', () async {
      workspaceFiles['root/workspace/shot.png'] = _pngBytes;
      final content = ToolResultContent(
        toolUseId: 'tool-2',
        output: 'saved /root/workspace/shot.png',
      );

      final resolved = await ToolResultImageResolver.resolveBlocks(
        content.llmOutput,
      );
      expect(resolved, hasLength(1));
      expect((resolved.single['source'] as Map)['media_type'], 'image/png');
      expect(readPaths, ['root/workspace/shot.png']);

      // The agent loop stores these in the payload metadata; toApiJson then
      // emits the image block without another read.
      final withImages = ToolResultContent(
        toolUseId: 'tool-2',
        output: content.llmOutput,
        metadata: {
          'toolResultImages': [
            ToolResultImageResolver.metadataEntryFor(resolved.single)!,
          ],
        },
      );
      final blocks = withImages.toApiJson()['content'] as List;
      expect(blocks, hasLength(2));
      expect((blocks[1] as Map)['type'], 'image');
    });

    test('JPEG and WEBP bytes are accepted, other bytes are not', () {
      expect(ToolResultImageResolver.detectMediaType(_jpegBytes), 'image/jpeg');
      expect(ToolResultImageResolver.detectMediaType(_webpBytes), 'image/webp');
      expect(
        ToolResultImageResolver.detectMediaType(
          Uint8List.fromList(List<int>.filled(16, 0x41)),
        ),
        isNull,
      );
    });

    test('an oversized file stays text', () async {
      final oversized = Uint8List(ToolResultImageResolver.maxBytes + 1)
        ..setRange(0, 8, _pngBytes);
      workspaceFiles['root/workspace/huge.png'] = oversized;
      final content = ToolResultContent(
        toolUseId: 'tool-3',
        output: 'saved /root/workspace/huge.png',
      );

      final resolved = await ToolResultImageResolver.resolveBlocks(
        content.llmOutput,
      );

      expect(resolved, isEmpty);
      expect(content.toApiJson()['content'], isA<String>());
      expect(content.toApiJson()['content'], contains('huge.png'));
    });

    test('a network URL is never downloaded and stays text', () async {
      final content = ToolResultContent(
        toolUseId: 'tool-4',
        output: 'see https://cdn.example/shot.png for the render',
      );

      final resolved = await ToolResultImageResolver.resolveBlocks(
        content.llmOutput,
      );

      expect(resolved, isEmpty);
      expect(readPaths, isEmpty);
      expect(content.toApiJson()['content'], isA<String>());
    });

    test('a missing workspace file stays text', () async {
      final content = ToolResultContent(
        toolUseId: 'tool-5',
        output: 'saved /root/workspace/gone.png',
      );

      expect(await ToolResultImageResolver.resolveBlocks(content.llmOutput),
          isEmpty);
      expect(content.toApiJson()['content'], isA<String>());
    });
  });

  group('provider transform keeps the image block', () {
    Map<String, dynamic> canonicalMessage() => {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'tool-1',
              'content': [
                {'type': 'text', 'text': 'rendered'},
                {
                  'type': 'image',
                  'source': {
                    'type': 'base64',
                    'media_type': 'image/png',
                    'data': base64Encode(_pngBytes),
                  },
                },
              ],
            },
          ],
        };

    test('an image-capable provider keeps text plus image', () {
      const transform = ProviderMessageTransform();
      final result = transform.transformCanonical(
        [canonicalMessage()],
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude-sonnet',
          capabilities: ModelCapabilities(supportsImages: true),
        ),
      );

      final content =
          (result.messages.single['content'] as List).single as Map;
      final blocks = content['content'] as List;
      expect(blocks, hasLength(2));
      expect(blocks.first, {'type': 'text', 'text': 'rendered'});
      expect((blocks[1] as Map)['type'], 'image');
      expect(result.warnings.where((w) => w.contains('image')), isEmpty);
    });

    test('a provider without image support gets plain text', () {
      const transform = ProviderMessageTransform();
      final result = transform.transformCanonical(
        [canonicalMessage()],
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'text-only',
          capabilities: ModelCapabilities(supportsImages: false),
        ),
      );

      final content =
          (result.messages.single['content'] as List).single as Map;
      expect(content['content'], isA<String>());
      expect(content['content'], contains('rendered'));
    });

    test(
        'toProviderPayload keeps the Anthropic tool_result content a list of '
        'image blocks, never a JSON string', () {
      const transform = ProviderMessageTransform();
      final payload = transform.toProviderPayload(
        [canonicalMessage()],
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude-sonnet',
          capabilities: ModelCapabilities(supportsImages: true),
        ),
      );

      // The Anthropic request body always puts a tool result in a user message.
      final message = payload.singleWhere((item) => item['role'] == 'user');
      final blocks = message['content'] as List;
      final toolResult =
          blocks.firstWhere((block) => block['type'] == 'tool_result') as Map;
      final content = toolResult['content'];

      expect(content, isA<List<dynamic>>(),
          reason: 'Anthropic tool_result content must stay a list');
      final parts = content as List;
      expect(parts, hasLength(2));
      expect(parts.first, {'type': 'text', 'text': 'rendered'});
      final image = parts[1] as Map;
      expect(image['type'], 'image');
      expect((image['source'] as Map)['media_type'], 'image/png');
      expect((image['source'] as Map)['data'], base64Encode(_pngBytes));

      // A stringified JSON image must not be what the model receives.
      expect(parts.whereType<String>(), isEmpty);
      expect(
        parts.any((part) => part is String && part.contains('"type":"image"')),
        isFalse,
      );
    });

    test('an image-capable Anthropic provider also keeps an image_url block',
        () {
      const transform = ProviderMessageTransform();
      final payload = transform.toProviderPayload(
        [
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'tool-1',
                'content': [
                  {'type': 'text', 'text': 'rendered'},
                  {
                    'type': 'image_url',
                    'image_url': {
                      'url': 'data:image/png;base64,${base64Encode(_pngBytes)}',
                    },
                  },
                ],
              },
            ],
          },
        ],
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'claude-sonnet',
          capabilities: ModelCapabilities(supportsImages: true),
        ),
      );

      final message = payload.singleWhere((item) => item['role'] == 'user');
      final toolResult = (message['content'] as List)
          .firstWhere((block) => block['type'] == 'tool_result') as Map;
      final parts = toolResult['content'] as List;
      expect((parts[1] as Map)['type'], 'image');
      expect((parts[1] as Map)['source'], {
        'type': 'base64',
        'media_type': 'image/png',
        'data': base64Encode(_pngBytes),
      });
    });

    test('an Anthropic provider without image support still gets text', () {
      const transform = ProviderMessageTransform();
      final payload = transform.toProviderPayload(
        [canonicalMessage()],
        const ProviderTransformOptions(
          apiFormat: 'anthropic',
          modelId: 'text-only',
          capabilities: ModelCapabilities(supportsImages: false),
        ),
      );

      final message = payload.singleWhere((item) => item['role'] == 'user');
      final toolResult = (message['content'] as List)
          .firstWhere((block) => block['type'] == 'tool_result') as Map;
      expect(toolResult['content'], isA<String>());
      expect(toolResult['content'], contains('rendered'));
    });

    test('the OpenAI payload carries an image_url part', () {
      const transform = ProviderMessageTransform();
      final payload = transform.toProviderPayload(
        [canonicalMessage()],
        const ProviderTransformOptions(
          apiFormat: 'openai',
          modelId: 'gpt-4o',
          capabilities: ModelCapabilities(supportsImages: true),
        ),
      );

      final toolResult = payload.firstWhere(
        (message) => message['role'] == 'tool',
      );
      final parts = toolResult['content'] as List;
      expect(parts, hasLength(2));
      expect(parts.first, {'type': 'text', 'text': 'rendered'});
      expect((parts[1] as Map)['type'], 'image_url');
      expect(
        ((parts[1] as Map)['image_url'] as Map)['url'],
        startsWith('data:image/png;base64,'),
      );
    });
  });
}
