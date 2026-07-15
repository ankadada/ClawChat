// This tests the host-only runner in `tool/`, deliberately outside app lib/.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tool/skill_evals/lib/skill_eval_host_gate.dart';
import '../../../tool/skill_evals/lib/skill_eval_runner.dart';

void main() {
  group('SkillEvalRunner real bundled assets', () {
    test('covers all nine real assets and closes verified runtime evidence',
        () {
      final flutterRoot = _flutterProjectRoot();
      final result = const HostSkillEvalRunner().run(
        skillAssetsDirectory: Directory('${flutterRoot.path}/assets/skills'),
        inventoryFile: File(
          '${flutterRoot.path}/tool/skill_evals/bundled-skill-inventory.json',
        ),
        corpusDirectory: Directory('${flutterRoot.path}/tool/skill_evals'),
        runtimeProjectDirectory: flutterRoot,
      );

      expect(result.inventoryErrorCount, 0);
      expect(result.coverageKnown, isTrue);
      expect(result.releaseBlockerCount, 0);
      expect(result.exitCode, 0);
      expect(
        result.toCliOutput(),
        'skill_evals status=PASS inventory_errors=0 release_blockers=0 '
        'reasons=none',
      );
    });
  });

  group('SkillEvalRunner inventory failures', () {
    late Directory temporaryRoot;
    late Directory externalRoot;
    late Directory assetsDirectory;
    late File inventoryFile;

    setUp(() {
      temporaryRoot = Directory.systemTemp.createTempSync('skill-evals-test-');
      externalRoot =
          Directory.systemTemp.createTempSync('skill-evals-external-');
      assetsDirectory = Directory('${temporaryRoot.path}/assets/skills');
      inventoryFile = File('${temporaryRoot.path}/inventory.json');
      _writeSkill(assetsDirectory, 'alpha', 'trusted alpha bytes');
      _writeInventory(inventoryFile, [_entry('alpha', 'trusted alpha bytes')]);
    });

    tearDown(() {
      temporaryRoot.deleteSync(recursive: true);
      externalRoot.deleteSync(recursive: true);
    });

    test('rejects an empty asset corpus and empty inventory', () {
      assetsDirectory.deleteSync(recursive: true);
      assetsDirectory.createSync(recursive: true);
      _writeInventory(inventoryFile, []);

      final result = _run(assetsDirectory, inventoryFile);

      expect(result.countFor(SkillEvalReasonCode.emptyCorpus), 1);
      expect(result.inventoryErrorCount, 1);
      expect(result.exitCode, 1);
    });

    test('rejects unexpected root files and links without following links', () {
      File('${assetsDirectory.path}/unexpected.txt').writeAsStringSync('data');
      Link('${assetsDirectory.path}/linked-alpha')
          .createSync('${assetsDirectory.path}/alpha');

      final result = _run(assetsDirectory, inventoryFile);

      expect(result.countFor(SkillEvalReasonCode.unsafeAssetEntry), 2);
      expect(result.inventoryErrorCount, 2);
    });

    test('rejects a symlink asset root before linked bytes can be listed', () {
      final externalAssets = Directory('${externalRoot.path}/assets/skills');
      _writeSkill(externalAssets, 'alpha', 'linked alpha bytes');
      _writeInventory(inventoryFile, [_entry('alpha', 'linked alpha bytes')]);
      final linkedAssets = Directory('${temporaryRoot.path}/linked-assets');
      Link(linkedAssets.path).createSync(externalAssets.path);

      final result = _run(linkedAssets, inventoryFile);

      expect(result.countFor(SkillEvalReasonCode.unsafeAssetRoot), 1);
      expect(result.inventoryErrorCount, 1);
    });

    test('retains the host blocker when an asset root is missing or wrong-type',
        () {
      assetsDirectory.deleteSync(recursive: true);

      var result = _run(assetsDirectory, inventoryFile);

      expect(result.countFor(SkillEvalReasonCode.assetRootMissing), 1);

      final fileRoot = File('${temporaryRoot.path}/asset-root-file')
        ..writeAsStringSync('not a directory');
      result = _run(Directory(fileRoot.path), inventoryFile);

      expect(result.countFor(SkillEvalReasonCode.unsafeAssetRoot), 1);
    });

    test('rejects a symlink inventory file before linked bytes can be decoded',
        () {
      final externalInventory = File('${externalRoot.path}/inventory.json');
      _writeInventory(
        externalInventory,
        [_entry('alpha', 'trusted alpha bytes')],
      );
      inventoryFile.deleteSync();
      Link(inventoryFile.path).createSync(externalInventory.path);

      final result = _run(assetsDirectory, inventoryFile);

      expect(result.countFor(SkillEvalReasonCode.unsafeInventoryFile), 1);
      expect(result.countFor(SkillEvalReasonCode.inventoryDecoderError), 0);
      expect(result.inventoryErrorCount, 1);
    });

    test('rejects missing and non-file inventory before decode', () {
      inventoryFile.deleteSync();
      var result = _run(assetsDirectory, inventoryFile);
      expect(result.countFor(SkillEvalReasonCode.unsafeInventoryFile), 1);

      Directory(inventoryFile.path).createSync();
      result = _run(assetsDirectory, inventoryFile);
      expect(result.countFor(SkillEvalReasonCode.unsafeInventoryFile), 1);
    });

    test('rejects digest mismatch and missing SKILL.md', () {
      _writeInventory(inventoryFile, [_entry('alpha', 'different bytes')]);
      var result = _run(assetsDirectory, inventoryFile);
      expect(
        result.countFor(SkillEvalReasonCode.skillMarkdownDigestMismatch),
        1,
      );

      Directory('${assetsDirectory.path}/alpha').deleteSync(recursive: true);
      Directory('${assetsDirectory.path}/alpha').createSync(recursive: true);
      result = _run(assetsDirectory, inventoryFile);
      expect(result.countFor(SkillEvalReasonCode.assetMissingSkillMarkdown), 1);
    });

    test('rejects a nested SKILL.md symlink before linked bytes can be hashed',
        () {
      final externalSkill = File('${externalRoot.path}/SKILL.md')
        ..writeAsStringSync('linked alpha bytes');
      final localSkill = File('${assetsDirectory.path}/alpha/SKILL.md')
        ..deleteSync();
      Link(localSkill.path).createSync(externalSkill.path);
      _writeInventory(inventoryFile, [_entry('alpha', 'linked alpha bytes')]);

      final result = _run(assetsDirectory, inventoryFile);

      expect(result.countFor(SkillEvalReasonCode.unsafeAssetEntry), 1);
      expect(
        result.countFor(SkillEvalReasonCode.skillMarkdownDigestMismatch),
        0,
      );
      expect(result.countFor(SkillEvalReasonCode.assetMissingSkillMarkdown), 0);
    });

    test('rejects missing and extra inventory entries', () {
      _writeSkill(assetsDirectory, 'beta', 'trusted beta bytes');
      var result = _run(assetsDirectory, inventoryFile);
      expect(
        result.countFor(SkillEvalReasonCode.inventoryMissingAssetEntry),
        1,
      );

      _writeInventory(inventoryFile, [
        _entry('alpha', 'trusted alpha bytes'),
        _entry('ghost', 'never present'),
      ]);
      result = _run(assetsDirectory, inventoryFile);
      expect(result.countFor(SkillEvalReasonCode.inventoryExtraAssetEntry), 1);
    });

    test(
        'rejects duplicate inventory entries before asset coverage is accepted',
        () {
      _writeInventory(inventoryFile, [
        _entry('alpha', 'trusted alpha bytes'),
        _entry('alpha', 'trusted alpha bytes'),
      ]);

      final result = _run(assetsDirectory, inventoryFile);

      expect(result.inventoryErrorCount, 1);
      expect(result.countFor(SkillEvalReasonCode.inventoryDuplicateEntry), 1);
      expect(result.exitCode, 1);
    });

    test('rejects malformed inventory bytes through the strict decoder', () {
      inventoryFile.writeAsBytesSync([0xff, 0xfe]);

      final result = _run(assetsDirectory, inventoryFile);

      expect(result.countFor(SkillEvalReasonCode.inventoryDecoderError), 1);
      expect(result.toCliOutput(), contains('inventory_decoder_error=1'));
    });

    test('does not allow a synthetic fixture to substitute mismatched assets',
        () {
      final fixtureDirectory =
          Directory('${temporaryRoot.path}/fixtures/skills');
      _writeSkill(fixtureDirectory, 'alpha', 'synthetic fixture bytes');

      final result = const SkillEvalRunner().run(
        skillAssetsDirectory: assetsDirectory,
        inventoryFile: inventoryFile,
        fixtureSkillsDirectory: fixtureDirectory,
      );

      expect(result.countFor(SkillEvalReasonCode.fixtureAssetMismatch), 1);
      expect(result.inventoryErrorCount, 1);
    });

    test('rejects a symlink fixture root before linked bytes can be hashed',
        () {
      final externalFixture = Directory('${externalRoot.path}/fixtures/skills');
      _writeSkill(externalFixture, 'alpha', 'trusted alpha bytes');
      final linkedFixture =
          Directory('${temporaryRoot.path}/linked-fixture-skills');
      Link(linkedFixture.path).createSync(externalFixture.path);

      final result = const SkillEvalRunner().run(
        skillAssetsDirectory: assetsDirectory,
        inventoryFile: inventoryFile,
        fixtureSkillsDirectory: linkedFixture,
      );

      expect(result.countFor(SkillEvalReasonCode.unsafeFixtureRoot), 1);
      expect(result.countFor(SkillEvalReasonCode.fixtureAssetMismatch), 0);
      expect(result.inventoryErrorCount, 1);
    });

    test('rejects a missing fixture root before fixture scan', () {
      final missingFixture = Directory('${temporaryRoot.path}/missing-fixture');

      final result = const SkillEvalRunner().run(
        skillAssetsDirectory: assetsDirectory,
        inventoryFile: inventoryFile,
        fixtureSkillsDirectory: missingFixture,
      );

      expect(result.countFor(SkillEvalReasonCode.unsafeFixtureRoot), 1);
    });

    test('rejects a nested fixture SKILL.md symlink before hashing', () {
      final fixtureDirectory =
          Directory('${temporaryRoot.path}/fixtures/skills');
      _writeSkill(fixtureDirectory, 'alpha', 'trusted alpha bytes');
      final externalFixtureSkill = File('${externalRoot.path}/fixture-SKILL.md')
        ..writeAsStringSync('trusted alpha bytes');
      final fixtureSkill = File('${fixtureDirectory.path}/alpha/SKILL.md')
        ..deleteSync();
      Link(fixtureSkill.path).createSync(externalFixtureSkill.path);

      final result = const SkillEvalRunner().run(
        skillAssetsDirectory: assetsDirectory,
        inventoryFile: inventoryFile,
        fixtureSkillsDirectory: fixtureDirectory,
      );

      expect(result.countFor(SkillEvalReasonCode.unsafeFixtureEntry), 1);
      expect(result.countFor(SkillEvalReasonCode.fixtureAssetMismatch), 0);
      expect(result.countFor(SkillEvalReasonCode.fixtureMissingAsset), 0);
    });

    test('enabled manifests reject malformed and duplicate-key raw JSON', () {
      for (final manifest in [
        '{malformed',
        '{"schemaVersion":1,"schemaVersion":1}'
      ]) {
        _writeSkillJson(assetsDirectory, 'alpha', manifest);
        _writeInventory(inventoryFile, [
          _entry(
            'alpha',
            'trusted alpha bytes',
            disposition: 'manifest_v1_enabled',
            skillJson: manifest,
          ),
        ]);

        final result = _run(assetsDirectory, inventoryFile);

        expect(
          result.countFor(SkillEvalReasonCode.enabledSkillJsonDecoderError),
          1,
        );
        expect(
            result.countFor(SkillEvalReasonCode.enabledSkillJsonDigestMismatch),
            0);
      }
    });

    test('rejects an enabled skill.json symlink before linked bytes can hash',
        () {
      final source = jsonEncode(_validManifest());
      final externalManifest = File('${externalRoot.path}/skill.json')
        ..writeAsStringSync(source);
      final linkedManifest = File('${assetsDirectory.path}/alpha/skill.json');
      Link(linkedManifest.path).createSync(externalManifest.path);
      _writeInventory(inventoryFile, [
        _entry(
          'alpha',
          'trusted alpha bytes',
          disposition: 'manifest_v1_enabled',
          skillJson: source,
        ),
      ]);

      final result = _run(assetsDirectory, inventoryFile);

      expect(result.countFor(SkillEvalReasonCode.unsafeAssetEntry), 1);
      expect(
        result.countFor(SkillEvalReasonCode.enabledSkillJsonDigestMismatch),
        0,
      );
      expect(
        result.countFor(SkillEvalReasonCode.enabledSkillJsonDecoderError),
        0,
      );
    });

    test('enabled manifests reject unknown fields after strict decoding', () {
      final manifest = _validManifest()..['unexpected'] = true;
      final source = jsonEncode(manifest);
      _writeSkillJson(assetsDirectory, 'alpha', source);
      _writeInventory(inventoryFile, [
        _entry(
          'alpha',
          'trusted alpha bytes',
          disposition: 'manifest_v1_enabled',
          skillJson: source,
        ),
      ]);

      final result = _run(assetsDirectory, inventoryFile);

      expect(
        result.countFor(SkillEvalReasonCode.enabledSkillJsonManifestInvalid),
        1,
      );
      expect(
          result.countFor(SkillEvalReasonCode.enabledSkillJsonDigestMismatch),
          0);
    });

    test('enabled manifests reject fail-closed integrity metadata', () {
      final manifest = _validManifest();
      manifest['integrity'] = {
        'algorithm': 'sha256',
        'digest': List.filled(64, '0').join(),
      };
      final source = jsonEncode(manifest);
      _writeSkillJson(assetsDirectory, 'alpha', source);
      _writeInventory(inventoryFile, [
        _entry(
          'alpha',
          'trusted alpha bytes',
          disposition: 'manifest_v1_enabled',
          skillJson: source,
        ),
      ]);

      final result = _run(assetsDirectory, inventoryFile);

      expect(
        result.countFor(
          SkillEvalReasonCode.enabledSkillJsonIntegrityInvalid,
        ),
        1,
      );
    });

    test('all ready dispositions remain blocked without runtime evidence', () {
      for (final disposition in [
        'disabled',
        'removed',
        'manifest_v1_enabled'
      ]) {
        final skillJson = disposition == 'manifest_v1_enabled'
            ? jsonEncode(_validManifest())
            : null;
        if (skillJson != null) {
          _writeSkillJson(assetsDirectory, 'alpha', skillJson);
        }
        _writeInventory(inventoryFile, [
          _entry(
            'alpha',
            'trusted alpha bytes',
            disposition: disposition,
            skillJson: skillJson,
          ),
        ]);

        final result = _run(assetsDirectory, inventoryFile);

        expect(result.inventoryErrorCount, 0);
        expect(result.releaseBlockerCount, 1);
        expect(
          result.countFor(
            SkillEvalReasonCode.releaseBlockerRuntimeEvidenceMissing,
          ),
          1,
        );
        expect(result.isPass, isFalse);
        expect(result.exitCode, 1);
      }
    });

    test('inventory-only validation has no host completeness claim', () {
      final result = _run(assetsDirectory, inventoryFile);

      expect(result.inventoryErrorCount, 0);
      expect(result.isPass, isFalse);
      expect(result.releaseBlockerCount, 1);
    });
  });
}

SkillEvalRunResult _run(Directory assetsDirectory, File inventoryFile) =>
    const SkillEvalRunner().run(
      skillAssetsDirectory: assetsDirectory,
      inventoryFile: inventoryFile,
    );

Directory _flutterProjectRoot() {
  final current = Directory.current;
  if (File('${current.path}/pubspec.yaml').existsSync()) return current;
  final candidate = Directory('${current.path}/flutter_app');
  if (File('${candidate.path}/pubspec.yaml').existsSync()) return candidate;
  throw StateError('Flutter project root was not found.');
}

void _writeSkill(Directory root, String name, String content) {
  final directory = Directory('${root.path}/$name')
    ..createSync(recursive: true);
  File('${directory.path}/SKILL.md').writeAsStringSync(content);
}

void _writeSkillJson(Directory root, String name, String source) {
  File('${root.path}/$name/skill.json').writeAsStringSync(source);
}

void _writeInventory(File file, List<Map<String, Object>> entries) {
  file.writeAsStringSync(
    jsonEncode({
      'schemaVersion': 1,
      'assetRoot': 'assets/skills',
      'entries': entries,
    }),
  );
}

Map<String, Object> _entry(
  String directory,
  String skillMarkdown, {
  String disposition = 'disabled',
  String? skillJson,
}) =>
    {
      'assetDirectory': directory,
      'skillMarkdownSha256': _sha256(skillMarkdown),
      'disposition': disposition,
      'planningStatus': 'ready_for_release',
      if (disposition == 'manifest_v1_enabled')
        'skillJsonSha256': _sha256(skillJson!),
      if (disposition != 'manifest_v1_enabled')
        'reason': 'Test only pending remediation.',
    };

Map<String, Object> _validManifest() => {
      'schemaVersion': 1,
      'id': 'com.example.alpha',
      'name': 'Alpha',
      'description': 'Host test manifest.',
      'model': {
        'name': 'alpha_skill',
        'description': 'Host test skill.',
      },
      'version': '1.0.0',
      'source': {'type': 'local'},
      'integrity': <String, Object>{},
      'author': 'Host test',
      'license': 'MIT',
      'capabilities': {
        'tools': <String>[],
        'commands': <String>[],
        'networkDomains': <String>[],
        'filesystem': {
          'read': <String>[],
          'write': <String>[],
        },
        'android': {
          'intents': <String>[],
          'permissions': <String>[],
        },
        'secrets': <String>[],
        'subprocess': {
          'required': false,
          'runtimes': <String>[],
        },
        'riskTier': 'low',
        'updatePolicy': 'manual',
      },
    };

String _sha256(String value) => sha256.convert(utf8.encode(value)).toString();
