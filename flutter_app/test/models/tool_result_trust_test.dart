import 'package:clawchat/models/chat_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('trusted is the default and is serialized', () {
    final content = ToolResultContent(toolUseId: 't1', output: 'ok');
    expect(content.trust, ToolResultTrust.trusted);
    expect(content.toJson()['trust'], 'trusted');
  });

  test('untrusted survives a transcript round-trip', () {
    final content = ToolResultContent.fromToolResultJson({
      'type': 'tool_result',
      'tool_use_id': 't1',
      'output': 'from https://evil.example',
      'trust': 'untrusted',
    });
    expect(content.trust, ToolResultTrust.untrusted);
    final restored = ToolResultContent.fromToolResultJson(content.toJson());
    expect(restored.trust, ToolResultTrust.untrusted);
  });

  test('a legacy transcript without the field reads back trusted', () {
    final content = ToolResultContent.fromToolResultJson({
      'type': 'tool_result',
      'tool_use_id': 't1',
      'output': 'legacy',
    });
    expect(content.trust, ToolResultTrust.trusted);
  });

  test('ChatMessage round-trip keeps trust', () {
    final message = ChatMessage(role: 'user', content: [
      ToolResultContent(
        toolUseId: 't1',
        output: 'x',
        trust: ToolResultTrust.untrusted,
      ),
    ]);
    final restored = ChatMessage.fromJson(message.toJson());
    final block = restored.content.single as ToolResultContent;
    expect(block.trust, ToolResultTrust.untrusted);
  });

  test('the API projection does not carry the trust field', () {
    final content = ToolResultContent(
      toolUseId: 't1',
      output: 'x',
      trust: ToolResultTrust.untrusted,
    );
    expect(content.toApiJson().containsKey('trust'), false);
  });
}
