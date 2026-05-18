import 'package:clawchat/services/api_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiValidator.validateBearerUrl', () {
    test('accepts HTTPS URLs', () {
      final uri = ApiValidator.validateBearerUrl('https://api.example.com/v1');
      expect(uri.scheme, 'https');
      expect(uri.host, 'api.example.com');
    });

    test('rejects non-local HTTP URLs', () {
      expect(
        () => ApiValidator.validateBearerUrl('http://api.example.com/v1'),
        throwsException,
      );
    });

    test('allows localhost HTTP for development', () {
      expect(
        ApiValidator.validateBearerUrl('http://localhost:8080/v1').host,
        'localhost',
      );
      expect(
        ApiValidator.validateBearerUrl('http://127.0.0.1:8080/v1').host,
        '127.0.0.1',
      );
      expect(
        ApiValidator.validateBearerUrl('http://[::1]:8080/v1').host,
        '::1',
      );
    });

    test('invalid URLs throw', () {
      expect(
        () => ApiValidator.validateBearerUrl('not a url'),
        throwsException,
      );
      expect(
        () => ApiValidator.validateBearerUrl('/relative/path'),
        throwsException,
      );
    });
  });
}
