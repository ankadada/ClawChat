import 'package:clawchat/constants.dart';
import 'package:clawchat/services/tools/write_file_tool.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConstants.channelName);
  final tool = WriteFileTool();
  String? lastWritePath;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      switch (call.method) {
        case 'runInProot':
          return '';
        case 'writeRootfsFile':
          lastWritePath = args['path'] as String;
          return true;
      }
      return null;
    });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<String?> resolvePath(String path) async {
    lastWritePath = null;
    await tool.execute({'path': path, 'content': 'data'});
    return lastWritePath == null ? null : '/$lastWritePath';
  }

  Future<bool> shellMetacharactersMatch(String pathFragment) async {
    final result = await tool.execute({
      'path': '/root/workspace/$pathFragment',
      'content': 'data',
    });
    return result == 'Error: Path contains invalid characters.';
  }

  group('WriteFileTool path validation - accepted paths', () {
    test('accepts absolute path within workspace', () async {
      expect(
        await resolvePath('/root/workspace/test.txt'),
        '/root/workspace/test.txt',
      );
    });

    test('accepts nested paths within workspace', () async {
      expect(
        await resolvePath('/root/workspace/dir/subdir/file.txt'),
        '/root/workspace/dir/subdir/file.txt',
      );
    });

    test('accepts path with . segments (current dir)', () async {
      expect(
        await resolvePath('/root/workspace/./dir/./file.txt'),
        '/root/workspace/dir/file.txt',
      );
    });

    test('resolves .. within workspace boundary', () async {
      expect(
        await resolvePath('/root/workspace/a/../b/file.txt'),
        '/root/workspace/b/file.txt',
      );
    });

    test('resolves deep .. still within workspace', () async {
      expect(
        await resolvePath('/root/workspace/a/b/c/../../d/file.txt'),
        '/root/workspace/a/d/file.txt',
      );
    });
  });

  group('WriteFileTool path validation - rejected paths', () {
    test('rejects /etc/passwd', () async {
      expect(await resolvePath('/etc/passwd'), isNull);
    });

    test('rejects /root/other/file', () async {
      expect(await resolvePath('/root/other/file'), isNull);
    });

    test('rejects path that traverses out of workspace via ..', () async {
      expect(await resolvePath('/root/workspace/../../etc/shadow'), isNull);
    });

    test('rejects workspace root itself (no trailing slash)', () async {
      expect(await resolvePath('/root/workspace'), isNull);
    });

    test('rejects /tmp path', () async {
      expect(await resolvePath('/tmp/exploit.sh'), isNull);
    });

    test('rejects .. at start that resolves to null', () async {
      expect(await resolvePath('../../../etc/passwd'), isNull);
    });

    test('rejects path that collapses to root', () async {
      expect(await resolvePath('/root/workspace/../..'), isNull);
    });

    test('rejects sibling of workspace', () async {
      expect(await resolvePath('/root/workspace/../other/file'), isNull);
    });
  });

  group('WriteFileTool shell metacharacter detection', () {
    test('detects semicolon', () async {
      expect(await shellMetacharactersMatch('test;echo'), isTrue);
    });

    test('detects pipe', () async {
      expect(await shellMetacharactersMatch('test|echo'), isTrue);
    });

    test('detects ampersand', () async {
      expect(await shellMetacharactersMatch('test&echo'), isTrue);
    });

    test('detects backtick', () async {
      expect(await shellMetacharactersMatch('test`echo`'), isTrue);
    });

    test('detects dollar sign', () async {
      expect(await shellMetacharactersMatch(r'test$HOME'), isTrue);
    });

    test('detects parentheses', () async {
      expect(await shellMetacharactersMatch('test(echo)'), isTrue);
    });

    test('detects curly braces', () async {
      expect(await shellMetacharactersMatch('test{echo}'), isTrue);
    });

    test('detects exclamation mark', () async {
      expect(await shellMetacharactersMatch('test!echo'), isTrue);
    });

    test('detects angle brackets', () async {
      expect(await shellMetacharactersMatch('test>echo'), isTrue);
      expect(await shellMetacharactersMatch('test<echo'), isTrue);
    });

    test('detects asterisk', () async {
      expect(await shellMetacharactersMatch('test*'), isTrue);
    });

    test('detects question mark', () async {
      expect(await shellMetacharactersMatch('test?'), isTrue);
    });

    test('detects square brackets', () async {
      expect(await shellMetacharactersMatch('test[0]'), isTrue);
    });

    test('detects tilde', () async {
      expect(await shellMetacharactersMatch('~user'), isTrue);
    });

    test('detects hash', () async {
      expect(await shellMetacharactersMatch('test#comment'), isTrue);
    });

    test('detects backslash', () async {
      expect(await shellMetacharactersMatch(r'test\n'), isTrue);
    });

    test('detects single quote', () async {
      expect(await shellMetacharactersMatch("test'echo"), isTrue);
    });

    test('allows normal filename', () async {
      expect(await shellMetacharactersMatch('normal-file.txt'), isFalse);
    });

    test('allows filename with underscores and numbers', () async {
      expect(await shellMetacharactersMatch('my_file-2.dart'), isFalse);
    });

    test('allows path separators', () async {
      expect(await shellMetacharactersMatch('dir/subdir/file.txt'), isFalse);
    });

    test('allows dotfiles', () async {
      expect(await shellMetacharactersMatch('.gitignore'), isFalse);
    });
  });
}
