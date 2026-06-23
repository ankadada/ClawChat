import 'package:clawchat/services/llm_content_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sanitizer = LlmContentSanitizer();

  group('LlmContentSanitizer', () {
    test('redacts authorization headers and bearer tokens', () {
      final result = sanitizer.sanitizeText(
        'Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123456789\n'
        'curl -H "authorization=Basic dXNlcjpwYXNzd29yZA=="',
      );

      expect(result.text, contains('Authorization: [redacted: bearer_token]'));
      expect(result.text, contains('authorization=[redacted: authorization]'));
      expect(result.text, isNot(contains('abcdefghijklmnopqrstuvwxyz')));
      expect(result.text, isNot(contains('dXNlcjpwYXNzd29yZA')));
      expect(result.stats.countByType['bearer_token'], 1);
      expect(result.stats.countByType['authorization'], 1);
    });

    test('redacts json env and key-value secrets', () {
      final result = sanitizer.sanitizeText(
        '{"api_key":"sk-test-value-abcdefghijklmnopqrstuvwxyz",'
        '"client_secret":"client-secret-value"}\n'
        'export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz123456\n'
        'password: hunter2\n'
        '--token cli-token-value',
      );

      expect(result.text, contains('"api_key":"[redacted: api_key]"'));
      expect(result.text, contains('"client_secret":"[redacted: secret]"'));
      expect(result.text, contains('GITHUB_TOKEN=[redacted: token]'));
      expect(result.text, contains('password: [redacted: password]'));
      expect(result.text, contains('--token [redacted: token]'));
      expect(result.text, isNot(contains('hunter2')));
      expect(result.stats.totalCount, greaterThanOrEqualTo(5));
    });

    test('redacts provider keys', () {
      final result = sanitizer.sanitizeText(
        'openai sk-proj-abcdefghijklmnopqrstuvwxyz123456 '
        'anthropic sk-ant-abcdefghijklmnopqrstuvwxyz123456 '
        'github github_pat_abcdefghijklmnopqrstuvwxyz123456 '
        'google AIzaSyA12345678901234567890123456789012 '
        'aws AKIA1234567890ABCDEF',
      );

      expect(result.text, isNot(contains('sk-proj-')));
      expect(result.text, isNot(contains('sk-ant-')));
      expect(result.text, isNot(contains('github_pat_')));
      expect(result.text, isNot(contains('AIza')));
      expect(result.text, isNot(contains('AKIA1234567890ABCDEF')));
      expect(result.stats.countByType['api_key'], greaterThanOrEqualTo(3));
      expect(result.stats.countByType['token'], 1);
      expect(result.stats.countByType['aws_key'], 1);
    });

    test('redacts pem private key blocks', () {
      final pem = [
        '-----BEGIN OPENSSH PRIVATE KEY-----',
        'abc123secret',
        '-----END OPENSSH PRIVATE KEY-----',
      ].join('\n');
      final result = sanitizer.sanitizeText('before\n$pem\nafter');

      expect(result.text, 'before\n[redacted: private_key]\nafter');
      expect(result.stats.countByType['private_key'], 1);
    });

    test('redacts url query secret parameters', () {
      final result = sanitizer.sanitizeText(
        'https://example.test/path?page=1&token=secret-token&api_key=secret-key',
      );

      expect(result.text, contains('page=1'));
      expect(result.text, contains('&token=[redacted: token]'));
      expect(result.text, contains('&api_key=[redacted: api_key]'));
      expect(result.text, isNot(contains('secret-token')));
      expect(result.text, isNot(contains('secret-key')));
    });

    test('sanitizes nested objects and counts key-based redactions', () {
      final result = sanitizer.sanitizeObject({
        'safe': 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz',
        'nested': {
          'password': 'hunter2',
          'list': ['token=abcdefghijklmnopqrstuvwxyz'],
        },
      });

      expect(result.value.toString(), isNot(contains('hunter2')));
      expect(result.value.toString(),
          isNot(contains('abcdefghijklmnopqrstuvwxyz')));
      expect(result.stats.countByType['password'], 1);
      expect(result.stats.countByType['bearer_token'], 1);
      expect(result.stats.countByType['token'], 1);
    });

    test('does not redact common false positives', () {
      const text = 'tokenization secretary passwordless '
          '123e4567-e89b-12d3-a456-426614174000 '
          'abcdef1234567890abcdef1234567890abcdef12';
      final result = sanitizer.sanitizeText(text);

      expect(result.text, text);
      expect(result.stats.hasRedactions, isFalse);
    });

    test('does not redact api_url while redacting explicit token', () {
      final result = sanitizer.sanitizeText(
        'api_url=https://example.test token=real-token',
      );

      expect(result.text, contains('api_url=https://example.test'));
      expect(result.text, contains('token=[redacted: token]'));
      expect(result.text, isNot(contains('real-token')));
      expect(result.stats.totalCount, 1);
      expect(result.stats.countByType['token'], 1);
    });
  });
}
