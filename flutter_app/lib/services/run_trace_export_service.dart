import 'dart:convert';

import 'llm_content_sanitizer.dart';
import 'runtime_debug_events.dart';

class RunTraceExportService {
  static const schemaVersion = RunTraceSnapshot.schemaVersion;

  const RunTraceExportService();

  String buildJson(
    List<RunTraceSnapshot> traces, {
    DateTime? generatedAt,
  }) {
    final payload = <String, Object?>{
      'schemaVersion': schemaVersion,
      'generatedAt': (generatedAt ?? DateTime.now()).toUtc().toIso8601String(),
      'privacy': 'metadata_only',
      'persistence': 'memory_only',
      'traces': traces.map(_traceJson).toList(growable: false),
    };
    return _finalSanitize(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
  }

  Map<String, Object?> _traceJson(RunTraceSnapshot trace) => {
        'traceId': _safeIdentifier(trace.traceId),
        'sessionId': _safeIdentifier(trace.sessionId),
        'startedAt': trace.startedAt.toUtc().toIso8601String(),
        if (trace.endedAt != null)
          'endedAt': trace.endedAt!.toUtc().toIso8601String(),
        'status': trace.status.wireValue,
        'durationMs': trace.duration.inMilliseconds,
        'events': trace.events
            .map((event) => <String, Object?>{
                  'sequence': event.sequence,
                  'timestamp': event.timestamp.toUtc().toIso8601String(),
                  'type': event.type,
                  if (event.data.isNotEmpty) 'data': event.data,
                })
            .toList(growable: false),
      };

  String _safeIdentifier(String value) {
    final normalized = value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return normalized.length <= 160 ? normalized : normalized.substring(0, 160);
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
