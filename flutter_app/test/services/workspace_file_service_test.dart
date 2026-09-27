import 'dart:convert';

import 'package:clawchat/models/workspace.dart';
import 'package:clawchat/models/workspace_file.dart';
import 'package:clawchat/services/workspace_file_service.dart';
import 'package:clawchat/constants.dart';
import 'package:clawchat/services/native_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A recording stand-in for the scoped native APIs.
class _FakeRootfs {
  final listed = <String>[];
  final readBytes = <String>[];
  final deleted = <String>[];
  final written = <String, String>{};
  List<String> allowedRoots = const [];
  int lastMaxEntries = 0;
  Map<String, dynamic> listing = const {'entries': [], 'truncated': false};
  Uint8List? bytesResult;
  bool deleteResult = true;
  bool writeResult = true;
  Object? listError;

  Future<Map<String, dynamic>> list({
    required String path,
    required List<String> allowedRoots,
    required int maxEntries,
  }) async {
    listed.add(path);
    this.allowedRoots = allowedRoots;
    lastMaxEntries = maxEntries;
    final error = listError;
    if (error != null) throw error;
    return listing;
  }

  Future<Uint8List?> readBytesFile(
    String path, {
    List<String>? allowedRoots,
    int maxBytes = 0,
  }) async {
    readBytes.add(path);
    this.allowedRoots = allowedRoots ?? const [];
    return bytesResult;
  }

  Future<bool> deleteFile(String path, {List<String>? allowedRoots}) async {
    deleted.add(path);
    this.allowedRoots = allowedRoots ?? const [];
    return deleteResult;
  }

  final writeCreateNew = <bool>[];

  Future<bool> writeFile(
    String path,
    String content, {
    List<String>? allowedRoots,
    bool createNew = false,
  }) async {
    written[path] = content;
    writeCreateNew.add(createNew);
    this.allowedRoots = allowedRoots ?? const [];
    return writeResult;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeRootfs fake;
  late WorkspaceFileService service;

  WorkspaceFileService serviceFor(WorkspaceMetadata workspace) =>
      WorkspaceFileService(
        workspace: workspace,
        list: fake.list,
        readBytes: fake.readBytesFile,
        delete: fake.deleteFile,
        write: fake.writeFile,
      );

  late WorkspaceMetadata workspace;

  setUp(() {
    fake = _FakeRootfs();
    workspace = WorkspaceMetadata(
      id: 'ws-1',
      name: 'Docs',
      rootPath: '/root/workspace/docs',
    );
    service = serviceFor(workspace);
  });

  WorkspaceFileEntry entry(
    String name, {
    String? path,
    bool isDirectory = false,
    bool isSymbolicLink = false,
    int sizeBytes = 0,
  }) =>
      WorkspaceFileEntry(
        name: name,
        path: path ?? '/root/workspace/docs/$name',
        isDirectory: isDirectory,
        isSymbolicLink: isSymbolicLink,
        sizeBytes: sizeBytes,
      );

  group('scope', () {
    test('listing only ever asks for the workspace root', () async {
      await service.list('/root/workspace/docs');

      expect(fake.listed, ['/root/workspace/docs']);
      expect(fake.allowedRoots, ['/root/workspace/docs']);
      expect(fake.lastMaxEntries, WorkspaceFileService.maxEntries);
    });

    test('paths outside the workspace are refused before the native call',
        () async {
      for (final path in [
        '/root/workspace',
        '/root/workspace/other',
        '/etc',
        '/root/workspace/docs/../secrets',
        '/root/workspace/docs\u0000',
      ]) {
        await expectLater(
          service.list(path),
          throwsA(
            isA<WorkspaceFileException>()
                .having((error) => error.code, 'code', 'outside_scope'),
          ),
        );
      }
      expect(fake.listed, isEmpty);
    });

    test('a nested workspace cannot read its parent', () async {
      final nested = serviceFor(
        WorkspaceMetadata(
          id: 'ws-2',
          name: 'Nested',
          rootPath: '/root/workspace/docs/nested',
        ),
      );

      await expectLater(
        nested.list('/root/workspace/docs'),
        throwsA(isA<WorkspaceFileException>()),
      );
      expect(fake.listed, isEmpty);
    });

    test('display and session references use workspace-relative paths',
        () async {
      expect(service.displayPath('/root/workspace/docs/a/b.md'), 'a/b.md');
      expect(service.displayPath('/root/workspace/docs'), 'Docs');
      expect(service.displayPath('/etc'), '/etc');

      expect(
        service.sessionReference(entry('plan.md')),
        '工作区文件：/root/workspace/docs/plan.md',
      );
      expect(
        () => service.sessionReference(entry('x', path: '/etc/passwd')),
        throwsA(isA<WorkspaceFileException>()),
      );
    });
  });

  group('listing', () {
    test('parses entries, links and truncation', () async {
      fake.listing = {
        'entries': [
          {
            'name': 'sub',
            'path': '/root/workspace/docs/sub',
            'isDirectory': true,
            'isSymbolicLink': false,
            'sizeBytes': 0,
            'modifiedEpochMs': 1700000000000,
          },
          {
            'name': 'link',
            'path': '/root/workspace/docs/link',
            'isDirectory': false,
            'isSymbolicLink': true,
            'sizeBytes': 12,
            'modifiedEpochMs': 0,
          },
          {'name': '', 'path': ''},
        ],
        'truncated': true,
      };

      final listing = await service.list('/root/workspace/docs');

      expect(listing.entries, hasLength(2));
      expect(listing.entries.first.isDirectory, isTrue);
      expect(listing.entries.first.canOpen, isTrue);
      expect(listing.entries.last.isSymbolicLink, isTrue);
      expect(listing.entries.last.canOpen, isFalse);
      expect(listing.entries.first.modifiedAt, isNotNull);
      expect(listing.truncated, isTrue);
    });

    test('an empty or unusable listing is empty, not a crash', () async {
      fake.listing = const {};
      final listing = await service.list('/root/workspace/docs');
      expect(listing.isEmpty, isTrue);
      expect(listing.truncated, isFalse);
    });

    test('native refusals surface as a scoped failure', () async {
      fake.listError =
          Exception('Path is outside the granted filesystem scope');

      await expectLater(
        service.list('/root/workspace/docs'),
        throwsA(
          isA<WorkspaceFileException>()
              .having((error) => error.code, 'code', 'list_failed'),
        ),
      );
    });
  });

  group('preview', () {
    test('text previews decode through the bounded byte read and feed undo',
        () async {
      fake.bytesResult = Uint8List.fromList(utf8.encode('hello\n'));

      final preview = await service.preview(entry('note.md'));

      expect(preview.kind, WorkspaceFilePreviewKind.text);
      expect(preview.text, 'hello\n');
      expect(service.textForUndo(preview), 'hello\n');
      expect(fake.readBytes, ['/root/workspace/docs/note.md']);
      expect(fake.allowedRoots, ['/root/workspace/docs']);
    });

    test(
        'oversized text is refused with a reason instead of truncated silently',
        () async {
      final preview = await service.preview(
        entry('big.txt',
            sizeBytes: WorkspaceFileService.maxTextPreviewBytes + 1),
      );

      expect(preview.kind, WorkspaceFilePreviewKind.unsupported);
      expect(preview.note, contains('较大'));
      expect(fake.readBytes, isEmpty);
    });

    test('images preview by extension, with the media type normalised',
        () async {
      fake.bytesResult = Uint8List.fromList([1, 2, 3]);

      final jpg = await service.preview(entry('photo.jpg'));
      final png = await service.preview(entry('shot.PNG'));

      expect(jpg.kind, WorkspaceFilePreviewKind.image);
      expect(jpg.mediaType, 'image/jpeg');
      expect(png.mediaType, 'image/png');
      expect(service.textForUndo(jpg), isNull);
    });

    test('oversized images are refused before reading', () async {
      final preview = await service.preview(
        entry('huge.png',
            sizeBytes: WorkspaceFileService.maxImagePreviewBytes + 1),
      );

      expect(preview.kind, WorkspaceFilePreviewKind.unsupported);
      expect(fake.readBytes, isEmpty);
    });

    test('binary content is refused as unsupported', () async {
      fake.bytesResult = Uint8List.fromList([0x61, 0x00, 0x62]);

      final preview = await service.preview(entry('blob.bin'));

      expect(preview.kind, WorkspaceFilePreviewKind.unsupported);
      expect(preview.note, contains('二进制'));
    });

    test('a file outside the workspace is never read', () async {
      await expectLater(
        service.preview(entry('x.md', path: '/root/workspace/elsewhere.md')),
        throwsA(isA<WorkspaceFileException>()),
      );
      expect(fake.readBytes, isEmpty);
    });
  });

  group('exclusive creation travels the real chain', () {
    const nativeChannel = MethodChannel('com.anka.clawbot/native');
    late List<Map<String, Object?>> captured;

    setUp(() {
      captured = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, (call) async {
        captured.add({
          'method': call.method,
          'arguments': call.arguments,
        });
        if (call.method == 'writeRootfsFile') return true;
        if (call.method == 'createRootfsDirectory') return true;
        if (call.method == 'listRootfsDirectory') {
          return {'entries': <Object?>[], 'truncated': false};
        }
        if (call.method == 'deleteRootfsFile') return true;
        if (call.method == 'readRootfsFileBounded') return null;
        if (call.method == 'readRootfsFileBytes') {
          return Uint8List.fromList(utf8.encode('preview body'));
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, null);
    });

    test('a save sends createNew: true over the platform channel', () async {
      final service = WorkspaceFileService(workspace: workspace);
      final saved = await service.saveTextWithRetry(
        candidatePaths: const ['/root/workspace/docs/shared/note.md'],
        body: 'body',
      );

      expect(saved, '/root/workspace/docs/shared/note.md');
      final write = captured.singleWhere(
        (call) => call['method'] == 'writeRootfsFile',
      );
      final arguments =
          Map<String, Object?>.from(write['arguments'] as Map? ?? {});
      expect(arguments['path'], '/root/workspace/docs/shared/note.md');
      expect(arguments['content'], 'body');
      expect(arguments['createNew'], isTrue);
      expect(arguments['allowedRoots'], ['/root/workspace/docs']);

      // The documented destination lives in a subdirectory: the save creates
      // it through the same scope before writing, which is what makes the
      // first save into a fresh workspace succeed on a device.
      final mkdir = captured.singleWhere(
        (call) => call['method'] == 'createRootfsDirectory',
      );
      final mkdirArguments =
          Map<String, Object?>.from(mkdir['arguments'] as Map? ?? {});
      expect(mkdirArguments['path'], '/root/workspace/docs/shared');
      expect(mkdirArguments['allowedRoots'], ['/root/workspace/docs']);
      expect(
        captured.indexWhere(
          (call) => call['method'] == 'createRootfsDirectory',
        ),
        lessThan(
          captured.indexWhere((call) => call['method'] == 'writeRootfsFile'),
        ),
      );
    });

    test('a saved markdown previews through the scoped bounded read', () async {
      final service = WorkspaceFileService(workspace: workspace);
      final preview = await service.preview(const WorkspaceFileEntry(
        name: 'note.md',
        path: '/root/workspace/docs/shared/note.md',
        isDirectory: false,
        isSymbolicLink: false,
        sizeBytes: 12,
        modifiedAt: null,
      ));

      // The preview reads the same path the save wrote, inside the workspace
      // scope and inside the 64 KiB text cap, and it decodes as text: a device
      // save must be previewable (which is what enables the undo affordance).
      expect(preview.kind, WorkspaceFilePreviewKind.text);
      expect(preview.text, 'preview body');
      final read = captured.singleWhere(
        (call) => call['method'] == 'readRootfsFileBytes',
      );
      final arguments =
          Map<String, Object?>.from(read['arguments'] as Map? ?? {});
      expect(arguments['path'], '/root/workspace/docs/shared/note.md');
      expect(arguments['allowedRoots'], ['/root/workspace/docs']);
      expect(arguments['maxBytes'], WorkspaceFileService.maxTextPreviewBytes);
    });

    test('restore also sends createNew: true', () async {
      final service = WorkspaceFileService(workspace: workspace);
      await service.restoreText('/root/workspace/docs/shared/note.md', 'text');

      final write = captured.singleWhere(
        (call) => call['method'] == 'writeRootfsFile',
      );
      final arguments =
          Map<String, Object?>.from(write['arguments'] as Map? ?? {});
      expect(arguments['createNew'], isTrue);
    });

    test('the native bridge forwards createNew for direct callers too',
        () async {
      final written = await NativeBridge.writeRootfsFile(
        '/root/workspace/docs/shared/direct.md',
        'direct',
        allowedRoots: const ['/root/workspace/docs'],
        createNew: true,
      );

      expect(written, isTrue);
      final write = captured.singleWhere(
        (call) => call['method'] == 'writeRootfsFile',
      );
      final arguments =
          Map<String, Object?>.from(write['arguments'] as Map? ?? {});
      expect(arguments['createNew'], isTrue);
      expect(arguments['allowedRoots'], ['/root/workspace/docs']);
      expect(AppConstants.channelName, 'com.anka.clawbot/native');
    });
  });

  group('delete and undo', () {
    test('file deletion stays inside the workspace', () async {
      await service.delete(entry('note.md'));

      expect(fake.deleted, ['/root/workspace/docs/note.md']);
      expect(fake.allowedRoots, ['/root/workspace/docs']);
    });

    test('directories and links are refused with an explicit reason', () async {
      await expectLater(
        service.delete(entry('sub', isDirectory: true)),
        throwsA(
          isA<WorkspaceFileException>().having(
              (error) => error.code, 'code', 'directory_delete_unsupported'),
        ),
      );
      await expectLater(
        service.delete(entry('link', isSymbolicLink: true)),
        throwsA(
          isA<WorkspaceFileException>().having(
              (error) => error.code, 'code', 'symlink_delete_unsupported'),
        ),
      );
      expect(fake.deleted, isEmpty);
    });

    test('a native refusal becomes a delete_failed error', () async {
      fake.deleteResult = false;

      await expectLater(
        service.delete(entry('note.md')),
        throwsA(
          isA<WorkspaceFileException>()
              .having((error) => error.code, 'code', 'delete_failed'),
        ),
      );
    });

    test('a taken name is skipped and the next candidate is written', () async {
      var calls = 0;
      final createNewFlags = <bool>[];
      final created = <String>[];
      final service = WorkspaceFileService(
        workspace: workspace,
        createDirectory: (path, {List<String>? allowedRoots}) async {
          created.add(path);
          return true;
        },
        write: (path, content,
            {List<String>? allowedRoots, bool createNew = false}) async {
          calls++;
          createNewFlags.add(createNew);
          // The first candidate is already taken (CREATE_NEW refused it).
          return calls > 1;
        },
      );

      final saved = await service.saveTextWithRetry(
        candidatePaths: const [
          '/root/workspace/docs/shared/taken.md',
          '/root/workspace/docs/shared/free.md',
        ],
        body: 'body',
      );

      expect(calls, 2);
      // Every attempt asks for exclusive creation; the retry is not a silent
      // overwrite of the name that was already there.
      expect(createNewFlags, [true, true]);
      expect(created, ['/root/workspace/docs/shared']);
      expect(saved, '/root/workspace/docs/shared/free.md');
    });

    test('a candidate outside the workspace is refused, never written',
        () async {
      final written = <String>[];
      final service = WorkspaceFileService(
        workspace: workspace,
        write: (path, content,
            {List<String>? allowedRoots, bool createNew = false}) async {
          written.add(path);
          return true;
        },
      );

      await expectLater(
        service.saveTextWithRetry(
          candidatePaths: const ['/etc/passwd'],
          body: 'body',
        ),
        throwsA(
          isA<WorkspaceFileException>()
              .having((error) => error.code, 'code', 'outside_scope'),
        ),
      );
      expect(written, isEmpty);
    });

    test('when no candidate can be written the save reports failure', () async {
      final service = WorkspaceFileService(
        workspace: workspace,
        createDirectory: (path, {List<String>? allowedRoots}) async => true,
        write: (path, content,
                {List<String>? allowedRoots, bool createNew = false}) async =>
            false,
      );

      expect(
        await service.saveTextWithRetry(
          candidatePaths: const ['/root/workspace/docs/shared/a.md'],
          body: 'body',
        ),
        isNull,
      );
    });

    test('a directory that cannot be created skips the write', () async {
      final written = <String>[];
      final service = WorkspaceFileService(
        workspace: workspace,
        createDirectory: (path, {List<String>? allowedRoots}) async => false,
        write: (path, content,
            {List<String>? allowedRoots, bool createNew = false}) async {
          written.add(path);
          return true;
        },
      );

      expect(
        await service.saveTextWithRetry(
          candidatePaths: const ['/root/workspace/docs/shared/a.md'],
          body: 'body',
        ),
        isNull,
      );
      expect(written, isEmpty);
    });

    test('a save directly in the workspace root creates no directory',
        () async {
      final created = <String>[];
      final service = WorkspaceFileService(
        workspace: workspace,
        createDirectory: (path, {List<String>? allowedRoots}) async {
          created.add(path);
          return true;
        },
        write: (path, content,
                {List<String>? allowedRoots, bool createNew = false}) async =>
            true,
      );

      expect(
        await service.saveTextWithRetry(
          candidatePaths: const ['/root/workspace/docs/root-note.md'],
          body: 'body',
        ),
        '/root/workspace/docs/root-note.md',
      );
      expect(created, isEmpty);
    });

    test('text undo writes the same content through the same scope', () async {
      await service.restoreText('/root/workspace/docs/note.md', 'hello');

      expect(fake.written['/root/workspace/docs/note.md'], 'hello');
      expect(fake.allowedRoots, ['/root/workspace/docs']);
    });

    test('decoding helpers refuse NUL payloads', () {
      expect(
        WorkspaceFileService.decodeBoundedText(utf8.encode('ok')),
        'ok',
      );
      expect(WorkspaceFileService.decodeBoundedText([1, 0, 2]), isNull);
    });
  });
}
