import 'dart:async';

import 'package:clawchat/constants.dart';
import 'package:clawchat/services/native_bridge.dart';
import 'package:clawchat/services/shared_content.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NativeBridge share intents', () {
    const channel = MethodChannel(AppConstants.channelName);
    const shareCallbackChannel =
        MethodChannel('${AppConstants.channelName}/share_callbacks');

    tearDown(() {
      NativeBridge.resetShareIntentHandlerForTesting();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('delivers pending shared content when handler is registered',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'consumePendingShareIntent') {
          return {
            'text': 'shared text',
            'images': [
              {
                'path': '/tmp/shared.png',
                'name': 'shared.png',
                'size': 10,
                'mimeType': 'image/png',
              },
            ],
          };
        }
        return null;
      });

      final completer = Completer<SharedContent>();
      NativeBridge.setShareIntentHandler((content) async {
        if (!completer.isCompleted) completer.complete(content);
      });

      final content = await completer.future.timeout(
        const Duration(seconds: 1),
      );
      expect(content.text, 'shared text');
      expect(content.images.single.name, 'shared.png');
    });

    test('delivers pending errors-only shared content as feedback', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'consumePendingShareIntent') {
          return {
            'errors': ['Unsupported shared file type: application/pdf'],
          };
        }
        return null;
      });

      final completer = Completer<SharedContent>();
      NativeBridge.setShareIntentHandler((content) async {
        if (!completer.isCompleted) completer.complete(content);
      });

      final content = await completer.future.timeout(
        const Duration(seconds: 1),
      );
      expect(content.hasContent, isFalse);
      expect(content.hasFeedback, isTrue);
      expect(content.hasPayload, isTrue);
      expect(content.errors, ['Unsupported shared file type: application/pdf']);
    });

    test('delivers callback errors-only shared content as feedback', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);

      final completer = Completer<SharedContent>();
      NativeBridge.setShareIntentHandler((content) async {
        if (!completer.isCompleted) completer.complete(content);
      });

      final response = Completer<ByteData?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        shareCallbackChannel.name,
        shareCallbackChannel.codec.encodeMethodCall(
          const MethodCall('onShareIntent', {
            'errors': ['Shared image is too large'],
          }),
        ),
        response.complete,
      );

      final envelope = await response.future;
      expect(envelope, isNotNull);
      expect(
        shareCallbackChannel.codec.decodeEnvelope(envelope as ByteData),
        isTrue,
      );
      final content = await completer.future.timeout(
        const Duration(seconds: 1),
      );
      expect(content.hasContent, isFalse);
      expect(content.hasPayload, isTrue);
      expect(content.errors, ['Shared image is too large']);
    });
  });
}
