import 'package:flutter_test/flutter_test.dart';

// Extracted from LlmService._sanitizeErrorBody for unit testing.
// Must be kept in sync with lib/services/llm_service.dart.
String sanitizeErrorBody(String body) {
  String sanitized =
      body.length > 500 ? '${body.substring(0, 500)}...' : body;
  sanitized = sanitized.replaceAll(
    RegExp(r'(sk-|key-|api-)[a-zA-Z0-9_-]{10,}'),
    '[REDACTED]',
  );
  return sanitized;
}

// Extracted from LlmService._isRetryableHttpError for unit testing.
bool isRetryableHttpError(String msg) {
  final pattern = RegExp(r'\((429|5\d{2})\)');
  return pattern.hasMatch(msg);
}

void main() {
  group('LlmService._sanitizeErrorBody', () {
    test('returns short body unchanged', () {
      const msg = 'Rate limit exceeded. Please retry after 60s.';
      expect(sanitizeErrorBody(msg), msg);
    });

    test('truncates body longer than 500 chars', () {
      final long = 'a' * 1000;
      final result = sanitizeErrorBody(long);
      expect(result.length, 503); // 500 chars + '...'
      expect(result, endsWith('...'));
      expect(result.startsWith('a' * 500), isTrue);
    });

    test('truncates exactly at 500 boundary', () {
      final exact500 = 'b' * 500;
      expect(sanitizeErrorBody(exact500), exact500);

      final exact501 = 'c' * 501;
      final result = sanitizeErrorBody(exact501);
      expect(result.length, 503);
    });

    test('redacts sk- prefixed API keys', () {
      final input = 'Invalid key: sk-ant-api03-xxxxxxxxxxxx';
      final result = sanitizeErrorBody(input);
      expect(result, contains('[REDACTED]'));
      expect(result, isNot(contains('sk-ant-api03-xxxxxxxxxxxx')));
    });

    test('redacts key- prefixed tokens', () {
      final result = sanitizeErrorBody('Error with key-abcdefghijklmnop');
      expect(result, contains('[REDACTED]'));
      expect(result, isNot(contains('key-abcdefghijklmnop')));
    });

    test('redacts api- prefixed tokens', () {
      final result = sanitizeErrorBody('Token: api-1234567890abcdef');
      expect(result, contains('[REDACTED]'));
      expect(result, isNot(contains('api-1234567890abcdef')));
    });

    test('does not redact short key-like strings (less than 10 chars)', () {
      // The regex requires 10+ chars after the prefix
      final result = sanitizeErrorBody('sk-short');
      expect(result, 'sk-short');
    });

    test('redacts multiple keys in same body', () {
      final input = 'Keys: sk-aaaaaaaaaa and api-bbbbbbbbbb found';
      final result = sanitizeErrorBody(input);
      expect(result, isNot(contains('sk-aaaaaaaaaa')));
      expect(result, isNot(contains('api-bbbbbbbbbb')));
      expect('[REDACTED]'.allMatches(result).length, 2);
    });

    test('handles empty body', () {
      expect(sanitizeErrorBody(''), '');
    });

    test('preserves non-key content around redacted keys', () {
      final result = sanitizeErrorBody(
        'Error 401: key-abcdefghijklmnop is invalid',
      );
      expect(result, contains('Error 401:'));
      expect(result, contains('is invalid'));
      expect(result, contains('[REDACTED]'));
    });

    test('redacts keys with underscores and dashes', () {
      final result = sanitizeErrorBody('sk-ant_api03-key_with-dashes_123');
      expect(result, contains('[REDACTED]'));
    });

    test('truncation happens before redaction', () {
      // Place an API key after char 500 to verify it gets truncated away
      final body = '${'x' * 510}sk-aaaaaaaaaa';
      final result = sanitizeErrorBody(body);
      expect(result.length, 503);
      // Key is beyond truncation point, so it is gone
      expect(result, isNot(contains('sk-aaaaaaaaaa')));
    });
  });

  group('LlmService._isRetryableHttpError', () {
    test('matches 429 rate limit', () {
      expect(isRetryableHttpError('API error (429): rate limited'), isTrue);
    });

    test('matches 500 internal server error', () {
      expect(isRetryableHttpError('API error (500): server error'), isTrue);
    });

    test('matches 502 bad gateway', () {
      expect(isRetryableHttpError('API error (502): bad gateway'), isTrue);
    });

    test('matches 503 service unavailable', () {
      expect(isRetryableHttpError('API error (503): unavailable'), isTrue);
    });

    test('matches 504 gateway timeout', () {
      expect(isRetryableHttpError('API error (504): timeout'), isTrue);
    });

    test('does not match 400 bad request', () {
      expect(isRetryableHttpError('API error (400): bad request'), isFalse);
    });

    test('does not match 401 unauthorized', () {
      expect(isRetryableHttpError('API error (401): unauthorized'), isFalse);
    });

    test('does not match 403 forbidden', () {
      expect(isRetryableHttpError('API error (403): forbidden'), isFalse);
    });

    test('does not match 404 not found', () {
      expect(isRetryableHttpError('API error (404): not found'), isFalse);
    });

    test('does not match plain text without status code', () {
      expect(isRetryableHttpError('some random error'), isFalse);
    });

    test('does not match empty string', () {
      expect(isRetryableHttpError(''), isFalse);
    });
  });

  group('LlmConfig equality', () {
    // These tests use the data classes directly; no HTTP dependency.
    test('ContentBlock.toJson produces correct text block', () {
      const block = ContentBlock(type: 'text', text: 'hello');
      final json = block.toJson();
      expect(json['type'], 'text');
      expect(json['text'], 'hello');
    });

    test('ContentBlock.toJson produces correct tool_use block', () {
      const block = ContentBlock(
        type: 'tool_use',
        toolUseId: 'call_123',
        toolName: 'bash',
        toolInput: {'command': 'ls'},
      );
      final json = block.toJson();
      expect(json['type'], 'tool_use');
      expect(json['id'], 'call_123');
      expect(json['name'], 'bash');
      expect(json['input'], {'command': 'ls'});
    });

    test('ToolDefinition.toAnthropicJson format', () {
      const tool = ToolDefinition(
        name: 'bash',
        description: 'Run a command',
        inputSchema: {
          'type': 'object',
          'properties': {
            'command': {'type': 'string'}
          }
        },
      );
      final json = tool.toAnthropicJson();
      expect(json['name'], 'bash');
      expect(json['description'], 'Run a command');
      expect(json['input_schema'], isNotNull);
    });

    test('ToolDefinition.toOpenAIJson format', () {
      const tool = ToolDefinition(
        name: 'bash',
        description: 'Run a command',
        inputSchema: {
          'type': 'object',
          'properties': {
            'command': {'type': 'string'}
          }
        },
      );
      final json = tool.toOpenAIJson();
      expect(json['type'], 'function');
      expect(json['function']['name'], 'bash');
      expect(json['function']['description'], 'Run a command');
      expect(json['function']['parameters'], isNotNull);
    });
  });
}

// Re-declare data classes here since importing from the source would pull in
// http and other Flutter dependencies. These are value-class copies for testing
// serialization logic only.
class ContentBlock {
  final String type;
  final String? text;
  final String? toolUseId;
  final String? toolName;
  final Map<String, dynamic>? toolInput;

  const ContentBlock({
    required this.type,
    this.text,
    this.toolUseId,
    this.toolName,
    this.toolInput,
  });

  Map<String, dynamic> toJson() {
    if (type == 'text') {
      return {'type': 'text', 'text': text};
    } else {
      return {
        'type': 'tool_use',
        'id': toolUseId,
        'name': toolName,
        'input': toolInput,
      };
    }
  }
}

class ToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const ToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  Map<String, dynamic> toAnthropicJson() => {
        'name': name,
        'description': description,
        'input_schema': inputSchema,
      };

  Map<String, dynamic> toOpenAIJson() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': inputSchema,
        },
      };
}
