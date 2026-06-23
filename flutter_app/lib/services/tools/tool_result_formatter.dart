import 'dart:convert';

import '../../models/chat_models.dart';

class ToolResultFormatter {
  static const int defaultLlmCharLimit = 12000;
  static const int bashLlmCharLimit = 12000;
  static const int readFileLlmCharLimit = 12000;
  static const int webFetchLlmCharLimit = 16000;
  static const int _longLineLimit = 1600;
  static const int _longLineHead = 900;
  static const int _longLineTail = 300;

  const ToolResultFormatter._();

  static ToolResultPayload format({
    required String toolName,
    required Map<String, dynamic> input,
    required String output,
    bool isError = false,
  }) {
    return switch (toolName) {
      'bash' => bash(input: input, output: output, isError: isError),
      'read_file' => readFile(input: input, output: output, isError: isError),
      'web_fetch' => webFetch(input: input, output: output, isError: isError),
      'write_file' => writeFile(input: input, output: output, isError: isError),
      'set_env_var' => envVar(input: input, output: output, isError: isError),
      'generate_image' =>
        imageGen(input: input, output: output, isError: isError),
      _ => generic(toolName: toolName, output: output, isError: isError),
    };
  }

  static ToolResultPayload generic({
    required String toolName,
    required String output,
    bool isError = false,
    int limit = defaultLlmCharLimit,
  }) {
    final sanitized = _sanitizeForLlm(output);
    final fitted = _headTail(sanitized, limit);
    final forLlm = _encodeEnvelope({
      'tool': toolName,
      'status': isError ? 'error' : 'success',
      'output': fitted.text,
      if (fitted.truncated) 'truncated': true,
      if (fitted.omittedChars > 0) 'omitted_chars': fitted.omittedChars,
    });
    return ToolResultPayload(
      forUser: output,
      forLlm: forLlm,
      summary: _summary(toolName, isError, fitted.text),
      metadata: _metadata(
        toolName: toolName,
        original: output,
        forLlm: forLlm,
        truncated: fitted.truncated,
        omittedReason: _omissionReason(sanitized, fitted),
        status: isError ? 'error' : 'success',
      ),
    );
  }

  static ToolResultPayload bash({
    required Map<String, dynamic> input,
    required String output,
    bool isError = false,
  }) {
    final sanitized = _sanitizeForLlm(output);
    final fitted = _headTail(sanitized, bashLlmCharLimit);
    final command = input['command']?.toString() ?? '';
    final forLlm = _encodeEnvelope({
      'tool': 'bash',
      'status': isError ? 'error' : 'success',
      'command': command,
      'output': fitted.text,
      if (fitted.truncated) 'truncated': true,
      if (fitted.omittedChars > 0) 'omitted_chars': fitted.omittedChars,
    });
    return ToolResultPayload(
      forUser: output,
      forLlm: forLlm,
      summary: 'bash ${isError ? 'failed' : 'completed'}: $command',
      metadata: _metadata(
        toolName: 'bash',
        original: output,
        forLlm: forLlm,
        truncated: fitted.truncated,
        omittedReason: _omissionReason(sanitized, fitted),
        status: isError ? 'error' : 'success',
      ),
    );
  }

  static ToolResultPayload readFile({
    required Map<String, dynamic> input,
    required String output,
    bool isError = false,
  }) {
    final sanitized = _sanitizeForLlm(output);
    final fitted = _headTail(sanitized, readFileLlmCharLimit);
    final path = input['path']?.toString() ?? '';
    final forLlm = _encodeEnvelope({
      'tool': 'read_file',
      'status': isError ? 'error' : 'success',
      'path': path,
      if (input['offset'] != null) 'offset': input['offset'],
      if (input['limit'] != null) 'limit': input['limit'],
      'content': fitted.text,
      if (fitted.truncated) 'truncated': true,
      if (fitted.omittedChars > 0) 'omitted_chars': fitted.omittedChars,
      if (fitted.truncated)
        'note': 'Use read_file with offset/limit to inspect omitted lines.',
    });
    return ToolResultPayload(
      forUser: output,
      forLlm: forLlm,
      summary: 'read_file ${isError ? 'failed' : 'read'}: $path',
      metadata: _metadata(
        toolName: 'read_file',
        original: output,
        forLlm: forLlm,
        truncated: fitted.truncated,
        omittedReason: _omissionReason(sanitized, fitted),
        status: isError ? 'error' : 'success',
      ),
    );
  }

  static ToolResultPayload webFetch({
    required Map<String, dynamic> input,
    required String output,
    bool isError = false,
  }) {
    final sanitized = _sanitizeForLlm(_stripNoisyHtml(output));
    final fitted = _headTail(sanitized, webFetchLlmCharLimit);
    final url = input['url']?.toString() ?? '';
    final forLlm = _encodeEnvelope({
      'tool': 'web_fetch',
      'status': isError ? 'error' : 'success',
      'url': url,
      'content': fitted.text,
      if (fitted.truncated) 'truncated': true,
      if (fitted.omittedChars > 0) 'omitted_chars': fitted.omittedChars,
    });
    return ToolResultPayload(
      forUser: output,
      forLlm: forLlm,
      summary: 'web_fetch ${isError ? 'failed' : 'fetched'}: $url',
      metadata: _metadata(
        toolName: 'web_fetch',
        original: output,
        forLlm: forLlm,
        truncated: fitted.truncated,
        omittedReason: _omissionReason(sanitized, fitted),
        status: isError ? 'error' : 'success',
      ),
    );
  }

  static ToolResultPayload writeFile({
    required Map<String, dynamic> input,
    required String output,
    bool isError = false,
  }) {
    final path = input['path']?.toString() ?? '';
    final payload = _encodeEnvelope({
      'tool': 'write_file',
      'status': isError ? 'error' : 'success',
      'path': path,
      'message': _headTail(_sanitizeForLlm(output), 2000).text,
    });
    return ToolResultPayload(
      forUser: output,
      forLlm: payload,
      summary: 'write_file ${isError ? 'failed' : 'wrote'}: $path',
      metadata: _metadata(
        toolName: 'write_file',
        original: output,
        forLlm: payload,
        status: isError ? 'error' : 'success',
      ),
    );
  }

  static ToolResultPayload envVar({
    required Map<String, dynamic> input,
    required String output,
    bool isError = false,
  }) {
    final name = input['name']?.toString() ?? '';
    final action = input['action']?.toString() ?? 'set';
    final payload = _encodeEnvelope({
      'tool': 'set_env_var',
      'status': isError ? 'error' : 'success',
      'name': name,
      'action': action,
      'message': _headTail(_sanitizeForLlm(output), 2000).text,
    });
    return ToolResultPayload(
      forUser: output,
      forLlm: payload,
      summary: 'set_env_var $action: $name',
      metadata: _metadata(
        toolName: 'set_env_var',
        original: output,
        forLlm: payload,
        status: isError ? 'error' : 'success',
      ),
    );
  }

  static ToolResultPayload imageGen({
    required Map<String, dynamic> input,
    required String output,
    bool isError = false,
  }) {
    final fitted = _headTail(_sanitizeForLlm(output), 4000);
    final payload = _encodeEnvelope({
      'tool': 'generate_image',
      'status': isError ? 'error' : 'success',
      if (input['size'] != null) 'size': input['size'],
      'result': fitted.text,
      if (fitted.truncated) 'truncated': true,
    });
    return ToolResultPayload(
      forUser: output,
      forLlm: payload,
      summary: 'generate_image ${isError ? 'failed' : 'completed'}',
      metadata: _metadata(
        toolName: 'generate_image',
        original: output,
        forLlm: payload,
        truncated: fitted.truncated,
        status: isError ? 'error' : 'success',
      ),
    );
  }

  static String _encodeEnvelope(Map<String, dynamic> envelope) {
    return const JsonEncoder.withIndent('  ').convert(envelope);
  }

  static Map<String, dynamic> _metadata({
    required String toolName,
    required String original,
    required String forLlm,
    bool truncated = false,
    String? omittedReason,
    String? status,
  }) {
    return {
      'toolName': toolName,
      'originalChars': original.length,
      'llmChars': forLlm.length,
      'truncated': truncated,
      if (omittedReason != null) 'omittedReason': omittedReason,
      if (status != null) 'status': status,
    };
  }

  static String _sanitizeForLlm(String text) {
    return _compressLongLines(_omitBase64(text));
  }

  static String _omitBase64(String text) {
    var omittedCount = 0;
    var result = text.replaceAllMapped(
      RegExp(r'data:[^;,\s]+;base64,[A-Za-z0-9+/=_-]{120,}'),
      (match) {
        omittedCount++;
        return '[data URL omitted: chars=${match.group(0)!.length}]';
      },
    );
    result = result.replaceAllMapped(
      RegExp(
        r'(^|[^A-Za-z0-9+/=_-])([A-Za-z0-9+/=_-]{800,})($|[^A-Za-z0-9+/=_-])',
      ),
      (match) {
        final value = match.group(2)!;
        if (!_looksLikeBase64(value)) return value;
        omittedCount++;
        return '${match.group(1)!}[base64 omitted: chars=${value.length}]'
            '${match.group(3)!}';
      },
    );
    if (omittedCount == 0) return result;
    return result;
  }

  static bool _looksLikeBase64(String value) {
    if (value.length < 800) return false;
    final base64ish = RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(value);
    if (!base64ish) return false;
    final padding = '='.allMatches(value).length;
    return padding <= 2;
  }

  static String _compressLongLines(String text) {
    return text.split('\n').map((line) {
      if (line.length <= _longLineLimit) return line;
      final head = line.substring(0, _longLineHead);
      final tail = line.substring(line.length - _longLineTail);
      final omitted = line.length - head.length - tail.length;
      return '$head...[long line omitted: chars=$omitted]...$tail';
    }).join('\n');
  }

  static String _stripNoisyHtml(String text) {
    var result = text.replaceAll(
      RegExp(r'<script\b[^>]*>.*?</script>',
          caseSensitive: false, dotAll: true),
      '[script omitted]',
    );
    result = result.replaceAll(
      RegExp(r'<style\b[^>]*>.*?</style>', caseSensitive: false, dotAll: true),
      '[style omitted]',
    );
    return result;
  }

  static _FittedText _headTail(String text, int limit) {
    if (limit <= 0) {
      return _FittedText(
        '[omitted: chars=${text.length}]',
        truncated: text.isNotEmpty,
        omittedChars: text.length,
      );
    }
    if (text.length <= limit) {
      return _FittedText(text, truncated: false, omittedChars: 0);
    }
    final marker = '\n\n[... omitted ${text.length - limit} chars ...]\n\n';
    final remaining = (limit - marker.length).clamp(0, limit);
    final headLength = (remaining * 0.6).floor();
    final tailLength = remaining - headLength;
    return _FittedText(
      '${text.substring(0, headLength)}$marker${text.substring(text.length - tailLength)}',
      truncated: true,
      omittedChars: text.length - headLength - tailLength,
    );
  }

  static String? _omissionReason(String sanitized, _FittedText fitted) {
    final reasons = <String>[];
    if (fitted.truncated) reasons.add('length');
    if (sanitized.contains('base64 omitted') ||
        sanitized.contains('data URL omitted')) {
      reasons.add('base64');
    }
    if (sanitized.contains('long line omitted')) reasons.add('long_line');
    return reasons.isEmpty ? null : reasons.join(',');
  }

  static String _summary(String toolName, bool isError, String output) {
    final normalized = output.replaceAll(RegExp(r'\s+'), ' ').trim();
    final preview = normalized.length <= 120
        ? normalized
        : '${normalized.substring(0, 120)}...';
    return '$toolName ${isError ? 'error' : 'success'}'
        '${preview.isEmpty ? '' : ': $preview'}';
  }
}

class _FittedText {
  final String text;
  final bool truncated;
  final int omittedChars;

  const _FittedText(
    this.text, {
    required this.truncated,
    required this.omittedChars,
  });
}
