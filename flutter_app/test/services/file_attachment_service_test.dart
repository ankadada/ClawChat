import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/services/file_attachment_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConstants.channelName);
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('clawchat_attachment_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'writeRootfsFile':
          return true;
        case 'runInProot':
          return '';
      }
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> writeFile(String name, List<int> bytes) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<File> writeStringFile(String name, String content) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsString(content);
    return file;
  }

  PlatformFile platformFile(File file, String name) {
    return PlatformFile(
      name: name,
      path: file.path,
      size: file.lengthSync(),
    );
  }

  group('FileAttachmentService.prepareForMessage', () {
    test('image file returns ImageContent', () async {
      final file = await writeFile('photo.png', [1, 2, 3, 4]);

      final prepared = await FileAttachmentService.prepareForMessage(
        platformFile(file, 'photo.png'),
      );

      expect(prepared.content, isA<ImageContent>());
      final image = prepared.content as ImageContent;
      expect(image.mediaType, 'image/png');
      expect(image.filename, 'photo.png');
      expect(prepared.includeAsContentBlock, isTrue);
    });

    test('text file returns inlined code block', () async {
      final file = await writeStringFile('main.dart', 'void main() {}');

      final prepared = await FileAttachmentService.prepareForMessage(
        platformFile(file, 'main.dart'),
      );

      expect(prepared.content, isA<TextContent>());
      expect(prepared.inputText, contains('File: main.dart'));
      expect(prepared.inputText, contains('```'));
      expect(prepared.inputText, contains('void main() {}'));
      expect(prepared.includeAsContentBlock, isFalse);
    });

    test('oversized image throws', () async {
      final file = await writeFile('large.png', List<int>.filled(4 * 1024 * 1024, 1));

      expect(
        FileAttachmentService.prepareForMessage(
          platformFile(file, 'large.png'),
        ),
        throwsException,
      );
    });

    test('oversized text throws', () async {
      final file = await writeStringFile('large.txt', 'x' * (101 * 1024));

      expect(
        FileAttachmentService.prepareForMessage(
          platformFile(file, 'large.txt'),
        ),
        throwsException,
      );
    });

    test('binary file returns workspace path marker', () async {
      final file = await writeFile('archive.bin', [0, 1, 2, 3]);

      final prepared = await FileAttachmentService.prepareForMessage(
        platformFile(file, 'archive.bin'),
      );

      expect(prepared.content, isA<TextContent>());
      expect(prepared.inputText, contains('/root/workspace/uploads/archive.bin'));
      expect(prepared.includeAsContentBlock, isFalse);
    });
  });
}
