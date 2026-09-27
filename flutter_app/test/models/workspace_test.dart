import 'package:clawchat/models/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkspaceMetadata', () {
    test('defaults to the agent tree and round-trips through JSON', () {
      final workspace = WorkspaceMetadata.defaultWorkspace();
      final restored = WorkspaceMetadata.tryFromJson(workspace.toJson());

      expect(workspace.rootPath, kDefaultWorkspaceRoot);
      expect(workspace.isDefault, isTrue);
      expect(restored, isNotNull);
      expect(restored!.id, workspace.id);
      expect(restored.name, workspace.name);
      expect(restored.rootPath, kDefaultWorkspaceRoot);
    });

    test('keeps only flat attribute values as the extension point', () {
      final workspace = WorkspaceMetadata(
        id: 'ws-1',
        name: ' 项目 ',
        attributes: {
          'skillsRoot': 'skills',
          'memoryScope': 3,
          'nested': {'a': 1},
          'list': [1, 2],
          '': 'ignored',
        },
      );

      expect(workspace.name, '项目');
      expect(workspace.attributes['skillsRoot'], 'skills');
      expect(workspace.attributes['memoryScope'], 3);
      expect(workspace.attributes.containsKey('nested'), isFalse);
      expect(workspace.attributes.containsKey('list'), isFalse);
      expect(workspace.attributes.containsKey(''), isFalse);

      final restored = WorkspaceMetadata.tryFromJson(workspace.toJson());
      expect(restored!.attributes, workspace.attributes);
    });

    test('scope containment rejects traversal and outside paths', () {
      final workspace = WorkspaceMetadata(
        id: 'ws-2',
        name: 'Docs',
        rootPath: '/root/workspace/docs',
      );

      expect(workspace.containsPath('/root/workspace/docs'), isTrue);
      expect(workspace.containsPath('/root/workspace/docs/a/b.md'), isTrue);
      expect(workspace.containsPath('/root/workspace/doc'), isFalse);
      expect(workspace.containsPath('/root/workspace'), isFalse);
      expect(
          workspace.containsPath('/root/workspace/docs/../secrets'), isFalse);
      expect(workspace.containsPath('/etc/passwd'), isFalse);
      expect(workspace.containsPath(''), isFalse);

      expect(
        workspace.relativePathOf('/root/workspace/docs/notes/todo.md'),
        'notes/todo.md',
      );
      expect(workspace.relativePathOf('/root/workspace/other.md'), isNull);
    });

    test('normalizes paths and refuses unusable roots', () {
      expect(
        WorkspaceMetadata.normalizeGuestPath('/root/workspace//a/./b/'),
        '/root/workspace/a/b',
      );
      expect(WorkspaceMetadata.normalizeGuestPath('/root/../etc'), isNull);
      expect(WorkspaceMetadata.normalizeGuestPath('   '), isNull);
      expect(WorkspaceMetadata.normalizeGuestPath(null), isNull);

      expect(
        WorkspaceMetadata.validateRootPath('/root/workspace/work'),
        '/root/workspace/work',
      );
      expect(WorkspaceMetadata.validateRootPath('/etc'), isNull);
      expect(WorkspaceMetadata.validateRootPath('/root/workspacex'), isNull);
      expect(
          WorkspaceMetadata.validateRootPath('/root/workspace/../etc'), isNull);
    });

    test('rejects stored entries that cannot be trusted', () {
      expect(WorkspaceMetadata.tryFromJson(null), isNull);
      expect(WorkspaceMetadata.tryFromJson('nope'), isNull);
      expect(WorkspaceMetadata.tryFromJson({'name': 'x'}), isNull);
      expect(
        WorkspaceMetadata.tryFromJson({'id': 'bad id', 'name': 'x'}),
        isNull,
      );
      expect(
        WorkspaceMetadata.tryFromJson({'id': 'ok', 'name': '   '}),
        isNull,
      );
      // An unusable root falls back to the default tree instead of dropping the
      // workspace.
      final fallback = WorkspaceMetadata.tryFromJson({
        'id': 'ok',
        'name': 'Docs',
        'rootPath': '/etc',
      });
      expect(fallback!.rootPath, kDefaultWorkspaceRoot);
    });

    test('bounds names and sanitizes file segments', () {
      expect(WorkspaceMetadata.validateName('  Plan  '), 'Plan');
      expect(WorkspaceMetadata.validateName('   '), isNull);
      expect(
        WorkspaceMetadata.validateName('x' * 100)!.length,
        WorkspaceMetadata.maxNameLength,
      );

      expect(
        WorkspaceMetadata.sanitizeFileSegment('2026-09-26 10:00 分享'),
        '2026-09-26_10_00_分享',
      );
      expect(WorkspaceMetadata.sanitizeFileSegment('../../etc/passwd'),
          'etc_passwd');
      expect(WorkspaceMetadata.sanitizeFileSegment('   '), 'shared');
      expect(
        WorkspaceMetadata.sanitizeFileSegment('a' * 100).length,
        48,
      );
    });

    test('copyWith keeps identity and refreshes the timestamp', () {
      final created = DateTime(2026, 1, 1);
      final workspace = WorkspaceMetadata(
        id: 'ws-3',
        name: 'Docs',
        createdAt: created,
        updatedAt: created,
      );
      final renamed = workspace.copyWith(
        name: 'Notes',
        rootPath: '/root/workspace/notes',
      );

      expect(renamed.id, 'ws-3');
      expect(renamed.createdAt, created);
      expect(renamed.name, 'Notes');
      expect(renamed.rootPath, '/root/workspace/notes');
      expect(renamed.updatedAt.isAfter(created), isTrue);
    });
  });
}
