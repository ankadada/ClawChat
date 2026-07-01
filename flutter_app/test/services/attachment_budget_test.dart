import 'dart:convert';

import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/services/attachment_budget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AttachmentBudget', () {
    const budget = AttachmentBudget();

    test('rejects oversized inline image bytes before base64 loading', () {
      expect(
        () => budget.checkInlineImageBytes(
          AttachmentBudget.maxInlineImageBytes + 1,
          fileName: 'large.png',
        ),
        throwsA(isA<AttachmentBudgetException>()),
      );
    });

    test('rejects oversized message attachment payloads', () {
      final oversizedImage = ImageContent(
        data: base64Encode(List<int>.filled(
          AttachmentBudget.maxMessageAttachmentBytes + 1,
          1,
        )),
        mediaType: 'image/png',
      );

      expect(
        () => budget.checkMessageAttachments([oversizedImage]),
        throwsA(isA<AttachmentBudgetException>()),
      );
    });

    test('estimates text attachment bytes using utf8', () {
      expect(
        budget.estimatedContentBytes(TextContent('中文')),
        utf8.encode('中文').length,
      );
    });
  });
}
