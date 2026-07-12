import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current.parent;

  test('DESIGN is the nine-section interaction contract with valid tokens', () {
    final source = File('${root.path}/DESIGN.md').readAsStringSync();
    expect(source, startsWith('---\n'));
    expect(source, contains('\nname: ClawChat\n'));
    expect(source, contains('\n  primary: "#2563EB"\n'));

    final sections = RegExp(r'^## (.+)$', multiLine: true)
        .allMatches(source)
        .map((match) => match.group(1))
        .toList(growable: false);
    expect(sections, const [
      '1. Product and interaction principles',
      '2. Color semantic roles and non-color state',
      '3. Typography, platform scaling, and code roles',
      '4. Spacing, grid, breakpoints, and foldable safe regions',
      '5. Layout and composition: chat, settings, and System Health',
      '6. Components and complete async/destructive states',
      '7. Motion and reduced motion',
      '8. Voice, content, localization, and privacy copy',
      '9. Accessibility and anti-patterns',
    ]);

    final references = RegExp(r'\{([a-z0-9.-]+)\}')
        .allMatches(source)
        .map((match) => match.group(1))
        .toSet();
    expect(references, {
      'colors.primary',
      'colors.on-surface-dark',
      'colors.surface-light-alt',
      'colors.on-surface-light',
      'typography.label',
      'typography.body',
      'rounded.md',
      'spacing.touch',
      'spacing.three',
      'spacing.four',
    });

    for (final color in const [
      '#2563EB',
      '#FFFFFF',
      '#F9F9F9',
      '#1E1E26',
      '#141418',
      '#E5E5E5',
      '#343442',
      '#6B7280',
      '#22C55E',
      '#F59E0B',
      '#EF4444',
    ]) {
      expect(source, contains(color));
    }
  });

  test('current documentation links resolve and migration is archival', () {
    final documents = [
      File('${root.path}/README.md'),
      File('${root.path}/ARCHITECTURE.md'),
      File('${root.path}/DESIGN.md'),
    ];
    final linkPattern = RegExp(r'\[[^\]]+\]\(([^)]+)\)');
    for (final document in documents) {
      final source = document.readAsStringSync();
      for (final match in linkPattern.allMatches(source)) {
        final target = match.group(1)!;
        if (target.startsWith('http') || target.startsWith('#')) continue;
        final path = target.split('#').first;
        expect(
          FileSystemEntity.typeSync('${document.parent.path}/$path'),
          isNot(FileSystemEntityType.notFound),
          reason: '${document.path} links to missing $target',
        );
      }
    }

    final archive = File(
      '${root.path}/docs/migrations/openclaw-to-clawchat.md',
    ).readAsStringSync();
    expect(archive,
        contains('# OpenClaw \u5230 ClawChat \u8fc1\u79fb\u6863\u6848'));
    expect(archive, contains('Migration History (Archive)'));
    expect(archive, contains('ARCHITECTURE.md'));
    expect(archive, contains('DESIGN.md'));
  });
}
