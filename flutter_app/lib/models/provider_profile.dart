import 'package:uuid/uuid.dart';

import '../constants.dart';

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
}
