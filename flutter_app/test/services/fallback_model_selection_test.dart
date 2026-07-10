import 'package:clawchat/services/fallback_model_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes fetched model options without duplicates', () {
    expect(
      FallbackModelSelection.normalizeKnownModels([
        ' claude-sonnet ',
        '',
        'gpt-5',
        'claude-sonnet',
        '  ',
      ]),
      ['claude-sonnet', 'gpt-5'],
    );
  });

  test('maps empty override to target profile default selection', () {
    expect(
      FallbackModelSelection.selectedValueForOverride(
        modelOverride: '  ',
        knownModels: const ['backup-model'],
      ),
      const FallbackModelSelection.targetDefault(),
    );
    expect(
      FallbackModelSelection.modelOverrideForSelection(
        selection: const FallbackModelSelection.targetDefault(),
        customModel: 'ignored-custom',
      ),
      '',
    );
  });

  test('preserves known and custom fallback model overrides', () {
    expect(
      FallbackModelSelection.selectedValueForOverride(
        modelOverride: 'backup-model',
        knownModels: const ['backup-model', 'other-model'],
      ),
      const FallbackModelSelection.known('backup-model'),
    );
    expect(
      FallbackModelSelection.selectedValueForOverride(
        modelOverride: 'custom/vendor-model',
        knownModels: const ['backup-model'],
      ),
      const FallbackModelSelection.custom(),
    );
    expect(
      FallbackModelSelection.modelOverrideForSelection(
        selection: const FallbackModelSelection.known('backup-model'),
        customModel: 'custom/vendor-model',
      ),
      'backup-model',
    );
    expect(
      FallbackModelSelection.modelOverrideForSelection(
        selection: const FallbackModelSelection.custom(),
        customModel: ' custom/vendor-model ',
      ),
      'custom/vendor-model',
    );
  });

  test('treats former sentinel strings as literal known model ids', () {
    const formerDefaultSentinel = '__target_profile_default__';
    const formerCustomSentinel = '__custom_model_override__';
    const knownModels = [formerDefaultSentinel, formerCustomSentinel];

    expect(
      FallbackModelSelection.selectedValueForOverride(
        modelOverride: formerDefaultSentinel,
        knownModels: knownModels,
      ),
      const FallbackModelSelection.known(formerDefaultSentinel),
    );
    expect(
      FallbackModelSelection.modelOverrideForSelection(
        selection: const FallbackModelSelection.known(formerCustomSentinel),
        customModel: 'ignored-custom',
      ),
      formerCustomSentinel,
    );
  });
}
