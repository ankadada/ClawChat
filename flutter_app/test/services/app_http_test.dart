import 'dart:async';
import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/services/app_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  final runtimeInfo = AppRuntimeInfo.forTesting();

  tearDown(AppHttpClientRegistry.resetForTesting);

  test('AppUserAgent constructs the exact Android product identity', () {
    expect(
      AppUserAgent.forAndroidVersion('9.8.7'),
      'ClawChat/9.8.7 (Android)',
    );
  });

  group('AppRuntimeInfo', () {
    test('uses package semantic version and excludes build number', () {
      final info = AppRuntimeInfo.fromPackageInfo(
        PackageInfo(
          appName: 'ClawChat',
          packageName: AppConstants.packageName,
          version: '9.8.7',
          buildNumber: '654321',
        ),
        isAndroidForTesting: true,
      );

      expect(info.userAgent, 'ClawChat/9.8.7 (Android)');
      expect(info.userAgent, isNot(contains('654321')));
    });

    test('production platform seam rejects non-Android', () {
      expect(
        () => AppRuntimeInfo.fromPackageInfo(
          PackageInfo(
            appName: 'ClawChat',
            packageName: AppConstants.packageName,
            version: '1.2.3',
            buildNumber: '4',
          ),
          isAndroidForTesting: false,
        ),
        throwsUnsupportedError,
      );
    });

    test('AppConstants.version matches pubspec semantic version', () async {
      final pubspec = await File('pubspec.yaml').readAsString();
      final match = RegExp(
        r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+[0-9]+)?\s*$',
        multiLine: true,
      ).firstMatch(pubspec);

      expect(match, isNotNull);
      expect(AppConstants.version, match!.group(1));
      expect(runtimeInfo.version, AppConstants.version);
    });
  });

  test('AppHttpClient forces UA last and preserves unrelated headers',
      () async {
    final client = AppHttpClient(runtimeInfo);
    addTearDown(client.close);
    final seen = await _captureHeaders((uri) async {
      final request = http.Request('GET', uri)
        ..headers.addAll({
          'User-Agent': 'caller-one',
          'USER-AGENT': 'caller-two',
          'X-Custom': 'survives',
        });
      final response = await client.send(request);
      await response.stream.drain<void>();
    });

    expect(seen.value(HttpHeaders.userAgentHeader), runtimeInfo.userAgent);
    expect(seen.value('x-custom'), 'survives');
  });

  test('AbortableMultipartRequest uses the fixed UA', () async {
    final client = AppHttpClient(runtimeInfo);
    addTearDown(client.close);
    final seen = await _captureHeaders((uri) async {
      final request = http.AbortableMultipartRequest('POST', uri)
        ..fields['model'] = 'dummy';
      final response = await client.send(request);
      await response.stream.drain<void>();
    });

    expect(seen.value(HttpHeaders.userAgentHeader), runtimeInfo.userAgent);
  });

  test('pinned WebFetch transport rejects a loopback resolution', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = AppWebFetchClient(runtimeInfo);
    try {
      final request = http.Request(
        'GET',
        Uri.parse('http://127.0.0.1:${server.port}/blocked'),
      );

      await expectLater(
        client.send(request),
        throwsA(isA<SocketException>()),
      );
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('pinned resolver abort detaches and ignores a late DNS result',
      () async {
    final limiter = AppResolverLimiter(maxConcurrent: 1);
    final resolverStarted = Completer<void>();
    final releaseResolver = Completer<List<InternetAddress>>();
    final abort = Completer<void>();
    var connectCount = 0;
    final client = AppWebFetchClient(
      runtimeInfo,
      resolverLimiter: limiter,
      resolveHost: (_) {
        resolverStarted.complete();
        return releaseResolver.future;
      },
      connectSocket: (_, __) {
        connectCount += 1;
        throw StateError('late DNS result dispatched a connection');
      },
    );
    final request = http.AbortableRequest(
      'GET',
      Uri.parse('http://public.example/resource'),
      abortTrigger: abort.future,
    );
    final response = client.send(request);

    try {
      await resolverStarted.future;
      final elapsed = Stopwatch()..start();
      abort.complete();
      await expectLater(
        response,
        throwsA(isA<http.RequestAbortedException>()),
      );
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
      expect(connectCount, 0);
      expect(limiter.activeCount, 1);

      releaseResolver.complete([InternetAddress('93.184.216.34')]);
      await _waitUntil(() => limiter.activeCount == 0);
      await Future<void>.delayed(Duration.zero);
      expect(connectCount, 0);
    } finally {
      if (!releaseResolver.isCompleted) {
        releaseResolver.complete([InternetAddress('93.184.216.34')]);
      }
      client.close();
    }
  });

  test('repeated aborted pinned DNS work remains bounded', () async {
    final limiter = AppResolverLimiter(maxConcurrent: 2);
    final releaseResolver = Completer<List<InternetAddress>>();
    var resolverStarts = 0;
    var connectCount = 0;
    final client = AppWebFetchClient(
      runtimeInfo,
      resolverLimiter: limiter,
      resolveHost: (_) {
        resolverStarts += 1;
        return releaseResolver.future;
      },
      connectSocket: (_, __) {
        connectCount += 1;
        throw StateError('cancelled request dispatched a connection');
      },
    );
    final aborts = List.generate(8, (_) => Completer<void>());
    final futures = List.generate(
      aborts.length,
      (index) => client.send(http.AbortableRequest(
        'GET',
        Uri.parse('http://public$index.example/resource'),
        abortTrigger: aborts[index].future,
      )),
    );

    try {
      await _waitUntil(() => resolverStarts == 2);
      expect(limiter.activeCount, 2);
      expect(limiter.pendingCount, 6);
      for (final abort in aborts) {
        abort.complete();
      }
      await Future.wait(futures.map(
        (future) => expectLater(
          future,
          throwsA(isA<http.RequestAbortedException>()),
        ),
      ));
      expect(resolverStarts, 2);
      expect(connectCount, 0);
      expect(limiter.activeCount, 2);
      expect(limiter.pendingCount, 0);

      releaseResolver.complete([InternetAddress('93.184.216.34')]);
      await _waitUntil(() => limiter.activeCount == 0);
      await Future<void>.delayed(Duration.zero);
      expect(connectCount, 0);
    } finally {
      if (!releaseResolver.isCompleted) {
        releaseResolver.complete([InternetAddress('93.184.216.34')]);
      }
      client.close();
    }
  });

  test('pinned WebFetch cannot reuse a warmed general-pool connection',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requestCount = 0;
    server.listen((request) async {
      requestCount += 1;
      await request.drain<void>();
      request.response.write('ok');
      await request.response.close();
    });

    final nativeClient = HttpClient()
      ..connectionFactory = (uri, proxyHost, proxyPort) =>
          Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
    final generalClient = AppHttpClient(
      runtimeInfo,
      createNativeClient: () => nativeClient,
    );
    final pinnedClient = AppWebFetchClient(
      runtimeInfo,
      resolveHost: (_) async => [InternetAddress.loopbackIPv4],
    );
    final uri = Uri.parse('http://public.example:${server.port}/resource');
    try {
      final warmResponse = await generalClient.send(http.Request('GET', uri));
      await warmResponse.stream.drain<void>();

      await expectLater(
        pinnedClient.send(http.Request('GET', uri)),
        throwsA(isA<SocketException>()),
      );
      expect(requestCount, 1);
    } finally {
      pinnedClient.close();
      generalClient.close();
      await server.close(force: true);
    }
  });

  test('pinned WebFetch fails closed after a DNS rebind', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requestCount = 0;
    var resolutionCount = 0;
    server.listen((request) async {
      requestCount += 1;
      await request.drain<void>();
      request.response.write('ok');
      await request.response.close();
    });

    final client = AppWebFetchClient(
      runtimeInfo,
      resolveHost: (_) async {
        resolutionCount += 1;
        return resolutionCount == 1
            ? [InternetAddress('93.184.216.34')]
            : [InternetAddress.loopbackIPv4];
      },
      connectSocket: (_, __) =>
          Socket.startConnect(InternetAddress.loopbackIPv4, server.port),
    );
    final uri = Uri.parse('http://public.example:${server.port}/resource');
    try {
      final first = await client.send(http.Request('GET', uri));
      await first.stream.drain<void>();

      await expectLater(
        client.send(http.Request('GET', uri)),
        throwsA(isA<SocketException>()),
      );
      expect(resolutionCount, 2);
      expect(requestCount, 1);
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('overlapping pinned targets keep resolver state request-local',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final allowedStarted = Completer<void>();
    final releaseAllowed = Completer<void>();
    final seenHosts = <String>[];
    server.listen((request) async {
      seenHosts.add(request.headers.value(HttpHeaders.hostHeader) ?? '');
      await request.drain<void>();
      if (!allowedStarted.isCompleted) allowedStarted.complete();
      await releaseAllowed.future;
      request.response.write('ok');
      await request.response.close();
    });

    final client = AppWebFetchClient(
      runtimeInfo,
      resolveHost: (host) async => host == 'allowed.example'
          ? [InternetAddress('93.184.216.34')]
          : [InternetAddress.loopbackIPv4],
      connectSocket: (_, __) =>
          Socket.startConnect(InternetAddress.loopbackIPv4, server.port),
    );
    final allowedFuture = client.send(http.Request(
      'GET',
      Uri.parse('http://allowed.example:${server.port}/resource'),
    ));
    try {
      await allowedStarted.future;
      await expectLater(
        client.send(http.Request(
          'GET',
          Uri.parse('http://blocked.example:${server.port}/resource'),
        )),
        throwsA(isA<SocketException>()),
      );
      releaseAllowed.complete();
      final allowed = await allowedFuture;
      await allowed.stream.drain<void>();
      expect(seenHosts, ['allowed.example:${server.port}']);
    } finally {
      if (!releaseAllowed.isCompleted) releaseAllowed.complete();
      client.close();
      await server.close(force: true);
    }
  });

  group('AppHttpOverrides', () {
    late HttpOverrides? original;
    late AppHttpOverrideInstallation installation;

    setUp(() {
      original = HttpOverrides.current;
      installation = AppHttpOverrides.install(runtimeInfo);
    });

    tearDown(() {
      installation.restore();
      HttpOverrides.global = original;
    });

    test('raw HttpClient inherits the fixed User-Agent', () async {
      final seen = await _captureHeaders((uri) async {
        final client = HttpClient();
        try {
          final response = await (await client.getUrl(uri)).close();
          await response.drain<void>();
        } finally {
          client.close();
        }
      });

      expect(seen.value(HttpHeaders.userAgentHeader), runtimeInfo.userAgent);
    });

    test('package:http IOClient inherits the fixed User-Agent', () async {
      final seen = await _captureHeaders((uri) async {
        final client = IOClient(HttpClient());
        try {
          final response = await client.send(http.Request('GET', uri));
          await response.stream.drain<void>();
        } finally {
          client.close();
        }
      });

      expect(seen.value(HttpHeaders.userAgentHeader), runtimeInfo.userAgent);
    });
  });

  test('override delegates to and restores a pre-existing override', () async {
    final original = HttpOverrides.current;
    final delegate = _CountingHttpOverrides();
    HttpOverrides.global = delegate;
    final installation = AppHttpOverrides.install(runtimeInfo);
    try {
      final seen = await _captureHeaders((uri) async {
        final client = HttpClient();
        try {
          final response = await (await client.getUrl(uri)).close();
          await response.drain<void>();
        } finally {
          client.close();
        }
      });

      expect(delegate.createCount, 1);
      expect(seen.value(HttpHeaders.userAgentHeader), runtimeInfo.userAgent);
      installation.restore();
      expect(identical(HttpOverrides.current, delegate), isTrue);
    } finally {
      installation.restore();
      HttpOverrides.global = original;
    }
  });

  test('root registry close is idempotent and closes both transports', () {
    final registry = AppHttpClientRegistry(runtimeInfo: runtimeInfo);
    AppHttpClientRegistry.installForApp(registry);

    registry.dispose();
    registry.dispose();

    expect(registry.client.isClosed, isTrue);
    expect(registry.webFetchClient.isClosed, isTrue);
    expect(
      () => registry.client.send(http.Request('GET', Uri.parse('https://x'))),
      throwsStateError,
    );
  });

  test('owned WebFetch stream releases when upstream cancel throws', () async {
    var released = false;

    await AppWebFetchClient.cancelOwnedStreamForTesting(
      () => Future<void>.error(StateError('cancel failed')),
      () => released = true,
    );

    expect(released, isTrue);
  });

  test('owned WebFetch stream releases when upstream cancel stalls', () async {
    var released = false;
    final clock = Stopwatch()..start();

    await AppWebFetchClient.cancelOwnedStreamForTesting(
      () => Completer<void>().future,
      () => released = true,
    );

    expect(released, isTrue);
    expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('source guard keeps app-owned private transports in app_http only',
      () async {
    final forbidden = RegExp(
      r'''(?:\bHttpClient\s*\(|\bIOClient\s*\(|package:dio/|\bDio\s*\(|\bhttp\.(?:get|post|put|patch|delete|head|read|readBytes)\s*\(|\.send\s*\(\s*\))''',
    );
    final violations = <String>[];
    await for (final entity in Directory('lib').list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('/services/app_http.dart')) continue;
      final content = await entity.readAsString();
      if (forbidden.hasMatch(content)) violations.add(entity.path);
    }

    expect(violations, isEmpty);
  });
}

final class _CountingHttpOverrides extends HttpOverrides {
  int createCount = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    createCount += 1;
    return super.createHttpClient(context);
  }
}

Future<HttpHeaders> _captureHeaders(
  Future<void> Function(Uri uri) send,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final captured = Completer<HttpHeaders>();
  server.listen((request) async {
    if (!captured.isCompleted) captured.complete(request.headers);
    await request.drain<void>();
    request.response.statusCode = HttpStatus.ok;
    await request.response.close();
  });

  try {
    await send(Uri.parse('http://127.0.0.1:${server.port}/capture'));
    return await captured.future;
  } finally {
    await server.close(force: true);
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
