import 'dart:convert';

import '../constants.dart';
import '../models/model_capabilities.dart';
import '../models/provider_profile.dart';
import 'llm_content_sanitizer.dart';
import 'runtime_debug_events.dart';

class DiagnosticsExportSummary {
  final String appVersion;
  final String? activeProfileId;
  final ProviderProfile? activeProfile;
  final ResolvedModelProfile? resolvedModelProfile;
  final String? currentSessionId;
  final String? lastError;
  final bool safeMode;
  final int startupFailureCount;
  final List<RuntimeDebugEvent> events;

  const DiagnosticsExportSummary({
    this.appVersion = AppConstants.version,
    this.activeProfileId,
    this.activeProfile,
    this.resolvedModelProfile,
    this.currentSessionId,
    this.lastError,
    this.safeMode = false,
    this.startupFailureCount = 0,
    this.events = const [],
  });
}

class DiagnosticsExportService {
  static const _maxEvents = 120;
  static const _redactedExportKeys = {
    'prompt',
    'system_prompt',
    'user_prompt',
    'message',
    'messages',
    'content',
    'payload',
    'request',
    'response',
    'tool_output',
    'tool_result',
    'raw_provider_payload',
  };
  static const _redactedExportFragments = {
    'base64',
    'image_data',
    'data_url',
    'api_key',
    'authorization',
    'secret',
    'password',
  };

  const DiagnosticsExportService();

  String buildReport(DiagnosticsExportSummary summary) {
    final buffer = StringBuffer()
      ..writeln('ClawChat diagnostics')
      ..writeln('version: ${summary.appVersion}')
      ..writeln('safeMode: ${summary.safeMode}')
      ..writeln('startupFailures: ${summary.startupFailureCount}')
      ..writeln('sessionId: ${_safeScalar(summary.currentSessionId)}')
      ..writeln('lastError: ${_safeScalar(summary.lastError)}')
      ..writeln()
      ..writeln('Provider')
      ..writeln(_providerSummary(summary))
      ..writeln()
      ..writeln('Recent events');

    final events = summary.events.length <= _maxEvents
        ? summary.events
        : summary.events.sublist(summary.events.length - _maxEvents);
    if (events.isEmpty) {
      buffer.writeln('- none');
    } else {
      for (final event in events) {
        buffer.writeln(_eventLine(event));
      }
    }

    return _finalSanitize(buffer.toString());
  }

  String _providerSummary(DiagnosticsExportSummary summary) {
    final profile = summary.activeProfile;
    final resolved = summary.resolvedModelProfile;
    final capabilities = resolved?.capabilities;
    final values = <String, Object?>{
      'profileId': summary.activeProfileId,
      'profileName': profile?.displayName,
      'apiFormat': profile?.apiFormat,
      'providerKind': resolved?.provider.kind.name,
      'providerKey': resolved?.providerKey,
      'model': resolved?.modelId ?? profile?.effectiveModel,
      if (capabilities != null) ..._capabilitySummary(capabilities),
    };
    return const JsonEncoder.withIndent('  ').convert(_sanitizeMap(values));
  }

  Map<String, Object?> _capabilitySummary(ModelCapabilities capabilities) {
    return {
      'supportsImages': capabilities.supportsImages,
      'supportsTools': capabilities.supportsTools,
      'supportsReasoningContent': capabilities.supportsReasoningContent,
      'supportsStreamingUsage': capabilities.supportsStreamingUsage,
      'streamingUsageMode': capabilities.streamingUsageMode.name,
      'tokenLimitParameter': capabilities.tokenLimitParameter.requestKey,
      'maxContextTokens': capabilities.maxContextTokens,
    };
  }

  String _eventLine(RuntimeDebugEvent event) {
    final sanitizedData = _sanitizeMap(event.data);
    final encoded =
        sanitizedData.isEmpty ? '' : ' ${jsonEncode(sanitizedData)}';
    return '- ${event.timestamp.toIso8601String()} '
        '${_safeScalar(event.type)} '
        'session=${_safeScalar(event.sessionId)}$encoded';
  }

  Map<String, Object?> _sanitizeMap(Map<dynamic, dynamic> value) {
    return _sanitizeExportValue(value) as Map<String, Object?>;
  }

  Object? _sanitizeExportValue(Object? value) {
    if (value is Map) {
      return value.map<String, Object?>((key, nested) {
        final stringKey = key.toString();
        if (_shouldRedactExportKey(stringKey)) {
          return MapEntry(stringKey, '[redacted]');
        }
        return MapEntry(stringKey, _sanitizeExportValue(nested));
      });
    }
    if (value is List) {
      return value.map(_sanitizeExportValue).toList(growable: false);
    }
    return value;
  }

  bool _shouldRedactExportKey(String key) {
    final normalized = key.toLowerCase().replaceAll('-', '_');
    return _redactedExportKeys.contains(normalized) ||
        _redactedExportFragments.any(normalized.contains);
  }

  String _safeScalar(Object? value) {
    if (value == null) return 'none';
    return const LlmContentSanitizer()
        .sanitizeText(value.toString().replaceAll(RegExp(r'\s+'), ' ').trim())
        .text;
  }

  String _finalSanitize(String report) {
    var sanitized = const LlmContentSanitizer().sanitizeText(report).text;
    sanitized = sanitized.replaceAll(
      RegExp(r'data:[^;,\s]+;base64,[A-Za-z0-9+/=_-]{40,}'),
      '[redacted: data_url]',
    );
    sanitized = sanitized.replaceAll(
      RegExp(r'\b[A-Za-z0-9+/=_-]{160,}\b'),
      '[redacted: long_token_or_base64]',
    );
    return sanitized;
  }
}
