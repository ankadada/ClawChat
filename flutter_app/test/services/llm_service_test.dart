import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/models/model_capabilities.dart';
import 'package:clawchat/services/model_capability_registry.dart';
import 'package:clawchat/services/llm_service.dart';
import 'package:clawchat/services/prompt_cache_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CapabilityRegistry.instance.clearRuntimeOverridesForTesting();
    PromptCacheSettings.setAnthropicPromptCacheEnabledForProcess(false);
  });

  group('LlmService error sanitization', () {
    test('returns short body unchanged', () async {
      const msg = 'Rate limit exceeded. Please retry after 60s.';
      expect(await sanitizedErrorBody(msg), msg);
    });

    test('truncates body longer than 500 chars', () async {
      final long = 'a' * 1000;
      final result = await sanitizedErrorBody(long);
      expect(result.length, 503); // 500 chars + '...'
      expect(result, endsWith('...'));
      expect(result.startsWith('a' * 500), isTrue);
    });

    test('truncates exactly at 500 boundary', () async {
      final exact500 = 'b' * 500;
      expect(await sanitizedErrorBody(exact500), exact500);

      final exact501 = 'c' * 501;
      final result = await sanitizedErrorBody(exact501);
      expect(result.length, 503);
    });

    test('redacts sk- prefixed API keys', () async {
      final result =
          await sanitizedErrorBody('Invalid key: sk-ant-api03-xxxxxxxxxxxx');
      expect(result, contains('[REDACTED]'));
      expect(result, isNot(contains('sk-ant-api03-xxxxxxxxxxxx')));
    });

    test('redacts key- prefixed tokens', () async {
      final result =
          await sanitizedErrorBody('Error with key-abcdefghijklmnop');
      expect(result, contains('[REDACTED]'));
      expect(result, isNot(contains('key-abcdefghijklmnop')));
    });

    test('redacts api- prefixed tokens', () async {
      final result = await sanitizedErrorBody('Token: api-1234567890abcdef');
      expect(result, contains('[REDACTED]'));
      expect(result, isNot(contains('api-1234567890abcdef')));
    });

    test('does not redact short key-like strings (less than 10 chars)',
        () async {
      final result = await sanitizedErrorBody('sk-short');
      expect(result, 'sk-short');
    });

    test('redacts multiple keys in same body', () async {
      const input = 'Keys: sk-aaaaaaaaaa and api-bbbbbbbbbb found';
      final result = await sanitizedErrorBody(input);
      expect(result, isNot(contains('sk-aaaaaaaaaa')));
      expect(result, isNot(contains('api-bbbbbbbbbb')));
      expect('[REDACTED]'.allMatches(result).length, 2);
    });

    test('redacts broad sensitive values from API error messages', () async {
      const bearer = 'abcdefghijklmnopqrstuvwxyz1234567890';
      const githubPat = 'github_pat_abcdefghijklmnopqrstuvwxyz123456';
      const body = 'Authorization: Bearer $bearer\n'
          'password=hunter2\n'
          'github token $githubPat\n'
          'client_secret=client-secret-value';

      final error = await openAiChatError(400, body);

      expect(error, contains('[redacted: bearer_token]'));
      expect(error, contains('password=[redacted: password]'));
      expect(error, contains('[redacted: token]'));
      expect(error, contains('client_secret=[redacted: secret]'));
      expect(error, isNot(contains(bearer)));
      expect(error, isNot(contains('hunter2')));
      expect(error, isNot(contains(githubPat)));
      expect(error, isNot(contains('client-secret-value')));
    });

    test('handles empty body', () async {
      expect(await sanitizedErrorBody(''), '');
    });

    test('preserves non-key content around redacted keys', () async {
      final result = await sanitizedErrorBody(
        'Error 401: key-abcdefghijklmnop is invalid',
      );
      expect(result, contains('Error 401:'));
      expect(result, contains('is invalid'));
      expect(result, contains('[REDACTED]'));
    });

    test('redacts keys with underscores and dashes', () async {
      final result =
          await sanitizedErrorBody('sk-ant_api03-key_with-dashes_123');
      expect(result, contains('[REDACTED]'));
    });

    test('truncation happens before redaction', () async {
      final body = '${'x' * 510}sk-aaaaaaaaaa';
      final result = await sanitizedErrorBody(body);
      expect(result.length, 503);
      expect(result, isNot(contains('sk-aaaaaaaaaa')));
    });
  });

  group('LlmService retryable HTTP status handling', () {
    test('matches 429 rate limit', () async {
      expect(await requestCountWhenFirstStatusIs(429), 2);
    });

    test('matches 500 internal server error', () async {
      expect(await requestCountWhenFirstStatusIs(500), 2);
    });

    test('matches 502 bad gateway', () async {
      expect(await requestCountWhenFirstStatusIs(502), 2);
    });

    test('matches 503 service unavailable', () async {
      expect(await requestCountWhenFirstStatusIs(503), 2);
    });

    test('matches 504 gateway timeout', () async {
      expect(await requestCountWhenFirstStatusIs(504), 2);
    });

    test('does not match 400 bad request', () async {
      expect(await requestCountForAlwaysStatus(400), 1);
    });

    test('does not match 401 unauthorized', () async {
      expect(await requestCountForAlwaysStatus(401), 1);
    });

    test('does not match 403 forbidden', () async {
      expect(await requestCountForAlwaysStatus(403), 1);
    });

    test('does not match 404 not found', () async {
      expect(await requestCountForAlwaysStatus(404), 1);
    });

    test('does not match plain text without status code', () async {
      expect(await requestCountForAlwaysStatus(418), 1);
    });

    test('does not match empty string', () async {
      expect(await sanitizedErrorBody(''), '');
    });
  });

  group('LlmService retry attempt retirement', () {
    test('aborts a ClientException attempt before starting its retry',
        () async {
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: false);
      final service = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(seconds: 30),
      );
      var attemptCount = 0;
      var activeAttempts = 0;
      var maxConcurrentAttempts = 0;
      var firstAbortReceived = false;

      final result = service.retryWithBackoffForTesting((attemptAbort) async {
        attemptCount += 1;
        activeAttempts += 1;
        if (activeAttempts > maxConcurrentAttempts) {
          maxConcurrentAttempts = activeAttempts;
        }
        if (attemptCount == 1) {
          unawaited(attemptAbort.then((_) {
            firstAbortReceived = true;
            activeAttempts -= 1;
          }));
          throw http.ClientException('transient transport failure');
        }
        expect(firstAbortReceived, isTrue);
        expect(activeAttempts, 1);
        activeAttempts -= 1;
        return 'ok';
      });

      await _waitUntil(() => scheduler.delayCallCount == 1);
      expect(firstAbortReceived, isTrue);
      expect(activeAttempts, 0);
      scheduler.elapse(const Duration(seconds: 2));

      expect(await result, 'ok');
      expect(attemptCount, 2);
      expect(maxConcurrentAttempts, 1);
      service.dispose();
    });

    test('aborts a retryable provider stream-open attempt before retry',
        () async {
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: false);
      final service = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(seconds: 30),
      );
      var attemptCount = 0;
      var activeAttempts = 0;
      var maxConcurrentAttempts = 0;
      var firstAbortReceived = false;

      final result = service.resilientSseDataForTesting((attemptAbort) async {
        attemptCount += 1;
        activeAttempts += 1;
        if (activeAttempts > maxConcurrentAttempts) {
          maxConcurrentAttempts = activeAttempts;
        }
        if (attemptCount == 1) {
          unawaited(attemptAbort.then((_) {
            firstAbortReceived = true;
            activeAttempts -= 1;
          }));
          throw Exception('Provider API error (503): transient');
        }
        expect(firstAbortReceived, isTrue);
        expect(activeAttempts, 1);
        activeAttempts -= 1;
        return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
      }).toList();

      await _waitUntil(() => scheduler.delayCallCount == 1);
      expect(firstAbortReceived, isTrue);
      expect(activeAttempts, 0);
      scheduler.elapse(const Duration(seconds: 2));

      expect(await result, isEmpty);
      expect(attemptCount, 2);
      expect(maxConcurrentAttempts, 1);
      service.dispose();
    });

    test('retiring service A attempt does not abort concurrent service B',
        () async {
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: false);
      final serviceA = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(seconds: 30),
      );
      final serviceB = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(seconds: 30),
      );
      final releaseB = Completer<String>();
      var attemptA = 0;
      var abortAReceived = false;
      var abortBReceived = false;

      final resultB = serviceB.retryWithBackoffForTesting((attemptAbort) {
        unawaited(attemptAbort.then((_) => abortBReceived = true));
        return releaseB.future;
      });
      final resultA = serviceA.retryWithBackoffForTesting((attemptAbort) async {
        attemptA += 1;
        if (attemptA == 1) {
          unawaited(attemptAbort.then((_) => abortAReceived = true));
          throw http.ClientException('service A transient failure');
        }
        expect(abortAReceived, isTrue);
        expect(abortBReceived, isFalse);
        return 'A';
      });

      await _waitUntil(() => scheduler.delayCallCount == 1);
      expect(abortAReceived, isTrue);
      expect(abortBReceived, isFalse);
      scheduler.elapse(const Duration(seconds: 2));
      expect(await resultA, 'A');
      expect(abortBReceived, isFalse);

      releaseB.complete('B');
      expect(await resultB, 'B');
      expect(abortBReceived, isFalse);
      serviceA.dispose();
      serviceB.dispose();
    });
  });

  group('LlmService non-stream foreground timeout', () {
    test('does not time out while app is backgrounded', () async {
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: true);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestStarted = Completer<void>();
      final releaseResponse = Completer<void>();
      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        if (!requestStarted.isCompleted) requestStarted.complete();
        await releaseResponse.future;
        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType.json;
        request.response.write(_openAiResponse('ok after background'));
        await request.response.close();
      });
      final service = _timeoutTestService(
        scheduler,
        baseUrl: 'http://127.0.0.1:${server.port}',
        requestTimeout: const Duration(milliseconds: 40),
      );

      try {
        final responseFuture =
            service.chat(system: '', messages: const [], tools: const []);
        await requestStarted.future.timeout(const Duration(seconds: 2));

        scheduler.elapse(const Duration(milliseconds: 400));
        scheduler.setBackground(false);
        releaseResponse.complete();

        final response =
            await responseFuture.timeout(const Duration(seconds: 2));
        expect(response.content.single.text, 'ok after background');
      } finally {
        if (!releaseResponse.isCompleted) releaseResponse.complete();
        service.dispose();
        await server.close(force: true);
      }
    });

    test('exhausts the foreground budget deterministically', () async {
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: false);
      final service = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(milliseconds: 40),
      );
      final expectation = expectLater(
        service.withForegroundTimeoutForTesting(_abortablePendingOperation),
        throwsA(isA<TimeoutException>().having(
          (error) => error.duration,
          'duration',
          const Duration(milliseconds: 40),
        )),
      );

      scheduler.elapse(const Duration(milliseconds: 40));
      await expectation;
      service.dispose();
    });

    test('accumulates foreground time across multiple background cycles',
        () async {
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: false);
      final service = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(milliseconds: 100),
      );
      final expectation = expectLater(
        service.withForegroundTimeoutForTesting(_abortablePendingOperation),
        throwsA(isA<TimeoutException>()),
      );

      scheduler.elapse(const Duration(milliseconds: 30));
      scheduler.setBackground(true);
      scheduler.elapse(const Duration(milliseconds: 500));
      scheduler.setBackground(false);
      scheduler.elapse(const Duration(milliseconds: 30));
      scheduler.setBackground(true);
      scheduler.elapse(const Duration(milliseconds: 500));
      scheduler.setBackground(false);
      scheduler.elapse(const Duration(milliseconds: 39));
      expect(scheduler.activeTimerCount, 1);
      scheduler.elapse(const Duration(milliseconds: 1));

      await expectation;
      service.dispose();
    });

    test('sampled fallback cannot refresh budget around one-second polls',
        () async {
      final scheduler = _FakeLlmTimeoutScheduler(
        isInBackground: false,
        supportsLifecycleNotifications: false,
      );
      final service = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(seconds: 2),
      );
      final expectation = expectLater(
        service.withForegroundTimeoutForTesting(_abortablePendingOperation),
        throwsA(isA<TimeoutException>()),
      );

      for (var cycle = 0; cycle < 3; cycle += 1) {
        scheduler.elapse(const Duration(milliseconds: 900));
        scheduler.setBackground(true);
        scheduler.elapse(const Duration(milliseconds: 100));
        scheduler.setBackground(false);
      }

      await expectation;
      expect(scheduler.activeTimerCount, 0);
      service.dispose();
    });

    test('sampled fallback does not charge stable background time', () async {
      final scheduler = _FakeLlmTimeoutScheduler(
        isInBackground: true,
        supportsLifecycleNotifications: false,
      );
      final service = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(milliseconds: 100),
      );
      final result = Completer<String>();
      final wrapped = service.withForegroundTimeoutForTesting(
        (abortTrigger) => _controlledPendingOperation(
          abortTrigger,
          result,
        ),
      );

      scheduler.elapse(const Duration(seconds: 2));
      result.complete('healthy');

      expect(await wrapped, 'healthy');
      expect(scheduler.activeTimerCount, 0);
      service.dispose();
    });

    test('multiple active requests unregister lifecycle listeners on settle',
        () async {
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: true);
      final service = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(milliseconds: 100),
      );
      final first = Completer<String>();
      final second = Completer<String>();
      final firstResult = service.withForegroundTimeoutForTesting(
        (abort) => _controlledPendingOperation(abort, first),
      );
      final secondResult = service.withForegroundTimeoutForTesting(
        (abort) => _controlledPendingOperation(abort, second),
      );

      expect(scheduler.lifecycleListenerCount, 2);
      scheduler.elapse(const Duration(seconds: 1));
      first.complete('first');
      second.complete('second');

      expect(await firstResult, 'first');
      expect(await secondResult, 'second');
      expect(scheduler.lifecycleListenerCount, 0);
      expect(scheduler.activeTimerCount, 0);
      service.dispose();
    });

    test('fails at max wall clock even while backgrounded', () async {
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: true);
      final service = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(milliseconds: 80),
        requestMaxWallClock: const Duration(milliseconds: 140),
      );
      final expectation = expectLater(
        service.withForegroundTimeoutForTesting(_abortablePendingOperation),
        throwsA(isA<TimeoutException>().having(
          (error) => error.message,
          'message',
          contains('maximum wall-clock timeout'),
        )),
      );

      scheduler.elapse(const Duration(milliseconds: 140));
      await expectation;
      service.dispose();
    });

    test('propagates request cancellation immediately while backgrounded',
        () async {
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: true);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestStarted = Completer<void>();
      final releaseResponse = Completer<void>();
      server.listen((request) async {
        await request.drain<void>();
        requestStarted.complete();
        await releaseResponse.future;
        try {
          request.response.write(_openAiResponse('too late'));
          await request.response.close();
        } on IOException {
          // Expected when the abort closes the request-local connection.
        }
      });
      final service = _timeoutTestService(
        scheduler,
        baseUrl: 'http://127.0.0.1:${server.port}',
        requestTimeout: const Duration(milliseconds: 40),
      );

      try {
        final result =
            service.chat(system: '', messages: const [], tools: const []);
        await requestStarted.future.timeout(const Duration(seconds: 2));
        scheduler.elapse(const Duration(milliseconds: 400));

        service.dispose();

        await expectLater(
          result.timeout(const Duration(seconds: 2)),
          throwsA(isA<http.RequestAbortedException>()),
        );
        expect(scheduler.activeTimerCount, 0);
        expect(scheduler.delayCallCount, 0);
      } finally {
        if (!releaseResponse.isCompleted) releaseResponse.complete();
        service.dispose();
        await server.close(force: true);
      }
    });

    test('cancelling a background request leaves a concurrent request healthy',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final releaseSecond = Completer<void>();
      var requestCount = 0;
      server.listen((request) async {
        requestCount += 1;
        final current = requestCount;
        await request.drain<void>();
        if (current == 1) {
          firstStarted.complete();
          await releaseFirst.future;
        } else {
          secondStarted.complete();
          await releaseSecond.future;
        }
        try {
          request.response.write(_openAiResponse('healthy'));
          await request.response.close();
        } on IOException {
          // Expected for the independently aborted first request.
        }
      });
      final cancelledScheduler = _FakeLlmTimeoutScheduler(isInBackground: true);
      final healthyScheduler = _FakeLlmTimeoutScheduler(isInBackground: true);
      final cancelledService = _timeoutTestService(
        cancelledScheduler,
        baseUrl: 'http://127.0.0.1:${server.port}',
        requestTimeout: const Duration(milliseconds: 40),
      );
      final healthyService = _timeoutTestService(
        healthyScheduler,
        baseUrl: 'http://127.0.0.1:${server.port}',
        requestTimeout: const Duration(milliseconds: 40),
      );

      try {
        final cancelledResult = cancelledService.chat(
          system: '',
          messages: const [],
          tools: const [],
        );
        await firstStarted.future.timeout(const Duration(seconds: 2));
        final healthyResult = healthyService.chat(
          system: '',
          messages: const [],
          tools: const [],
        );
        await secondStarted.future.timeout(const Duration(seconds: 2));
        cancelledScheduler.elapse(const Duration(milliseconds: 400));
        healthyScheduler.elapse(const Duration(milliseconds: 400));

        cancelledService.dispose();
        releaseSecond.complete();

        await expectLater(
          cancelledResult.timeout(const Duration(seconds: 2)),
          throwsA(isA<http.RequestAbortedException>()),
        );
        final response =
            await healthyResult.timeout(const Duration(seconds: 2));
        expect(response.content.single.text, 'healthy');
        expect(cancelledScheduler.activeTimerCount, 0);
        expect(healthyScheduler.activeTimerCount, 0);
        expect(cancelledScheduler.lifecycleListenerCount, 0);
        expect(healthyScheduler.lifecycleListenerCount, 0);
      } finally {
        if (!releaseFirst.isCompleted) releaseFirst.complete();
        if (!releaseSecond.isCompleted) releaseSecond.complete();
        cancelledService.dispose();
        healthyService.dispose();
        await server.close(force: true);
      }
    });
  });

  test('foreground timeout releases attempt before retry starts', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final firstRequestStarted = Completer<void>();
    final firstDisconnected = Completer<void>();
    final secondRequestStarted = Completer<void>();
    var connectionCount = 0;
    var activeConnections = 0;
    var maxActiveConnections = 0;
    var laterRequestArrivedBeforeDisconnect = false;
    server.listen((socket) {
      connectionCount += 1;
      final connection = connectionCount;
      activeConnections += 1;
      if (activeConnections > maxActiveConnections) {
        maxActiveConnections = activeConnections;
      }
      var requestSeen = false;
      var connectionFinished = false;
      final bytes = <int>[];
      void markConnectionFinished() {
        if (connectionFinished) return;
        connectionFinished = true;
        activeConnections -= 1;
        if (connection == 1 && !firstDisconnected.isCompleted) {
          firstDisconnected.complete();
        }
      }

      socket.listen(
        (chunk) async {
          if (requestSeen) return;
          bytes.addAll(chunk);
          if (!utf8.decode(bytes, allowMalformed: true).contains('\r\n\r\n')) {
            return;
          }
          requestSeen = true;
          if (connection == 1) {
            firstRequestStarted.complete();
            return;
          }
          laterRequestArrivedBeforeDisconnect =
              laterRequestArrivedBeforeDisconnect ||
                  !firstDisconnected.isCompleted;
          if (connection == 2) secondRequestStarted.complete();
          final body = _openAiResponse('retry healthy');
          final responseBytes = utf8.encode(body);
          socket.add(utf8.encode(
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: application/json\r\n'
            'Content-Length: ${responseBytes.length}\r\n'
            'Connection: close\r\n\r\n',
          ));
          socket.add(responseBytes);
          await socket.flush();
          await socket.close();
        },
        onError: (_) {
          markConnectionFinished();
          socket.destroy();
        },
        onDone: markConnectionFinished,
      );
    });
    final scheduler = _FakeLlmTimeoutScheduler(isInBackground: false);
    final service = _timeoutTestService(
      scheduler,
      baseUrl: 'http://127.0.0.1:${server.port}',
      requestTimeout: const Duration(milliseconds: 40),
    );
    final laterService = _timeoutTestService(
      _FakeLlmTimeoutScheduler(isInBackground: false),
      baseUrl: 'http://127.0.0.1:${server.port}',
      requestTimeout: const Duration(seconds: 5),
    );

    try {
      final result =
          service.chat(system: '', messages: const [], tools: const []);
      await firstRequestStarted.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('first request did not start'),
      );

      scheduler.elapse(const Duration(milliseconds: 40));
      await firstDisconnected.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('first request did not disconnect'),
      );
      await _waitUntil(() => scheduler.delayCallCount == 1);
      scheduler.elapse(const Duration(seconds: 2));
      await secondRequestStarted.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('retry request did not start'),
      );

      final response = await result.timeout(const Duration(seconds: 2));
      expect(response.content.single.text, 'retry healthy');
      final later = await laterService.chat(
          system: '',
          messages: const [],
          tools: const []).timeout(const Duration(seconds: 2));
      expect(later.content.single.text, 'retry healthy');
      expect(laterRequestArrivedBeforeDisconnect, isFalse);
      expect(maxActiveConnections, 1);
      expect(connectionCount, 3);
    } finally {
      service.dispose();
      laterService.dispose();
      await server.close();
    }
  });

  group('LlmService streaming idle timeout', () {
    test('stalled SSE consumes monotonic foreground idle budget', () async {
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: false);
      final service = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(seconds: 5),
      );
      final input = StreamController<List<int>>();
      final expectation = expectLater(
        service.linesWithForegroundTimeoutForTesting(input.stream).toList(),
        throwsA(isA<TimeoutException>().having(
          (error) => error.duration,
          'duration',
          const Duration(seconds: 60),
        )),
      );
      await Future<void>.delayed(Duration.zero);

      scheduler.elapse(const Duration(seconds: 60));

      await expectation;
      expect(scheduler.activeTimerCount, 0);
      expect(scheduler.lifecycleListenerCount, 0);
      await input.close();
      service.dispose();
    });

    test('background pauses idle budget and resume consumes only foreground',
        () async {
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: false);
      final service = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(seconds: 5),
      );
      final input = StreamController<List<int>>();
      final output =
          service.linesWithForegroundTimeoutForTesting(input.stream).toList();
      await Future<void>.delayed(Duration.zero);

      scheduler.elapse(const Duration(seconds: 30));
      scheduler.setBackground(true);
      scheduler.elapse(const Duration(minutes: 2));
      scheduler.setBackground(false);
      scheduler.elapse(const Duration(seconds: 29));
      input.add(utf8.encode('healthy\n'));
      await input.close();

      expect(await output, ['healthy']);
      expect(scheduler.activeTimerCount, 0);
      expect(scheduler.lifecycleListenerCount, 0);
      service.dispose();
    });

    test('provider wall cap expires while stream is backgrounded', () async {
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: true);
      final service = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(seconds: 5),
        requestMaxWallClock: const Duration(seconds: 30),
      );
      final input = StreamController<List<int>>();
      final expectation = expectLater(
        service.linesWithForegroundTimeoutForTesting(input.stream).toList(),
        throwsA(isA<TimeoutException>().having(
          (error) => error.message,
          'message',
          contains('maximum wall-clock timeout'),
        )),
      );
      await Future<void>.delayed(Duration.zero);

      scheduler.elapse(const Duration(seconds: 30));

      await expectation;
      expect(scheduler.activeTimerCount, 0);
      expect(scheduler.lifecycleListenerCount, 0);
      await input.close();
      service.dispose();
    });

    test('response error retires its still-open stream before reconnect',
        () async {
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: false);
      final service = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(seconds: 30),
      );
      final cancelStarted = Completer<void>();
      final releaseCancellation = Completer<void>();
      final cancellationSettled = Completer<void>();
      final lifecycle = <String>[];
      final firstInput = StreamController<List<int>>(
        onCancel: () async {
          lifecycle.add('cancel-started');
          cancelStarted.complete();
          await releaseCancellation.future;
          lifecycle.add('cancel-settled');
          cancellationSettled.complete();
        },
      );
      final events = <String>[];
      var openCount = 0;

      final output = service.resilientSseDataForTesting((_) async {
        openCount += 1;
        lifecycle.add('open-$openCount');
        if (openCount == 1) {
          return http.StreamedResponse(firstInput.stream, 200);
        }
        expect(cancellationSettled.isCompleted, isTrue);
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode('data: fresh\n\n')),
          200,
        );
      }).listen((event) {
        lifecycle.add('event-$event');
        events.add(event);
      });

      try {
        firstInput.addError(http.ClientException('transient response error'));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(
          cancelStarted.isCompleted,
          isTrue,
          reason: 'errored response subscription must be cancelled',
        );

        expect(events, isEmpty);
        expect(scheduler.delayCallCount, 0);
        expect(openCount, 1);
        firstInput.add(utf8.encode('data: stale-before-settle\n\n'));

        releaseCancellation.complete();
        await cancellationSettled.future;
        await _waitUntil(() => events.contains('__retry__'));
        await _waitUntil(() => scheduler.delayCallCount == 1);

        expect(
          lifecycle.indexOf('cancel-settled'),
          lessThan(lifecycle.indexOf('event-__retry__')),
        );
        firstInput.add(utf8.encode('data: stale-after-settle\n\n'));
        scheduler.elapse(const Duration(seconds: 2));

        await output.asFuture<void>();
        expect(events, ['__retry__', 'fresh']);
        expect(openCount, 2);
      } finally {
        if (!releaseCancellation.isCompleted) releaseCancellation.complete();
        await firstInput.close();
        scheduler.elapse(const Duration(minutes: 1));
        await Future<void>.delayed(Duration.zero);
        await output.cancel();
        service.dispose();
      }
    });

    test('reconnect delay cannot reset the provider wall-clock budget',
        () async {
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: false);
      final service = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(seconds: 5),
        requestMaxWallClock: const Duration(seconds: 61),
      );
      final firstInput = StreamController<List<int>>();
      final firstOutput = Completer<void>();
      final streamDone = Completer<void>();
      final events = <String>[];
      var openCount = 0;

      try {
        final subscription =
            service.resilientSseDataForTesting((attemptAbortTrigger) async {
          openCount += 1;
          return http.StreamedResponse(firstInput.stream, 200);
        }).listen((event) {
          events.add(event);
          if (event != '__retry__' && !firstOutput.isCompleted) {
            firstOutput.complete();
          }
        }, onError: (Object error, StackTrace stackTrace) {
          if (!streamDone.isCompleted) {
            streamDone.completeError(error, stackTrace);
          }
        }, onDone: () {
          if (!streamDone.isCompleted) streamDone.complete();
        });
        firstInput.add(utf8.encode('data: first\n\n'));
        await firstOutput.future;
        await Future<void>.delayed(Duration.zero);

        scheduler.elapse(const Duration(seconds: 60));
        await _waitUntil(() => events.contains('__retry__'));
        expect(scheduler.delayCallCount, 1);
        scheduler.elapse(const Duration(seconds: 1));

        await expectLater(
          streamDone.future,
          throwsA(isA<TimeoutException>().having(
            (error) => error.message,
            'message',
            contains('maximum wall-clock timeout'),
          )),
        );
        await subscription.cancel();
        expect(openCount, 1);
        expect(events, ['first', '__retry__']);
        expect(scheduler.activeTimerCount, 0);
        expect(scheduler.lifecycleListenerCount, 0);
      } finally {
        await firstInput.close();
        service.dispose();
      }
    });

    test('multiple reconnect backoffs cumulatively share one wall deadline',
        () async {
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: false);
      final service = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(seconds: 30),
        requestMaxWallClock: const Duration(seconds: 5),
      );
      var openCount = 0;
      final expectation = expectLater(
        service.resilientSseDataForTesting((attemptAbortTrigger) async {
          openCount += 1;
          return http.StreamedResponse(
            Stream<List<int>>.error(
              http.ClientException('transient response failure'),
            ),
            200,
          );
        }).toList(),
        throwsA(isA<TimeoutException>().having(
          (error) => error.message,
          'message',
          contains('maximum wall-clock timeout'),
        )),
      );

      await _waitUntil(() => scheduler.delayCallCount == 1);
      scheduler.elapse(const Duration(seconds: 2));
      await _waitUntil(() => scheduler.delayCallCount == 2);
      scheduler.elapse(const Duration(seconds: 3));

      await expectation;
      expect(openCount, 2);
      expect(scheduler.activeTimerCount, 0);
      expect(scheduler.lifecycleListenerCount, 0);
      service.dispose();
    });

    test('hung reconnect handshake aborts at original stream deadline',
        () async {
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: false);
      final service = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(seconds: 30),
        requestMaxWallClock: const Duration(seconds: 70),
      );
      final firstInput = StreamController<List<int>>();
      final secondOpenStarted = Completer<void>();
      final secondOpenAborted = Completer<void>();
      final streamError = Completer<Object>();
      final events = <String>[];
      var openCount = 0;

      final subscription = service.resilientSseDataForTesting(
        (attemptAbortTrigger) async {
          openCount += 1;
          if (openCount == 1) {
            return http.StreamedResponse(firstInput.stream, 200);
          }
          if (openCount == 2) {
            secondOpenStarted.complete();
            await attemptAbortTrigger;
            secondOpenAborted.complete();
            throw http.RequestAbortedException();
          }
          throw StateError('unexpected late reconnect');
        },
      ).listen(
        events.add,
        onError: (Object error, StackTrace stackTrace) {
          if (!streamError.isCompleted) streamError.complete(error);
        },
      );

      try {
        firstInput.add(utf8.encode('data: first\n\n'));
        await _waitUntil(() => events.contains('first'));
        await Future<void>.delayed(Duration.zero);

        scheduler.elapse(const Duration(seconds: 60));
        await _waitUntil(() => events.contains('__retry__'));
        scheduler.elapse(const Duration(seconds: 2));
        await secondOpenStarted.future;
        scheduler.setBackground(true);
        scheduler.elapse(const Duration(seconds: 8));

        await secondOpenAborted.future;
        final error = await streamError.future;
        expect(
          error,
          isA<TimeoutException>().having(
            (value) => value.message,
            'message',
            contains('maximum wall-clock timeout'),
          ),
        );
        expect(openCount, 2);
        expect(events, ['first', '__retry__']);
        expect(scheduler.activeTimerCount, 0);
        expect(scheduler.lifecycleListenerCount, 0);
      } finally {
        await subscription.cancel();
        await firstInput.close();
        service.dispose();
      }
    });

    test('loopback server observes reconnect abort at logical deadline',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>{};
      final secondRequestStarted = Completer<void>();
      final secondDisconnected = Completer<void>();
      var connectionCount = 0;
      server.listen((socket) {
        sockets.add(socket);
        connectionCount += 1;
        final connection = connectionCount;
        var requestSeen = false;
        final requestBytes = <int>[];
        socket.listen(
          (chunk) {
            if (requestSeen) return;
            requestBytes.addAll(chunk);
            if (!utf8
                .decode(requestBytes, allowMalformed: true)
                .contains('\r\n\r\n')) {
              return;
            }
            requestSeen = true;
            if (connection == 1) {
              final sse = sseData({
                'choices': [
                  {
                    'delta': {'content': 'first'},
                    'finish_reason': null,
                  }
                ],
              });
              socket.add(utf8.encode(
                'HTTP/1.1 200 OK\r\n'
                'Content-Type: text/event-stream\r\n'
                'Content-Length: 4096\r\n'
                'Connection: close\r\n\r\n'
                '$sse',
              ));
            } else if (connection == 2) {
              secondRequestStarted.complete();
            }
          },
          onDone: () {
            sockets.remove(socket);
            if (connection == 2 && !secondDisconnected.isCompleted) {
              secondDisconnected.complete();
            }
          },
          onError: (_) {
            sockets.remove(socket);
            if (connection == 2 && !secondDisconnected.isCompleted) {
              secondDisconnected.complete();
            }
            socket.destroy();
          },
        );
      });
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: false);
      final service = _timeoutTestService(
        scheduler,
        baseUrl: 'http://127.0.0.1:${server.port}',
        requestTimeout: const Duration(seconds: 30),
        requestMaxWallClock: const Duration(seconds: 70),
      );
      final events = <StreamEvent>[];
      final streamDone = Completer<void>();
      final subscription = service.chatStream(
          system: '',
          messages: const [],
          tools: const []).listen(events.add, onDone: streamDone.complete);

      try {
        await _waitUntil(
          () => events
              .whereType<TextDelta>()
              .any((event) => event.text == 'first'),
        );
        await Future<void>.delayed(Duration.zero);
        scheduler.elapse(const Duration(seconds: 60));
        await _waitUntil(() => events.any((event) => event is StreamReset));
        scheduler.elapse(const Duration(seconds: 2));
        await secondRequestStarted.future.timeout(const Duration(seconds: 2));
        scheduler.setBackground(true);
        scheduler.elapse(const Duration(seconds: 8));

        await secondDisconnected.future.timeout(const Duration(seconds: 2));
        await streamDone.future.timeout(const Duration(seconds: 2));
        expect(connectionCount, 2);
        expect(
          events.whereType<StreamError>().single.message,
          contains('maximum wall-clock timeout'),
        );
      } finally {
        await subscription.cancel();
        service.dispose();
        for (final socket in sockets.toList(growable: false)) {
          socket.destroy();
        }
        await server.close();
      }
    });

    test('initial handshake backoffs share one logical stream deadline',
        () async {
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: false);
      final service = _timeoutTestService(
        scheduler,
        requestTimeout: const Duration(seconds: 30),
        requestMaxWallClock: const Duration(seconds: 5),
      );
      var openCount = 0;
      final expectation = expectLater(
        service.resilientSseDataForTesting((attemptAbortTrigger) async {
          openCount += 1;
          throw http.ClientException('transient handshake failure');
        }).toList(),
        throwsA(isA<TimeoutException>().having(
          (error) => error.message,
          'message',
          contains('maximum wall-clock timeout'),
        )),
      );

      await _waitUntil(() => scheduler.delayCallCount == 1);
      scheduler.elapse(const Duration(seconds: 2));
      await _waitUntil(() => scheduler.delayCallCount == 2);
      scheduler.elapse(const Duration(seconds: 3));

      await expectation;
      expect(openCount, 2);
      expect(scheduler.activeTimerCount, 0);
      service.dispose();
    });

    test('OpenAI compatibility retry handshake shares stream deadline',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final firstRequestStarted = Completer<void>();
      final releaseFirstResponse = Completer<void>();
      final compatibilityRequestStarted = Completer<void>();
      final releaseCompatibilityResponse = Completer<void>();
      var requestCount = 0;
      server.listen((request) async {
        requestCount += 1;
        final current = requestCount;
        await request.drain<void>();
        if (current == 1) {
          firstRequestStarted.complete();
          await releaseFirstResponse.future;
          request.response.statusCode = HttpStatus.badRequest;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'error': {'message': 'max_tokens is unsupported'},
          }));
          await request.response.close();
          return;
        }
        if (current == 2) {
          compatibilityRequestStarted.complete();
          await releaseCompatibilityResponse.future;
          try {
            request.response.headers.contentType =
                ContentType('text', 'event-stream', charset: 'utf-8');
            request.response.write('data: [DONE]\n\n');
            await request.response.close();
          } on HttpException {
            // Expected after the shared logical deadline aborts this retry.
          }
          return;
        }
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      });
      final scheduler = _FakeLlmTimeoutScheduler(isInBackground: false);
      final service = _timeoutTestService(
        scheduler,
        baseUrl: 'http://127.0.0.1:${server.port}',
        requestTimeout: const Duration(seconds: 60),
        requestMaxWallClock: const Duration(seconds: 30),
      );

      try {
        final eventsFuture = service.chatStream(
            system: '', messages: const [], tools: const []).toList();
        await firstRequestStarted.future.timeout(const Duration(seconds: 2));
        scheduler.elapse(const Duration(seconds: 29));
        releaseFirstResponse.complete();
        await compatibilityRequestStarted.future
            .timeout(const Duration(seconds: 2));
        scheduler.setBackground(true);
        scheduler.elapse(const Duration(seconds: 1));

        final events = await eventsFuture.timeout(const Duration(seconds: 2));
        expect(requestCount, 2);
        expect(
          events.whereType<StreamError>().single.message,
          contains('maximum wall-clock timeout'),
        );
      } finally {
        if (!releaseFirstResponse.isCompleted) releaseFirstResponse.complete();
        if (!releaseCompatibilityResponse.isCompleted) {
          releaseCompatibilityResponse.complete();
        }
        service.dispose();
        LlmService.clearTokenKeyOverrides();
        await server.close(force: true);
      }
    });

    test('stream idle code has no wall-clock DateTime sampling', () async {
      final source = await File('lib/services/llm_service.dart').readAsString();
      final start =
          source.indexOf('Stream<String> _linesWithForegroundTimeout');
      final end = source.indexOf(
        'Stream<_ResilientSseEvent> _resilientSseDataStream',
        start,
      );
      final idleSource = source.substring(start, end);

      expect(idleSource, contains('_timeoutScheduler.now()'));
      expect(idleSource, isNot(contains('DateTime.now()')));
      expect(source, contains('Stopwatch()..start()'));
    });
  });

  group('LlmService OpenAI reasoning_content 400 fallback', () {
    const reasoningMessages = [
      {
        'role': 'assistant',
        'content': 'answer',
        'reasoning_content': 'internal reasoning',
      },
    ];

    test('non-stream unsupported reasoning_content retries stripped', () async {
      final bodies = await captureOpenAiChatBodiesForReasoning400(
        model: 'deepseek-reasoner',
        firstErrorBody: jsonEncode({
          'error': {
            'message': 'unrecognized extra field: reasoning_content',
          },
        }),
        messages: reasoningMessages,
      );

      expect(bodies, hasLength(2));
      expect(bodyContainsReasoningContent(bodies.first), isTrue);
      expect(bodyContainsReasoningContent(bodies.last), isFalse);
    });

    test(
        'non-stream unsupported reasoning_content does not enable stripped model',
        () async {
      final bodies = await captureOpenAiChatBodiesForReasoning400(
        model: 'gpt-test',
        firstErrorBody: jsonEncode({
          'error': {
            'message': 'unknown field: reasoning_content',
          },
        }),
        messages: reasoningMessages,
        expectSuccess: false,
      );

      expect(bodies, hasLength(1));
      expect(bodyContainsReasoningContent(bodies.single), isFalse);
    });

    test('non-stream missing required reasoning_content enables fallback',
        () async {
      final bodies = await captureOpenAiChatBodiesForReasoning400(
        model: 'gpt-test',
        firstErrorBody: jsonEncode({
          'error': {
            'message': 'Missing required field: reasoning_content',
          },
        }),
        messages: reasoningMessages,
      );

      expect(bodies, hasLength(2));
      expect(bodyContainsReasoningContent(bodies.first), isFalse);
      expect(bodyContainsReasoningContent(bodies.last), isTrue);
    });

    test('stream unsupported reasoning_content retries stripped', () async {
      final bodies = <Map<String, dynamic>>[];
      final events = await collectOpenAiStreamEventsWithHandler(
        (request) async {
          if (bodies.length == 1) {
            request.response.statusCode = 400;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({
              'error': {
                'message': 'reasoning_content is not permitted',
              },
            }));
            await request.response.close();
            return;
          }

          request.response.write(sseData({
            'choices': [
              {
                'delta': {'content': 'ok'},
                'finish_reason': null,
              }
            ],
          }));
          request.response.write(sseData({
            'choices': [
              {
                'delta': {},
                'finish_reason': 'stop',
              }
            ],
          }, delimiter: false));
          await request.response.close();
        },
        model: 'deepseek-reasoner',
        messages: reasoningMessages,
        onRequestBody: bodies.add,
      );

      expect(events.whereType<StreamError>(), isEmpty);
      expect(bodies, hasLength(2));
      expect(bodyContainsReasoningContent(bodies.first), isTrue);
      expect(bodyContainsReasoningContent(bodies.last), isFalse);
    });

    test('stream unsupported reasoning_content does not enable stripped model',
        () async {
      final bodies = <Map<String, dynamic>>[];
      final events = await collectOpenAiStreamEventsWithHandler(
        (request) async {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'error': {
              'message': 'reasoning_content is unsupported',
            },
          }));
          await request.response.close();
        },
        messages: reasoningMessages,
        onRequestBody: bodies.add,
      );

      expect(events.whereType<StreamError>(), hasLength(1));
      expect(bodies, hasLength(1));
      expect(bodyContainsReasoningContent(bodies.single), isFalse);
    });

    test('stream missing required reasoning_content enables fallback',
        () async {
      final bodies = <Map<String, dynamic>>[];
      final events = await collectOpenAiStreamEventsWithHandler(
        (request) async {
          if (bodies.length == 1) {
            request.response.statusCode = 400;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({
              'error': {
                'message': 'reasoning_content is required',
              },
            }));
            await request.response.close();
            return;
          }

          request.response.write(sseData({
            'choices': [
              {
                'delta': {'content': 'ok'},
                'finish_reason': null,
              }
            ],
          }));
          request.response.write(sseData({
            'choices': [
              {
                'delta': {},
                'finish_reason': 'stop',
              }
            ],
          }, delimiter: false));
          await request.response.close();
        },
        messages: reasoningMessages,
        onRequestBody: bodies.add,
      );

      expect(events.whereType<StreamError>(), isEmpty);
      expect(bodies, hasLength(2));
      expect(bodyContainsReasoningContent(bodies.first), isFalse);
      expect(bodyContainsReasoningContent(bodies.last), isTrue);
    });
  });

  group('LlmService Anthropic invalid encrypted content handling', () {
    test('throws EncryptedContentError for invalid_encrypted_content 400',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'type': 'error',
          'error': {
            'type': 'invalid_request_error',
            'code': 'invalid_encrypted_content',
            'message':
                'The encrypted content lite...dhmz could not be verified.',
          },
        }));
        await request.response.close();
      });

      final service = LlmService(LlmConfig.anthropic(
        apiKey: 'sk-test',
        model: 'claude-sonnet-4-20250514',
        baseUrl: 'http://127.0.0.1:${server.port}',
      ));

      try {
        await expectLater(
          service.chat(
            system: '',
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
            tools: const [],
          ),
          throwsA(isA<EncryptedContentError>()
              .having((e) => e.code, 'code', 'invalid_encrypted_content')
              .having((e) => e.statusCode, 'statusCode', 400)),
        );
      } finally {
        service.dispose();
        await server.close(force: true);
      }
    });
  });

  group('LlmConfig equality', () {
    test('ContentBlock.toJson produces correct text block', () {
      const block = ContentBlock(type: 'text', text: 'hello');
      final json = block.toJson();
      expect(json['type'], 'text');
      expect(json['text'], 'hello');
    });

    test('ContentBlock.toJson preserves reasoning_content for text blocks', () {
      const block = ContentBlock(
        type: 'text',
        text: 'hello',
        reasoningContent: 'private reasoning',
      );
      final json = block.toJson();
      expect(json['type'], 'text');
      expect(json['text'], 'hello');
      expect(json['reasoning_content'], 'private reasoning');
    });

    test('ContentBlock.toJson produces correct tool_use block', () {
      const block = ContentBlock(
        type: 'tool_use',
        toolUseId: 'call_123',
        toolName: 'bash',
        toolInput: {'command': 'ls'},
      );
      final json = block.toJson();
      expect(json['type'], 'tool_use');
      expect(json['id'], 'call_123');
      expect(json['name'], 'bash');
      expect(json['input'], {'command': 'ls'});
    });

    test('ToolDefinition.toAnthropicJson format', () {
      const tool = ToolDefinition(
        name: 'bash',
        description: 'Run a command',
        inputSchema: {
          'type': 'object',
          'properties': {
            'command': {'type': 'string'}
          }
        },
      );
      final json = tool.toAnthropicJson();
      expect(json['name'], 'bash');
      expect(json['description'], 'Run a command');
      expect(json['input_schema'], isNotNull);
    });

    test('ToolDefinition.toOpenAIJson format', () {
      const tool = ToolDefinition(
        name: 'bash',
        description: 'Run a command',
        inputSchema: {
          'type': 'object',
          'properties': {
            'command': {'type': 'string'}
          }
        },
      );
      final json = tool.toOpenAIJson();
      expect(json['type'], 'function');
      expect(json['function']['name'], 'bash');
      expect(json['function']['description'], 'Run a command');
      expect(json['function']['parameters'], isNotNull);
    });
  });

  group('LlmService request body compatibility', () {
    test('modelIdFromDisplay preserves slash-prefixed raw model ids', () {
      const models = ['gpt-5.5', 'codex/gpt-5.5'];

      expect(LlmService.modelIdFromDisplay(models[0]), 'gpt-5.5');
      expect(LlmService.modelIdFromDisplay(models[1]), 'codex/gpt-5.5');
    });

    test('strips Anthropic preset display suffix from request model', () async {
      final body = await captureAnthropicBody(
        model: 'claude-sonnet-4-20250514${LlmService.presetModelSuffix}',
      );

      expect(body['model'], 'claude-sonnet-4-20250514');
    });

    test('strips OpenAI-compatible preset display suffix from request model',
        () async {
      final body = await captureOpenAiBody(
        model: 'gpt-test${LlmService.presetModelSuffix}',
      );

      expect(body['model'], 'gpt-test');
    });

    test(
        'generic OpenAI-compatible requests use max_tokens for non-reasoning models',
        () async {
      final body = await captureOpenAiBody(model: 'gpt-test');
      expect(body['max_tokens'], 8192);
    });

    test('reasoning models use max_completion_tokens regardless of provider',
        () async {
      final body = await captureOpenAiBody(model: 'gpt-5.5');
      expect(body['max_completion_tokens'], 8192);
    });

    test('token key fallback is scoped per model on the same proxy', () async {
      final bodies = await captureTokenFallbackBodiesForTwoModels();

      expect(bodies[0]['model'], 'legacy-model');
      expect(bodies[0], contains('max_tokens'));
      expect(bodies[1]['model'], 'legacy-model');
      expect(bodies[1], contains('max_completion_tokens'));
      expect(bodies[2]['model'], 'gpt-test');
      expect(bodies[2], contains('max_tokens'));
      expect(bodies[2], isNot(contains('max_completion_tokens')));
    });

    test('token key fallback override can be cleared', () async {
      final bodies = await captureTokenFallbackBodiesWithManualClear();

      expect(bodies.map((body) => body['model']), [
        'legacy-model',
        'legacy-model',
        'legacy-model',
        'legacy-model',
      ]);
      expect(bodies[0], contains('max_tokens'));
      expect(bodies[1], contains('max_completion_tokens'));
      expect(bodies[2], contains('max_tokens'));
      expect(bodies[3], contains('max_completion_tokens'));
    });

    test('builds valid Anthropic simple text request body', () async {
      final captured = await captureAnthropicRequest(
        model: 'claude-sonnet-4-20250514${LlmService.presetModelSuffix}',
        system: 'You are concise.',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        baseUrlForPort: (port) => 'http://127.0.0.1:$port/v1/messages',
      );

      expect(captured.uri.path, '/v1/messages');
      expect(captured.body['model'], 'claude-sonnet-4-20250514');
      expect(captured.body['system'], 'You are concise.');
      expect(captured.body['messages'], [
        {'role': 'user', 'content': 'hi'},
      ]);
      expect(captured.body['max_tokens'], 8192);
      expect(jsonDecode(jsonEncode(captured.body)), captured.body);
    });

    test('adds Anthropic prompt cache breakpoint to request body', () async {
      PromptCacheSettings.setAnthropicPromptCacheEnabledForProcess(true);
      final captured = await captureAnthropicRequest(
        model: 'claude-sonnet-4-20250514${LlmService.presetModelSuffix}',
        system: 'You are concise.',
        messages: const [
          {'role': 'user', 'content': 'old question'},
          {'role': 'assistant', 'content': 'stable answer'},
          {'role': 'user', 'content': 'latest question'},
        ],
        baseUrlForPort: (port) => 'http://127.0.0.1:$port/v1/messages',
      );

      final cachedContent = captured.body['messages'][1]['content'] as List;
      expect(cachedContent.single['cache_control'], {'type': 'ephemeral'});
    });

    test('builds valid OpenAI-compatible simple text request body', () async {
      final captured = await captureOpenAiRequest(
        model: 'gpt-test${LlmService.presetModelSuffix}',
        system: 'You are concise.',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        baseUrlForPort: (port) => 'http://127.0.0.1:$port/v1/chat/completions',
      );

      expect(captured.uri.path, '/v1/chat/completions');
      expect(captured.body['model'], 'gpt-test');
      expect(captured.body['messages'], [
        {'role': 'system', 'content': 'You are concise.'},
        {'role': 'user', 'content': 'hi'},
      ]);
      expect(captured.body['max_tokens'], 8192);
      expect(jsonDecode(jsonEncode(captured.body)), captured.body);
    });

    test('omits OpenAI tool definitions when capabilities disable tools',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'gpt-test',
        capabilityRegistry: const _NoToolsCapabilityRegistry(),
        tools: const [
          ToolDefinition(
            name: 'echo',
            description: 'Echo text',
            inputSchema: {
              'type': 'object',
              'properties': {
                'text': {'type': 'string'},
              },
            },
          ),
        ],
      );

      expect(captured.body, isNot(contains('tools')));
    });

    test('downgrades historical tool payloads when tools are unsupported',
        () async {
      const toolDefinitions = [
        ToolDefinition(
          name: 'echo',
          description: 'Echo text',
          inputSchema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
            },
          },
        ),
      ];
      const messages = [
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'call:1',
              'name': 'bash',
              'input': {'command': 'pwd'},
            },
          ],
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'call:1',
              'for_llm': 'compact safe result',
              'output': 'FULL OUTPUT THAT MUST NOT LEAK',
            },
          ],
        },
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call:2',
              'type': 'function',
              'function': {
                'name': 'web_fetch',
                'arguments': '{"url":"https://example.test"}',
              },
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 'call:2',
          'content': 'fetch complete',
        },
      ];

      final openai = await captureOpenAiRequest(
        model: 'gpt-test',
        messages: messages,
        tools: toolDefinitions,
        capabilityRegistry: const _NoToolsCapabilityRegistry(),
      );
      final anthropic = await captureAnthropicRequest(
        model: 'claude-sonnet-4-20250514',
        messages: messages,
        tools: toolDefinitions,
        capabilityRegistry: const _NoToolsCapabilityRegistry(),
      );

      expect(openai.body, isNot(contains('tools')));
      expect(anthropic.body, isNot(contains('tools')));
      expectNoProviderToolSyntax(openai.body);
      expectNoProviderToolSyntax(anthropic.body);
      expect(openai.body.toString(), contains('[Tool call]'));
      expect(anthropic.body.toString(), contains('[Tool call]'));
      expect(openai.body.toString(), contains('for_llm: compact safe result'));
      expect(
          anthropic.body.toString(), contains('for_llm: compact safe result'));
      expect(
        openai.body.toString(),
        isNot(contains('FULL OUTPUT THAT MUST NOT LEAK')),
      );
      expect(
        anthropic.body.toString(),
        isNot(contains('FULL OUTPUT THAT MUST NOT LEAK')),
      );
    });

    test('redacts secrets from system prompts in request bodies', () async {
      final anthropic = await captureAnthropicRequest(
        model: 'claude-sonnet-4-20250514',
        system:
            'Use api_key=sk-proj-abcdefghijklmnopqrstuvwxyz123456 carefully.',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        baseUrlForPort: (port) => 'http://127.0.0.1:$port/v1/messages',
      );
      final openai = await captureOpenAiRequest(
        model: 'gpt-test',
        system:
            'Use api_key=sk-proj-abcdefghijklmnopqrstuvwxyz123456 carefully.',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        baseUrlForPort: (port) => 'http://127.0.0.1:$port/v1/chat/completions',
      );

      expect(anthropic.body['system'], contains('[redacted: api_key]'));
      expect(anthropic.body['system'], isNot(contains('sk-proj-')));
      expect(
        openai.body['messages'].first['content'],
        contains('[redacted: api_key]'),
      );
      expect(openai.body['messages'].first['content'],
          isNot(contains('sk-proj-')));
    });

    test(
        'passes assistant reasoning_content back to DeepSeek-style OpenAI-compatible APIs',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'deepseek-reasoner',
        system: 'You are concise.',
        messages: const [
          {
            'role': 'assistant',
            'content': 'answer',
            'reasoning_content': 'internal reasoning',
          },
        ],
        baseUrlForPort: (port) => 'http://127.0.0.1:$port/v1/chat/completions',
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': 'You are concise.'},
        {
          'role': 'assistant',
          'content': 'answer',
          'reasoning_content': 'internal reasoning',
        },
      ]);
    });

    test(
        'strips assistant reasoning_content from non-reasoning OpenAI requests',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'gpt-test',
        messages: const [
          {
            'role': 'assistant',
            'content': 'answer',
            'reasoning_content': 'internal reasoning',
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {'role': 'assistant', 'content': 'answer'},
      ]);
    });

    test('strips reasoning_content from non-reasoning DeepSeek chat models',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'deepseek-chat',
        messages: const [
          {
            'role': 'assistant',
            'content': 'answer',
            'reasoning_content': 'internal reasoning',
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {'role': 'assistant', 'content': 'answer'},
      ]);
    });

    test('strips reasoning_content from non-DeepSeek reasoner models',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'other-reasoner',
        messages: const [
          {
            'role': 'assistant',
            'content': 'answer',
            'reasoning_content': 'internal reasoning',
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {'role': 'assistant', 'content': 'answer'},
      ]);
    });

    test('allows bare r1 OpenAI-compatible reasoning_content', () async {
      final captured = await captureOpenAiRequest(
        model: 'r1',
        messages: const [
          {
            'role': 'assistant',
            'content': 'answer',
            'reasoning_content': 'internal reasoning',
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {
          'role': 'assistant',
          'content': 'answer',
          'reasoning_content': 'internal reasoning',
        },
      ]);
    });

    test('does not send reasoning_content to official OpenAI reasoning models',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'gpt-5.5',
        messages: const [
          {
            'role': 'assistant',
            'content': 'answer',
            'reasoning_content': 'internal reasoning',
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {'role': 'assistant', 'content': 'answer'},
      ]);
    });

    test('adds empty reasoning_content for old assistant messages on DeepSeek',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'deepseek-reasoner',
        messages: const [
          {'role': 'assistant', 'content': 'old answer'},
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {
          'role': 'assistant',
          'content': 'old answer',
          'reasoning_content': '',
        },
      ]);
    });

    test('parses Anthropic non-stream usage including cache fields', () async {
      final response = await anthropicChatResponseWithBody({
        'stop_reason': 'end_turn',
        'content': [
          {'type': 'text', 'text': 'ok'}
        ],
        'usage': {
          'input_tokens': 100,
          'output_tokens': 20,
          'cache_read_input_tokens': 30,
          'cache_creation_input_tokens': 40,
        },
      });

      expect(response.inputTokens, 100);
      expect(response.outputTokens, 20);
      expect(response.usage?.cacheReadInputTokens, 30);
      expect(response.usage?.cacheCreationInputTokens, 40);
      expect(response.usage?.totalInputTokens, 170);
    });

    test('parses OpenAI non-stream usage including cached tokens', () async {
      final response = await openAiChatResponseWithBody({
        'choices': [
          {
            'message': {'content': 'ok'},
            'finish_reason': 'stop',
          }
        ],
        'usage': {
          'prompt_tokens': 100,
          'completion_tokens': 20,
          'prompt_tokens_details': {
            'cached_tokens': 30,
          },
        },
      });

      expect(response.inputTokens, 100);
      expect(response.outputTokens, 20);
      expect(response.usage?.cacheReadInputTokens, 30);
      expect(response.usage?.cacheCreationInputTokens, isNull);
      expect(response.usage?.totalInputTokens, 100);
    });

    test('strips assistant reasoning_content from Anthropic request bodies',
        () async {
      final captured = await captureAnthropicRequest(
        model: 'claude-sonnet-4-20250514',
        messages: const [
          {
            'role': 'assistant',
            'content': 'answer',
            'reasoning_content': 'internal reasoning',
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'assistant', 'content': 'answer'},
      ]);
    });

    test('converts raw OpenAI tool history to Anthropic tool blocks', () async {
      final captured = await captureAnthropicRequest(
        model: 'claude-sonnet-4-20250514',
        messages: const [
          {
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              {
                'id': 'call_1',
                'type': 'function',
                'function': {
                  'name': 'bash',
                  'arguments': '{"command":"pwd"}',
                },
              },
            ],
          },
          {
            'role': 'tool',
            'tool_call_id': 'call_1',
            'content': '/root/workspace',
          },
        ],
      );

      expect(captured.body['messages'], [
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'call_1',
              'name': 'bash',
              'input': {'command': 'pwd'},
            },
          ],
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'call_1',
              'content': '/root/workspace',
            },
          ],
        },
      ]);
    });

    test('converts OpenAI image_url blocks to Anthropic image blocks',
        () async {
      final captured = await captureAnthropicRequest(
        model: 'claude-sonnet-4-20250514',
        messages: const [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'describe'},
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:image/png;base64,abc123',
                },
              },
            ],
          },
        ],
      );

      expect(captured.body['messages'], [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'describe'},
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': 'image/png',
                'data': 'abc123',
              },
            },
          ],
        },
      ]);
    });

    test('preserves raw OpenAI tool messages when building OpenAI bodies',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'gpt-test',
        messages: const [
          {
            'role': 'tool',
            'tool_call_id': 'call_1',
            'content': 'done',
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {
          'role': 'tool',
          'content': 'done',
          'tool_call_id': 'call_1',
        },
      ]);
    });

    test('prefers content-block tool_use over top-level tool_calls', () async {
      final captured = await captureOpenAiRequest(
        model: 'gpt-test',
        messages: const [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'call_content',
                'name': 'bash',
                'input': {'command': 'pwd'},
              },
            ],
            'tool_calls': [
              {
                'id': 'call_top',
                'type': 'function',
                'function': {
                  'name': 'bash',
                  'arguments': '{"command":"ignored"}',
                },
              },
            ],
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call_content',
              'type': 'function',
              'function': {
                'name': 'bash',
                'arguments': '{"command":"pwd"}',
              },
            },
          ],
        },
      ]);
    });

    test('builds golden Anthropic payload for mixed multimodal tool history',
        () async {
      final captured = await captureAnthropicRequest(
        model: 'claude-sonnet-4-20250514',
        system: 'You are concise.',
        messages: const [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'describe'},
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': 'abc123',
                },
              },
            ],
          },
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'text',
                'text': 'thinking answer',
                'reasoning_content': 'anthropic should strip this',
              },
            ],
            'reasoning_content': 'top level hidden',
          },
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'call:1',
                'name': 'bash',
                'input': {'command': 'pwd'},
              },
            ],
          },
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'call:1',
                'content': '/root/workspace',
              },
            ],
          },
        ],
      );

      expect(captured.body['messages'], [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'describe'},
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': 'image/png',
                'data': 'abc123',
              },
            },
          ],
        },
        {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'thinking answer'},
          ],
        },
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'call_1',
              'name': 'bash',
              'input': {'command': 'pwd'},
            },
          ],
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'call_1',
              'content': '/root/workspace',
            },
          ],
        },
      ]);
      expect(jsonDecode(jsonEncode(captured.body)), captured.body);
    });

    test('builds golden OpenAI payload for mixed multimodal tool history',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'gpt-test',
        system: 'You are concise.',
        messages: const [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'describe'},
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': 'abc123',
                },
              },
            ],
          },
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'call:1',
                'name': 'bash',
                'input': {'command': 'pwd'},
              },
            ],
          },
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'call:1',
                'content': '/root/workspace',
              },
            ],
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': 'You are concise.'},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'describe'},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,abc123'},
            },
          ],
        },
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {
                'name': 'bash',
                'arguments': '{"command":"pwd"}',
              },
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 'call_1',
          'content': '/root/workspace',
        },
      ]);
      expect(jsonDecode(jsonEncode(captured.body)), captured.body);
    });

    test('builds golden OpenAI payload preserving supported reasoning_content',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'deepseek-reasoner',
        system: 'You are concise.',
        messages: const [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'text',
                'text': 'answer',
                'reasoning_content': 'block reasoning',
              },
            ],
            'reasoning_content': 'top reasoning',
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': 'You are concise.'},
        {
          'role': 'assistant',
          'content': 'answer',
          'reasoning_content': 'top reasoning\nblock reasoning',
        },
      ]);
    });

    test('replaces images with text warning for known text-only models',
        () async {
      final captured = await captureOpenAiRequest(
        model: 'codex/gpt-5.5',
        messages: const [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'inspect'},
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': 'abc123',
                },
              },
            ],
          },
        ],
      );

      expect(captured.body['messages'], [
        {'role': 'system', 'content': ''},
        {
          'role': 'user',
          'content':
              'inspect\n[Attachment omitted: images are not supported by this provider]',
        },
      ]);
    });
  });

  group('LlmService streaming compatibility', () {
    test('returns sanitized EncryptedContentError for Anthropic SSE error',
        () async {
      final events = await collectAnthropicStreamEvents([
        sseData({
          'type': 'error',
          'error': {
            'type': 'invalid_request_error',
            'code': 'invalid_encrypted_content',
            'message': 'The encrypted content ${'x' * 800}',
          },
        }),
      ]);

      final error = events.whereType<StreamError>().single;
      expect(error.cause, isA<EncryptedContentError>());
      expect((error.cause as EncryptedContentError).code,
          'invalid_encrypted_content');
      expect(error.message, contains('invalid_encrypted_content'));
      expect(error.message.length, lessThan(620));
      expect(error.message, endsWith('...'));
    });

    test('rejects Anthropic stream ending without message_stop event',
        () async {
      final events = await collectAnthropicStreamEvents([
        sseData({
          'type': 'message_start',
          'message': {
            'usage': {
              'input_tokens': 1,
              'cache_read_input_tokens': 2,
              'cache_creation_input_tokens': 3,
            },
          },
        }),
        sseData({
          'type': 'content_block_start',
          'content_block': {'type': 'text'},
        }),
        sseData({
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'ok'},
        }),
        sseData({'type': 'content_block_stop'}),
        sseData({
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
          'usage': {'output_tokens': 1},
        }, delimiter: false),
      ]);

      final error = events.whereType<StreamError>().single;
      expect(error.message, contains('without message_stop'));
      expect(events.whereType<StreamDone>(), isEmpty);
    });

    test('rejects Anthropic done sentinel without message_stop', () async {
      final events = await collectAnthropicStreamEvents([
        sseData({'type': 'message_start', 'message': {}}),
        sseData({
          'type': 'content_block_start',
          'content_block': {'type': 'text'},
        }),
        sseData({
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'ok'},
        }),
        sseData({'type': 'content_block_stop'}),
        'data: [DONE]\n\n',
      ]);

      final error = events.whereType<StreamError>().single;
      expect(error.message, contains('without message_stop'));
      expect(events.whereType<StreamDone>(), isEmpty);
    });

    test('rejects malformed Anthropic SSE JSON frame', () async {
      final events = await collectAnthropicStreamEvents([
        sseData({'type': 'message_start', 'message': {}}),
        'data: {"type":\n\n',
      ]);

      final error = events.whereType<StreamError>().single;
      expect(error.message, contains('malformed SSE JSON frame'));
      expect(events.whereType<StreamDone>(), isEmpty);
    });

    test('streams Anthropic thinking deltas separately from answer text',
        () async {
      final events = await collectAnthropicStreamEvents([
        sseData({'type': 'message_start', 'message': {}}),
        sseData({
          'type': 'content_block_start',
          'content_block': {'type': 'thinking'},
        }),
        sseData({
          'type': 'content_block_delta',
          'delta': {'type': 'thinking_delta', 'thinking': 'step one\n'},
        }),
        sseData({
          'type': 'content_block_delta',
          'delta': {'type': 'thinking_delta', 'thinking': 'step two'},
        }),
        sseData({'type': 'content_block_stop'}),
        sseData({
          'type': 'content_block_start',
          'content_block': {'type': 'text'},
        }),
        sseData({
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'answer'},
        }),
        sseData({'type': 'content_block_stop'}),
        sseData({
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
        }),
        sseData({'type': 'message_stop'}, delimiter: false),
      ]);

      expect(events.whereType<ReasoningDelta>().map((e) => e.text), [
        'step one\n',
        'step two',
      ]);
      expect(events.whereType<TextDelta>().map((e) => e.text), ['answer']);
      final done = events.whereType<StreamDone>().single;
      expect(done.response.content.single.text, 'answer');
      expect(
        done.response.content.single.reasoningContent,
        'step one\nstep two',
      );
    });

    test('accepts OpenAI stream ending without final delimiter or done marker',
        () async {
      final events = await collectOpenAiStreamEvents([
        sseData({
          'choices': [
            {
              'delta': {'content': 'ok'},
              'finish_reason': null,
            }
          ],
        }),
        sseData({
          'choices': [
            {
              'delta': {},
              'finish_reason': 'stop',
            }
          ],
          'usage': {
            'prompt_tokens': 1,
            'completion_tokens': 1,
            'prompt_tokens_details': {
              'cached_tokens': 2,
            },
          },
        }, delimiter: false),
      ]);

      expect(events.whereType<StreamError>().map((e) => e.message), isEmpty);
      final done = events.whereType<StreamDone>().single;
      expect(done.response.content.single.text, 'ok');
      expect(done.response.stopReason, 'end_turn');
      expect(done.response.inputTokens, 1);
      expect(done.response.outputTokens, 1);
      expect(done.response.usage?.cacheReadInputTokens, 2);
    });

    test('rejects OpenAI stream ending without finish_reason', () async {
      final events = await collectOpenAiStreamEvents([
        sseData({
          'choices': [
            {
              'delta': {'content': 'partial'},
              'finish_reason': null,
            }
          ],
        }),
      ]);

      expect(events.whereType<TextDelta>().map((event) => event.text),
          ['partial']);
      final error = events.whereType<StreamError>().single;
      expect(error.message, contains('without finish_reason'));
      expect(events.whereType<StreamDone>(), isEmpty);
    });

    test('rejects malformed OpenAI SSE JSON frame', () async {
      final events = await collectOpenAiStreamEvents([
        sseData({
          'choices': [
            {
              'delta': {'content': 'partial'},
              'finish_reason': null,
            }
          ],
        }),
        'data: {"choices":\n\n',
      ]);

      expect(events.whereType<TextDelta>().map((event) => event.text),
          ['partial']);
      final error = events.whereType<StreamError>().single;
      expect(error.message, contains('malformed SSE JSON frame'));
      expect(events.whereType<StreamDone>(), isEmpty);
    });

    test('rejects OpenAI incomplete tool call JSON before StreamDone',
        () async {
      final events = await collectOpenAiStreamEvents([
        sseData({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_1',
                    'function': {'name': 'echo', 'arguments': '{"text":'},
                  }
                ],
              },
              'finish_reason': null,
            }
          ],
        }),
        sseData({
          'choices': [
            {
              'delta': {},
              'finish_reason': 'tool_calls',
            }
          ],
        }),
        'data: [DONE]\n\n',
      ]);

      expect(events.whereType<ToolUseStart>(), hasLength(1));
      expect(events.whereType<ToolInputDelta>(), hasLength(1));
      final error = events.whereType<StreamError>().single;
      expect(error.message, contains('incomplete tool call JSON'));
      expect(events.whereType<StreamDone>(), isEmpty);
    });

    test('retries OpenAI stream without stream_options when unsupported',
        () async {
      LlmService.clearStreamUsageUnsupportedHostsForTesting();
      final bodies = <Map<String, dynamic>>[];
      final events = await collectOpenAiStreamEventsWithHandler(
        (request) async {
          if (bodies.length == 1) {
            request.response.statusCode = 400;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({
              'error': {
                'message': 'unknown field: stream_options.include_usage',
              },
            }));
            await request.response.close();
            return;
          }

          request.response.write(sseData({
            'choices': [
              {
                'delta': {'content': 'ok'},
                'finish_reason': null,
              }
            ],
          }));
          request.response.write(sseData({
            'choices': [
              {
                'delta': {},
                'finish_reason': 'stop',
              }
            ],
          }, delimiter: false));
          await request.response.close();
        },
        onRequestBody: bodies.add,
      );

      expect(events.whereType<StreamError>(), isEmpty);
      expect(events.whereType<StreamDone>().single.response.content.single.text,
          'ok');
      expect(bodies, hasLength(2));
      expect(bodies.first, contains('stream_options'));
      expect(bodies.last, isNot(contains('stream_options')));

      final nextBodies = await captureOpenAiStreamBodies();
      expect(nextBodies.single, isNot(contains('stream_options')));
      LlmService.clearStreamUsageUnsupportedHostsForTesting();
    });

    test('captures OpenAI streaming reasoning_content without displaying it',
        () async {
      final events = await collectOpenAiStreamEvents([
        sseData({
          'choices': [
            {
              'delta': {'reasoning_content': 'hidden '},
              'finish_reason': null,
            }
          ],
        }),
        sseData({
          'choices': [
            {
              'delta': {'content': 'visible'},
              'finish_reason': null,
            }
          ],
        }),
        sseData({
          'choices': [
            {
              'delta': {'reasoning_content': 'state'},
              'finish_reason': null,
            }
          ],
        }),
        sseData({
          'choices': [
            {
              'delta': {},
              'finish_reason': 'stop',
            }
          ],
        }, delimiter: false),
      ]);

      expect(events.whereType<TextDelta>().map((e) => e.text), ['visible']);
      expect(events.whereType<ReasoningDelta>().map((e) => e.text), [
        'hidden ',
        'state',
      ]);
      final done = events.whereType<StreamDone>().single;
      final textBlock = done.response.content.single;
      expect(textBlock.text, 'visible');
      expect(textBlock.reasoningContent, 'hidden state');
    });

    test('reconnects OpenAI streams by resetting emitted text', () async {
      var requestCount = 0;
      final events = await collectOpenAiStreamEventsWithHandler(
        (request) async {
          requestCount++;
          if (requestCount == 1) {
            request.response.contentLength = 1024;
            request.response.write(sseData({
              'choices': [
                {
                  'delta': {'content': 'old partial'},
                  'finish_reason': null,
                }
              ],
            }));
            await request.response.flush();
            await closeIncompleteResponse(request.response);
            return;
          }

          request.response.write(sseData({
            'choices': [
              {
                'delta': {'content': 'new '},
                'finish_reason': null,
              }
            ],
          }));
          request.response.write(sseData({
            'choices': [
              {
                'delta': {'content': 'answer'},
                'finish_reason': null,
              }
            ],
          }));
          request.response.write(sseData({
            'choices': [
              {
                'delta': {},
                'finish_reason': 'stop',
              }
            ],
            'usage': {
              'prompt_tokens': 1,
              'completion_tokens': 1,
            },
          }));
          request.response.write('data: [DONE]\n\n');
          await request.response.close();
        },
      );

      expect(requestCount, 2);
      expect(events.whereType<StreamError>().map((e) => e.message), isEmpty);
      final resetIndex = events.indexWhere((event) => event is StreamReset);
      expect(resetIndex, isNonNegative);
      if (resetIndex > 0) {
        expect(
          events
              .take(resetIndex)
              .whereType<TextDelta>()
              .map((e) => e.text)
              .join(),
          'old partial',
        );
      }
      expect(
        events
            .skip(resetIndex + 1)
            .whereType<TextDelta>()
            .map((e) => e.text)
            .join(),
        'new answer',
      );
      final done = events.whereType<StreamDone>().single;
      expect(done.response.content.single.text, 'new answer');
    });

    test('reconnects Anthropic streams by resetting emitted text', () async {
      var requestCount = 0;
      final events = await collectAnthropicStreamEventsWithHandler(
        (request) async {
          requestCount++;
          if (requestCount == 1) {
            request.response.contentLength = 1024;
          }
          request.response.write(sseData({
            'type': 'message_start',
            'message': {
              'usage': {'input_tokens': 1},
            },
          }));
          request.response.write(sseData({
            'type': 'content_block_start',
            'content_block': {'type': 'text'},
          }));
          request.response.write(sseData({
            'type': 'content_block_delta',
            'delta': {
              'type': 'text_delta',
              'text': requestCount == 1 ? 'old partial' : 'new answer',
            },
          }));
          await request.response.flush();

          if (requestCount == 1) {
            await closeIncompleteResponse(request.response);
            return;
          }

          request.response.write(sseData({'type': 'content_block_stop'}));
          request.response.write(sseData({
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
            'usage': {'output_tokens': 1},
          }));
          request.response.write(sseData({'type': 'message_stop'}));
          await request.response.close();
        },
      );

      expect(requestCount, 2);
      expect(events.whereType<StreamError>().map((e) => e.message), isEmpty);
      final resetIndex = events.indexWhere((event) => event is StreamReset);
      expect(resetIndex, isNonNegative);
      if (resetIndex > 0) {
        expect(
          events
              .take(resetIndex)
              .whereType<TextDelta>()
              .map((e) => e.text)
              .join(),
          'old partial',
        );
      }
      expect(
        events
            .skip(resetIndex + 1)
            .whereType<TextDelta>()
            .map((e) => e.text)
            .join(),
        'new answer',
      );
      final done = events.whereType<StreamDone>().single;
      expect(done.response.content.single.text, 'new answer');
    });

    test('reconnect reset prevents Anthropic tool input splicing', () async {
      var requestCount = 0;
      final events = await collectAnthropicStreamEventsWithHandler(
        (request) async {
          requestCount++;
          if (requestCount == 1) {
            request.response.contentLength = 1024;
          }
          request.response.write(sseData({
            'type': 'message_start',
            'message': {
              'usage': {'input_tokens': 1},
            },
          }));
          request.response.write(sseData({
            'type': 'content_block_start',
            'content_block': {
              'type': 'tool_use',
              'id': requestCount == 1 ? 'tool-old' : 'tool-new',
              'name': 'lookup',
            },
          }));
          request.response.write(sseData({
            'type': 'content_block_delta',
            'delta': {
              'type': 'input_json_delta',
              'partial_json': requestCount == 1 ? '{"q":"old' : '{"q":"new"}',
            },
          }));
          await request.response.flush();
          if (requestCount == 1) {
            await closeIncompleteResponse(request.response);
            return;
          }
          request.response.write(sseData({'type': 'content_block_stop'}));
          request.response.write(sseData({
            'type': 'message_delta',
            'delta': {'stop_reason': 'tool_use'},
          }));
          request.response.write(sseData({'type': 'message_stop'}));
          await request.response.close();
        },
      );

      expect(requestCount, 2);
      final resetIndex = events.indexWhere((event) => event is StreamReset);
      expect(resetIndex, isNonNegative);
      expect(
        events
            .skip(resetIndex + 1)
            .whereType<ToolInputDelta>()
            .map((e) => e.json)
            .join(),
        '{"q":"new"}',
      );
      final done = events.whereType<StreamDone>().single;
      final toolBlock = done.response.content.single;
      expect(toolBlock.toolUseId, 'tool-new');
      expect(toolBlock.rawToolInputJson, '{"q":"new"}');
      expect(toolBlock.toolInput, {'q': 'new'});
    });
  });
}

Future<void> closeIncompleteResponse(HttpResponse response) async {
  try {
    await response.close();
  } on HttpException {
    // The incomplete response is intentional: it simulates a dropped stream.
  }
}

Future<String> sanitizedErrorBody(String responseBody) async {
  final error = await openAiChatError(400, responseBody);
  const marker = 'OpenAI API error (400): ';
  final start = error.indexOf(marker);
  expect(start, isNonNegative);
  return error.substring(start + marker.length);
}

Future<String> openAiChatError(int statusCode, String responseBody) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.statusCode = statusCode;
    request.response.write(responseBody);
    await request.response.close();
  });

  final service = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: 'gpt-test',
    baseUrl: 'http://127.0.0.1:${server.port}',
  ));
  try {
    await service.chat(system: '', messages: const [], tools: const []);
  } catch (e) {
    return e.toString();
  } finally {
    service.dispose();
    await server.close(force: true);
  }
  fail('Expected chat request to fail');
}

LlmService _timeoutTestService(
  _FakeLlmTimeoutScheduler scheduler, {
  String baseUrl = 'http://127.0.0.1:1',
  required Duration requestTimeout,
  Duration? requestMaxWallClock,
}) {
  return LlmService(
    LlmConfig.openai(
      apiKey: 'sk-test',
      model: 'gpt-test',
      baseUrl: baseUrl,
    ),
    isInBackground: () => scheduler.isInBackground,
    requestTimeout: requestTimeout,
    requestMaxWallClock: requestMaxWallClock,
    timeoutScheduler: scheduler,
  );
}

Future<String> _abortablePendingOperation(Future<void> abortTrigger) async {
  await abortTrigger;
  throw http.RequestAbortedException();
}

Future<String> _controlledPendingOperation(
  Future<void> abortTrigger,
  Completer<String> result,
) {
  abortTrigger.then((_) {
    if (!result.isCompleted) {
      result.completeError(http.RequestAbortedException());
    }
  });
  return result.future;
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

String _openAiResponse(String content) {
  return jsonEncode({
    'choices': [
      {
        'message': {'content': content},
        'finish_reason': 'stop',
      }
    ],
  });
}

final class _FakeLlmTimeoutScheduler implements LlmTimeoutScheduler {
  _FakeLlmTimeoutScheduler({
    required this.isInBackground,
    this.supportsLifecycleNotifications = true,
  });

  DateTime _now = DateTime.utc(2026);
  final List<_FakeTimer> _timers = <_FakeTimer>[];
  final Set<void Function(LlmLifecycleTransition)> _lifecycleListeners = {};
  bool isInBackground;
  final bool supportsLifecycleNotifications;
  int delayCallCount = 0;

  int get activeTimerCount => _timers.where((timer) => timer.isActive).length;
  int get lifecycleListenerCount => _lifecycleListeners.length;

  @override
  DateTime now() => _now;

  @override
  Timer schedule(Duration duration, void Function() callback) {
    final normalized = duration.isNegative ? Duration.zero : duration;
    final timer = _FakeTimer(
      dueAt: _now.add(normalized),
      callback: callback,
    );
    _timers.add(timer);
    return timer;
  }

  @override
  Future<void> delay(Duration duration) {
    delayCallCount += 1;
    final completer = Completer<void>();
    schedule(duration, completer.complete);
    return completer.future;
  }

  @override
  void Function()? registerLifecycleListener(
    void Function(LlmLifecycleTransition transition) listener,
  ) {
    if (!supportsLifecycleNotifications) return null;
    _lifecycleListeners.add(listener);
    return () => _lifecycleListeners.remove(listener);
  }

  void setBackground(bool value) {
    if (isInBackground == value) return;
    isInBackground = value;
    for (final listener in _lifecycleListeners.toList(growable: false)) {
      listener(LlmLifecycleTransition(
        isInBackground: value,
        timestamp: _now,
      ));
    }
  }

  void elapse(Duration duration) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'must not be negative');
    }
    final target = _now.add(duration);
    var callbacks = 0;
    while (true) {
      _FakeTimer? next;
      for (final timer in _timers) {
        if (!timer.isActive || timer.dueAt.isAfter(target)) continue;
        if (next == null || timer.dueAt.isBefore(next.dueAt)) {
          next = timer;
        }
      }
      if (next == null) break;
      _now = next.dueAt;
      next.fire();
      callbacks += 1;
      if (callbacks > 10000) {
        throw StateError('Fake timeout scheduler did not settle');
      }
    }
    _now = target;
  }
}

final class _FakeTimer implements Timer {
  _FakeTimer({required this.dueAt, required void Function() callback})
      : _callback = callback;

  final DateTime dueAt;
  final void Function() _callback;
  bool _isActive = true;
  int _tick = 0;

  @override
  bool get isActive => _isActive;

  @override
  int get tick => _tick;

  @override
  void cancel() => _isActive = false;

  void fire() {
    if (!_isActive) return;
    _isActive = false;
    _tick = 1;
    _callback();
  }
}

bool bodyContainsReasoningContent(Map<String, dynamic> body) {
  return jsonEncode(body).contains('reasoning_content');
}

Future<List<Map<String, dynamic>>> captureOpenAiChatBodiesForReasoning400({
  required String model,
  required String firstErrorBody,
  required List<Map<String, dynamic>> messages,
  bool expectSuccess = true,
}) async {
  final bodies = <Map<String, dynamic>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join())
        as Map<String, dynamic>;
    bodies.add(body);

    if (bodies.length == 1) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(firstErrorBody);
    } else {
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'choices': [
          {
            'message': {'content': 'ok'},
            'finish_reason': 'stop',
          }
        ],
      }));
    }
    await request.response.close();
  });

  final service = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: model,
    baseUrl: 'http://127.0.0.1:${server.port}',
  ));
  try {
    await service.chat(system: '', messages: messages, tools: const []);
    if (!expectSuccess) fail('Expected chat request to fail');
    return bodies;
  } catch (_) {
    if (expectSuccess) rethrow;
    return bodies;
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

Future<int> requestCountWhenFirstStatusIs(int statusCode) async {
  var count = 0;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    count++;
    if (count == 1) {
      request.response.statusCode = statusCode;
      request.response.write('retry me');
    } else {
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'choices': [
          {
            'message': {'content': 'ok'},
            'finish_reason': 'stop',
          }
        ],
      }));
    }
    await request.response.close();
  });

  final service = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: 'gpt-test',
    baseUrl: 'http://127.0.0.1:${server.port}',
  ));
  try {
    await service.chat(system: '', messages: const [], tools: const []);
    return count;
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

Future<int> requestCountForAlwaysStatus(int statusCode) async {
  var count = 0;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    count++;
    request.response.statusCode = statusCode;
    request.response.write('do not retry');
    await request.response.close();
  });

  final service = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: 'gpt-test',
    baseUrl: 'http://127.0.0.1:${server.port}',
  ));
  try {
    await service.chat(system: '', messages: const [], tools: const []);
  } catch (_) {
    return count;
  } finally {
    service.dispose();
    await server.close(force: true);
  }
  fail('Expected chat request to fail');
}

Future<List<Map<String, dynamic>>>
    captureTokenFallbackBodiesForTwoModels() async {
  LlmService.clearTokenKeyOverrides();
  final bodies = <Map<String, dynamic>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join())
        as Map<String, dynamic>;
    bodies.add(body);

    if (body['model'] == 'legacy-model' && body.containsKey('max_tokens')) {
      request.response.statusCode = 400;
      request.response.write('use max_completion_tokens instead of max_tokens');
    } else if (body['model'] == 'gpt-test' &&
        body.containsKey('max_completion_tokens')) {
      request.response.statusCode = 400;
      request.response.write('use max_tokens instead of max_completion_tokens');
    } else {
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'choices': [
          {
            'message': {'content': 'ok'},
            'finish_reason': 'stop',
          }
        ],
      }));
    }
    await request.response.close();
  });

  final baseUrl = 'http://127.0.0.1:${server.port}';
  final legacyService = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: 'legacy-model',
    baseUrl: baseUrl,
  ));
  final currentService = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: 'gpt-test',
    baseUrl: baseUrl,
  ));
  try {
    await legacyService.chat(system: '', messages: const [], tools: const []);
    await currentService.chat(system: '', messages: const [], tools: const []);
    return bodies;
  } finally {
    legacyService.dispose();
    currentService.dispose();
    await server.close(force: true);
    LlmService.clearTokenKeyOverrides();
  }
}

Future<List<Map<String, dynamic>>>
    captureTokenFallbackBodiesWithManualClear() async {
  LlmService.clearTokenKeyOverrides();
  final bodies = <Map<String, dynamic>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join())
        as Map<String, dynamic>;
    bodies.add(body);

    if (body.containsKey('max_tokens')) {
      request.response.statusCode = 400;
      request.response.write('use max_completion_tokens instead of max_tokens');
    } else {
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'choices': [
          {
            'message': {'content': 'ok'},
            'finish_reason': 'stop',
          }
        ],
      }));
    }
    await request.response.close();
  });

  Future<void> sendLegacyRequest() async {
    final service = LlmService(LlmConfig.openai(
      apiKey: 'sk-test',
      model: 'legacy-model',
      baseUrl: 'http://127.0.0.1:${server.port}',
    ));
    try {
      await service.chat(system: '', messages: const [], tools: const []);
    } finally {
      service.dispose();
    }
  }

  try {
    await sendLegacyRequest();
    LlmService.clearTokenKeyOverrides();
    await sendLegacyRequest();
    return bodies;
  } finally {
    await server.close(force: true);
    LlmService.clearTokenKeyOverrides();
  }
}

class CapturedLlmRequest {
  final Uri uri;
  final Map<String, dynamic> body;

  const CapturedLlmRequest({
    required this.uri,
    required this.body,
  });
}

Future<Map<String, dynamic>> captureAnthropicBody({
  required String model,
}) async =>
    (await captureAnthropicRequest(model: model)).body;

Future<CapturedLlmRequest> captureAnthropicRequest({
  required String model,
  String system = '',
  List<Map<String, dynamic>> messages = const [],
  List<ToolDefinition> tools = const [],
  String Function(int port)? baseUrlForPort,
  CapabilityRegistry capabilityRegistry = CapabilityRegistry.instance,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final capturedRequest = Completer<CapturedLlmRequest>();
  server.listen((request) async {
    final body = await utf8.decoder.bind(request).join();
    if (!capturedRequest.isCompleted) {
      capturedRequest.complete(CapturedLlmRequest(
        uri: request.uri,
        body: jsonDecode(body) as Map<String, dynamic>,
      ));
    }
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'stop_reason': 'end_turn',
      'content': [
        {'type': 'text', 'text': 'ok'}
      ],
    }));
    await request.response.close();
  });

  final service = LlmService(
      LlmConfig.anthropic(
        apiKey: 'sk-test',
        model: model,
        baseUrl: baseUrlForPort?.call(server.port) ??
            'http://127.0.0.1:${server.port}',
      ),
      capabilityRegistry: capabilityRegistry);
  try {
    await service.chat(system: system, messages: messages, tools: tools);
    return await capturedRequest.future;
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

Future<LlmResponse> anthropicChatResponseWithBody(
  Map<String, dynamic> responseBody,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await utf8.decoder.bind(request).join();
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(responseBody));
    await request.response.close();
  });

  final service = LlmService(LlmConfig.anthropic(
    apiKey: 'sk-test',
    model: 'claude-sonnet-4-20250514',
    baseUrl: 'http://127.0.0.1:${server.port}',
  ));
  try {
    return await service.chat(
      system: '',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
      tools: const [],
    );
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

Future<Map<String, dynamic>> captureOpenAiBody({
  required String model,
}) async =>
    (await captureOpenAiRequest(model: model)).body;

Future<CapturedLlmRequest> captureOpenAiRequest({
  required String model,
  String system = '',
  List<Map<String, dynamic>> messages = const [],
  List<ToolDefinition> tools = const [],
  String Function(int port)? baseUrlForPort,
  CapabilityRegistry capabilityRegistry = CapabilityRegistry.instance,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final capturedRequest = Completer<CapturedLlmRequest>();
  server.listen((request) async {
    final body = await utf8.decoder.bind(request).join();
    if (!capturedRequest.isCompleted) {
      capturedRequest.complete(CapturedLlmRequest(
        uri: request.uri,
        body: jsonDecode(body) as Map<String, dynamic>,
      ));
    }
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'choices': [
        {
          'message': {'content': 'ok'},
          'finish_reason': 'stop',
        }
      ],
    }));
    await request.response.close();
  });

  final service = LlmService(
      LlmConfig.openai(
        apiKey: 'sk-test',
        model: model,
        baseUrl: baseUrlForPort?.call(server.port) ??
            'http://127.0.0.1:${server.port}',
      ),
      capabilityRegistry: capabilityRegistry);
  try {
    await service.chat(system: system, messages: messages, tools: tools);
    return await capturedRequest.future;
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

Future<LlmResponse> openAiChatResponseWithBody(
  Map<String, dynamic> responseBody,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await utf8.decoder.bind(request).join();
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(responseBody));
    await request.response.close();
  });

  final service = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: 'gpt-test',
    baseUrl: 'http://127.0.0.1:${server.port}',
  ));
  try {
    return await service.chat(
      system: '',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
      tools: const [],
    );
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

class _NoToolsCapabilityRegistry extends CapabilityRegistry {
  const _NoToolsCapabilityRegistry();

  @override
  ResolvedModelProfile resolve({
    required ApiFormat apiFormat,
    required String baseUrl,
    required String model,
    CapabilityOverride? override,
  }) {
    final resolved = CapabilityRegistry.instance.resolve(
      apiFormat: apiFormat,
      baseUrl: baseUrl,
      model: model,
      override: override,
    );
    return ResolvedModelProfile(
      modelId: resolved.modelId,
      providerKey: resolved.providerKey,
      provider: resolved.provider,
      capabilities: resolved.capabilities.copyWith(
        supportsTools: false,
      ),
    );
  }
}

void expectNoProviderToolSyntax(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      expect(entry.key, isNot('tool_calls'));
      expect(entry.key, isNot('tool_call_id'));
      if (entry.key == 'role') {
        expect(entry.value, isNot('tool'));
      }
      if (entry.key == 'type') {
        expect(entry.value, isNot('tool_use'));
        expect(entry.value, isNot('tool_result'));
      }
      expectNoProviderToolSyntax(entry.value);
    }
  } else if (value is Iterable) {
    for (final item in value) {
      expectNoProviderToolSyntax(item);
    }
  }
}

String sseData(Map<String, dynamic> data, {bool delimiter = true}) {
  return 'data: ${jsonEncode(data)}${delimiter ? '\n\n' : '\n'}';
}

Future<List<StreamEvent>> collectAnthropicStreamEvents(
  List<String> responseChunks,
) async {
  return collectAnthropicStreamEventsWithHandler((request) async {
    for (final chunk in responseChunks) {
      request.response.write(chunk);
      await request.response.flush();
    }
    await request.response.close();
  });
}

Future<List<StreamEvent>> collectAnthropicStreamEventsWithHandler(
  Future<void> Function(HttpRequest request) handleRequest,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await utf8.decoder.bind(request).join();
    request.response.statusCode = 200;
    request.response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    await handleRequest(request);
  });

  final service = LlmService(LlmConfig.anthropic(
    apiKey: 'sk-test',
    model: 'claude-sonnet-4-20250514',
    baseUrl: 'http://127.0.0.1:${server.port}',
  ));
  try {
    return await service.chatStream(
      system: '',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
      tools: const [],
    ).toList();
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

Future<List<StreamEvent>> collectOpenAiStreamEvents(
  List<String> responseChunks,
) async {
  return collectOpenAiStreamEventsWithHandler((request) async {
    for (final chunk in responseChunks) {
      request.response.write(chunk);
      await request.response.flush();
    }
    await request.response.close();
  });
}

Future<List<StreamEvent>> collectOpenAiStreamEventsWithHandler(
  Future<void> Function(HttpRequest request) handleRequest, {
  String model = 'gpt-test',
  List<Map<String, dynamic>> messages = const [
    {'role': 'user', 'content': 'hi'},
  ],
  void Function(Map<String, dynamic> body)? onRequestBody,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final body = await utf8.decoder.bind(request).join();
    if (onRequestBody != null) {
      onRequestBody(jsonDecode(body) as Map<String, dynamic>);
    }
    request.response.statusCode = 200;
    request.response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    await handleRequest(request);
  });

  final service = LlmService(LlmConfig.openai(
    apiKey: 'sk-test',
    model: model,
    baseUrl: 'http://127.0.0.1:${server.port}',
  ));
  try {
    return await service.chatStream(
      system: '',
      messages: messages,
      tools: const [],
    ).toList();
  } finally {
    service.dispose();
    await server.close(force: true);
  }
}

Future<List<Map<String, dynamic>>> captureOpenAiStreamBodies() async {
  final bodies = <Map<String, dynamic>>[];
  await collectOpenAiStreamEventsWithHandler(
    (request) async {
      request.response.write(sseData({
        'choices': [
          {
            'delta': {'content': 'ok'},
            'finish_reason': null,
          }
        ],
      }));
      request.response.write(sseData({
        'choices': [
          {
            'delta': {},
            'finish_reason': 'stop',
          }
        ],
      }, delimiter: false));
      await request.response.close();
    },
    onRequestBody: bodies.add,
  );
  return bodies;
}
