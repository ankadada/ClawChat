// This exercises the repository-owned host corpus outside app lib/.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tool/skill_evals/lib/skill_eval_host_gate.dart';
import '../../../tool/skill_evals/lib/skill_eval_runner.dart';
import '../../../tool/skill_evals/lib/bounded_file_reader.dart';

void main() {
  group('HostSkillEvalRunner closed corpus', () {
    late Directory temporaryRoot;
    late Directory assetsDirectory;
    late Directory corpusDirectory;
    late File inventoryFile;

    setUp(() {
      temporaryRoot = Directory.systemTemp.createTempSync('host-evals-test-');
      final flutterRoot = _flutterProjectRoot();
      assetsDirectory = Directory('${temporaryRoot.path}/assets/skills');
      corpusDirectory = Directory('${temporaryRoot.path}/tool/skill_evals');
      _copyDirectory(
          Directory('${flutterRoot.path}/assets/skills'), assetsDirectory);
      _copyDirectory(
        Directory('${flutterRoot.path}/tool/skill_evals'),
        corpusDirectory,
      );
      inventoryFile = File(
        '${corpusDirectory.path}/bundled-skill-inventory.json',
      );
    });

    tearDown(() => temporaryRoot.deleteSync(recursive: true));

    test('clean checked-in corpus closes host and runtime evidence', () {
      final result = _run(assetsDirectory, inventoryFile, corpusDirectory);

      expect(result.inventoryErrorCount, 0);
      expect(result.releaseBlockerCount, 0);
      expect(result.exitCode, 0);
      expect(result.toCliOutput(),
          'skill_evals status=PASS inventory_errors=0 release_blockers=0 reasons=none');
    });

    test('runtime evidence digest drift restores all release blockers', () {
      final evidenceFile =
          File('${corpusDirectory.path}/runtime-evidence.json');
      final evidence =
          jsonDecode(evidenceFile.readAsStringSync()) as Map<String, dynamic>;
      final first =
          (evidence['files'] as List<dynamic>).first as Map<String, dynamic>;
      first['sha256'] = 'a' * 64;
      evidenceFile.writeAsStringSync(jsonEncode(evidence));

      final result = _run(assetsDirectory, inventoryFile, corpusDirectory);

      expect(result.countFor(SkillEvalReasonCode.runtimeEvidenceInvalid), 1);
      expect(
        result.countFor(
          SkillEvalReasonCode.releaseBlockerRuntimeEvidenceMissing,
        ),
        9,
      );
      expect(result.inventoryErrorCount, greaterThan(0));
      expect(result.releaseBlockerCount, 9);
      expect(result.exitCode, 1);
    });

    test(
        'runtime catalog rejects missing, extra, duplicate, and installable inventory drift',
        () {
      final original = inventoryFile.readAsStringSync();

      void expectCatalogMismatch(void Function(Map<String, dynamic>) mutate) {
        final inventory = jsonDecode(original) as Map<String, dynamic>;
        mutate(inventory);
        inventoryFile.writeAsStringSync(jsonEncode(inventory));

        final result = _run(assetsDirectory, inventoryFile, corpusDirectory);

        expect(
          result.countFor(SkillEvalReasonCode.runtimeCatalogMismatch),
          1,
        );
        expect(result.inventoryErrorCount, greaterThan(0));
      }

      expectCatalogMismatch((inventory) {
        (inventory['entries'] as List<dynamic>).removeLast();
      });
      expectCatalogMismatch((inventory) {
        final entries = inventory['entries'] as List<dynamic>;
        final extra =
            Map<String, dynamic>.from(entries.first as Map<String, dynamic>);
        extra['assetDirectory'] = 'unexpected-skill';
        entries.add(extra);
      });
      expectCatalogMismatch((inventory) {
        final entries = inventory['entries'] as List<dynamic>;
        final first = entries.first as Map<String, dynamic>;
        final second = entries[1] as Map<String, dynamic>;
        second['assetDirectory'] = first['assetDirectory'];
      });
      expectCatalogMismatch((inventory) {
        final entry = (inventory['entries'] as List<dynamic>).first
            as Map<String, dynamic>;
        entry['reason'] = 'A different bounded reason.';
      });
      expectCatalogMismatch((inventory) {
        final entry = (inventory['entries'] as List<dynamic>).first
            as Map<String, dynamic>;
        entry
          ..remove('reason')
          ..['disposition'] = 'manifest_v1_enabled'
          ..['skillJsonSha256'] = 'a' * 64;
      });
    });

    test('central reader accepts exact bound and rejects oversize', () {
      final file = File('${temporaryRoot.path}/bounded')
        ..writeAsBytesSync(List<int>.filled(64 * 1024, 0x61));
      expect(HostBoundedFileReader.read(file, 64 * 1024), hasLength(64 * 1024));
      expect(
        () => HostBoundedFileReader.read(file, (64 * 1024) - 1),
        throwsA(isA<BoundedFileReadException>()),
      );
    });

    test('rejects an arbitrary inventory leaf before corpus evaluation', () {
      final external = File('${temporaryRoot.path}/external-inventory.json');
      _copyFile(inventoryFile, external);

      final result = _run(assetsDirectory, external, corpusDirectory);

      expect(
        result.countFor(SkillEvalReasonCode.corpusInventoryPathMismatch),
        1,
      );
      expect(result.inventoryErrorCount, 1);
      expect(result.coverageKnown, isFalse);
      expect(result.releaseBlockerCount, 0);
    });

    test('rejects symlinked corpus root and inventory leaf', () {
      final linkedRoot = Directory('${temporaryRoot.path}/linked-corpus');
      Link(linkedRoot.path).createSync(corpusDirectory.path);
      var result = _run(assetsDirectory, inventoryFile, linkedRoot);
      expect(result.countFor(SkillEvalReasonCode.corpusRootUnsafe), 1);
      expect(result.releaseBlockerCount, 0);

      final external = File('${temporaryRoot.path}/inventory-target.json');
      _copyFile(inventoryFile, external);
      inventoryFile.deleteSync();
      Link(inventoryFile.path).createSync(external.path);
      result = _run(assetsDirectory, inventoryFile, corpusDirectory);
      expect(result.countFor(SkillEvalReasonCode.corpusInventoryUnsafe), 1);
      expect(result.coverageKnown, isFalse);
    });

    test('fails closed for schema deletion or tamper', () {
      final schema = File(
        '${corpusDirectory.path}/schema/skill-eval-case.schema.json',
      );
      schema.deleteSync();
      var result = _run(assetsDirectory, inventoryFile, corpusDirectory);
      expect(result.countFor(SkillEvalReasonCode.corpusPathMissing),
          greaterThan(0));

      _copyFile(
        File(
            '${_flutterProjectRoot().path}/tool/skill_evals/schema/skill-eval-case.schema.json'),
        schema,
      );
      schema.writeAsStringSync('{}');
      result = _run(assetsDirectory, inventoryFile, corpusDirectory);
      expect(result.countFor(SkillEvalReasonCode.schemaDigestMismatch), 1);
    });

    test('fails closed for unexpected or symlinked corpus entries', () {
      File('${corpusDirectory.path}/unexpected.txt').writeAsStringSync('x');
      Link('${corpusDirectory.path}/cases-link')
          .createSync('${corpusDirectory.path}/cases');

      final result = _run(assetsDirectory, inventoryFile, corpusDirectory);

      expect(result.countFor(SkillEvalReasonCode.corpusUnsafeEntry), 2);
    });

    test('rejects duplicate IDs, unknown fixtures, and missing asset coverage',
        () {
      final duplicate = File(
        '${corpusDirectory.path}/cases/positive/duplicate.json',
      );
      _copyFile(
        File(
            '${corpusDirectory.path}/cases/positive/structure.code-review.json'),
        duplicate,
      );
      var result = _run(assetsDirectory, inventoryFile, corpusDirectory);
      expect(result.countFor(SkillEvalReasonCode.caseDuplicateId), 1);

      duplicate.writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'id': 'unknown.fixture',
          'fixtureId': 'unknown-fixture',
          'kind': 'structure',
          'input': {'text': 'verify structure'},
          'expected': {
            'decision': 'match',
            'reasonCode': 'structure_valid',
            'selectedSkillId': 'unknown-fixture',
          },
        }),
      );
      result = _run(assetsDirectory, inventoryFile, corpusDirectory);
      expect(result.countFor(SkillEvalReasonCode.caseUnknownFixture), 1);

      duplicate.deleteSync();
      File('${corpusDirectory.path}/cases/positive/static.code-review.json')
          .deleteSync();
      File('${corpusDirectory.path}/goldens/static.code-review.json')
          .deleteSync();
      result = _run(assetsDirectory, inventoryFile, corpusDirectory);
      expect(result.countFor(SkillEvalReasonCode.fixtureCoverageMissing), 1);
    });

    test('rejects strict case schema and semantic violations', () {
      final caseFile = File(
        '${corpusDirectory.path}/cases/positive/trigger.web-search.json',
      );
      for (final source in [
        '{"schemaVersion":1,"schemaVersion":1}',
        jsonEncode({
          'schemaVersion': 2,
          'id': 'bad.version',
          'fixtureId': 'web-search',
          'kind': 'trigger_metadata',
          'input': {'text': 'Search the web'},
          'expected': {
            'decision': 'match',
            'reasonCode': 'trigger_metadata_match',
            'selectedSkillId': 'web-search',
          },
        }),
        jsonEncode({
          'schemaVersion': 1,
          'id': 'bad.kind',
          'fixtureId': 'web-search',
          'kind': 'unknown',
          'input': {'text': 'Search the web'},
          'expected': {
            'decision': 'match',
            'reasonCode': 'trigger_metadata_match',
            'selectedSkillId': 'web-search',
          },
        }),
        jsonEncode({
          'schemaVersion': 1,
          'id': 'bad.oversized',
          'fixtureId': 'web-search',
          'kind': 'trigger_metadata',
          'input': {'text': List.filled(2049, 'x').join()},
          'expected': {
            'decision': 'match',
            'reasonCode': 'trigger_metadata_match',
            'selectedSkillId': 'web-search',
          },
        }),
        jsonEncode({
          'schemaVersion': 1,
          'id': 'bad.selected',
          'fixtureId': 'web-search',
          'kind': 'trigger_metadata',
          'input': {'text': 'Search the web'},
          'expected': {
            'decision': 'no_match',
            'reasonCode': 'trigger_metadata_no_match',
            'selectedSkillId': 'web-search',
          },
        }),
      ]) {
        caseFile.writeAsStringSync(source);
        final result = _run(assetsDirectory, inventoryFile, corpusDirectory);
        expect(result.countFor(SkillEvalReasonCode.caseInvalid), 1);
      }
    });

    test('does not parse beyond the 512 case category cap', () {
      final positive = Directory('${corpusDirectory.path}/cases/positive');
      for (var index = 0; index < 513; index += 1) {
        File(
          '${positive.path}/overflow-${index.toString().padLeft(3, '0')}.json',
        ).writeAsStringSync('{invalid');
      }

      final result = _run(assetsDirectory, inventoryFile, corpusDirectory);

      // One cap finding plus the first 512 malformed files. The 513th
      // overflow file and later sorted category entries are not parsed.
      expect(result.countFor(SkillEvalReasonCode.caseInvalid), 513);
    });

    test(
        'detects fixture substitution, static scanner changes, and golden tamper',
        () {
      final fixture = File(
        '${corpusDirectory.path}/fixtures/skills/translator/SKILL.md',
      );
      fixture.writeAsStringSync('# Translator\nRun curl safely.');
      var result = _run(assetsDirectory, inventoryFile, corpusDirectory);
      expect(result.countFor(SkillEvalReasonCode.fixtureAssetMismatch), 1);
      expect(result.countFor(SkillEvalReasonCode.staticScanMismatch), 1);
      expect(result.countFor(SkillEvalReasonCode.goldenMismatch), 1);

      _copyFile(
        File(
            '${_flutterProjectRoot().path}/tool/skill_evals/fixtures/skills/translator/SKILL.md'),
        fixture,
      );
      final golden = File(
        '${corpusDirectory.path}/goldens/trigger.web-search.json',
      );
      golden.writeAsStringSync('{}');
      result = _run(assetsDirectory, inventoryFile, corpusDirectory);
      expect(result.countFor(SkillEvalReasonCode.goldenInvalid), 1);
    });

    test('accepts canonical golden equality despite object key order', () {
      final golden = File(
        '${corpusDirectory.path}/goldens/trigger.web-search.json',
      );
      golden.writeAsStringSync(
        '{"ruleIds":[],"selectedSkillId":"web-search",'
        '"reasonCode":"trigger_metadata_match","decision":"match",'
        '"kind":"trigger_metadata","caseId":"trigger.web-search"}',
      );

      final result = _run(assetsDirectory, inventoryFile, corpusDirectory);

      expect(result.inventoryErrorCount, 0);
      expect(result.countFor(SkillEvalReasonCode.goldenMismatch), 0);
      expect(result.releaseBlockerCount, 0);
    });

    test('enabled counterfactual cannot self-certify a rejected legacy fixture',
        () {
      final inventory =
          jsonDecode(inventoryFile.readAsStringSync()) as Map<String, dynamic>;
      final entries = inventory['entries'] as List<dynamic>;
      final entry = entries.firstWhere((value) =>
          (value as Map<String, dynamic>)['assetDirectory'] ==
          'code-review') as Map<String, dynamic>;
      final manifest = _emptyEnabledManifest();
      final manifestSource = jsonEncode(manifest);
      File('${assetsDirectory.path}/code-review/skill.json')
          .writeAsStringSync(manifestSource);
      entry
        ..remove('reason')
        ..['disposition'] = 'manifest_v1_enabled'
        ..['planningStatus'] = 'ready_for_release'
        ..['skillJsonSha256'] = _sha256(manifestSource);
      inventoryFile.writeAsStringSync(jsonEncode(inventory));

      final result = _run(assetsDirectory, inventoryFile, corpusDirectory);

      expect(result.countFor(SkillEvalReasonCode.enabledStaticScanRejected), 1);
      expect(result.inventoryErrorCount, greaterThan(0));
    });

    test('clean synthetic enabled text has no static rejection', () {
      final result =
          HostStaticInstructionScanner.scanText('# Safe\nPlain notes.');

      expect(result.isRejected, isFalse);
      expect(result.failureReason, isNull);
    });

    test('clean aligned enabled fixture has no enabled static finding', () {
      const skill = '''---
name: clean
description: plain-notes
tools: []
filesystem: []
---
# clean''';
      final manifest = jsonEncode(_emptyEnabledManifest());
      File('${assetsDirectory.path}/code-review/SKILL.md')
          .writeAsStringSync(skill);
      File('${assetsDirectory.path}/code-review/skill.json')
          .writeAsStringSync(manifest);
      File('${corpusDirectory.path}/fixtures/skills/code-review/SKILL.md')
          .writeAsStringSync(skill);
      final inventory =
          jsonDecode(inventoryFile.readAsStringSync()) as Map<String, dynamic>;
      final entry = (inventory['entries'] as List<dynamic>).firstWhere(
          (value) =>
              (value as Map<String, dynamic>)['assetDirectory'] ==
              'code-review') as Map<String, dynamic>;
      entry
        ..remove('reason')
        ..['disposition'] = 'manifest_v1_enabled'
        ..['planningStatus'] = 'ready_for_release'
        ..['skillMarkdownSha256'] = _sha256(skill)
        ..['skillJsonSha256'] = _sha256(manifest);
      inventoryFile.writeAsStringSync(jsonEncode(inventory));
      File('${corpusDirectory.path}/cases/positive/static.code-review.json')
          .writeAsStringSync(
              '{"schemaVersion":1,"id":"static.code-review","fixtureId":"code-review","kind":"static_scan","input":{"text":"scan instructions"},"expected":{"decision":"no_match","reasonCode":"static_scan_clean"}}');
      File('${corpusDirectory.path}/goldens/static.code-review.json')
          .writeAsStringSync(
              '{"caseId":"static.code-review","kind":"static_scan","decision":"no_match","reasonCode":"static_scan_clean","selectedSkillId":null,"ruleIds":[]}');

      final result = _run(assetsDirectory, inventoryFile, corpusDirectory);

      expect(result.countFor(SkillEvalReasonCode.enabledStaticScanRejected), 0);
      expect(
          result.countFor(SkillEvalReasonCode.enabledClaimToolUndeclared), 0);
      expect(result.countFor(SkillEvalReasonCode.enabledClaimUnenforceable), 0);
      expect(result.releaseBlockerCount, 9);
    });

    test('block-form tools cannot be ignored by an empty manifest', () {
      const skill = '''---
name: clean
description: plain-notes
tools:
  - evil_tool
---
# clean''';
      _configureCleanEnabledCodeReview(
        assetsDirectory: assetsDirectory,
        corpusDirectory: corpusDirectory,
        inventoryFile: inventoryFile,
        skill: skill,
      );

      final result = _run(assetsDirectory, inventoryFile, corpusDirectory);

      expect(
          result.countFor(SkillEvalReasonCode.enabledClaimToolUndeclared), 1);
      expect(result.inventoryErrorCount, greaterThan(0));
    });

    test('block-form commands, domains, and secrets fail with empty manifest',
        () {
      const skill = '''---
name: clean
description: plain-notes
tools: []
commands:
  - git-status
networkDomains:
  - api.example.com
secrets:
  - API_KEY
---
# clean''';
      _configureCleanEnabledCodeReview(
        assetsDirectory: assetsDirectory,
        corpusDirectory: corpusDirectory,
        inventoryFile: inventoryFile,
        skill: skill,
      );

      final result = _run(assetsDirectory, inventoryFile, corpusDirectory);

      expect(
          result.countFor(SkillEvalReasonCode.enabledClaimToolUndeclared), 1);
      expect(result.countFor(SkillEvalReasonCode.enabledClaimUnenforceable), 1);
      expect(result.inventoryErrorCount, greaterThan(0));
    });

    test('inline and block frontmatter declarations have identical claims', () {
      const inline = '''---
name: clean
description: plain-notes
tools: [read_file, network:query]
commands: [git-status]
networkDomains: [API.example.com.]
secrets: [api_key]
---
# clean''';
      const block = '''---
name: clean
description: plain-notes
tools:
  - read_file
  - network:query
commands:
  - git-status
networkDomains:
  - API.example.com.
secrets:
  - api_key
---
# clean''';
      const bareBlock = '''---
name: clean
description: plain-notes
tools:
- read_file
- network:query
commands:
- git-status
networkDomains:
- API.example.com.
secrets:
- api_key
---
# clean''';

      final inlineClaims = EnabledSkillFrontmatter.parse(inline);
      final blockClaims = EnabledSkillFrontmatter.parse(block);
      final bareBlockClaims = EnabledSkillFrontmatter.parse(bareBlock);

      expect(blockClaims.tools, inlineClaims.tools);
      expect(blockClaims.commands, inlineClaims.commands);
      expect(blockClaims.networkDomains, inlineClaims.networkDomains);
      expect(blockClaims.secrets, inlineClaims.secrets);
      expect(bareBlockClaims.tools, inlineClaims.tools);
      expect(bareBlockClaims.commands, inlineClaims.commands);
      expect(bareBlockClaims.networkDomains, inlineClaims.networkDomains);
      expect(bareBlockClaims.secrets, inlineClaims.secrets);
    });

    test(
        'strict frontmatter rejects duplicate and unsupported declaration forms',
        () {
      const base = '''---
name: clean
description: plain-notes
tools: []
---
# clean''';
      final malformed = <String>[
        base.replaceFirst('tools: []', 'tools: [read_file, read_file]'),
        base.replaceFirst('tools: []', 'tools: [read_file]\ntools: []'),
        base.replaceFirst('tools: []', 'Tools: []'),
        base.replaceFirst('tools: []', 'tools: [&anchor]'),
        base.replaceFirst('tools: []', 'tools: [read_file] # hidden'),
        base.replaceFirst('tools: []', 'tools: ["read_file"]'),
        base.replaceFirst('tools: []', 'tools: [read_file'),
        base.replaceFirst('tools: []', 'tools: []\nfilesystem: [/tmp]'),
        base.replaceFirst('tools: []', 'tools: {read_file: true}'),
        base.replaceFirst('tools: []', 'tools:\n - read_file'),
        base.replaceFirst('description: plain-notes', 'description:\n  notes'),
        base.replaceFirst('tools: []', 'tools:\n\t- read_file'),
        base.replaceFirst('---\n# clean', '# clean'),
      ];

      for (final source in malformed) {
        expect(
          () => EnabledSkillFrontmatter.parse(source),
          throwsA(isA<FrontmatterFormatException>()),
        );
      }
    });

    test('manifest-only capability fails strict bidirectional closure', () {
      const skill = '''---
name: clean
description: plain-notes
tools: []
---
# clean''';
      final manifest = _emptyEnabledManifest();
      ((manifest['capabilities'] as Map<String, dynamic>)['tools']
              as List<String>)
          .add('read_file');
      _configureCleanEnabledCodeReview(
        assetsDirectory: assetsDirectory,
        corpusDirectory: corpusDirectory,
        inventoryFile: inventoryFile,
        skill: skill,
        manifest: manifest,
      );

      final result = _run(assetsDirectory, inventoryFile, corpusDirectory);

      expect(
          result.countFor(SkillEvalReasonCode.enabledClaimToolUndeclared), 1);
      expect(result.inventoryErrorCount, greaterThan(0));
    });

    test('matching nonempty tools remain conservatively unenforceable', () {
      for (final tool in const [
        'read_file',
        'write_file',
        'mcp_x',
        'load_skill',
        'bash',
        'web_fetch',
        'web_search',
        'set_env_var',
        'phone_intent',
        'made_up_tool',
      ]) {
        final skill = '''---
name: clean
description: plain-notes
tools: [$tool]
filesystem: []
---
# clean''';
        final manifest = _emptyEnabledManifest();
        ((manifest['capabilities'] as Map<String, dynamic>)['tools']
                as List<String>)
            .add(tool);
        _configureCleanEnabledCodeReview(
          assetsDirectory: assetsDirectory,
          corpusDirectory: corpusDirectory,
          inventoryFile: inventoryFile,
          skill: skill,
          manifest: manifest,
        );

        final result = _run(assetsDirectory, inventoryFile, corpusDirectory);

        expect(
          result.countFor(SkillEvalReasonCode.enabledClaimUnenforceable),
          greaterThan(0),
          reason: tool,
        );
        expect(result.inventoryErrorCount, greaterThan(0), reason: tool);
      }
    });

    test('enabled capability-free body rejects arbitrary claim prose', () {
      for (final body in const [
        'Reply in JSON.',
        'Inspect /etc/passwd.',
        'Run git status.',
        'Contact api.example.com.',
        'Use PAYMENT_TOKEN.',
        'Invoke made_up_tool.',
      ]) {
        final skill = '''---
name: clean
description: plain-notes
tools: []
filesystem: []
---
# clean
$body''';
        _configureCleanEnabledCodeReview(
          assetsDirectory: assetsDirectory,
          corpusDirectory: corpusDirectory,
          inventoryFile: inventoryFile,
          skill: skill,
        );

        final result = _run(assetsDirectory, inventoryFile, corpusDirectory);

        expect(
          result.countFor(SkillEvalReasonCode.enabledClaimUnenforceable),
          greaterThan(0),
          reason: body,
        );
        expect(result.inventoryErrorCount, greaterThan(0), reason: body);
      }
    });

    test('fixed scanner detects boundaries and ignores near misses', () {
      expect(
        HostStaticInstructionScanner.scanText('Run curl now.').ruleIds,
        contains('static_shell_instruction'),
      );
      expect(
        HostStaticInstructionScanner.scanText('c u r l is spaced.').ruleIds,
        isEmpty,
      );
      expect(
        HostStaticInstructionScanner.scanText('tokenizer only.').ruleIds,
        isEmpty,
      );
      expect(
        HostStaticInstructionScanner.scanText('GITHUB_TOKEN required.').ruleIds,
        contains('static_secret_reference'),
      );
    });
  });
}

SkillEvalRunResult _run(
  Directory assetsDirectory,
  File inventoryFile,
  Directory corpusDirectory,
) =>
    const HostSkillEvalRunner().run(
      skillAssetsDirectory: assetsDirectory,
      inventoryFile: inventoryFile,
      corpusDirectory: corpusDirectory,
      runtimeProjectDirectory: _flutterProjectRoot(),
    );

Directory _flutterProjectRoot() {
  final current = Directory.current;
  if (File('${current.path}/pubspec.yaml').existsSync()) return current;
  final candidate = Directory('${current.path}/flutter_app');
  if (File('${candidate.path}/pubspec.yaml').existsSync()) return candidate;
  throw StateError('Flutter project root was not found.');
}

void _copyDirectory(Directory source, Directory destination) {
  destination.createSync(recursive: true);
  for (final entity in source.listSync(followLinks: false)) {
    final destinationPath = '${destination.path}/${_basename(entity.path)}';
    if (entity is File) {
      _copyFile(entity, File(destinationPath));
    } else if (entity is Directory) {
      _copyDirectory(entity, Directory(destinationPath));
    } else {
      throw StateError('Test fixture source must not contain links.');
    }
  }
}

void _copyFile(File source, File destination) {
  destination.parent.createSync(recursive: true);
  source.copySync(destination.path);
}

String _basename(String path) => path.substring(path.lastIndexOf('/') + 1);

String _sha256(String value) => sha256.convert(utf8.encode(value)).toString();

void _configureCleanEnabledCodeReview({
  required Directory assetsDirectory,
  required Directory corpusDirectory,
  required File inventoryFile,
  required String skill,
  Map<String, dynamic>? manifest,
}) {
  final manifestSource = jsonEncode(manifest ?? _emptyEnabledManifest());
  File('${assetsDirectory.path}/code-review/SKILL.md').writeAsStringSync(skill);
  File('${assetsDirectory.path}/code-review/skill.json')
      .writeAsStringSync(manifestSource);
  File('${corpusDirectory.path}/fixtures/skills/code-review/SKILL.md')
      .writeAsStringSync(skill);
  final inventory =
      jsonDecode(inventoryFile.readAsStringSync()) as Map<String, dynamic>;
  final entry = (inventory['entries'] as List<dynamic>).firstWhere((value) =>
          (value as Map<String, dynamic>)['assetDirectory'] == 'code-review')
      as Map<String, dynamic>;
  entry
    ..remove('reason')
    ..['disposition'] = 'manifest_v1_enabled'
    ..['planningStatus'] = 'ready_for_release'
    ..['skillMarkdownSha256'] = _sha256(skill)
    ..['skillJsonSha256'] = _sha256(manifestSource);
  inventoryFile.writeAsStringSync(jsonEncode(inventory));
  File('${corpusDirectory.path}/cases/positive/static.code-review.json')
      .writeAsStringSync(
          '{"schemaVersion":1,"id":"static.code-review","fixtureId":"code-review","kind":"static_scan","input":{"text":"scan instructions"},"expected":{"decision":"no_match","reasonCode":"static_scan_clean"}}');
  File('${corpusDirectory.path}/goldens/static.code-review.json').writeAsStringSync(
      '{"caseId":"static.code-review","kind":"static_scan","decision":"no_match","reasonCode":"static_scan_clean","selectedSkillId":null,"ruleIds":[]}');
}

Map<String, dynamic> _emptyEnabledManifest() => {
      'schemaVersion': 1,
      'id': 'com.example.code-review',
      'name': 'Code review',
      'description': 'Temporary host test manifest.',
      'model': {'name': 'code_review', 'description': 'Host test.'},
      'version': '1.0.0',
      'source': {'type': 'local'},
      'integrity': <String, dynamic>{},
      'author': 'Host test',
      'license': 'MIT',
      'capabilities': {
        'tools': <String>[],
        'commands': <String>[],
        'networkDomains': <String>[],
        'filesystem': {'read': <String>[], 'write': <String>[]},
        'android': {'intents': <String>[], 'permissions': <String>[]},
        'secrets': <String>[],
        'subprocess': {'required': false, 'runtimes': <String>[]},
        'riskTier': 'low',
        'updatePolicy': 'manual',
      },
    };
