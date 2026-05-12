import 'package:flutter_test/flutter_test.dart';

// Extracted from WriteFileTool for unit testing. These must be kept in sync
// with lib/services/tools/write_file_tool.dart.
void main() {
  const allowedRoot = '/root/workspace';

  final shellMetacharacters = RegExp(r"[;|&`$(){}!<>*?\[\]~#\\']");

  // Replicates WriteFileTool._resolvePath exactly
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
    if (!normalized.startsWith('$allowedRoot/')) return null;
    return normalized;
  }

  group('WriteFileTool path validation - accepted paths', () {
    test('accepts absolute path within workspace', () {
      expect(resolvePath('/root/workspace/test.txt'), '/root/workspace/test.txt');
    });

    test('accepts nested paths within workspace', () {
      expect(
        resolvePath('/root/workspace/dir/subdir/file.txt'),
        '/root/workspace/dir/subdir/file.txt',
      );
    });

    test('accepts path with . segments (current dir)', () {
      expect(
        resolvePath('/root/workspace/./dir/./file.txt'),
        '/root/workspace/dir/file.txt',
      );
    });

    test('resolves .. within workspace boundary', () {
      expect(
        resolvePath('/root/workspace/a/../b/file.txt'),
        '/root/workspace/b/file.txt',
      );
    });

    test('resolves deep .. still within workspace', () {
      expect(
        resolvePath('/root/workspace/a/b/c/../../d/file.txt'),
        '/root/workspace/a/d/file.txt',
      );
    });
  });

  group('WriteFileTool path validation - rejected paths', () {
    test('rejects /etc/passwd', () {
      expect(resolvePath('/etc/passwd'), isNull);
    });

    test('rejects /root/other/file', () {
      expect(resolvePath('/root/other/file'), isNull);
    });

    test('rejects path that traverses out of workspace via ..', () {
      expect(resolvePath('/root/workspace/../../etc/shadow'), isNull);
    });

    test('rejects workspace root itself (no trailing slash)', () {
      // WriteFileTool requires paths WITHIN workspace, not the root itself.
      // The check is: normalized.startsWith('$allowedRoot/') — exact match fails.
      expect(resolvePath('/root/workspace'), isNull);
    });

    test('rejects /tmp path', () {
      expect(resolvePath('/tmp/exploit.sh'), isNull);
    });

    test('rejects .. at start that resolves to null', () {
      expect(resolvePath('../../../etc/passwd'), isNull);
    });

    test('rejects path that collapses to root', () {
      expect(resolvePath('/root/workspace/../..'), isNull);
    });

    test('rejects sibling of workspace', () {
      expect(resolvePath('/root/workspace/../other/file'), isNull);
    });
  });

  group('WriteFileTool shell metacharacter detection', () {
    test('detects semicolon', () {
      expect(shellMetacharacters.hasMatch('test;echo'), isTrue);
    });

    test('detects pipe', () {
      expect(shellMetacharacters.hasMatch('test|echo'), isTrue);
    });

    test('detects ampersand', () {
      expect(shellMetacharacters.hasMatch('test&echo'), isTrue);
    });

    test('detects backtick', () {
      expect(shellMetacharacters.hasMatch('test`echo`'), isTrue);
    });

    test('detects dollar sign', () {
      expect(shellMetacharacters.hasMatch(r'test$HOME'), isTrue);
    });

    test('detects parentheses', () {
      expect(shellMetacharacters.hasMatch('test(echo)'), isTrue);
    });

    test('detects curly braces', () {
      expect(shellMetacharacters.hasMatch('test{echo}'), isTrue);
    });

    test('detects exclamation mark', () {
      expect(shellMetacharacters.hasMatch('test!echo'), isTrue);
    });

    test('detects angle brackets', () {
      expect(shellMetacharacters.hasMatch('test>echo'), isTrue);
      expect(shellMetacharacters.hasMatch('test<echo'), isTrue);
    });

    test('detects asterisk', () {
      expect(shellMetacharacters.hasMatch('test*'), isTrue);
    });

    test('detects question mark', () {
      expect(shellMetacharacters.hasMatch('test?'), isTrue);
    });

    test('detects square brackets', () {
      expect(shellMetacharacters.hasMatch('test[0]'), isTrue);
    });

    test('detects tilde', () {
      expect(shellMetacharacters.hasMatch('~user'), isTrue);
    });

    test('detects hash', () {
      expect(shellMetacharacters.hasMatch('test#comment'), isTrue);
    });

    test('detects backslash', () {
      expect(shellMetacharacters.hasMatch(r'test\n'), isTrue);
    });

    test('detects single quote', () {
      expect(shellMetacharacters.hasMatch("test'echo"), isTrue);
    });

    test('allows normal filename', () {
      expect(shellMetacharacters.hasMatch('normal-file.txt'), isFalse);
    });

    test('allows filename with underscores and numbers', () {
      expect(shellMetacharacters.hasMatch('my_file-2.dart'), isFalse);
    });

    test('allows path separators', () {
      expect(shellMetacharacters.hasMatch('dir/subdir/file.txt'), isFalse);
    });

    test('allows dotfiles', () {
      expect(shellMetacharacters.hasMatch('.gitignore'), isFalse);
    });
  });
}
