import 'dart:io';

import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/services/attachment_budget.dart';
import 'package:clawchat/services/shared_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SharedContent', () {
    test('parses native text and image metadata', () {
      final content = SharedContent.fromNative({
        'text': 'https://example.test/article',
        'subject': 'Example',
        'images': [
          {
            'path': '/tmp/shared.png',
            'name': 'shared.png',
            'size': 12,
            'mimeType': 'image/png',
          },
        ],
        'errors': ['one skipped'],
      });

      expect(content.text, 'https://example.test/article');
      expect(content.subject, 'Example');
      expect(content.images.single.path, '/tmp/shared.png');
      expect(content.images.single.name, 'shared.png');
      expect(content.images.single.size, 12);
      expect(content.errors, ['one skipped']);
    });

    test('preserves errors-only native payloads as feedback', () {
      final content = SharedContent.fromNative({
        'errors': ['Unsupported shared file type: application/pdf'],
      });

      expect(content.hasContent, isFalse);
      expect(content.hasFeedback, isTrue);
      expect(content.hasPayload, isTrue);
      expect(content.errors, ['Unsupported shared file type: application/pdf']);
    });

    test('plans errors-only imports as feedback without draft creation',
        () async {
      final prepared = await const SharedContentPreparer().prepare(
        const SharedContent(errors: ['Shared image is too large']),
      );
      final plan = SharedContentImportPlan.fromPrepared(prepared);

      expect(prepared.hasContent, isFalse);
      expect(prepared.hasFeedback, isTrue);
      expect(prepared.hasPayload, isTrue);
      expect(prepared.warnings, ['Shared image is too large']);
      expect(plan.createDraft, isFalse);
      expect(plan.showFeedback, isTrue);
    });

    test('plans accepted shared content as draft-only feedback', () {
      const prepared = PreparedSharedContent(draftText: 'shared text');
      final plan = SharedContentImportPlan.fromPrepared(prepared);

      expect(prepared.hasContent, isTrue);
      expect(prepared.hasFeedback, isFalse);
      expect(prepared.hasPayload, isTrue);
      expect(plan.createDraft, isTrue);
      expect(plan.showFeedback, isTrue);
    });

    test('prepares safe shared image without sending automatically', () async {
      final tempDir = await Directory.systemTemp.createTemp('share_content_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final image = File('${tempDir.path}/small.png');
      await image.writeAsBytes([1, 2, 3, 4]);

      final prepared = await const SharedContentPreparer().prepare(
        SharedContent(
          text: 'shared note',
          images: [
            SharedImage(
              path: image.path,
              name: 'small.png',
              size: await image.length(),
              mimeType: 'image/png',
            ),
          ],
        ),
      );

      expect(prepared.draftText, 'shared note');
      expect(prepared.attachments.single.content, isA<ImageContent>());
      expect(prepared.attachments.single.includeAsContentBlock, isTrue);
      expect(prepared.warnings, isEmpty);
    });

    test('applies attachment budget to oversized shared images', () async {
      final tempDir = await Directory.systemTemp.createTemp('share_content_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final image = File('${tempDir.path}/huge.png');
      final raf = await image.open(mode: FileMode.write);
      await raf.setPosition(AttachmentBudget.maxInlineImageBytes + 1);
      await raf.writeByte(0);
      await raf.close();

      final prepared = await const SharedContentPreparer().prepare(
        SharedContent(
          images: [
            SharedImage(
              path: image.path,
              name: 'huge.png',
              size: await image.length(),
              mimeType: 'image/png',
            ),
          ],
        ),
      );

      expect(prepared.attachments, isEmpty);
      expect(prepared.warnings.single, contains('huge.png'));
      expect(prepared.warnings.single, contains('图片过大'));
    });
  });
}
