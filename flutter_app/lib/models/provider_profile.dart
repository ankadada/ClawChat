import 'package:uuid/uuid.dart';

import '../constants.dart';
import 'model_capabilities.dart';

class ModelFallbackTarget {
  final String targetProfileId;
  final String modelOverride;
  final bool enabled;

  const ModelFallbackTarget({
    required this.targetProfileId,
    this.modelOverride = '',
    this.enabled = true,
  });

  String get effectiveModelOverride => modelOverride.trim();

  bool get hasModelOverride => effectiveModelOverride.isNotEmpty;

  String effectiveModelFor(ProviderProfile targetProfile) {
    return hasModelOverride
        ? effectiveModelOverride
        : targetProfile.effectiveModel;
  }

  ModelFallbackTarget copyWith({
    String? targetProfileId,
    String? modelOverride,
    bool? enabled,
  }) {
    return ModelFallbackTarget(
      targetProfileId: targetProfileId ?? this.targetProfileId,
      modelOverride: modelOverride ?? this.modelOverride,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'targetProfileId': targetProfileId,
        'modelOverride': modelOverride,
        'enabled': enabled,
      };

  factory ModelFallbackTarget.fromJson(Map<String, dynamic> json) {
    final targetProfileId = json['targetProfileId']?.toString().trim();
    if (targetProfileId == null || targetProfileId.isEmpty) {
      throw const FormatException('Invalid fallback target profile id');
    }
    final enabled = json['enabled'];
    return ModelFallbackTarget(
      targetProfileId: targetProfileId,
      modelOverride: json['modelOverride']?.toString().trim() ?? '',
      enabled: enabled is bool ? enabled : true,
    );
  }
}

class ProviderProfile {
  static const anthropicFormat = 'anthropic';
  static const openaiFormat = 'openai';

  final String id;
  String name;
  String apiFormat;
  String apiKey;
  String baseUrl;
  String model;
  int maxTokens;
  int thinkingBudget;
  double temperature;
  CapabilityOverride? capabilityOverride;
  final List<ModelFallbackTarget> fallbackTargets;

  ProviderProfile({
    String? id,
    required this.name,
    required this.apiFormat,
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    required this.maxTokens,
    required this.thinkingBudget,
    required this.temperature,
    this.capabilityOverride,
    this.fallbackTargets = const [],
  }) : id = id ?? const Uuid().v4();

  factory ProviderProfile.defaults({String name = '默认配置'}) {
    return ProviderProfile(
      name: name,
      apiFormat: anthropicFormat,
      apiKey: '',
      baseUrl: '',
      model: AppConstants.defaultModel,
      maxTokens: AppConstants.defaultMaxTokens,
      thinkingBudget: 0,
      temperature: AppConstants.defaultTemperature,
    );
  }

  String get displayName => name.trim().isEmpty ? '未命名配置' : name.trim();

  String get effectiveModel =>
      model.trim().isEmpty ? AppConstants.defaultModel : model.trim();

  bool get hasEnabledFallbackTargets =>
      fallbackTargets.any((target) => target.enabled);

  ProviderProfile copyWith({
    String? id,
    String? name,
    String? apiFormat,
    String? apiKey,
    String? baseUrl,
    String? model,
    int? maxTokens,
    int? thinkingBudget,
    double? temperature,
    CapabilityOverride? capabilityOverride,
    List<ModelFallbackTarget>? fallbackTargets,
    bool clearCapabilityOverride = false,
  }) {
    return ProviderProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      apiFormat: apiFormat ?? this.apiFormat,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      maxTokens: maxTokens ?? this.maxTokens,
      thinkingBudget: thinkingBudget ?? this.thinkingBudget,
      temperature: temperature ?? this.temperature,
      capabilityOverride: clearCapabilityOverride
          ? null
          : (capabilityOverride ?? this.capabilityOverride),
      fallbackTargets: fallbackTargets ?? this.fallbackTargets,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'apiFormat': apiFormat,
        'apiKey': apiKey,
        'baseUrl': baseUrl,
        'model': model,
        'maxTokens': maxTokens,
        'thinkingBudget': thinkingBudget,
        'temperature': temperature,
        if (capabilityOverride != null && !capabilityOverride!.isEmpty)
          'capabilityOverride': capabilityOverride!.toJson(),
        if (fallbackTargets.isNotEmpty)
          'fallbackTargets':
              fallbackTargets.map((target) => target.toJson()).toList(),
      };

  factory ProviderProfile.fromJson(Map<String, dynamic> json) {
    return ProviderProfile(
      id: _stringValue(json['id'], fallback: const Uuid().v4()),
      name: _stringValue(json['name'], fallback: '默认配置'),
      apiFormat: _normalizeApiFormat(json['apiFormat']),
      apiKey: _stringValue(json['apiKey']),
      baseUrl: _stringValue(json['baseUrl']),
      model: _stringValue(
        json['model'],
        fallback: AppConstants.defaultModel,
      ),
      maxTokens: _intValue(
        json['maxTokens'],
        fallback: AppConstants.defaultMaxTokens,
      ),
      thinkingBudget: _intValue(json['thinkingBudget']),
      temperature: _doubleValue(
        json['temperature'],
        fallback: AppConstants.defaultTemperature,
      ),
      capabilityOverride: _capabilityOverride(json['capabilityOverride']),
      fallbackTargets: _fallbackTargets(json['fallbackTargets']),
    );
  }

  static String _normalizeApiFormat(Object? value) {
    final text = value?.toString();
    return text == openaiFormat ? openaiFormat : anthropicFormat;
  }

  static String _stringValue(Object? value, {String fallback = ''}) {
    final text = value?.toString();
    return text == null || text.isEmpty ? fallback : text;
  }

  static int _intValue(Object? value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static double _doubleValue(Object? value, {double fallback = 0}) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static CapabilityOverride? _capabilityOverride(Object? value) {
    if (value is! Map) return null;
    final override = CapabilityOverride.fromJson(
      Map<String, dynamic>.from(value),
    );
    return override.isEmpty ? null : override;
  }

  static List<ModelFallbackTarget> _fallbackTargets(Object? value) {
    if (value == null) return const [];
    if (value is! List) {
      throw const FormatException('Invalid fallback targets');
    }
    final targets = <ModelFallbackTarget>[];
    for (final item in value) {
      if (item is! Map) {
        throw const FormatException('Invalid fallback target');
      }
      targets.add(
        ModelFallbackTarget.fromJson(Map<String, dynamic>.from(item)),
      );
    }
    return targets;
  }
}
