typedef ModelListFetcher = Future<List<String>> Function({
  required String apiFormat,
  required String apiKey,
  String? baseUrl,
});

enum FallbackModelSelectionKind { targetDefault, known, custom }

class FallbackModelSelection {
  final FallbackModelSelectionKind kind;
  final String? modelId;

  const FallbackModelSelection.targetDefault()
      : this._(FallbackModelSelectionKind.targetDefault, null);

  const FallbackModelSelection.known(String modelId)
      : this._(FallbackModelSelectionKind.known, modelId);

  const FallbackModelSelection.custom()
      : this._(FallbackModelSelectionKind.custom, null);

  const FallbackModelSelection._(this.kind, this.modelId);

  static List<String> normalizeKnownModels(Iterable<String> models) {
    final seen = <String>{};
    final normalized = <String>[];
    for (final model in models) {
      final value = model.trim();
      if (value.isEmpty || !seen.add(value)) continue;
      normalized.add(value);
    }
    return normalized;
  }

  static FallbackModelSelection selectedValueForOverride({
    required String modelOverride,
    required Iterable<String> knownModels,
  }) {
    final override = modelOverride.trim();
    if (override.isEmpty) return const FallbackModelSelection.targetDefault();
    final known = normalizeKnownModels(knownModels);
    return known.contains(override)
        ? FallbackModelSelection.known(override)
        : const FallbackModelSelection.custom();
  }

  static String modelOverrideForSelection({
    required FallbackModelSelection selection,
    required String customModel,
  }) {
    return switch (selection.kind) {
      FallbackModelSelectionKind.targetDefault => '',
      FallbackModelSelectionKind.known => selection.modelId!.trim(),
      FallbackModelSelectionKind.custom => customModel.trim(),
    };
  }

  @override
  bool operator ==(Object other) {
    return other is FallbackModelSelection &&
        other.kind == kind &&
        other.modelId == modelId;
  }

  @override
  int get hashCode => Object.hash(kind, modelId);
}
