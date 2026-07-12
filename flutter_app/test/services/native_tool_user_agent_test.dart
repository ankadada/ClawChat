import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/services/app_http.dart';
import 'package:clawchat/services/bootstrap_service.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/tools/image_gen_tool.dart';
import 'package:clawchat/services/tools/web_fetch_tool.dart';
import 'package:clawchat/services/tools/web_search_tool.dart';
import 'package:clawchat/services/tts_service.dart';
import 'package:clawchat/services/whisper_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixedUserAgent = AppRuntimeInfo.forTesting().userAgent;

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late PreferencesService prefs;
  setUpAll(() async {
    PreferencesService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      if (call.method == 'readAll') return <String, String>{};
      return null;
    });
    SharedPreferences.setMockInitialValues({});
    prefs = PreferencesService();
    await prefs.init();
    prefs.apiKey = 'dummy-key';
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    PreferencesService.resetForTesting();
  });

  tearDown(AppHttpClientRegistry.resetForTesting);

  test('WebFetch cannot override UA and preserves other custom headers',
      () async {
    final exchange = await _serveOnce(
      responseBody: 'ok',
      run: (uri) async {
        final realClients = _RealHttpOverrides();
        final client = AppWebFetchClient(
          AppRuntimeInfo.forTesting(),
          createNativeClient: () => realClients.createHttpClient(null),
          resolveHost: (_) async => [InternetAddress('93.184.216.34')],
          connectSocket: (_, __) => Socket.startConnect(
            InternetAddress.loopbackIPv4,
            uri.port,
          ),
        );
        try {
          return await WebFetchTool(
            client: client,
            validateUrl: (_) async {},
            upgradeInsecureUrls: false,
          ).execute({
            'url': uri.toString(),
            'headers': {
              'User-Agent': 'caller-one',
              'user-agent': 'caller-two',
              'X-Custom': 'survives',
            },
          });
        } finally {
          client.close();
        }
      },
    );

    expect(exchange.headers.value(HttpHeaders.userAgentHeader), fixedUserAgent);
    expect(exchange.headers.value('x-custom'), 'survives');
  });

  test('WebFetch redirect hop re-resolves and rejects a private target',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requestCount = 0;
    server.listen((request) async {
      requestCount += 1;
      await request.drain<void>();
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://blocked.example:${server.port}/private',
      );
      await request.response.close();
    });
    final realClients = _RealHttpOverrides();
    final client = AppWebFetchClient(
      AppRuntimeInfo.forTesting(),
      createNativeClient: () => realClients.createHttpClient(null),
      resolveHost: (host) async => host == 'start.example'
          ? [InternetAddress('93.184.216.34')]
          : [InternetAddress.loopbackIPv4],
      connectSocket: (_, __) =>
          Socket.startConnect(InternetAddress.loopbackIPv4, server.port),
    );
    try {
      final result = await WebFetchTool(
        client: client,
        validateUrl: (_) async {},
        upgradeInsecureUrls: false,
      ).execute({
        'url': 'http://start.example:${server.port}/start',
      });

      expect(result, contains('SSRF policy'));
      expect(requestCount, 1);
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('Image generation uses the fixed product UA', () async {
    final exchange = await _serveOnce(
      responseBody: jsonEncode({
        'data': [
          {'url': 'https://example.invalid/image.png'},
        ],
      }),
      run: (uri) async {
        prefs.baseUrl = uri.origin;
        return ImageGenTool(prefs).execute({'prompt': 'dummy'});
      },
    );

    expect(exchange.headers.value(HttpHeaders.userAgentHeader), fixedUserAgent);
  });

  test('TTS API uses the fixed product UA', () async {
    final exchange = await _serveOnce(
      statusCode: HttpStatus.internalServerError,
      responseBody: 'expected test failure',
      run: (uri) async {
        prefs.baseUrl = uri.origin;
        return TtsService().speakViaApiForTesting(
          'dummy text',
          'dummy-model',
          prefs,
        );
      },
    );

    expect(exchange.headers.value(HttpHeaders.userAgentHeader), fixedUserAgent);
  });

  test('Whisper multipart upload uses the fixed product UA', () async {
    final directory = await Directory.systemTemp.createTemp('clawchat-ua-');
    final audio = File('${directory.path}/sample.m4a');
    await audio.writeAsBytes(List<int>.filled(128, 0));
    try {
      final exchange = await _serveOnce(
        responseBody: jsonEncode({'text': 'ok'}),
        run: (uri) => WhisperService().transcribeFileForTesting(
          file: audio,
          apiKey: 'dummy-key',
          model: 'dummy-model',
          baseUrl: uri.origin,
        ),
      );

      expect(
          exchange.headers.value(HttpHeaders.userAgentHeader), fixedUserAgent);
      expect(await audio.exists(), isFalse);
    } finally {
      if (await audio.exists()) await audio.delete();
      await directory.delete();
    }
  });

  test('WebSearch uses the fixed product UA instead of browser spoofing',
      () async {
    final exchange = await _serveOnce(
      responseBody: '<html></html>',
      run: (uri) => WebSearchTool(endpoint: uri).execute({
        'query': 'dummy',
        'num_results': 1,
      }),
    );

    expect(exchange.headers.value(HttpHeaders.userAgentHeader), fixedUserAgent);
  });

  test('bootstrap streamed download uses fixed UA and reports progress',
      () async {
    final directory = await Directory.systemTemp.createTemp('clawchat-rootfs-');
    final destination = File('${directory.path}/rootfs.tar.gz');
    final progress = <int>[];
    try {
      final exchange = await _serveOnce(
        responseBody: 'streamed-rootfs-bytes',
        run: (uri) => BootstrapService(
          httpClient: AppHttpClientRegistry.instance.client,
        ).downloadFileForTesting(
          uri,
          destination,
          onProgress: (received, total) => progress.add(received),
        ),
      );

      expect(
          exchange.headers.value(HttpHeaders.userAgentHeader), fixedUserAgent);
      expect(await destination.readAsString(), 'streamed-rootfs-bytes');
      expect(progress, isNotEmpty);
    } finally {
      if (await destination.exists()) await destination.delete();
      await directory.delete();
    }
  });

  test('bootstrap download removes a partial file after failure', () async {
    final realClients = _RealHttpOverrides();
    AppHttpClientRegistry.installForApp(AppHttpClientRegistry(
      runtimeInfo: AppRuntimeInfo.forTesting(),
      createNativeClient: () => realClients.createHttpClient(null),
    ));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    });
    final directory =
        await Directory.systemTemp.createTemp('clawchat-partial-');
    final destination = File('${directory.path}/rootfs.tar.gz');
    await destination.writeAsString('partial');
    try {
      await expectLater(
        BootstrapService().downloadFileForTesting(
          Uri.parse('http://127.0.0.1:${server.port}/rootfs'),
          destination,
        ),
        throwsA(isA<HttpException>()),
      );
      expect(await destination.exists(), isFalse);
    } finally {
      await server.close(force: true);
      if (await destination.exists()) await destination.delete();
      await directory.delete();
    }
  });

  test('bootstrap timeout aborts its request and removes the partial file',
      () async {
    final realClients = _RealHttpOverrides();
    AppHttpClientRegistry.installForApp(AppHttpClientRegistry(
      runtimeInfo: AppRuntimeInfo.forTesting(),
      createNativeClient: () => realClients.createHttpClient(null),
    ));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final releaseResponse = Completer<void>();
    server.listen((request) async {
      await request.drain<void>();
      request.response.contentLength = 64;
      request.response.add(List<int>.filled(8, 1));
      await request.response.flush();
      await releaseResponse.future;
      await request.response.close();
    });
    final directory =
        await Directory.systemTemp.createTemp('clawchat-timeout-');
    final destination = File('${directory.path}/rootfs.tar.gz');
    try {
      await expectLater(
        BootstrapService().downloadFileForTesting(
          Uri.parse('http://127.0.0.1:${server.port}/rootfs'),
          destination,
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(await destination.exists(), isFalse);
    } finally {
      if (!releaseResponse.isCompleted) releaseResponse.complete();
      await server.close(force: true);
      if (await destination.exists()) await destination.delete();
      await directory.delete();
    }
  });
}

final class _Exchange {
  const _Exchange(this.headers);

  final HttpHeaders headers;
}

Future<_Exchange> _serveOnce({
  required String responseBody,
  required FutureOr<Object?> Function(Uri uri) run,
  int statusCode = HttpStatus.ok,
}) {
  final realClients = _RealHttpOverrides();
  return _serveOnceWithRealClient(
    responseBody: responseBody,
    run: run,
    statusCode: statusCode,
    createHttpClient: () => realClients.createHttpClient(null),
  );
}

Future<_Exchange> _serveOnceWithRealClient({
  required String responseBody,
  required FutureOr<Object?> Function(Uri uri) run,
  required int statusCode,
  required AppNativeHttpClientFactory createHttpClient,
}) async {
  AppHttpClientRegistry.resetForTesting();
  AppHttpClientRegistry.installForApp(AppHttpClientRegistry(
    runtimeInfo: AppRuntimeInfo.forTesting(),
    createNativeClient: createHttpClient,
  ));
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final captured = Completer<HttpHeaders>();
  server.listen((request) async {
    if (!captured.isCompleted) captured.complete(request.headers);
    await request.drain<void>();
    request.response.statusCode = statusCode;
    request.response.headers.contentType = ContentType.json;
    request.response.write(responseBody);
    await request.response.close();
  });

  try {
    await run(Uri.parse('http://127.0.0.1:${server.port}'));
    return _Exchange(await captured.future);
  } finally {
    await server.close(force: true);
    AppHttpClientRegistry.resetForTesting();
  }
}

final class _RealHttpOverrides extends HttpOverrides {
  // This concrete test factory intentionally bypasses Flutter's fake client.
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}
