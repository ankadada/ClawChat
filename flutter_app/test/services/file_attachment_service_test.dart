import 'dart:convert';
import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/services/attachment_budget.dart';
import 'package:clawchat/services/file_attachment_service.dart';
import 'package:clawchat/services/native_bridge.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConstants.channelName);
  late Directory tempDir;
  late List<Map<String, dynamic>> rootfsWrites;
  late List<String> prootCommands;

  setUp(() async {
    tempDir =
        await Directory.systemTemp.createTemp('clawchat_attachment_test_');
    rootfsWrites = [];
    prootCommands = [];
    FileAttachmentService.resetInlineReadStreamForTesting();
    FileAttachmentService.resetPickerForTesting();
    NativeBridge.resetImportReadStreamForTesting();
    NativeBridge.setImportIdentityProbeForTesting((_) async => 'stable-file');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'writeRootfsFile':
        case 'writeRootfsBytes':
          rootfsWrites.add(
            {
              'method': call.method,
              ...Map<String, dynamic>.from(call.arguments as Map? ?? {}),
            },
          );
          return true;
        case 'runInProot':
          final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
          prootCommands.add(args['command']?.toString() ?? '');
          return '';
      }
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    FileAttachmentService.resetInlineReadStreamForTesting();
    FileAttachmentService.resetPickerForTesting();
    NativeBridge.resetImportReadStreamForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> writeFile(String name, List<int> bytes) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<File> writeStringFile(String name, String content) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsString(content);
    return file;
  }

  Future<File> writeSparseFile(String name, int size) async {
    final file = File('${tempDir.path}/$name');
    final raf = await file.open(mode: FileMode.write);
    try {
      await raf.setPosition(size - 1);
      await raf.writeByte(0);
    } finally {
      await raf.close();
    }
    return file;
  }

  PlatformFile platformFile(File file, String name) {
    return PlatformFile(
      name: name,
      path: file.path,
      size: file.lengthSync(),
    );
  }

  group('FileAttachmentService.prepareForMessage', () {
    test('picker cancellation is silent and picker errors are bounded',
        () async {
      FileAttachmentService.setPickerForTesting(({
        required type,
        required allowMultiple,
        required allowedExtensions,
      }) async =>
          null);
      expect(await FileAttachmentService.pickFiles(), isEmpty);

      FileAttachmentService.setPickerForTesting(({
        required type,
        required allowMultiple,
        required allowedExtensions,
      }) async {
        throw PlatformException(code: 'FILE_PICKER_CANCELLED');
      });
      expect(await FileAttachmentService.pickFiles(), isEmpty);

      FileAttachmentService.setPickerForTesting(({
        required type,
        required allowMultiple,
        required allowedExtensions,
      }) async {
        throw PlatformException(
          code: 'unknown_path',
          message: '/sensitive/provider/path',
        );
      });
      await expectLater(
        FileAttachmentService.pickFiles(),
        throwsA(
          isA<FilePickerException>()
              .having((error) => error.userMessage, 'userMessage',
                  contains('无法读取所选文件'))
              .having((error) => error.toString(), 'details',
                  isNot(contains('sensitive'))),
        ),
      );
    });

    test('null path with bounded bytes is staged in the app cache', () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      FileAttachmentService.setPickerForTesting(({
        required type,
        required allowMultiple,
        required allowedExtensions,
      }) async =>
          FilePickerResult([
            PlatformFile(name: 'photo.png', size: bytes.length, bytes: bytes),
          ]));

      final files = await FileAttachmentService.pickFiles();
      expect(files.single.path, isNotNull);
      expect(await File(files.single.path!).readAsBytes(), bytes);
      final prepared = await FileAttachmentService.prepareForMessage(
        files.single,
      );
      expect(prepared.content, isA<ImageContent>());
    });

    test('content URI identifier stages through native bridge and is cleaned',
        () async {
      final staged = await writeFile('native-picked.png', [1, 2, 3]);
      String? requestedUri;
      String? requestedName;
      String? disposedPath;
      NativeBridge.setPickedContentStagersForTesting(
        stager: (uri, name, maxBytes) async {
          requestedUri = uri;
          requestedName = name;
          expect(maxBytes, AttachmentBudget.maxWorkspaceImportBytes);
          return staged.path;
        },
        disposer: (path) async => disposedPath = path,
      );

      final prepared = await FileAttachmentService.prepareForMessage(
        PlatformFile(
          name: 'photo.png',
          size: 3,
          identifier: 'content://downloads/documents/1',
        ),
      );

      expect(prepared.content, isA<ImageContent>());
      expect(requestedUri, 'content://downloads/documents/1');
      expect(requestedName, 'photo.png');
      expect(disposedPath, staged.path);
    });

    test(
        'content provider failure falls back to bounded bytes and rejects file URI',
        () async {
      NativeBridge.setPickedContentStagersForTesting(
        stager: (uri, name, maxBytes) async {
          throw const FileSystemException('provider unavailable');
        },
      );
      final bytes = Uint8List.fromList([4, 5, 6]);
      final prepared = await FileAttachmentService.prepareForMessage(
        PlatformFile(
          name: 'fallback.png',
          size: bytes.length,
          bytes: bytes,
          identifier: 'content://provider/document/2',
        ),
      );
      expect(prepared.content, isA<ImageContent>());
      await expectLater(
        NativeBridge.stagePickedContentUri(
          contentUri: 'file:///private/secret',
          displayName: 'fallback.png',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('native content staging wrapper sends identifier and bound only',
        () async {
      Map<Object?, Object?>? request;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'stagePickedContentUri') {
          request = Map<Object?, Object?>.from(call.arguments as Map);
          return '/data/data/com.anka.clawbot/cache/clawchat_picked_content/picked_1';
        }
        return null;
      });

      final path = await NativeBridge.stagePickedContentUri(
        contentUri: 'content://downloads/documents/99',
        displayName: 'archive.zip',
      );

      expect(path, startsWith('/data/data/'));
      expect(request?['uri'], 'content://downloads/documents/99');
      expect(request?['displayName'], 'archive.zip');
      expect(request?['maxBytes'], AttachmentBudget.maxWorkspaceImportBytes);
    });

    test('skill archive picker accepts zip tar.gz and tgz without MIME filter',
        () async {
      for (final name in ['skill.zip', 'skill.tar.gz', 'skill.tgz']) {
        final archive = await writeFile(name, [1]);
        FileAttachmentService.setPickerForTesting(({
          required type,
          required allowMultiple,
          required allowedExtensions,
        }) async {
          expect(type, FileType.any);
          expect(allowedExtensions, isNull);
          return FilePickerResult([platformFile(archive, name)]);
        });

        final selected = await FileAttachmentService.pickSkillArchive();
        expect(selected?.name, name);
      }

      final unsupported = await writeFile('skill.gz', [1]);
      FileAttachmentService.setPickerForTesting(({
        required type,
        required allowMultiple,
        required allowedExtensions,
      }) async =>
          FilePickerResult([platformFile(unsupported, 'skill.gz')]));
      await expectLater(
        FileAttachmentService.pickSkillArchive(),
        throwsA(
          isA<FilePickerException>().having(
            (error) => error.reason,
            'reason',
            'unsupported_archive',
          ),
        ),
      );
    });

    test('image file returns ImageContent', () async {
      final file = await writeFile('photo.png', [1, 2, 3, 4]);

      final prepared = await FileAttachmentService.prepareForMessage(
        platformFile(file, 'photo.png'),
      );

      expect(prepared.content, isA<ImageContent>());
      final image = prepared.content as ImageContent;
      expect(image.mediaType, 'image/png');
      expect(image.filename, 'photo.png');
      expect(prepared.includeAsContentBlock, isTrue);
    });

    test('text file returns inlined code block', () async {
      final file = await writeStringFile('main.dart', 'void main() {}');

      final prepared = await FileAttachmentService.prepareForMessage(
        platformFile(file, 'main.dart'),
      );

      expect(prepared.content, isA<TextContent>());
      expect(prepared.inputText, contains('File: main.dart'));
      expect(prepared.inputText, contains('```'));
      expect(prepared.inputText, contains('void main() {}'));
      expect(prepared.includeAsContentBlock, isFalse);
    });

    test('sensitive text file requires confirmation before prompt injection',
        () async {
      final file = await writeStringFile('.env', 'API_KEY=secret');
      final platform = platformFile(file, '.env');

      expect(
        FileAttachmentService.requiresSensitiveTextConfirmation(platform),
        isTrue,
      );
      expect(
        FileAttachmentService.sensitiveTextWarning(platform),
        contains('.env'),
      );

      final prepared = await FileAttachmentService.prepareForMessage(platform);
      expect(prepared.containsSensitiveText, isTrue);
      expect(prepared.inputText, contains('API_KEY=secret'));
    });

    test('pem text file is warned before inlining', () async {
      final file = await writeStringFile('client.pem', 'PRIVATE KEY');
      final platform = platformFile(file, 'client.pem');

      expect(
        FileAttachmentService.requiresSensitiveTextConfirmation(platform),
        isTrue,
      );
      final prepared = await FileAttachmentService.prepareForMessage(platform);
      expect(prepared.inputText, contains('PRIVATE KEY'));
      expect(prepared.containsSensitiveText, isTrue);
    });

    test('oversized image throws', () async {
      final file =
          await writeFile('large.png', List<int>.filled(4 * 1024 * 1024, 1));

      expect(
        FileAttachmentService.prepareForMessage(
          platformFile(file, 'large.png'),
        ),
        throwsException,
      );
    });

    test('image growth after metadata preflight is bounded by actual bytes',
        () async {
      final file = await writeFile('growing.png', [1]);
      final maxChunk = Uint8List(3 * 1024 * 1024);
      FileAttachmentService.setInlineReadStreamForTesting((_) async* {
        yield maxChunk;
        yield [2];
      });

      await expectLater(
        FileAttachmentService.prepareForMessage(
          platformFile(file, 'growing.png'),
        ),
        throwsException,
      );

      expect(rootfsWrites, isEmpty);
      expect(prootCommands, isEmpty);
    });

    test('text growth after metadata preflight is bounded by actual bytes',
        () async {
      final file = await writeFile('growing.txt', [1]);
      final maxChunk = Uint8List(100 * 1024);
      FileAttachmentService.setInlineReadStreamForTesting((_) async* {
        yield maxChunk;
        yield [2];
      });

      await expectLater(
        FileAttachmentService.prepareForMessage(
          platformFile(file, 'growing.txt'),
        ),
        throwsException,
      );

      expect(rootfsWrites, isEmpty);
      expect(prootCommands, isEmpty);
    });

    test('source replacement is rejected after metadata preflight', () async {
      final file = await writeFile('replaced.png', [1]);
      final replacement = await writeFile('replacement.bin', [1, 2]);
      FileAttachmentService.setInlineReadStreamForTesting((path) {
        File(path).deleteSync();
        replacement.renameSync(path);
        return File(path).openRead();
      });

      await expectLater(
        FileAttachmentService.prepareForMessage(
          platformFile(file, 'replaced.png'),
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('inline read error creates no attachment or workspace output',
        () async {
      final file = await writeFile('read-error.txt', [1]);
      FileAttachmentService.setInlineReadStreamForTesting((_) async* {
        yield [1];
        throw const FileSystemException('injected read failure');
      });

      await expectLater(
        FileAttachmentService.prepareForMessage(
          platformFile(file, 'read-error.txt'),
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(rootfsWrites, isEmpty);
      expect(prootCommands, isEmpty);
    });

    test('image and text reads accept their exact byte boundaries', () async {
      final image = await writeSparseFile('boundary.png', 3 * 1024 * 1024);
      final text = await writeStringFile('boundary.txt', 'a' * (100 * 1024));

      final preparedImage = await FileAttachmentService.prepareForMessage(
        platformFile(image, 'boundary.png'),
      );
      final preparedText = await FileAttachmentService.prepareForMessage(
        platformFile(text, 'boundary.txt'),
      );

      expect(preparedImage.content, isA<ImageContent>());
      expect(preparedText.inputText, contains('a' * 1024));
    });

    test('malformed UTF-8 text is rejected after bounded read', () async {
      final file = await writeFile('malformed.txt', [0xff]);

      await expectLater(
        FileAttachmentService.prepareForMessage(
          platformFile(file, 'malformed.txt'),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('oversized binary import throws before workspace write', () async {
      final file = await writeSparseFile('large.bin', 51 * 1024 * 1024);

      expect(
        FileAttachmentService.prepareForMessage(
          platformFile(file, 'large.bin'),
        ),
        throwsException,
      );
    });

    test('oversized text throws', () async {
      final file = await writeStringFile('large.txt', 'x' * (101 * 1024));

      expect(
        FileAttachmentService.prepareForMessage(
          platformFile(file, 'large.txt'),
        ),
        throwsException,
      );
    });

    test('binary file returns workspace path marker', () async {
      final file = await writeFile('archive.bin', [0, 1, 2, 3]);

      final prepared = await FileAttachmentService.prepareForMessage(
        platformFile(file, 'archive.bin'),
      );

      expect(prepared.content, isA<TextContent>());
      expect(prepared.inputText, contains('archive.bin ->'));
      expect(
        prepared.inputText,
        matches(
          RegExp(r'/root/workspace/uploads/archive_[a-f0-9]{32}\.bin'),
        ),
      );
      expect(prepared.includeAsContentBlock, isFalse);
      expect(prepared.workspaceImportReceipt, isNotNull);
      expect(prepared.workspaceImportReceipt!.storedPath,
          contains('/root/workspace/uploads/archive_'));
    });

    test('same-name binary imports use immutable unique destinations',
        () async {
      final first = await writeFile('first.bin', [1, 2, 3]);
      final second = await writeFile('second.bin', [4, 5, 6]);

      final paths = await Future.wait([
        FileAttachmentService.importToWorkspace(
          platformFile(first, 'same.bin'),
        ),
        FileAttachmentService.importToWorkspace(
          platformFile(second, 'same.bin'),
        ),
      ]);

      final storedPaths = paths.map((receipt) => receipt.storedPath).toList();
      expect(storedPaths.toSet(), hasLength(2));
      expect(
        storedPaths,
        everyElement(
          matches(RegExp(
            r'^/root/workspace/uploads/same_[a-f0-9]{32}\.bin$',
          )),
        ),
      );
      expect(rootfsWrites, hasLength(2));
      expect(rootfsWrites.map((write) => write['path']).toSet(), hasLength(2));
      expect(
        rootfsWrites
            .map((write) => base64Encode(write['bytes'] as Uint8List))
            .toSet(),
        {
          base64Encode([1, 2, 3]),
          base64Encode([4, 5, 6])
        },
      );
      expect(rootfsWrites.every((write) => write['createNew'] == true), isTrue);
      expect(prootCommands, isEmpty);
    });

    test('sequential same-name text imports preserve both immutable paths',
        () async {
      final first = await writeStringFile('first.txt', 'first');
      final second = await writeStringFile('second.txt', 'second');

      final firstReceipt = await NativeBridge.importFileToWorkspace(
        first.path,
        'same.txt',
      );
      final secondReceipt = await NativeBridge.importFileToWorkspace(
        second.path,
        'same.txt',
      );

      final firstPath = firstReceipt.storedPath;
      final secondPath = secondReceipt.storedPath;
      expect(firstPath, isNot(secondPath));
      expect(firstPath, matches(RegExp(r'same_[a-f0-9]{32}\.txt$')));
      expect(secondPath, matches(RegExp(r'same_[a-f0-9]{32}\.txt$')));
      expect(
          rootfsWrites.map((write) => write['content']), ['first', 'second']);
      expect(rootfsWrites.every((write) => write['createNew'] == true), isTrue);
    });

    test('create-new destination failure never falls back to overwrite',
        () async {
      final file = await writeFile('write-fails.bin', [7, 8, 9]);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
        if (call.method == 'writeRootfsBytes') {
          expect(args['createNew'], isTrue);
          throw PlatformException(code: 'WRITE_FAILED');
        }
        return null;
      });

      await expectLater(
        FileAttachmentService.importToWorkspace(
          platformFile(file, 'write-fails.bin'),
        ),
        throwsA(isA<PlatformException>()),
      );

      expect(prootCommands, isEmpty);
    });

    test('native import rejects oversized input before reading or writing',
        () async {
      final file = await writeSparseFile('native-large.bin', 51 * 1024 * 1024);

      await expectLater(
        NativeBridge.importFileToWorkspace(file.path, 'native-large.bin'),
        throwsException,
      );
      expect(rootfsWrites, isEmpty);
      expect(prootCommands, isEmpty);
    });

    test('source growth after metadata check is bounded before scratch write',
        () async {
      final file = await writeFile('growing.bin', [1]);
      final repeatedChunk = Uint8List(1024 * 1024);
      NativeBridge.setImportReadStreamForTesting((_) async* {
        for (var index = 0; index < 51; index++) {
          yield repeatedChunk;
        }
      });

      await expectLater(
        NativeBridge.importFileToWorkspace(file.path, 'growing.bin'),
        throwsException,
      );

      expect(rootfsWrites, isEmpty);
      expect(prootCommands, isEmpty);
    });

    test('concurrent source read failure creates no scratch or destination',
        () async {
      final file = await writeFile('mutating.bin', [1]);
      NativeBridge.setImportReadStreamForTesting((_) async* {
        yield [1, 2, 3];
        throw const FileSystemException('source changed while reading');
      });

      await expectLater(
        NativeBridge.importFileToWorkspace(file.path, 'mutating.bin'),
        throwsA(isA<FileSystemException>()),
      );

      expect(rootfsWrites, isEmpty);
      expect(prootCommands, isEmpty);
    });

    test('same-size source replacement is rejected before scratch write',
        () async {
      final file = await writeFile('selected.bin', [1, 2, 3]);
      final replacement = await writeFile('replacement.bin', [4, 5, 6]);
      NativeBridge.setImportReadStreamForTesting((path) {
        File(path).deleteSync();
        File(replacement.path).renameSync(path);
        return File(path).openRead();
      });

      await expectLater(
        NativeBridge.importFileToWorkspace(file.path, 'selected.bin'),
        throwsA(isA<FileSystemException>()),
      );

      expect(rootfsWrites, isEmpty);
      expect(prootCommands, isEmpty);
    });

    test('source symlink substitution is rejected before scratch write',
        () async {
      final file = await writeFile('selected.bin', [1, 2, 3]);
      final replacement = await writeFile('replacement.bin', [4, 5, 6]);
      NativeBridge.setImportReadStreamForTesting((path) {
        File(path).deleteSync();
        Link(path).createSync(replacement.path);
        return File(path).openRead();
      });

      await expectLater(
        NativeBridge.importFileToWorkspace(file.path, 'selected.bin'),
        throwsA(isA<FileSystemException>()),
      );

      expect(rootfsWrites, isEmpty);
      expect(prootCommands, isEmpty);
    });

    test('metadata-stable identity change seam fails before scratch write',
        () async {
      final file = await writeFile('selected.bin', [1, 2, 3]);
      var probes = 0;
      NativeBridge.setImportIdentityProbeForTesting((_) async {
        probes++;
        return probes == 1 ? 'identity-a' : 'identity-b';
      });

      await expectLater(
        NativeBridge.importFileToWorkspace(file.path, 'selected.bin'),
        throwsA(isA<FileSystemException>()),
      );

      expect(probes, 2);
      expect(rootfsWrites, isEmpty);
      expect(prootCommands, isEmpty);
    });

    test('descriptor identity ABA mismatch is rejected before destination',
        () async {
      final file = await writeFile('selected.bin', [1, 2, 3]);
      NativeBridge.resetImportReadStreamForTesting();
      NativeBridge.setHostFileImportBrokerForTesting(
        (_, __, ___, ____) async => {
          'storedPath': '/root/workspace/uploads/restored-original-file.bin',
          'size': 3,
          'sha256': 'a' * 64,
          'sourceIdentity': 'alternate-file',
        },
      );

      await expectLater(
        NativeBridge.importFileToWorkspace(file.path, 'selected.bin'),
        throwsA(isA<FileSystemException>()),
      );

      expect(rootfsWrites, isEmpty);
      expect(prootCommands, isEmpty);
    });

    test('production broker returns metadata without Dart byte roundtrip',
        () async {
      final file = await writeFile('native.bin', [1, 2, 3]);
      NativeBridge.resetImportReadStreamForTesting();
      String? requestedDestination;
      NativeBridge.setHostFileImportBrokerForTesting(
        (_, destination, __, maxBytes) async {
          requestedDestination = destination;
          expect(maxBytes, 50 * 1024 * 1024);
          return {
            'storedPath': '/$destination',
            'size': 3,
            'sha256': 'a' * 64,
            'sourceIdentity': 'descriptor-snapshot',
          };
        },
      );

      final receipt =
          await NativeBridge.importFileToWorkspace(file.path, 'native.bin');

      expect(receipt.storedPath, '/$requestedDestination');
      expect(receipt.size, 3);
      expect(receipt.sha256, 'a' * 64);
      expect(rootfsWrites, isEmpty);
      expect(prootCommands, isEmpty);
    });

    test('production channel returns unacknowledged receipt', () async {
      final file = await writeFile('native.bin', [1, 2, 3]);
      NativeBridge.resetImportReadStreamForTesting();
      var acknowledged = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
        if (call.method == 'importHostFileToWorkspace') {
          final destination = args['destinationPath'] as String;
          return {
            'storedPath': '/$destination',
            'size': 3,
            'sha256': 'c' * 64,
            'sourceIdentity': 'descriptor-snapshot',
          };
        }
        if (call.method == 'acknowledgeHostFileImport') {
          expect(args['storedPath'], startsWith('/root/workspace/uploads/'));
          expect(args['operationId'], matches(RegExp(r'^[a-f0-9]{32}$')));
          acknowledged = true;
          return true;
        }
        return null;
      });

      final receipt =
          await NativeBridge.importFileToWorkspace(file.path, 'native.bin');

      expect(receipt.storedPath, startsWith('/root/workspace/uploads/native_'));
      expect(acknowledged, isFalse);
      expect(rootfsWrites, isEmpty);
    });

    test('failed explicit native journal acknowledgement fails closed',
        () async {
      final file = await writeFile('native.bin', [1, 2, 3]);
      NativeBridge.resetImportReadStreamForTesting();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
        if (call.method == 'importHostFileToWorkspace') {
          final destination = args['destinationPath'] as String;
          return {
            'storedPath': '/$destination',
            'size': 3,
            'sha256': 'd' * 64,
            'sourceIdentity': 'descriptor-snapshot',
          };
        }
        if (call.method == 'acknowledgeHostFileImport') return false;
        return null;
      });

      final receipt =
          await NativeBridge.importFileToWorkspace(file.path, 'native.bin');
      await expectLater(
        NativeBridge.acknowledgeWorkspaceImport(receipt),
        throwsA(isA<FileSystemException>()),
      );

      expect(rootfsWrites, isEmpty);
    });

    test('explicit discard sends the complete operation receipt', () async {
      final file = await writeFile('native.bin', [1, 2, 3]);
      NativeBridge.resetImportReadStreamForTesting();
      Map<String, dynamic>? discarded;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
        if (call.method == 'importHostFileToWorkspace') {
          final destination = args['destinationPath'] as String;
          return {
            'storedPath': '/$destination',
            'size': 3,
            'sha256': 'e' * 64,
            'sourceIdentity': 'descriptor-snapshot',
          };
        }
        if (call.method == 'discardHostFileImport') {
          discarded = args;
          return true;
        }
        return null;
      });

      final receipt =
          await NativeBridge.importFileToWorkspace(file.path, 'native.bin');
      await NativeBridge.discardWorkspaceImport(receipt);

      expect(discarded?['operationId'], receipt.operationId);
      expect(discarded?['storedPath'], receipt.storedPath);
      expect(discarded?['size'], 3);
      expect(discarded?['sha256'], 'e' * 64);
    });

    test('pending native receipt list reconstructs bounded display metadata',
        () async {
      NativeBridge.resetImportReadStreamForTesting();
      const operationId = 'f123456789abcdef0123456789abcde0';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'listPendingWorkspaceImports') {
          expect((call.arguments as Map)['limit'], 64);
          return [
            {
              'operationId': operationId,
              'storedPath': '/root/workspace/uploads/report_$operationId.bin',
              'size': 7,
              'sha256': 'a' * 64,
            },
          ];
        }
        return null;
      });

      final pending = await NativeBridge.listPendingWorkspaceImports();

      expect(pending, hasLength(1));
      expect(pending.single.operationId, operationId);
      expect(pending.single.displayName, 'report.bin');
      expect(pending.single.size, 7);
    });

    test('workspace filename component remains bounded after UUID suffix',
        () async {
      final file = await writeFile('native.bin', [1]);
      NativeBridge.resetImportReadStreamForTesting();
      String? requestedDestination;
      NativeBridge.setHostFileImportBrokerForTesting(
        (_, destination, __, ___) async {
          requestedDestination = destination;
          return {
            'storedPath': '/$destination',
            'size': 1,
            'sha256': 'b' * 64,
            'sourceIdentity': 'descriptor-snapshot',
          };
        },
      );

      await NativeBridge.importFileToWorkspace(
        file.path,
        '${'x' * 400}.${'y' * 80}',
      );

      final component = requestedDestination!.split('/').last;
      expect(utf8.encode(component).length, lessThanOrEqualTo(212));
      expect(component, contains(RegExp(r'_[a-f0-9]{32}')));
    });
  });
}
