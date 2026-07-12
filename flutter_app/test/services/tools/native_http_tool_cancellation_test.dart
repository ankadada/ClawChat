import 'dart:async';
import 'dart:io';

import 'package:clawchat/services/app_http.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/tools/image_gen_tool.dart';
import 'package:clawchat/services/tools/tool_registry.dart';
import 'package:clawchat/services/tools/web_fetch_tool.dart';
import 'package:clawchat/services/tools/web_search_tool.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late PreferencesService prefs;

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
    prefs.apiKey = 'test-key';
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    PreferencesService.resetForTesting();
  });

  test('WebFetch aborts an in-flight request as a known read-only failure',
      () async {
    final exchange = await _slowExchange();
    final realClients = _RealHttpOverrides();
    final client = AppWebFetchClient(
      AppRuntimeInfo.forTesting(),
      createNativeClient: () => realClients.createHttpClient(null),
      resolveHost: (_) async => [InternetAddress('93.184.216.34')],
      connectSocket: (_, __) => Socket.startConnect(
        InternetAddress.loopbackIPv4,
        exchange.server.port,
      ),
    );
    final signal = ToolCancellationSignal();
    final future = WebFetchTool(
      client: client,
      validateUrl: (_) async {},
      upgradeInsecureUrls: false,
    ).executeResultWithOperationAndCancellation(
      {'url': 'http://public.example:${exchange.server.port}/slow'},
      operationId: 'fetch-operation',
      cancellationSignal: signal,
    );
    try {
      await exchange.started.future;
      signal.cancel();

      await expectLater(
        future.timeout(const Duration(seconds: 1)),
        throwsA(isA<ToolExecutionCancelledException>().having(
          (error) => error.sideEffectsPrevented,
          'sideEffectsPrevented',
          isTrue,
        )),
      );
    } finally {
      exchange.release.complete();
      client.close();
      await exchange.server.close(force: true);
    }
  });

  test('WebFetch cancellation detaches from a stalled validation resolver',
      () async {
    final limiter = AppResolverLimiter(maxConcurrent: 2);
    final validationStarted = Completer<void>();
    final releaseValidation = Completer<void>();
    var pinnedResolutionCount = 0;
    final client = AppWebFetchClient(
      AppRuntimeInfo.forTesting(),
      resolverLimiter: limiter,
      resolveHost: (_) async {
        pinnedResolutionCount += 1;
        return [InternetAddress('93.184.216.34')];
      },
    );
    final signal = ToolCancellationSignal();
    final future = WebFetchTool(
      client: client,
      resolverLimiter: limiter,
      validateUrl: (_) async {
        validationStarted.complete();
        await releaseValidation.future;
      },
      upgradeInsecureUrls: false,
    ).executeResultWithOperationAndCancellation(
      {'url': 'http://public.example/resource'},
      operationId: 'validation-cancel',
      cancellationSignal: signal,
    );

    try {
      await validationStarted.future;
      final elapsed = Stopwatch()..start();
      signal.cancel();

      await expectLater(
        future,
        throwsA(isA<ToolExecutionCancelledException>()),
      );
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
      expect(pinnedResolutionCount, 0);
      expect(limiter.activeCount, 1);

      releaseValidation.complete();
      await _waitUntil(() => limiter.activeCount == 0);
    } finally {
      if (!releaseValidation.isCompleted) releaseValidation.complete();
      client.close();
    }
  });

  test('WebFetch total timeout includes a stalled validation resolver',
      () async {
    final limiter = AppResolverLimiter(maxConcurrent: 1);
    final releaseValidation = Completer<void>();
    var pinnedResolutionCount = 0;
    final client = AppWebFetchClient(
      AppRuntimeInfo.forTesting(),
      resolverLimiter: limiter,
      resolveHost: (_) async {
        pinnedResolutionCount += 1;
        return [InternetAddress('93.184.216.34')];
      },
    );
    final elapsed = Stopwatch()..start();
    final result = await WebFetchTool(
      client: client,
      resolverLimiter: limiter,
      operationTimeout: const Duration(milliseconds: 50),
      validateUrl: (_) => releaseValidation.future,
      upgradeInsecureUrls: false,
    ).execute({'url': 'http://public.example/resource'});

    try {
      expect(result, startsWith('Error:'));
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
      expect(pinnedResolutionCount, 0);
      expect(limiter.activeCount, 1);
    } finally {
      releaseValidation.complete();
      await _waitUntil(() => limiter.activeCount == 0);
      client.close();
    }
  });

  test('WebFetch cancellation detaches from a stalled pinned resolver',
      () async {
    final limiter = AppResolverLimiter(maxConcurrent: 2);
    final pinnedStarted = Completer<void>();
    final releasePinned = Completer<List<InternetAddress>>();
    var connectCount = 0;
    final client = AppWebFetchClient(
      AppRuntimeInfo.forTesting(),
      resolverLimiter: limiter,
      resolveHost: (_) {
        pinnedStarted.complete();
        return releasePinned.future;
      },
      connectSocket: (_, __) {
        connectCount += 1;
        throw StateError('late resolver result dispatched a request');
      },
    );
    final signal = ToolCancellationSignal();
    final future = WebFetchTool(
      client: client,
      resolverLimiter: limiter,
      validateUrl: (_) async {},
      upgradeInsecureUrls: false,
    ).executeResultWithOperationAndCancellation(
      {'url': 'http://public.example/resource'},
      operationId: 'pinned-cancel',
      cancellationSignal: signal,
    );

    try {
      await pinnedStarted.future;
      signal.cancel();
      await expectLater(
        future,
        throwsA(isA<ToolExecutionCancelledException>()),
      );
      expect(connectCount, 0);
      expect(limiter.activeCount, 1);

      releasePinned.complete([InternetAddress('93.184.216.34')]);
      await _waitUntil(() => limiter.activeCount == 0);
      await Future<void>.delayed(Duration.zero);
      expect(connectCount, 0);
    } finally {
      if (!releasePinned.isCompleted) {
        releasePinned.complete([InternetAddress('93.184.216.34')]);
      }
      client.close();
    }
  });

  test('WebFetch total timeout is not reset before pinned DNS', () async {
    final limiter = AppResolverLimiter(maxConcurrent: 2);
    final pinnedStarted = Completer<void>();
    final releasePinned = Completer<List<InternetAddress>>();
    var connectCount = 0;
    final client = AppWebFetchClient(
      AppRuntimeInfo.forTesting(),
      resolverLimiter: limiter,
      resolveHost: (_) {
        pinnedStarted.complete();
        return releasePinned.future;
      },
      connectSocket: (_, __) {
        connectCount += 1;
        throw StateError('request must not be dispatched');
      },
    );
    final elapsed = Stopwatch()..start();
    final resultFuture = WebFetchTool(
      client: client,
      resolverLimiter: limiter,
      operationTimeout: const Duration(milliseconds: 200),
      validateUrl: (_) => Future<void>.delayed(
        const Duration(milliseconds: 120),
      ),
      upgradeInsecureUrls: false,
    ).execute({'url': 'http://public.example/resource'});

    try {
      await pinnedStarted.future;
      final result = await resultFuture;
      expect(result, startsWith('Error:'));
      expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 290)));
      expect(connectCount, 0);

      releasePinned.complete([InternetAddress('93.184.216.34')]);
      await _waitUntil(() => limiter.activeCount == 0);
      await Future<void>.delayed(Duration.zero);
      expect(connectCount, 0);
    } finally {
      if (!releasePinned.isCompleted) {
        releasePinned.complete([InternetAddress('93.184.216.34')]);
      }
      client.close();
    }
  });

  test('repeated cancelled validation DNS work remains bounded', () async {
    final limiter = AppResolverLimiter(maxConcurrent: 2);
    final releaseValidation = Completer<void>();
    var validationStarts = 0;
    var pinnedResolutionCount = 0;
    final client = AppWebFetchClient(
      AppRuntimeInfo.forTesting(),
      resolverLimiter: limiter,
      resolveHost: (_) async {
        pinnedResolutionCount += 1;
        return [InternetAddress('93.184.216.34')];
      },
    );
    final signals = List.generate(8, (_) => ToolCancellationSignal());
    final tool = WebFetchTool(
      client: client,
      resolverLimiter: limiter,
      validateUrl: (_) async {
        validationStarts += 1;
        await releaseValidation.future;
      },
      upgradeInsecureUrls: false,
    );
    final futures = List.generate(
      signals.length,
      (index) => tool.executeResultWithOperationAndCancellation(
        {'url': 'http://public.example/resource'},
        operationId: 'bounded-$index',
        cancellationSignal: signals[index],
      ),
    );

    try {
      await _waitUntil(() => validationStarts == 2);
      expect(limiter.activeCount, 2);
      expect(limiter.pendingCount, 6);
      for (final signal in signals) {
        signal.cancel();
      }
      await Future.wait(futures.map(
        (future) => expectLater(
          future,
          throwsA(isA<ToolExecutionCancelledException>()),
        ),
      ));
      expect(validationStarts, 2);
      expect(pinnedResolutionCount, 0);
      expect(limiter.activeCount, 2);
      expect(limiter.pendingCount, 0);

      releaseValidation.complete();
      await _waitUntil(() => limiter.activeCount == 0);
    } finally {
      if (!releaseValidation.isCompleted) releaseValidation.complete();
      client.close();
    }
  });

  test('WebSearch cancellation is request-local and does not abort run C',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final startedB = Completer<void>();
    final startedC = Completer<void>();
    final releaseB = Completer<void>();
    final releaseC = Completer<void>();
    server.listen((request) async {
      await request.drain<void>();
      final query = request.uri.queryParameters['q'];
      final started = query == 'B' ? startedB : startedC;
      final release = query == 'B' ? releaseB : releaseC;
      if (!started.isCompleted) started.complete();
      await release.future;
      try {
        request.response.write('<html></html>');
        await request.response.close();
      } catch (_) {
        // The cancelled request owns and closes only its connection.
      }
    });
    final realClients = _RealHttpOverrides();
    final client = AppHttpClient(
      AppRuntimeInfo.forTesting(),
      createNativeClient: () => realClients.createHttpClient(null),
    );
    final tool = WebSearchTool(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/search'),
      httpClient: client,
    );
    final signalB = ToolCancellationSignal();
    final signalC = ToolCancellationSignal();
    final futureB = tool.executeResultWithOperationAndCancellation(
      {'query': 'B'},
      operationId: 'search-B',
      cancellationSignal: signalB,
    );
    final futureC = tool.executeResultWithOperationAndCancellation(
      {'query': 'C'},
      operationId: 'search-C',
      cancellationSignal: signalC,
    );
    try {
      await Future.wait([startedB.future, startedC.future]);
      signalB.cancel();
      await expectLater(
        futureB.timeout(const Duration(seconds: 1)),
        throwsA(isA<ToolExecutionCancelledException>().having(
          (error) => error.sideEffectsPrevented,
          'sideEffectsPrevented',
          isTrue,
        )),
      );

      releaseC.complete();
      final resultC = await futureC.timeout(const Duration(seconds: 1));
      expect(resultC.forUser, contains('No results found'));
      expect(client.isClosed, isFalse);
    } finally {
      if (!releaseB.isCompleted) releaseB.complete();
      if (!releaseC.isCompleted) releaseC.complete();
      client.close();
      await server.close(force: true);
    }
  });

  test('ImageGen aborts promptly but keeps dispatched POST outcome unknown',
      () async {
    final exchange = await _slowExchange();
    final realClients = _RealHttpOverrides();
    final client = AppHttpClient(
      AppRuntimeInfo.forTesting(),
      createNativeClient: () => realClients.createHttpClient(null),
    );
    prefs.baseUrl = 'http://127.0.0.1:${exchange.server.port}';
    final signal = ToolCancellationSignal();
    final future = ImageGenTool(
      prefs,
      httpClient: client,
    ).executeResultWithOperationAndCancellation(
      {'prompt': 'test prompt'},
      operationId: 'image-operation',
      cancellationSignal: signal,
    );
    try {
      await exchange.started.future;
      signal.cancel();

      await expectLater(
        future.timeout(const Duration(seconds: 1)),
        throwsA(isA<ToolExecutionCancelledException>().having(
          (error) => error.sideEffectsPrevented,
          'sideEffectsPrevented',
          isFalse,
        )),
      );
    } finally {
      exchange.release.complete();
      client.close();
      await exchange.server.close(force: true);
    }
  });
}

Future<
    ({
      HttpServer server,
      Completer<void> started,
      Completer<void> release,
    })> _slowExchange() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final started = Completer<void>();
  final release = Completer<void>();
  server.listen((request) async {
    await request.drain<void>();
    if (!started.isCompleted) started.complete();
    await release.future;
    try {
      request.response.write('late response');
      await request.response.close();
    } catch (_) {
      // Expected when the request-local abort closes the connection.
    }
  });
  return (server: server, started: started, release: release);
}

final class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition did not become true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
