import 'package:flutter_test/flutter_test.dart';

// Extracted from ReadFileTool for unit testing. These must be kept in sync
// with lib/services/tools/read_file_tool.dart.
void main() {
  const allowedRoot = '/root/workspace';

  // Replicates ReadFileTool._resolvePath exactly
  String? resolvePath(String path) {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    final resolved = <String>[];
    for (final seg in segments) {
      if (seg == '.') continue;
      if (seg == '..') {
        if (resolved.isEmpty) return null;
        resolved.removeLast();
      } else {
        resolved.add(seg);
      }
    }
    final normalized = '/${resolved.join('/')}';
    // ReadFileTool allows exact match on _allowedRoot OR prefix with /
    if (normalized != allowedRoot && !normalized.startsWith('$allowedRoot/')) {
      return null;
    }
    return normalized;
  }

  group('ReadFileTool path validation - accepted paths', () {
    test('accepts workspace root itself', () {
      // ReadFileTool allows reading the workspace root (unlike WriteFileTool)
      expect(resolvePath('/root/workspace'), '/root/workspace');
    });

    test('accepts files within workspace', () {
      expect(resolvePath('/root/workspace/file.txt'), '/root/workspace/file.txt');
    });

    test('accepts nested files within workspace', () {
      expect(
        resolvePath('/root/workspace/src/main.py'),
        '/root/workspace/src/main.py',
      );
    });

    test('accepts path with . segments', () {
      expect(
        resolvePath('/root/workspace/./file.txt'),
        '/root/workspace/file.txt',
      );
    });

    test('resolves .. within workspace boundary', () {
      expect(
        resolvePath('/root/workspace/a/../file.txt'),
        '/root/workspace/file.txt',
      );
    });
  });

  group('ReadFileTool path validation - rejected paths', () {
    test('rejects /etc/passwd', () {
      expect(resolvePath('/etc/passwd'), isNull);
    });

    test('rejects /root alone', () {
      expect(resolvePath('/root'), isNull);
    });

    test('rejects /tmp path', () {
      expect(resolvePath('/tmp/data.txt'), isNull);
    });

    test('rejects traversal escaping workspace', () {
      expect(resolvePath('/root/workspace/../../etc/shadow'), isNull);
    });

    test('rejects .. at start', () {
      expect(resolvePath('../../../etc/passwd'), isNull);
    });

    test('rejects sibling of workspace via traversal', () {
      expect(resolvePath('/root/workspace/../other'), isNull);
    });

    test('rejects path that collapses to /', () {
      expect(resolvePath('/root/..'), isNull);
    });

    test('rejects empty-ish path', () {
      // An empty path split produces no segments, resolves to "/"
      expect(resolvePath('/'), isNull);
    });
  });

  group('ReadFileTool path validation - edge cases', () {
    test('handles multiple consecutive slashes', () {
      expect(
        resolvePath('/root///workspace///file.txt'),
        '/root/workspace/file.txt',
      );
    });

    test('handles trailing slash', () {
      expect(
        resolvePath('/root/workspace/dir/'),
        '/root/workspace/dir',
      );
    });

    test('handles mixed . and .. segments', () {
      expect(
        resolvePath('/root/workspace/a/./b/../c/file.txt'),
        '/root/workspace/a/c/file.txt',
      );
    });

    test('difference from WriteFileTool: workspace root allowed', () {
      // This is the key behavioral difference: ReadFileTool checks
      // normalized == allowedRoot || normalized.startsWith(allowedRoot + '/')
      // whereas WriteFileTool only checks the startsWith condition.
      expect(resolvePath('/root/workspace'), '/root/workspace');
    });
  });
}
