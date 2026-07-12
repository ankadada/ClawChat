import 'package:clawchat/constants.dart';
import 'package:clawchat/services/tools/read_file_tool.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConstants.channelName);
  final tool = ReadFileTool();
  String? lastReadPath;
  List<String>? lastAllowedRoots;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'readRootfsFile') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        lastReadPath = args['path'] as String;
        lastAllowedRoots = (args['allowedRoots'] as List?)?.cast<String>();
        if (lastReadPath!.contains('linked-outside') ||
            lastReadPath!.contains('scope-link')) {
          throw PlatformException(
            code: 'ROOTFS_READ_ERROR',
            message: 'Symlink traversal is not allowed',
          );
        }
        return 'fake content';
      }
      return null;
    });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<String?> resolvePath(String path) async {
    lastReadPath = null;
    await tool.execute({'path': path});
    return lastReadPath == null ? null : '/$lastReadPath';
  }

  group('ReadFileTool path validation - accepted paths', () {
    test('accepts workspace root itself', () async {
      expect(await resolvePath('/root/workspace'), '/root/workspace');
    });

    test('accepts files within workspace', () async {
      expect(
        await resolvePath('/root/workspace/file.txt'),
        '/root/workspace/file.txt',
      );
    });

    test('accepts nested files within workspace', () async {
      expect(
        await resolvePath('/root/workspace/src/main.py'),
        '/root/workspace/src/main.py',
      );
    });

    test('accepts path with . segments', () async {
      expect(
        await resolvePath('/root/workspace/./file.txt'),
        '/root/workspace/file.txt',
      );
    });

    test('resolves .. within workspace boundary', () async {
      expect(
        await resolvePath('/root/workspace/a/../file.txt'),
        '/root/workspace/file.txt',
      );
    });
  });

  group('ReadFileTool path validation - rejected paths', () {
    test('rejects /etc/passwd', () async {
      expect(await resolvePath('/etc/passwd'), isNull);
    });

    test('rejects /root alone', () async {
      expect(await resolvePath('/root'), isNull);
    });

    test('rejects /tmp path', () async {
      expect(await resolvePath('/tmp/data.txt'), isNull);
    });

    test('rejects traversal escaping workspace', () async {
      expect(await resolvePath('/root/workspace/../../etc/shadow'), isNull);
    });

    test('rejects .. at start', () async {
      expect(await resolvePath('../../../etc/passwd'), isNull);
    });

    test('rejects sibling of workspace via traversal', () async {
      expect(await resolvePath('/root/workspace/../other'), isNull);
    });

    test('rejects path that collapses to /', () async {
      expect(await resolvePath('/root/..'), isNull);
    });

    test('rejects empty-ish path', () async {
      expect(await resolvePath('/'), isNull);
    });
  });

  group('ReadFileTool path validation - edge cases', () {
    test('handles multiple consecutive slashes', () async {
      expect(
        await resolvePath('/root///workspace///file.txt'),
        '/root/workspace/file.txt',
      );
    });

    test('handles trailing slash', () async {
      expect(
        await resolvePath('/root/workspace/dir/'),
        '/root/workspace/dir',
      );
    });

    test('handles mixed . and .. segments', () async {
      expect(
        await resolvePath('/root/workspace/a/./b/../c/file.txt'),
        '/root/workspace/a/c/file.txt',
      );
    });

    test('difference from WriteFileTool: workspace root allowed', () async {
      expect(await resolvePath('/root/workspace'), '/root/workspace');
    });
  });

  group('ReadFileTool native scope enforcement', () {
    test('passes the declared scope to the native open boundary', () async {
      await tool.executeWithAllowedScopes(
        {'path': '/root/workspace/scoped/file.txt'},
        const {'/root/workspace/scoped'},
      );
      expect(lastAllowedRoots, ['/root/workspace/scoped']);
    });

    test('fails closed for a pre-existing symlink escape', () async {
      final result = await tool.executeWithAllowedScopes(
        {'path': '/root/workspace/scoped/linked-outside/private.txt'},
        const {'/root/workspace/scoped'},
      );
      expect(result, startsWith('Error reading file:'));
    });

    test('fails closed when the declared scope root is a symlink', () async {
      final result = await tool.executeWithAllowedScopes(
        {'path': '/root/workspace/scope-link/private.txt'},
        const {'/root/workspace/scope-link'},
      );
      expect(result, startsWith('Error reading file:'));
    });
  });
}
