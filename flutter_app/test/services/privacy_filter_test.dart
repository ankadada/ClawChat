import 'dart:convert';

import 'package:clawchat/services/privacy_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PrivacyFilter.maskEnvVarValues', () {
    test('fully masks short and long environment values', () {
      final output = PrivacyFilter.maskEnvVarValues(
        'a=x b=ab token=supersecret12345',
        const {
          'ONE': 'x',
          'TWO': 'ab',
          'SECRET': 'supersecret12345',
        },
      );

      expect(output, isNot(contains('x')));
      expect(output, isNot(contains('ab')));
      expect(output, isNot(contains('supersecret12345')));
      expect(output, contains('********'));
      expect(output, isNot(contains('sup')));
      expect(output, isNot(contains('2345')));
    });

    test('masks base64 output from echo secret pipe', () {
      const secret = 'supersecret12345';
      final encodedWithEchoNewline = base64Encode(utf8.encode('$secret\n'));
      final output = PrivacyFilter.maskEnvVarValues(
        'echo \$SECRET | base64 -> $encodedWithEchoNewline',
        const {'SECRET': secret},
      );

      expect(output, isNot(contains(encodedWithEchoNewline)));
      expect(output, isNot(contains(secret)));
    });

    test('masks URL-safe base64 variants', () {
      const secret = '?????abc';
      final encoded = base64Url.encode(utf8.encode(secret));
      expect(encoded, contains('_'));
      final output = PrivacyFilter.maskEnvVarValues(
        'token=$encoded',
        const {'SECRET': secret},
      );

      expect(output, isNot(contains(encoded)));
      expect(output, isNot(contains(secret)));
    });

    test('masks xxd hex and ascii output from printf secret pipe', () {
      const secret = 'supersecret12345';
      const xxdLine =
          '00000000: 7375 7065 7273 6563 7265 7431 3233 3435  supersecret12345';
      final output = PrivacyFilter.maskEnvVarValues(
        'printf %s "\$SECRET" | xxd\n$xxdLine',
        const {'SECRET': secret},
      );

      expect(output, isNot(contains('7375 7065 7273 6563')));
      expect(output, isNot(contains(secret)));
    });
  });
}
