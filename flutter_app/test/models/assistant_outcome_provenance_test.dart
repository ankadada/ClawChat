import 'package:clawchat/models/chat_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('selected outcome and bounded alternative provenance round trip', () {
    final message = ChatMessage(
      role: 'assistant',
      content: [TextContent('selected')],
      currentProvenance: const AssistantOutcomeProvenance(
        model: 'model-selected',
        outputTokens: 12,
        latencyMs: 34,
      ),
      alternatives: const ['one', 'two'],
      alternativeProvenance: const [
        AssistantOutcomeProvenance(model: 'model-one'),
        AssistantOutcomeProvenance(model: 'model-two', outputTokens: 9),
      ],
    );

    final restored = ChatMessage.fromJson(message.toJson());

    expect(restored.textContent, 'selected');
    expect(restored.currentProvenance?.model, 'model-selected');
    expect(restored.alternativeProvenance, hasLength(2));
    expect(restored.alternativeProvenance?[1]?.outputTokens, 9);
    expect(restored.toJson(), message.toJson());
  });

  test('regeneration keeps only the newest bounded alternatives', () {
    var message = ChatMessage(
      role: 'assistant',
      content: [TextContent('zero')],
    );
    for (var i = 1; i <= 8; i++) {
      message = message.withNewAlternative([TextContent('$i')]);
    }
    expect(message.alternatives, hasLength(ChatMessage.maxAlternatives));
    expect(message.alternatives, ['4', '5', '6', '7']);
  });

  test('malformed provenance fails closed without losing legacy alternatives',
      () {
    final restored = ChatMessage.fromJson({
      'role': 'assistant',
      'timestamp': DateTime.utc(2026).toIso8601String(),
      'content': [
        {'type': 'text', 'text': 'selected'}
      ],
      'alternatives': ['legacy'],
      'alternativeProvenance': [
        {'model': 'x' * 121}
      ],
    });
    expect(restored.alternatives, ['legacy']);
    expect(restored.alternativeProvenance, [null]);
  });
}
