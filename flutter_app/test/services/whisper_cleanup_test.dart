import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/services/app_http.dart';
import 'package:clawchat/services/whisper_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const nativeChannel = MethodChannel('com.anka.clawbot/native');
  late Directory directory;
  late WhisperService service;

  setUp(() async {
    await WhisperService().resetForTesting();
    AppHttpClientRegistry.resetForTesting();
    final realClients = _RealHttpOverrides();
    final registry = AppHttpClientRegistry(
      runtimeInfo: AppRuntimeInfo.forTesting(),
      createNativeClient: () => realClients.createHttpClient(null),
    );
    AppHttpClientRegistry.installForApp(registry);
    service = WhisperService(httpClient: registry.client);
    directory = await Directory.systemTemp.createTemp('clawchat-whisper-');
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, null);
    await service.resetForTesting();
    AppHttpClientRegistry.resetForTesting();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('deletes the captured audio file after success', () async {
    final file = await _audioFile(directory, 'success.m4a');
    final server = await _jsonServer(
      statusCode: HttpStatus.ok,
      body: jsonEncode({'text': 'ok'}),
    );
    try {
      final result = await service.transcribeFileForTesting(
        file: file,
        apiKey: 'dummy-key',
        model: 'dummy-model',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );

      expect(result, 'ok');
      expect(await file.exists(), isFalse);
    } finally {
      await server.close(force: true);
    }
  });

  test('deletes the captured audio file after an HTTP error', () async {
    final file = await _audioFile(directory, 'http-error.m4a');
    final server = await _jsonServer(
      statusCode: HttpStatus.internalServerError,
      body: jsonEncode({'error': 'expected'}),
    );
    try {
      final result = await service.transcribeFileForTesting(
        file: file,
        apiKey: 'dummy-key',
        model: 'dummy-model',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );

      expect(result, isNull);
      expect(await file.exists(), isFalse);
    } finally {
      await server.close(force: true);
    }
  });

  test('cancel during upload aborts only that operation and deletes its file',
      () async {
    final file = await _audioFile(directory, 'cancel.m4a');
    final exchange = await _heldResponseServer();
    final transcription = service.transcribeFileForTesting(
      file: file,
      apiKey: 'dummy-key',
      model: 'dummy-model',
      baseUrl: 'http://127.0.0.1:${exchange.server.port}',
    );
    try {
      await exchange.requestStarted.future;
      await service.cancelRecording();

      expect(await transcription, isNull);
      expect(await file.exists(), isFalse);
    } finally {
      exchange.release();
      await exchange.server.close(force: true);
    }
  });

  test('timeout deletes the partial operation file', () async {
    final file = await _audioFile(directory, 'timeout.m4a');
    final exchange = await _heldResponseServer();
    try {
      final result = await service.transcribeFileForTesting(
        file: file,
        apiKey: 'dummy-key',
        model: 'dummy-model',
        baseUrl: 'http://127.0.0.1:${exchange.server.port}',
        timeout: const Duration(milliseconds: 100),
      );

      expect(result, isNull);
      expect(await file.exists(), isFalse);
    } finally {
      exchange.release();
      await exchange.server.close(force: true);
    }
  });

  test('response read failure still deletes the captured file', () async {
    final file = await _audioFile(directory, 'read-failure.m4a');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        await request.drain<void>();
        request.response.statusCode = HttpStatus.ok;
        request.response.contentLength = 100;
        final socket = await request.response.detachSocket(writeHeaders: true);
        socket.add(utf8.encode('short'));
        await socket.flush();
        socket.destroy();
      } catch (_) {
        // The test intentionally breaks the response stream.
      }
    });
    try {
      final result = await service.transcribeFileForTesting(
        file: file,
        apiKey: 'dummy-key',
        model: 'dummy-model',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );

      expect(result, isNull);
      expect(await file.exists(), isFalse);
    } finally {
      await server.close(force: true);
    }
  });

  test('stale upload completion never deletes a newer recording path',
      () async {
    final oldFile = await _audioFile(directory, 'old-upload.m4a');
    final newFile = await _audioFile(directory, 'new-recording.m4a');
    final exchange = await _heldResponseServer(
      responseBody: jsonEncode({'text': 'ok'}),
    );
    final oldTranscription = service.transcribeFileForTesting(
      file: oldFile,
      apiKey: 'dummy-key',
      model: 'dummy-model',
      baseUrl: 'http://127.0.0.1:${exchange.server.port}',
    );
    try {
      await exchange.requestStarted.future;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, (call) async {
        final operationId =
            (call.arguments as Map<Object?, Object?>)['operationId']! as String;
        if (call.method == 'startRecording') {
          return {'operationId': operationId, 'path': newFile.path};
        }
        if (call.method == 'stopRecording') {
          return {'operationId': operationId, 'path': newFile.path};
        }
        return null;
      });
      await service.startRecording();
      expect(service.isRecording, isTrue);

      exchange.release();
      expect(await oldTranscription, 'ok');
      expect(await oldFile.exists(), isFalse);
      expect(await newFile.exists(), isTrue);

      await service.cancelRecording();
      expect(await newFile.exists(), isFalse);
    } finally {
      exchange.release();
      await exchange.server.close(force: true);
    }
  });

  test('stop failure deletes the recording captured by that stop operation',
      () async {
    final file = await _audioFile(directory, 'stop-failure.m4a');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
      final operationId =
          (call.arguments as Map<Object?, Object?>)['operationId']! as String;
      if (call.method == 'startRecording') {
        return {'operationId': operationId, 'path': file.path};
      }
      if (call.method == 'stopRecording') {
        throw PlatformException(code: 'expected-stop-failure');
      }
      return null;
    });

    await service.startRecording();
    final result = await service.stopAndTranscribe();

    expect(result, isNull);
    expect(await file.exists(), isFalse);
  });

  test('unawaited upload cancellation cannot delete a newer recording',
      () async {
    final oldFile = await _audioFile(directory, 'whisper_old.m4a');
    final newFile = await _audioFile(directory, 'whisper_new.m4a');
    final exchange = await _heldResponseServer();
    final oldTranscription = service.transcribeFileForTesting(
      file: oldFile,
      apiKey: 'dummy-key',
      model: 'dummy-model',
      baseUrl: 'http://127.0.0.1:${exchange.server.port}',
    );
    try {
      await exchange.requestStarted.future;
      final oldCancellation = service.cancelRecording();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, (call) async {
        final operationId =
            (call.arguments as Map<Object?, Object?>)['operationId']! as String;
        return {'operationId': operationId, 'path': newFile.path};
      });
      await service.startRecording();
      await oldCancellation;
      expect(await oldTranscription, isNull);

      expect(service.isRecording, isTrue);
      expect(await oldFile.exists(), isFalse);
      expect(await newFile.readAsBytes(), List<int>.filled(1024, 1));

      await service.cancelRecording();
      expect(await newFile.exists(), isFalse);
    } finally {
      exchange.release();
      await exchange.server.close(force: true);
    }
  });

  test('native recording protocol uses unique owned paths and stale-safe IDs',
      () async {
    final source = await File(
      'android/app/src/main/kotlin/com/anka/clawbot/MainActivity.kt',
    ).readAsString();

    expect(source, isNot(contains('whisper_recording.m4a')));
    expect(source, contains(r'"whisper_${UUID.randomUUID()}.m4a"'));
    expect(source, contains('recordingOperationId'));
    expect(source, contains('operationId != recordingOperationId'));
    expect(source, contains('deleteWhisperRecordingCache'));
    expect(source, contains('cleanupOldWhisperRecordingCache'));
    expect(source, contains('WHISPER_ORPHAN_MAX_AGE_MS'));
    expect(source,
        contains('deleteWhisperRecordingCache(abandonedRecordingPath)'));
  });
}

Future<File> _audioFile(Directory directory, String name) async {
  final file = File('${directory.path}/$name');
  await file.writeAsBytes(List<int>.filled(1024, 1));
  return file;
}

Future<HttpServer> _jsonServer({
  required int statusCode,
  required String body,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await request.drain<void>();
    request.response.statusCode = statusCode;
    request.response.headers.contentType = ContentType.json;
    request.response.write(body);
    await request.response.close();
  });
  return server;
}

final class _HeldResponseServer {
  _HeldResponseServer(
    this.server,
    this.requestStarted,
    this._releaseResponse,
  );

  final HttpServer server;
  final Completer<void> requestStarted;
  final Completer<void> _releaseResponse;

  void release() {
    if (!_releaseResponse.isCompleted) _releaseResponse.complete();
  }
}

Future<_HeldResponseServer> _heldResponseServer({
  String responseBody = '{}',
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requestStarted = Completer<void>();
  final releaseResponse = Completer<void>();
  server.listen((request) async {
    try {
      await request.drain<void>();
      if (!requestStarted.isCompleted) requestStarted.complete();
      await releaseResponse.future;
      request.response.headers.contentType = ContentType.json;
      request.response.write(responseBody);
      await request.response.close();
    } catch (_) {
      // Cancellation can close the socket before the held response is sent.
    }
  });
  return _HeldResponseServer(server, requestStarted, releaseResponse);
}

final class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}
