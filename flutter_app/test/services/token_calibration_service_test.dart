import 'dart:convert';

import 'package:clawchat/services/token_calibration_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<TokenCalibrationService> createService({
    Map<String, Object> initialValues = const {},
  }) async {
    SharedPreferences.setMockInitialValues(initialValues);
    final prefs = await SharedPreferences.getInstance();
    return TokenCalibrationService(prefs: prefs);
  }

  TokenCalibrationSample sample({
    String key = 'anthropic|api.example.test|profile|model',
    int estimatedInputTokens = 1000,
    int? rawEstimatedInputTokens,
    int? actualInputTokens = 1200,
    int estimatedImageTokens = 0,
    int? rawEstimatedImageTokens,
    int estimatedToolTokens = 0,
    int? rawEstimatedToolTokens,
    int largestBlockTokens = 100,
    int? rawLargestBlockTokens,
    int? cacheReadTokens,
    int? cacheCreationTokens,
    bool isRecovery = false,
  }) {
    return TokenCalibrationSample(
      key: key,
      estimatedInputTokens: estimatedInputTokens,
      rawEstimatedInputTokens: rawEstimatedInputTokens ?? estimatedInputTokens,
      actualInputTokens: actualInputTokens,
      estimatedImageTokens: estimatedImageTokens,
      rawEstimatedImageTokens: rawEstimatedImageTokens ?? estimatedImageTokens,
      estimatedToolTokens: estimatedToolTokens,
      rawEstimatedToolTokens: rawEstimatedToolTokens ?? estimatedToolTokens,
      largestBlockTokens: largestBlockTokens,
      rawLargestBlockTokens: rawLargestBlockTokens ?? largestBlockTokens,
      cacheReadTokens: cacheReadTokens,
      cacheCreationTokens: cacheCreationTokens,
      isRecovery: isRecovery,
    );
  }

  group('TokenCalibrationService', () {
    test('updates multiplier with high alpha for first samples', () async {
      final service = await createService();

      final result = service.recordSample(sample());

      expect(service.multiplierFor('anthropic|api.example.test|profile|model'),
          closeTo(1.06, 0.0001));
      expect(result.updated, isTrue);
      expect(result.ratio, 1.2);
      expect(result.newMultiplier, closeTo(1.06, 0.0001));
    });

    test('returns skip reason without mutating profiles', () async {
      final service = await createService();

      final result = service.recordSample(sample(actualInputTokens: null));

      expect(result.updated, isFalse);
      expect(result.skipReason, 'missing_actual_tokens');
      expect(service.multiplierFor('anthropic|api.example.test|profile|model'),
          1.0);
    });

    test('uses lower alpha after three samples', () async {
      final service = await createService();

      for (var i = 0; i < 3; i++) {
        service.recordSample(sample(actualInputTokens: 1200));
      }
      final before = service.multiplierFor(
        'anthropic|api.example.test|profile|model',
      );
      service.recordSample(sample(actualInputTokens: 1200));
      final after = service.multiplierFor(
        'anthropic|api.example.test|profile|model',
      );

      expect(before, closeTo(1.1314, 0.0001));
      expect(after, closeTo(1.14169, 0.0001));
    });

    test('converges toward true raw ratio instead of square root', () async {
      final service = await createService();

      for (var i = 0; i < 32; i++) {
        service.recordSample(sample(
          estimatedInputTokens: (1000 *
                  service.multiplierFor(
                      'anthropic|api.example.test|profile|model'))
              .round(),
          rawEstimatedInputTokens: 1000,
          actualInputTokens: 2000,
        ));
      }

      final multiplier =
          service.multiplierFor('anthropic|api.example.test|profile|model');
      expect(multiplier, greaterThan(1.9));
      expect(multiplier, closeTo(2.0, 0.1));
    });

    test('clamps multiplier at lower and upper bounds', () async {
      final service = await createService(initialValues: {
        TokenCalibrationService.storageKey: jsonEncode({
          'low': {
            'multiplier': 0.1,
            'sampleCount': 4,
            'updatedAtMillis': 1,
          },
          'high': {
            'multiplier': 10.0,
            'sampleCount': 4,
            'updatedAtMillis': 1,
          },
        }),
      });

      expect(service.multiplierFor('low'), 0.25);
      expect(service.multiplierFor('high'), 4.0);

      service.recordSample(sample(
        key: 'low',
        estimatedInputTokens: 1000,
        actualInputTokens: 350,
      ));
      service.recordSample(sample(
        key: 'high',
        estimatedInputTokens: 1000,
        actualInputTokens: 2500,
      ));

      expect(service.multiplierFor('low'), greaterThanOrEqualTo(0.25));
      expect(service.multiplierFor('high'), lessThanOrEqualTo(4.0));
    });

    test('skips invalid or noisy samples', () async {
      final service = await createService();
      final skipped = [
        sample(actualInputTokens: null),
        sample(estimatedInputTokens: 511),
        sample(estimatedImageTokens: 250),
        sample(estimatedToolTokens: 350),
        sample(largestBlockTokens: 8000),
        sample(isRecovery: true),
        sample(actualInputTokens: 349),
        sample(actualInputTokens: 2501),
        sample(actualInputTokens: 1000, cacheReadTokens: 5000),
      ];

      for (final item in skipped) {
        service.recordSample(item);
      }

      expect(service.multiplierFor('anthropic|api.example.test|profile|model'),
          1.0);
    });

    test('uses total input tokens when cache share is not dominant', () async {
      final service = await createService();

      service.recordSample(sample(
        rawEstimatedInputTokens: 1000,
        actualInputTokens: 1000,
        cacheReadTokens: 200,
      ));

      expect(service.multiplierFor('anthropic|api.example.test|profile|model'),
          closeTo(1.06, 0.0001));
    });

    test('persists multiplier across service instances', () async {
      final service = await createService();
      service.recordSample(sample());

      final prefs = await SharedPreferences.getInstance();
      final reloaded = TokenCalibrationService(prefs: prefs);

      expect(reloaded.multiplierFor('anthropic|api.example.test|profile|model'),
          closeTo(1.06, 0.0001));
    });

    test('keeps only the 100 most recently updated profiles', () async {
      final service = await createService();

      for (var i = 0; i < 105; i++) {
        service.recordSample(sample(key: 'key-$i'));
      }

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(TokenCalibrationService.storageKey);
      final stored = jsonDecode(raw!) as Map<String, dynamic>;

      expect(stored.length, 100);
      expect(stored.containsKey('key-104'), isTrue);
    });

    test('falls back to default multiplier for bad persisted JSON', () async {
      final service = await createService(initialValues: {
        TokenCalibrationService.storageKey: '{not-json',
      });

      expect(service.multiplierFor('any'), 1.0);
    });
  });
}
