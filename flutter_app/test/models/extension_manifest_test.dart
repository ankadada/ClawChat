import 'dart:convert';

import 'package:clawchat/models/extension_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> manifestJson({
  String id = 'com.example.demo',
  String version = '1.2.3',
  Map<String, dynamic>? integrity,
}) {
  return {
    'schemaVersion': 1,
    'id': id,
    'name': 'Demo Skill',
    'description': 'Demonstrates a declared local skill.',
    'model': {
      'name': 'demo_skill',
      'description': 'Use for demo tasks.',
    },
    'version': version,
    'source': {'type': 'local'},
    'integrity': integrity ?? <String, dynamic>{},
    'author': 'Example Author',
    'license': 'MIT',
    'capabilities': {
      'tools': ['read_file', 'bash'],
      'commands': ['python3', 'git'],
      'networkDomains': ['API.Example.COM.', '*.cdn.example.com'],
      'filesystem': {
        'read': ['/root//workspace/./docs', '/tmp'],
        'write': ['/root/workspace/output/'],
      },
      'android': {
        'intents': ['android.intent.action.VIEW'],
        'permissions': ['android.permission.CAMERA'],
      },
      'secrets': ['github_token'],
      'subprocess': {
        'required': true,
        'runtimes': ['python3'],
      },
      'riskTier': 'High',
      'updatePolicy': 'manual',
    },
  };
}

void main() {
  group('ExtensionManifest', () {
    test('parses, normalizes, and serializes the complete schema', () {
      final manifest = ExtensionManifest.parse(jsonEncode(manifestJson()));

      expect(manifest.id, 'com.example.demo');
      expect(manifest.capabilities.networkDomains,
          ['*.cdn.example.com', 'api.example.com']);
      expect(manifest.capabilities.commands, ['git', 'python3']);
      expect(manifest.capabilities.filesystem.read,
          ['/root/workspace/docs', '/tmp']);
      expect(
          manifest.capabilities.filesystem.write, ['/root/workspace/output']);
      expect(manifest.capabilities.secrets, ['GITHUB_TOKEN']);
      expect(manifest.capabilities.riskTier, 'high');
      final snapshot = manifest.capabilities.snapshot;
      expect(snapshot.filesystemRead, isEmpty);
      expect(snapshot.filesystemWrite, isEmpty);
      expect(snapshot.deniedFilesystemRead, ['/root/workspace/docs', '/tmp']);
      expect(snapshot.deniedFilesystemWrite, ['/root/workspace/output']);
      expect(snapshot.hasUnsupportedFilesystemCapabilities, isTrue);
      expect(
        snapshot.summaryLines,
        contains(
          'Filesystem write unsupported/denied on Android: '
          '/root/workspace/output',
        ),
      );
      expect(
        ExtensionManifest.fromJson(manifest.toJson()).toJson(),
        manifest.toJson(),
      );
    });

    test('canonical digest is stable across object key ordering', () {
      final first = ExtensionManifest.parse(jsonEncode(manifestJson()));
      final reversed = Map<String, dynamic>.fromEntries(
        manifestJson().entries.toList().reversed,
      );
      final second = ExtensionManifest.parse(jsonEncode(reversed));

      expect(first.canonicalDigest, second.canonicalDigest);
      expect(first.grantDigest, second.grantDigest);
    });

    test('verifies declared digest and rejects a tampered manifest', () {
      final unsigned = ExtensionManifest.parse(jsonEncode(manifestJson()));
      final signedJson = manifestJson(integrity: {
        'algorithm': 'sha256',
        'digest': unsigned.canonicalDigest,
      });
      final verified = ExtensionManifest.parse(jsonEncode(signedJson));
      expect(verified.integrityStatus, IntegrityStatus.verifiedDigest);

      signedJson['description'] = 'Tampered description';
      final tampered = ExtensionManifest.parse(jsonEncode(signedJson));
      expect(tampered.integrityStatus, IntegrityStatus.mismatch);
      expect(tampered.failsIntegrityClosed, isTrue);
    });

    test('rejects unknown fields at every sensitive level', () {
      final topLevel = manifestJson()..['telemetry'] = true;
      expect(
        () => ExtensionManifest.fromJson(topLevel),
        throwsA(isA<FormatException>()),
      );

      final nested = manifestJson();
      (nested['capabilities'] as Map<String, dynamic>)['implicitAllow'] = true;
      expect(
        () => ExtensionManifest.fromJson(nested),
        throwsA(isA<FormatException>()),
      );

      final filesystem = manifestJson();
      ((filesystem['capabilities'] as Map<String, dynamic>)['filesystem']
          as Map<String, dynamic>)['execute'] = ['/'];
      expect(
        () => ExtensionManifest.fromJson(filesystem),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects unsafe domains paths commands URLs and secret values', () {
      final badDomain = manifestJson();
      (badDomain['capabilities'] as Map<String, dynamic>)['networkDomains'] = [
        'https://example.com'
      ];
      expect(
        () => ExtensionManifest.fromJson(badDomain),
        throwsA(isA<FormatException>()),
      );

      final badPath = manifestJson();
      ((badPath['capabilities'] as Map<String, dynamic>)['filesystem']
          as Map<String, dynamic>)['write'] = ['/root/../etc'];
      expect(
        () => ExtensionManifest.fromJson(badPath),
        throwsA(isA<FormatException>()),
      );

      final badCommand = manifestJson();
      (badCommand['capabilities'] as Map<String, dynamic>)['commands'] = [
        'curl https://example.com',
      ];
      expect(
        () => ExtensionManifest.fromJson(badCommand),
        throwsA(isA<FormatException>()),
      );

      final badSecret = manifestJson();
      (badSecret['capabilities'] as Map<String, dynamic>)['secrets'] = [
        'API_KEY=actual-secret',
      ];
      expect(
        () => ExtensionManifest.fromJson(badSecret),
        throwsA(isA<FormatException>()),
      );

      final badUrl = manifestJson();
      badUrl['source'] = {
        'type': 'url',
        'url': 'https://token@example.com/skill.git?api_key=secret',
      };
      expect(
        () => ExtensionManifest.fromJson(badUrl),
        throwsA(isA<FormatException>()),
      );
    });

    test('bounds list counts and requires semantic versions', () {
      final tooMany = manifestJson();
      (tooMany['capabilities'] as Map<String, dynamic>)['tools'] = [
        for (var index = 0; index < 65; index++) 'tool_$index',
      ];
      expect(
        () => ExtensionManifest.fromJson(tooMany),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ExtensionManifest.fromJson(manifestJson(version: 'latest')),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('capability summary and diff are reusable for install and upgrades', () {
    final oldJson = manifestJson();
    final oldCapabilities = oldJson['capabilities'] as Map<String, dynamic>;
    oldCapabilities['commands'] = <String>[];
    oldCapabilities['tools'] = ['read_file'];
    (oldCapabilities['filesystem'] as Map<String, dynamic>)['write'] =
        <String>[];
    oldCapabilities['secrets'] = <String>[];
    oldCapabilities['android'] = {
      'intents': <String>[],
      'permissions': <String>[],
    };
    oldCapabilities['subprocess'] = {
      'required': false,
      'runtimes': <String>[],
    };
    oldCapabilities['riskTier'] = 'low';
    final old = ExtensionManifest.fromJson(oldJson).capabilities.snapshot;
    final updatedJson = manifestJson(version: '2.0.0');
    final capabilities = updatedJson['capabilities'] as Map<String, dynamic>;
    capabilities['networkDomains'] = ['api.example.com', 'new.example.com'];
    capabilities['commands'] = <String>[];
    capabilities['tools'] = ['read_file', 'write_file'];
    capabilities['subprocess'] = {
      'required': false,
      'runtimes': <String>[],
    };
    capabilities['riskTier'] = 'low';
    final updated =
        ExtensionManifest.fromJson(updatedJson).capabilities.snapshot;

    expect(updated.summaryLines, contains('Secret names: GITHUB_TOKEN'));
    final diff = updated.diff(old);
    expect(diff.added, contains('Tool: write_file'));
    expect(
      diff.added,
      contains(
        'Filesystem write denied: /root/workspace/output',
      ),
    );
    expect(diff.added, contains('Network: new.example.com'));
    expect(diff.added, contains('Effective risk: critical'));
    expect(diff.removed, contains('Network: *.cdn.example.com'));
    expect(diff.removed, contains('Effective risk: high'));
  });

  test('publisher risk cannot understate computed capability risk', () {
    final json = manifestJson();
    (json['capabilities'] as Map<String, dynamic>)['riskTier'] = 'low';
    final snapshot = ExtensionManifest.fromJson(json).capabilities.snapshot;

    expect(snapshot.riskTier, 'low');
    expect(snapshot.computedRiskTier, 'critical');
    expect(snapshot.effectiveRiskTier, 'critical');
    expect(snapshot.summaryLines, contains('Declared risk: low'));
    expect(snapshot.summaryLines, contains('Effective risk: critical'));
  });

  test('legacy grant scopes migrate to explicit runtime denials', () {
    final migrated = ExtensionCapabilitySnapshot.fromJson({
      'tools': <String>[],
      'commands': <String>[],
      'networkDomains': <String>[],
      'filesystemRead': ['/root/workspace/input'],
      'filesystemWrite': ['/root/workspace/output'],
      'androidIntents': <String>[],
      'androidPermissions': <String>[],
      'secretNames': <String>[],
      'runtimes': <String>[],
      'subprocessRequired': false,
      'riskTier': 'moderate',
      'updatePolicy': 'manual',
    });

    expect(migrated.filesystemRead, isEmpty);
    expect(migrated.filesystemWrite, isEmpty);
    expect(migrated.deniedFilesystemRead, ['/root/workspace/input']);
    expect(migrated.deniedFilesystemWrite, ['/root/workspace/output']);
    expect(
      ExtensionCapabilitySnapshot.fromJson(migrated.toJson()).toJson(),
      migrated.toJson(),
    );
  });
}
