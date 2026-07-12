import 'dart:async';
import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/services/app_http.dart';
import 'package:clawchat/services/native_bridge.dart';
import 'package:clawchat/services/skill_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AppConstants.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temp;
  late List<String> commands;
  late int rootfsWrites;

  setUp(() async {
    SkillService.resetLocalImportReadStreamForTesting();
    temp = await Directory.systemTemp.createTemp('clawchat_remote_skill_');
    commands = <String>[];
    rootfsWrites = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      if (call.method == 'getFilesDir') return temp.path;
      if (call.method == 'writeRootfsFile') {
        rootfsWrites++;
        return true;
      }
      if (call.method == 'runInProot') {
        commands.add(args['command'] as String);
        return '';
      }
      return null;
    });
  });

  tearDown(() async {
    SkillService.resetLocalImportReadStreamForTesting();
    NativeBridge.resetImportReadStreamForTesting();
    messenger.setMockMethodCallHandler(channel, null);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('private literal URL is blocked before any socket connection', () async {
    var connectCalls = 0;
    final client = AppWebFetchClient(
      AppRuntimeInfo.forTesting(),
      connectSocket: (_, __) {
        connectCalls++;
        throw StateError('must not connect');
      },
    );
    addTearDown(client.close);
    SkillService.setArchiveHttpClientForTesting(client);

    await expectLater(
      SkillService.prepareSkillFromUrl('http://127.0.0.1/package.zip'),
      throwsA(isA<FormatException>()),
    );

    expect(connectCalls, 0);
    _expectNoRemoteProcess(commands);
    expect(rootfsWrites, 0);
  });

  test('private and mixed DNS answers fail closed before connection', () async {
    for (final addresses in [
      [InternetAddress('10.0.0.1')],
      [InternetAddress('93.184.216.34'), InternetAddress('192.168.0.1')],
    ]) {
      var connectCalls = 0;
      final client = AppWebFetchClient(
        AppRuntimeInfo.forTesting(),
        resolveHost: (_) async => addresses,
        connectSocket: (_, __) {
          connectCalls++;
          throw StateError('must not connect');
        },
      );
      SkillService.setArchiveHttpClientForTesting(client);
      try {
        await expectLater(
          SkillService.prepareSkillFromUrl(
            'http://public.example/package.zip',
          ),
          throwsA(isA<FormatException>()),
        );
        expect(connectCalls, 0);
      } finally {
        client.close();
      }
    }
    _expectNoRemoteProcess(commands);
    expect(rootfsWrites, 0);
  });

  test('redirect to a private literal is revalidated and blocked', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://127.0.0.1:${server.port}/private.zip',
      );
      await request.response.close();
    });
    final realClients = _RealHttpOverrides();
    final client = AppWebFetchClient(
      AppRuntimeInfo.forTesting(),
      createNativeClient: () => realClients.createHttpClient(null),
      resolveHost: (host) async => host == '127.0.0.1'
          ? [InternetAddress.loopbackIPv4]
          : [InternetAddress('93.184.216.34')],
      connectSocket: (_, __) =>
          Socket.startConnect(InternetAddress.loopbackIPv4, server.port),
    );
    SkillService.setArchiveHttpClientForTesting(client);
    try {
      await expectLater(
        SkillService.prepareSkillFromUrl(
          'http://public.example:${server.port}/package.zip',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(requests, 1);
      expect(rootfsWrites, 0);
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('same-host DNS rebind on redirect is blocked', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    var resolutions = 0;
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(HttpHeaders.locationHeader, '/next.zip');
      await request.response.close();
    });
    final realClients = _RealHttpOverrides();
    final client = AppWebFetchClient(
      AppRuntimeInfo.forTesting(),
      createNativeClient: () => realClients.createHttpClient(null),
      resolveHost: (_) async {
        resolutions++;
        return resolutions == 1
            ? [InternetAddress('93.184.216.34')]
            : [InternetAddress.loopbackIPv4];
      },
      connectSocket: (_, __) =>
          Socket.startConnect(InternetAddress.loopbackIPv4, server.port),
    );
    SkillService.setArchiveHttpClientForTesting(client);
    try {
      await expectLater(
        SkillService.prepareSkillFromUrl(
          'http://public.example:${server.port}/package.zip',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(resolutions, 2);
      expect(requests, 1);
      expect(rootfsWrites, 0);
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('download timeout aborts without scratch or staged payload', () async {
    final client = _HangingClient();
    SkillService.setArchiveHttpClientForTesting(
      client,
      timeout: const Duration(milliseconds: 80),
    );

    await expectLater(
      SkillService.prepareSkillFromUrl(
        'https://public.example/package.zip',
      ),
      throwsA(isA<FormatException>().having(
        (error) => error.message,
        'message',
        contains('timed out'),
      )),
    );

    expect(client.abortObserved, completion(isTrue));
    expect(rootfsWrites, 0);
    expect(await _stagedHostFiles(temp), isEmpty);
  });

  test('slow drip cannot extend the absolute import deadline', () async {
    final client = _StreamingClient(() async* {
      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        yield List<int>.filled(16, 1);
      }
    }());
    SkillService.setArchiveHttpClientForTesting(
      client,
      timeout: const Duration(milliseconds: 200),
      totalTimeout: const Duration(milliseconds: 120),
    );
    final clock = Stopwatch()..start();

    await expectLater(
      SkillService.prepareSkillFromUrl(
        'https://public.example/package.zip',
      ),
      throwsA(isA<FormatException>()),
    );

    expect(clock.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(rootfsWrites, 0);
    expect(await _stagedHostFiles(temp), isEmpty);
  });

  test('download cleanup survives an upstream cancel error', () async {
    final controller = StreamController<List<int>>(
      onCancel: () => Future<void>.error(StateError('cancel failed')),
    );
    SkillService.setArchiveHttpClientForTesting(
      _StreamingClient(controller.stream),
      timeout: const Duration(milliseconds: 50),
    );

    await expectLater(
      SkillService.prepareSkillFromUrl(
        'https://public.example/package.zip',
      ),
      throwsA(isA<FormatException>()),
    );

    expect(await _stagedHostFiles(temp), isEmpty);
  });

  test('download cleanup bounds a stalled upstream cancel future', () async {
    final controller = StreamController<List<int>>(
      onCancel: () => Completer<void>().future,
    );
    SkillService.setArchiveHttpClientForTesting(
      _StreamingClient(controller.stream),
      timeout: const Duration(milliseconds: 50),
    );
    final clock = Stopwatch()..start();

    await expectLater(
      SkillService.prepareSkillFromUrl(
        'https://public.example/package.zip',
      ),
      throwsA(isA<FormatException>()),
    );

    expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
    expect(await _stagedHostFiles(temp), isEmpty);
  });

  test('redirects consume one shared absolute deadline', () async {
    final client = _DelayedRedirectClient();
    SkillService.setArchiveHttpClientForTesting(
      client,
      timeout: const Duration(milliseconds: 200),
      totalTimeout: const Duration(milliseconds: 140),
    );
    final clock = Stopwatch()..start();

    await expectLater(
      SkillService.prepareSkillFromUrl(
        'https://public.example/package.zip',
      ),
      throwsA(isA<FormatException>()),
    );

    expect(client.requests, inInclusiveRange(2, 3));
    expect(clock.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(rootfsWrites, 0);
    expect(await _stagedHostFiles(temp), isEmpty);
  });

  test('native workspace copy consumes the same absolute deadline', () async {
    final copyStarted = Completer<void>();
    final copyResult = Completer<Map<String, Object?>>();
    var cancelObserved = false;
    SkillService.setArchiveHttpClientForTesting(
      _StreamingClient(Stream<List<int>>.value([1, 2, 3])),
      timeout: const Duration(milliseconds: 200),
      totalTimeout: const Duration(milliseconds: 120),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getFilesDir') return temp.path;
      if (call.method == 'runInProot') return '';
      if (call.method == 'importHostFileToWorkspace') {
        copyStarted.complete();
        return copyResult.future;
      }
      if (call.method == 'cancelImportOperation') {
        cancelObserved = true;
        if (!copyResult.isCompleted) {
          copyResult.completeError(
            PlatformException(code: 'FILE_IMPORT_CANCELLED'),
          );
        }
        return true;
      }
      return null;
    });
    final clock = Stopwatch()..start();

    final import = SkillService.prepareSkillFromUrl(
      'https://public.example/package.zip',
    );
    final failedImport = expectLater(import, throwsA(isA<FormatException>()));
    await copyStarted.future;
    await failedImport;

    expect(cancelObserved, isTrue);
    expect(clock.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(await _stagedHostFiles(temp), isEmpty);
  });

  test('actual response bytes enforce the archive limit and clean partials',
      () async {
    final chunk = Uint8List(1024 * 1024);
    final client = _StreamingClient(Stream<List<int>>.fromIterable(
      List<List<int>>.filled(26, chunk),
    ));
    SkillService.setArchiveHttpClientForTesting(client);

    await expectLater(
      SkillService.prepareSkillFromUrl(
        'https://public.example/package.zip',
      ),
      throwsA(isA<FormatException>().having(
        (error) => error.message,
        'message',
        contains('too large'),
      )),
    );

    expect(rootfsWrites, 0);
    expect(await _stagedHostFiles(temp), isEmpty);
  });

  test('cancellation aborts an active response and removes partials', () async {
    final client = _AbortAwareStreamingClient();
    final token = SkillImportCancellationToken();
    SkillService.setArchiveHttpClientForTesting(client);

    final import = SkillService.prepareSkillFromUrl(
      'https://public.example/package.zip',
      cancellationToken: token,
    );
    await client.started.future;
    await token.cancel();

    await expectLater(import, throwsA(isA<StateError>()));
    expect(await client.abortObserved, isTrue);
    expect(rootfsWrites, 0);
    expect(await _stagedHostFiles(temp), isEmpty);
  });

  test('cancel after HTTP completion aborts native copy and cleans staging',
      () async {
    final token = SkillImportCancellationToken();
    final copyStarted = Completer<void>();
    final copyResult = Completer<Map<String, Object?>>();
    var nativeCancelObserved = false;
    SkillService.setArchiveHttpClientForTesting(
      _StreamingClient(Stream<List<int>>.value([1, 2, 3])),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      if (call.method == 'getFilesDir') return temp.path;
      if (call.method == 'runInProot') return '';
      if (call.method == 'importHostFileToWorkspace') {
        expect(args['operationId'], token.operationId);
        copyStarted.complete();
        return copyResult.future;
      }
      if (call.method == 'cancelImportOperation') {
        nativeCancelObserved = true;
        if (!copyResult.isCompleted) {
          copyResult.completeError(
            PlatformException(code: 'FILE_IMPORT_CANCELLED'),
          );
        }
        return true;
      }
      return null;
    });

    final import = SkillService.prepareSkillFromUrl(
      'https://public.example/package.zip',
      cancellationToken: token,
    );
    final failedImport = expectLater(import, throwsA(anything));
    await copyStarted.future;
    await token.cancel();

    await failedImport;
    expect(nativeCancelObserved, isTrue);
    expect(await _stagedHostFiles(temp), isEmpty);
  });

  test('cancel during extraction kills owned proot operation', () async {
    final token = SkillImportCancellationToken();
    final extractionStarted = Completer<void>();
    final extractionResult = Completer<String>();
    var nativeCancelObserved = false;
    SkillService.setArchiveHttpClientForTesting(
      _StreamingClient(Stream<List<int>>.value([1, 2, 3])),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      if (call.method == 'getFilesDir') return temp.path;
      if (call.method == 'importHostFileToWorkspace') {
        final destination = args['destinationPath'] as String;
        return {
          'storedPath': '/$destination',
          'size': 3,
          'sha256': 'a' * 64,
          'sourceIdentity': 'descriptor-snapshot',
        };
      }
      if (call.method == 'discardHostFileImport') return true;
      if (call.method == 'runInProot') {
        final command = args['command'] as String;
        if (command.contains('python3 -c')) {
          expect(args['operationId'], token.operationId);
          extractionStarted.complete();
          return extractionResult.future;
        }
        return '';
      }
      if (call.method == 'cancelImportOperation') {
        nativeCancelObserved = true;
        if (!extractionResult.isCompleted) {
          extractionResult.completeError(
            PlatformException(code: 'PROOT_CANCELLED'),
          );
        }
        return true;
      }
      return null;
    });

    final import = SkillService.prepareSkillFromUrl(
      'https://public.example/package.zip',
      cancellationToken: token,
    );
    await extractionStarted.future;
    await token.cancel();

    await expectLater(import, throwsA(isA<StateError>()));
    expect(nativeCancelObserved, isTrue);
    expect(await _stagedHostFiles(temp), isEmpty);
  });

  test('cancel during staged inspection kills traversal before model bytes',
      () async {
    final token = SkillImportCancellationToken();
    final inspectionStarted = Completer<void>();
    final inspectionResult = Completer<String>();
    var rootfsReads = 0;
    var nativeCancelObserved = false;
    SkillService.setArchiveHttpClientForTesting(
      _StreamingClient(Stream<List<int>>.value([1, 2, 3])),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      if (call.method == 'getFilesDir') return temp.path;
      if (call.method == 'importHostFileToWorkspace') {
        final destination = args['destinationPath'] as String;
        return {
          'storedPath': '/$destination',
          'size': 3,
          'sha256': 'b' * 64,
          'sourceIdentity': 'descriptor-snapshot',
        };
      }
      if (call.method == 'discardHostFileImport') return true;
      if (call.method == 'readRootfsFile') {
        rootfsReads++;
        return 'must not be read';
      }
      if (call.method == 'runInProot') {
        final command = args['command'] as String;
        if (command.contains('python3 -c')) return 'SKILL_EXTRACT_OK';
        if (command.contains(r'links=$(')) {
          expect(args['operationId'], token.operationId);
          inspectionStarted.complete();
          return inspectionResult.future;
        }
        return '';
      }
      if (call.method == 'cancelImportOperation') {
        nativeCancelObserved = true;
        if (!inspectionResult.isCompleted) {
          inspectionResult.completeError(
            PlatformException(code: 'PROOT_CANCELLED'),
          );
        }
        return true;
      }
      return null;
    });

    final import = SkillService.prepareSkillFromUrl(
      'https://public.example/package.zip',
      cancellationToken: token,
    );
    await inspectionStarted.future;
    await token.cancel();

    await expectLater(import, throwsA(isA<StateError>()));
    expect(nativeCancelObserved, isTrue);
    expect(rootfsReads, 0);
    expect(await _stagedHostFiles(temp), isEmpty);
  });

  test('cancel during bounded SKILL read returns before consent bytes',
      () async {
    SharedPreferences.setMockInitialValues({});
    final token = SkillImportCancellationToken();
    final readStarted = Completer<void>();
    final readResult = Completer<Uint8List?>();
    var manifestReads = 0;
    var legacyReads = 0;
    SkillService.setArchiveStagerForTesting(
      (_, __) async => '/root/workspace/uploads/test.zip',
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      if (call.method == 'runInProot') {
        final command = args['command'] as String;
        if (command.contains('python3 -c')) return 'SKILL_EXTRACT_OK';
        if (command.contains(r'links=$(')) return '0 2 4';
        if (command.contains(' -maxdepth 4 ')) {
          return '/root/workspace/.skill-import-staging/import_x/SKILL.md';
        }
        return '';
      }
      if (call.method == 'readRootfsFile') {
        legacyReads++;
        return 'must not be read';
      }
      if (call.method == 'readRootfsFileBounded') {
        expect(args['operationId'], token.operationId);
        if ((args['path'] as String).endsWith('/skill.json')) {
          manifestReads++;
          return null;
        }
        expect(args['maxBytes'], 1024 * 1024);
        readStarted.complete();
        return readResult.future;
      }
      if (call.method == 'cancelImportOperation') {
        if (!readResult.isCompleted) {
          readResult.completeError(
            PlatformException(code: 'BOUNDED_READ_CANCELLED'),
          );
        }
        return true;
      }
      if (call.method == 'finishImportOperation') return true;
      return null;
    });

    final import = SkillService.prepareSkillFromUrl(
      'https://public.example/package.zip',
      cancellationToken: token,
    );
    final failedImport = expectLater(import, throwsA(isA<StateError>()));
    await readStarted.future;
    await token.cancel();
    await failedImport;

    expect(manifestReads, 0);
    expect(legacyReads, 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('skill_trust_grants_v1'), isNull);
  });

  test('oversized staged SKILL fails at native preflight before consent',
      () async {
    SharedPreferences.setMockInitialValues({});
    var manifestReads = 0;
    SkillService.setArchiveStagerForTesting(
      (_, __) async => '/root/workspace/uploads/test.zip',
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      if (call.method == 'runInProot') {
        final command = args['command'] as String;
        if (command.contains('python3 -c')) return 'SKILL_EXTRACT_OK';
        if (command.contains(r'links=$(')) return '0 2 4';
        if (command.contains(' -maxdepth 4 ')) {
          return '/root/workspace/.skill-import-staging/import_x/SKILL.md';
        }
        return '';
      }
      if (call.method == 'readRootfsFileBounded') {
        expect(args['maxBytes'], 1024 * 1024);
        if ((args['path'] as String).endsWith('/skill.json')) manifestReads++;
        throw PlatformException(code: 'BOUNDED_READ_ERROR');
      }
      if (call.method == 'cancelImportOperation' ||
          call.method == 'finishImportOperation') {
        return true;
      }
      return null;
    });

    await expectLater(
      SkillService.prepareSkillFromUrl(
        'https://public.example/package.zip',
      ),
      throwsA(isA<PlatformException>()),
    );

    expect(manifestReads, 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('skill_trust_grants_v1'), isNull);
  });
}

void _expectNoRemoteProcess(List<String> commands) {
  expect(commands.any((command) => command.contains('curl ')), isFalse);
  expect(commands.any((command) => command.contains('git clone')), isFalse);
}

Future<List<FileSystemEntity>> _stagedHostFiles(Directory temp) async {
  final root = Directory('${temp.path}/skill_imports');
  if (!await root.exists()) return const [];
  return root.list(recursive: true).where((entity) => entity is File).toList();
}

final class _HangingClient extends http.BaseClient {
  final Completer<bool> _abortObserved = Completer<bool>();

  Future<bool> get abortObserved => _abortObserved.future;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request is http.AbortableRequest) {
      request.abortTrigger!.then((_) {
        if (!_abortObserved.isCompleted) _abortObserved.complete(true);
      });
    }
    return Completer<http.StreamedResponse>().future;
  }
}

final class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.stream);

  final Stream<List<int>> stream;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(stream, HttpStatus.ok);
}

final class _AbortAwareStreamingClient extends http.BaseClient {
  final Completer<void> started = Completer<void>();
  final Completer<bool> _abortObserved = Completer<bool>();

  Future<bool> get abortObserved => _abortObserved.future;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final controller = StreamController<List<int>>();
    if (!started.isCompleted) started.complete();
    if (request is http.AbortableRequest) {
      request.abortTrigger!.then((_) {
        if (!_abortObserved.isCompleted) _abortObserved.complete(true);
        controller.addError(http.ClientException('aborted'));
        controller.close();
      });
    }
    return http.StreamedResponse(controller.stream, HttpStatus.ok);
  }
}

final class _DelayedRedirectClient extends http.BaseClient {
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return http.StreamedResponse(
      const Stream<List<int>>.empty(),
      HttpStatus.found,
      headers: {'location': '/next$requests.zip'},
    );
  }
}

final class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context);
}
