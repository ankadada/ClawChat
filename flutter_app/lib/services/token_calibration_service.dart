import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TokenCalibrationSample {
  final String key;
  final int estimatedInputTokens;
  final int rawEstimatedInputTokens;
  final int? actualInputTokens;
  final int estimatedImageTokens;
  final int rawEstimatedImageTokens;
  final int estimatedToolTokens;
  final int rawEstimatedToolTokens;
  final int largestBlockTokens;
  final int rawLargestBlockTokens;
  final int? cacheReadTokens;
  final int? cacheCreationTokens;
  final bool isRecovery;

  const TokenCalibrationSample({
    required this.key,
    required this.estimatedInputTokens,
    required this.rawEstimatedInputTokens,
    required this.actualInputTokens,
    required this.estimatedImageTokens,
    required this.rawEstimatedImageTokens,
    required this.estimatedToolTokens,
    required this.rawEstimatedToolTokens,
    required this.largestBlockTokens,
    required this.rawLargestBlockTokens,
    this.cacheReadTokens,
    this.cacheCreationTokens,
    this.isRecovery = false,
  });

  int? get totalInputTokens {
    final actual = actualInputTokens;
    if (actual == null) return null;
    if (key.startsWith('anthropic|')) {
      return actual + (cacheReadTokens ?? 0) + (cacheCreationTokens ?? 0);
    }
    return actual;
  }
}

class TokenCalibrationRecordResult {
  final String key;
  final bool updated;
  final String? skipReason;
  final int estimatedInputTokens;
  final int rawEstimatedInputTokens;
  final int? actualInputTokens;
  final int? totalInputTokens;
  final double? oldMultiplier;
  final double? ratio;
  final double? newMultiplier;

  const TokenCalibrationRecordResult._({
    required this.key,
    required this.updated,
    required this.skipReason,
    required this.estimatedInputTokens,
    required this.rawEstimatedInputTokens,
    required this.actualInputTokens,
    required this.totalInputTokens,
    this.oldMultiplier,
    this.ratio,
    this.newMultiplier,
  });

  factory TokenCalibrationRecordResult.updated({
    required TokenCalibrationSample sample,
    required double oldMultiplier,
    required double ratio,
    required double newMultiplier,
  }) {
    return TokenCalibrationRecordResult._(
      key: sample.key,
      updated: true,
      skipReason: null,
      estimatedInputTokens: sample.estimatedInputTokens,
      rawEstimatedInputTokens: sample.rawEstimatedInputTokens,
      actualInputTokens: sample.actualInputTokens,
      totalInputTokens: sample.totalInputTokens,
      oldMultiplier: oldMultiplier,
      ratio: ratio,
      newMultiplier: newMultiplier,
    );
  }

  factory TokenCalibrationRecordResult.skipped({
    required TokenCalibrationSample sample,
    required String reason,
  }) {
    return TokenCalibrationRecordResult._(
      key: sample.key,
      updated: false,
      skipReason: reason,
      estimatedInputTokens: sample.estimatedInputTokens,
      rawEstimatedInputTokens: sample.rawEstimatedInputTokens,
      actualInputTokens: sample.actualInputTokens,
      totalInputTokens: sample.totalInputTokens,
    );
  }
}

class TokenCalibrationService {
  static const storageKey = 'token_calibration_profiles';
  static const maxProfiles = 100;
  static const defaultMultiplier = 1.0;
  static const minMultiplier = 0.25;
  static const maxMultiplier = 4.0;

  SharedPreferences? _prefs;
  int _lastUpdateMillis = 0;

  TokenCalibrationService({SharedPreferences? prefs}) : _prefs = prefs;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  double multiplierFor(String key) {
    final profile = _loadProfiles()[key];
    return (profile?.multiplier ?? defaultMultiplier)
        .clamp(minMultiplier, maxMultiplier)
        .toDouble();
  }

  TokenCalibrationRecordResult recordSample(TokenCalibrationSample sample) {
    final skipReason = _skipReason(sample);
    if (skipReason != null) {
      return TokenCalibrationRecordResult.skipped(
        sample: sample,
        reason: skipReason,
      );
    }

    final totalInputTokens = sample.totalInputTokens!;
    final ratio = totalInputTokens / sample.rawEstimatedInputTokens;
    final profiles = _loadProfiles();
    final oldProfile = profiles[sample.key];
    final oldMultiplier = (oldProfile?.multiplier ?? defaultMultiplier)
        .clamp(minMultiplier, maxMultiplier)
        .toDouble();
    final oldSampleCount = oldProfile?.sampleCount ?? 0;
    final alpha = oldSampleCount < 3 ? 0.30 : 0.15;
    final nextMultiplier = (oldMultiplier * (1 - alpha) + ratio * alpha)
        .clamp(minMultiplier, maxMultiplier)
        .toDouble();

    profiles[sample.key] = _TokenCalibrationProfile(
      multiplier: nextMultiplier,
      sampleCount: oldSampleCount + 1,
      updatedAtMillis: _nextUpdateMillis(),
    );
    _saveProfiles(_trimProfiles(profiles));
    debugPrint(
      'Token calibration updated: key=${sample.key}, '
      'old=${oldMultiplier.toStringAsFixed(3)}, '
      'ratio=${ratio.toStringAsFixed(3)}, '
      'new=${nextMultiplier.toStringAsFixed(3)}',
    );
    return TokenCalibrationRecordResult.updated(
      sample: sample,
      oldMultiplier: oldMultiplier,
      ratio: ratio,
      newMultiplier: nextMultiplier,
    );
  }

  String? _skipReason(TokenCalibrationSample sample) {
    final totalInputTokens = sample.totalInputTokens;
    if (totalInputTokens == null) return 'missing_actual_tokens';
    if (sample.rawEstimatedInputTokens < 512) return 'estimate_too_small';
    if (sample.isRecovery) return 'recovery';

    final estimated = sample.rawEstimatedInputTokens;
    final cachedTokens =
        (sample.cacheReadTokens ?? 0) + (sample.cacheCreationTokens ?? 0);
    if (cachedTokens > 0 && cachedTokens / totalInputTokens > 0.8) {
      return 'cache_share_too_high';
    }
    if (sample.rawEstimatedImageTokens / estimated >= 0.25) {
      return 'image_share_too_high';
    }
    if (sample.rawEstimatedToolTokens / estimated >= 0.35) {
      return 'tool_share_too_high';
    }
    if (sample.rawLargestBlockTokens >= 8000) return 'large_block';

    final ratio = totalInputTokens / estimated;
    if (ratio < 0.35 || ratio > 2.5) return 'ratio_out_of_range';
    return null;
  }

  Map<String, _TokenCalibrationProfile> _loadProfiles() {
    final raw = _requirePrefs().getString(storageKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final profiles = <String, _TokenCalibrationProfile>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! Map) continue;
        final profile = _TokenCalibrationProfile.fromJson(
          Map<String, dynamic>.from(value),
        );
        if (profile != null) profiles[key] = profile;
      }
      return profiles;
    } catch (_) {
      return {};
    }
  }

  void _saveProfiles(Map<String, _TokenCalibrationProfile> profiles) {
    final encoded = profiles.map(
      (key, value) => MapEntry(key, value.toJson()),
    );
    _requirePrefs().setString(storageKey, jsonEncode(encoded));
  }

  Map<String, _TokenCalibrationProfile> _trimProfiles(
    Map<String, _TokenCalibrationProfile> profiles,
  ) {
    if (profiles.length <= maxProfiles) return profiles;
    final entries = profiles.entries.toList()
      ..sort(
        (a, b) => b.value.updatedAtMillis.compareTo(a.value.updatedAtMillis),
      );
    return Map<String, _TokenCalibrationProfile>.fromEntries(
      entries.take(maxProfiles),
    );
  }

  SharedPreferences _requirePrefs() {
    final prefs = _prefs;
    if (prefs == null) {
      throw StateError('TokenCalibrationService.init() must be called first.');
    }
    return prefs;
  }

  int _nextUpdateMillis() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastUpdateMillis = math.max(now, _lastUpdateMillis + 1);
    return _lastUpdateMillis;
  }
}

class _TokenCalibrationProfile {
  final double multiplier;
  final int sampleCount;
  final int updatedAtMillis;

  const _TokenCalibrationProfile({
    required this.multiplier,
    required this.sampleCount,
    required this.updatedAtMillis,
  });

  static _TokenCalibrationProfile? fromJson(Map<String, dynamic> json) {
    final multiplier = _finiteDouble(json['multiplier']);
    final sampleCount = _intValue(json['sampleCount']);
    final updatedAtMillis = _intValue(json['updatedAtMillis']);
    if (multiplier == null || sampleCount == null || updatedAtMillis == null) {
      return null;
    }
    return _TokenCalibrationProfile(
      multiplier: multiplier,
      sampleCount: math.max(0, sampleCount),
      updatedAtMillis: updatedAtMillis,
    );
  }

  Map<String, dynamic> toJson() => {
        'multiplier': multiplier,
        'sampleCount': sampleCount,
        'updatedAtMillis': updatedAtMillis,
      };

  static double? _finiteDouble(Object? value) {
    if (value is num && value.isFinite) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value);
      if (parsed != null && parsed.isFinite) return parsed;
    }
    return null;
  }

  static int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
