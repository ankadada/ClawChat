import 'dart:async';
import 'dart:io';

import 'package:clawchat/services/app_http.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/tts_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const nativeChannel = MethodChannel('com.anka.clawbot/native');
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late PreferencesService prefs;
  late TtsService service;
  late Directory directory;

  setUpAll(() async {
    PreferencesService.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      if (call.method == 'readAll') return <String, String>{};
      return null;
    });
    prefs = PreferencesService();
    await prefs.init();
    prefs.apiKey = 'dummy-key';
  });

  setUp(() async {
    await TtsService().resetApiAudioForTesting();
    AppHttpClientRegistry.resetForTesting();
    final realClients = _RealHttpOverrides();
    final registry = AppHttpClientRegistry(
      runtimeInfo: AppRuntimeInfo.forTesting(),
      createNativeClient: () => realClients.createHttpClient(null),
    );
    AppHttpClientRegistry.installForApp(registry);
    service = TtsService(httpClient: registry.client);
    directory = await Directory.systemTemp.createTemp('clawchat-tts-');
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, null);
    await service.resetApiAudioForTesting();
    AppHttpClientRegistry.resetForTesting();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    PreferencesService.resetForTesting();
  });

  test('native completion deletes the matching generated audio file', () async {
    final server = await _audioServer();
    final playCall = Completer<Map<Object?, Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'playAudio') {
        playCall.complete(call.arguments as Map<Object?, Object?>);
        return true;
      }
      return true;
    });
    try {
      expect(await _speak(service, prefs, directory, server), isTrue);
      final arguments = await playCall.future;
      final operationId = arguments['operationId']! as String;
      final path = arguments['path']! as String;
      expect(await File(path).exists(), isTrue);

      await service.handleNativeAudioEventForTesting(
        operationId: operationId,
        event: 'complete',
      );

      expect(await File(path).exists(), isFalse);
      expect(service.activeApiAudioOperationIdForTesting, isNull);
    } finally {
      await server.close(force: true);
    }
  });

  test('native playback error deletes the file and reports a generic error',
      () async {
    final server = await _audioServer();
    final playCall = Completer<Map<Object?, Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'playAudio') {
        playCall.complete(call.arguments as Map<Object?, Object?>);
      }
      return true;
    });
    try {
      expect(await _speak(service, prefs, directory, server), isTrue);
      final arguments = await playCall.future;
      final operationId = arguments['operationId']! as String;
      final path = arguments['path']! as String;

      await service.handleNativeAudioEventForTesting(
        operationId: operationId,
        event: 'error',
      );

      expect(await File(path).exists(), isFalse);
      expect(service.lastError, '语音播放失败');
    } finally {
      await server.close(force: true);
    }
  });

  test('stop deletes active generated audio even when native stop fails',
      () async {
    final server = await _audioServer();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'stopAudio') {
        throw PlatformException(
          code: 'expected-stop-failure',
          message: 'dummy-sensitive-native-detail',
        );
      }
      return true;
    });
    try {
      expect(await _speak(service, prefs, directory, server), isTrue);
      final path = service.activeApiAudioPathForTesting!;
      expect(await File(path).exists(), isTrue);

      await service.stop();

      expect(await File(path).exists(), isFalse);
      expect(service.activeApiAudioOperationIdForTesting, isNull);
    } finally {
      await server.close(force: true);
    }
  });

  test('native play failure removes the generated file immediately', () async {
    final server = await _audioServer();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'playAudio') {
        throw PlatformException(
          code: 'expected-play-failure',
          message: 'dummy-sensitive-native-detail',
        );
      }
      return true;
    });
    try {
      expect(await _speak(service, prefs, directory, server), isFalse);
      expect(service.activeApiAudioOperationIdForTesting, isNull);
      expect(await directory.list().isEmpty, isTrue);
      expect(service.lastError, '语音合成失败');
      expect(service.lastError, isNot(contains('dummy-sensitive')));
    } finally {
      await server.close(force: true);
    }
  });

  test('late old completion cannot delete newer generated audio', () async {
    final server = await _audioServer();
    final playCalls = <Map<Object?, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'playAudio') {
        playCalls.add(call.arguments as Map<Object?, Object?>);
      }
      return true;
    });
    try {
      expect(await _speak(service, prefs, directory, server), isTrue);
      final oldId = playCalls[0]['operationId']! as String;
      final oldPath = playCalls[0]['path']! as String;

      expect(await _speak(service, prefs, directory, server), isTrue);
      final newId = playCalls[1]['operationId']! as String;
      final newPath = playCalls[1]['path']! as String;
      expect(await File(oldPath).exists(), isFalse);
      expect(await File(newPath).exists(), isTrue);

      await service.handleNativeAudioEventForTesting(
        operationId: oldId,
        event: 'complete',
      );
      expect(await File(newPath).exists(), isTrue);
      expect(service.activeApiAudioOperationIdForTesting, newId);

      await service.handleNativeAudioEventForTesting(
        operationId: newId,
        event: 'complete',
      );
      expect(await File(newPath).exists(), isFalse);
    } finally {
      await server.close(force: true);
    }
  });

  test('latest API speak wins when an older request is still in flight',
      () async {
    final server = await _heldFirstAudioServer();
    final playCalls = <Map<Object?, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'playAudio') {
        playCalls.add(call.arguments as Map<Object?, Object?>);
      }
      return true;
    });
    prefs.baseUrl = 'http://127.0.0.1:${server.server.port}';
    try {
      final first = service.speakViaApiForTesting(
        'first',
        'dummy-model',
        prefs,
        cacheDirectory: directory,
      );
      await server.firstRequestStarted.future;

      final second = service.speakViaApiForTesting(
        'second',
        'dummy-model',
        prefs,
        cacheDirectory: directory,
      );

      expect(await second, isTrue);
      expect(await first, isFalse);
      expect(playCalls, hasLength(1));
      expect(
        service.activeApiAudioOperationIdForTesting,
        playCalls.single['operationId'],
      );
      expect(await File(playCalls.single['path']! as String).exists(), isTrue);
    } finally {
      server.releaseFirst();
      await service.stop();
      await server.server.close(force: true);
    }
  });

  test('a later stop supersedes speak waiting on an older native stop',
      () async {
    final server = await _audioServer();
    final playCalls = <Map<Object?, Object?>>[];
    final stopStarted = Completer<Map<Object?, Object?>>();
    final releaseStop = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'playAudio') {
        playCalls.add(call.arguments as Map<Object?, Object?>);
      }
      if (call.method == 'stopAudio') {
        if (!stopStarted.isCompleted) {
          stopStarted.complete(call.arguments as Map<Object?, Object?>);
        }
        await releaseStop.future;
      }
      return true;
    });
    try {
      expect(await _speak(service, prefs, directory, server), isTrue);
      final firstOperationId = playCalls.single['operationId'];

      final second = _speak(service, prefs, directory, server);
      final stoppedOperation = await stopStarted.future;
      expect(stoppedOperation['operationId'], firstOperationId);
      expect(playCalls, hasLength(1));

      final latestStop = service.stop();
      releaseStop.complete();
      expect(await second, isFalse);
      await latestStop;

      expect(playCalls, hasLength(1));
      expect(service.activeApiAudioOperationIdForTesting, isNull);
      expect(await directory.list().isEmpty, isTrue);
    } finally {
      if (!releaseStop.isCompleted) releaseStop.complete();
      await server.close(force: true);
    }
  });

  test('new speak starts only after its operation-scoped stop completes',
      () async {
    final server = await _audioServer();
    final playCalls = <Map<Object?, Object?>>[];
    final stopStarted = Completer<void>();
    final releaseStop = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'playAudio') {
        playCalls.add(call.arguments as Map<Object?, Object?>);
      }
      if (call.method == 'stopAudio') {
        if (!stopStarted.isCompleted) stopStarted.complete();
        await releaseStop.future;
      }
      return true;
    });
    try {
      expect(await _speak(service, prefs, directory, server), isTrue);
      final oldPath = playCalls.single['path']! as String;

      final second = _speak(service, prefs, directory, server);
      await stopStarted.future;
      expect(playCalls, hasLength(1));

      releaseStop.complete();
      expect(await second, isTrue);
      expect(playCalls, hasLength(2));
      final newPath = playCalls.last['path']! as String;
      expect(await File(oldPath).exists(), isFalse);
      expect(await File(newPath).exists(), isTrue);
      expect(
        service.activeApiAudioOperationIdForTesting,
        playCalls.last['operationId'],
      );
    } finally {
      if (!releaseStop.isCompleted) releaseStop.complete();
      await service.stop();
      await server.close(force: true);
    }
  });

  test('HTTP error body and transport metadata are not exposed', () async {
    final server = await _audioServer(
      statusCode: HttpStatus.internalServerError,
      bytes: 'dummy-sensitive-response'.codeUnits,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (_) async => true);
    try {
      expect(await _speak(service, prefs, directory, server), isFalse);
      expect(service.lastError, '语音合成失败 (500)');
      expect(service.lastError, isNot(contains('dummy-sensitive')));

      final source = await File('lib/services/tts_service.dart').readAsString();
      expect(source, isNot(contains('TTS API: POST')));
      expect(source, isNot(contains(r'model=$model')));
      expect(source, isNot(contains('contentType=')));
      expect(source, isNot(contains('TTS API exception:')));
      expect(source, isNot(contains('utf8.decode(body')));

      final nativeSource = await File(
        'android/app/src/main/kotlin/com/anka/clawbot/MainActivity.kt',
      ).readAsString();
      expect(nativeSource, contains('"operationId" to operationId'));
      expect(nativeSource, contains('"event" to "complete"'));
      expect(nativeSource, contains('"event" to "error"'));
      expect(nativeSource, contains('deleteTtsPlaybackCache(path)'));
      expect(nativeSource, contains('mediaPlaybackOperationId'));
      expect(
        nativeSource,
        contains('operationId != mediaPlaybackOperationId'),
      );
      expect(nativeSource, contains('result.success(false)'));
      expect(
        nativeSource,
        isNot(contains('invokeMethod("onAudioComplete", null)')),
      );
    } finally {
      await server.close(force: true);
    }
  });
}

Future<bool> _speak(
  TtsService service,
  PreferencesService prefs,
  Directory directory,
  HttpServer server,
) {
  prefs.baseUrl = 'http://127.0.0.1:${server.port}';
  return service.speakViaApiForTesting(
    'dummy text',
    'dummy-model',
    prefs,
    cacheDirectory: directory,
  );
}

final class _HeldFirstAudioServer {
  _HeldFirstAudioServer(
    this.server,
    this.firstRequestStarted,
    this._releaseFirst,
  );

  final HttpServer server;
  final Completer<void> firstRequestStarted;
  final Completer<void> _releaseFirst;

  void releaseFirst() {
    if (!_releaseFirst.isCompleted) _releaseFirst.complete();
  }
}

Future<_HeldFirstAudioServer> _heldFirstAudioServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final firstRequestStarted = Completer<void>();
  final releaseFirst = Completer<void>();
  var requestCount = 0;
  server.listen((request) async {
    requestCount += 1;
    final currentRequest = requestCount;
    try {
      await request.drain<void>();
      if (currentRequest == 1) {
        firstRequestStarted.complete();
        await releaseFirst.future;
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      request.response.add(const [1, 2, 3, 4]);
      await request.response.close();
    } catch (_) {
      // The first client is intentionally aborted by the newer operation.
    }
  });
  return _HeldFirstAudioServer(server, firstRequestStarted, releaseFirst);
}

Future<HttpServer> _audioServer({
  int statusCode = HttpStatus.ok,
  List<int> bytes = const [1, 2, 3, 4],
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await request.drain<void>();
    request.response.statusCode = statusCode;
    request.response.headers.contentType = ContentType('audio', 'mpeg');
    request.response.add(bytes);
    await request.response.close();
  });
  return server;
}

final class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}
