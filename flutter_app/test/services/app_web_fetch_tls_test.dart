import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/services/app_http.dart';
import 'package:clawchat/services/tools/web_fetch_tool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../helpers/tls_test_fixture.dart';

late TlsTestFixture _tlsFixture;

void main() {
  final runtimeInfo = AppRuntimeInfo.forTesting();

  setUpAll(() async => _tlsFixture = await TlsTestFixture.create());
  tearDownAll(() => _tlsFixture.dispose());

  test('HTTPS pins TCP while authenticating the original hostname', () async {
    final server = await _secureServer();
    final capturedHeaders = Completer<HttpHeaders>();
    server.listen((request) async {
      if (!capturedHeaders.isCompleted) {
        capturedHeaders.complete(request.headers);
      }
      await request.drain<void>();
      request.response.write('secure-ok');
      await request.response.close();
    });
    final client = _tlsClient(runtimeInfo);
    try {
      final response = await client.send(http.Request(
        'GET',
        Uri.parse('https://public.example:${server.port}/resource'),
      ));

      expect(await response.stream.bytesToString(), 'secure-ok');
      final headers = await capturedHeaders.future;
      expect(headers.value(HttpHeaders.hostHeader),
          'public.example:${server.port}');
      expect(
        headers.value(HttpHeaders.userAgentHeader),
        runtimeInfo.userAgent,
      );
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('HTTPS never emits plaintext HTTP to a plain pinned listener', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final firstBytes = Completer<List<int>>();
    server.listen((socket) {
      socket.listen((bytes) {
        if (!firstBytes.isCompleted) firstBytes.complete(List<int>.of(bytes));
        socket.destroy();
      }, onError: (_) {
        socket.destroy();
      });
    });
    final client = _tlsClient(runtimeInfo);
    try {
      await expectLater(
        client.send(http.Request(
          'POST',
          Uri.parse('https://public.example:${server.port}/private'),
        )..body = 'must-not-be-plaintext'),
        throwsA(anything),
      );
      final bytes = await firstBytes.future.timeout(const Duration(seconds: 2));
      final prefix = ascii.decode(
        bytes.take(32).toList(),
        allowInvalid: true,
      );

      expect(bytes.first, 0x16);
      expect(prefix, isNot(startsWith('POST ')));
      expect(prefix, isNot(contains('Host:')));
      expect(prefix, isNot(contains('must-not-be-plaintext')));
    } finally {
      client.close();
      await server.close();
    }
  });

  test('trusted certificate with a mismatched hostname fails before request',
      () async {
    final server = await _secureServer();
    var requestCount = 0;
    server.listen((request) async {
      requestCount += 1;
      await request.drain<void>();
      await request.response.close();
    }, onError: (_) {});
    final client = _tlsClient(runtimeInfo);
    try {
      await expectLater(
        client.send(http.Request(
          'GET',
          Uri.parse('https://wrong.example:${server.port}/resource'),
        )),
        throwsA(anything),
      );
      expect(requestCount, 0);
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('untrusted certificate fails closed with a generic public error',
      () async {
    final server = await _secureServer();
    var requestCount = 0;
    server.listen((request) async {
      requestCount += 1;
      await request.drain<void>();
      await request.response.close();
    }, onError: (_) {});
    final client = _tlsClient(
      runtimeInfo,
      trustContext: SecurityContext(withTrustedRoots: false),
    );
    try {
      final result = await WebFetchTool(
        client: client,
        validateUrl: (_) async {},
        upgradeInsecureUrls: false,
      ).execute({
        'url': 'https://public.example:${server.port}/private?token=dummy',
      });

      expect(result, 'Error: Request blocked by network or SSRF policy.');
      expect(result, isNot(contains('public.example')));
      expect(result, isNot(contains('dummy')));
      expect(requestCount, 0);
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('HTTPS redirect hops independently authenticate and pin', () async {
    final target = await _secureServer();
    final source = await _secureServer();
    final resolvedHosts = <String>[];
    final seenHosts = <String>[];
    final seenUserAgents = <String>[];
    target.listen((request) async {
      seenHosts.add(request.headers.value(HttpHeaders.hostHeader) ?? '');
      seenUserAgents.add(
        request.headers.value(HttpHeaders.userAgentHeader) ?? '',
      );
      await request.drain<void>();
      request.response.write('redirect-ok');
      await request.response.close();
    });
    source.listen((request) async {
      seenHosts.add(request.headers.value(HttpHeaders.hostHeader) ?? '');
      seenUserAgents.add(
        request.headers.value(HttpHeaders.userAgentHeader) ?? '',
      );
      await request.drain<void>();
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'https://target.example:${target.port}/final',
      );
      await request.response.close();
    });
    final client = _tlsClient(
      runtimeInfo,
      resolveHost: (host) async {
        resolvedHosts.add(host);
        return [_publicTestAddress];
      },
    );
    try {
      final result = await WebFetchTool(
        client: client,
        validateUrl: (_) async {},
        upgradeInsecureUrls: false,
      ).execute({
        'url': 'https://source.example:${source.port}/start',
      });

      expect(result, contains('Status: 200'));
      expect(result, contains('redirect-ok'));
      expect(resolvedHosts, ['source.example', 'target.example']);
      expect(seenHosts, [
        'source.example:${source.port}',
        'target.example:${target.port}',
      ]);
      expect(seenUserAgents, [runtimeInfo.userAgent, runtimeInfo.userAgent]);
    } finally {
      client.close();
      await source.close(force: true);
      await target.close(force: true);
    }
  });

  test('TLS source keeps hostname verification and HTTP/1.1 explicit',
      () async {
    final source = await File('lib/services/app_http.dart').readAsString();

    expect(source, contains('SecureSocket.secure('));
    expect(source, contains('host: target.host'));
    expect(source, contains("supportedProtocols: const ['http/1.1']"));
    expect(source, isNot(contains('onBadCertificate:')));
    expect(
      source,
      contains('ConnectionTask.fromSocket<Socket>(result.future, cancel)'),
    );
    expect(
      source,
      matches(
        RegExp(
          r'@visibleForTesting\s+factory AppWebFetchClient\.forTesting\(',
        ),
      ),
    );

    final productionConstructorStart = source.indexOf('AppWebFetchClient(');
    final testingConstructorStart =
        source.indexOf('factory AppWebFetchClient.forTesting(');
    final productionConstructor = source.substring(
      productionConstructorStart,
      testingConstructorStart,
    );
    expect(productionConstructor, isNot(contains('SecurityContext')));

    final registryStart = source.indexOf('final class AppHttpClientRegistry');
    final registryFields = source.indexOf('final AppHttpClient client;');
    final registryConstructor = source.substring(registryStart, registryFields);
    expect(registryConstructor, isNot(contains('SecurityContext')));
    expect(source, isNot(contains('webFetchTlsSecurityContext')));

    final productionTestingFactoryCalls = <String>[];
    await for (final entity in Directory('lib').list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('/services/app_http.dart')) continue;
      if ((await entity.readAsString()).contains(
        'AppWebFetchClient.forTesting(',
      )) {
        productionTestingFactoryCalls.add(entity.path);
      }
    }
    expect(productionTestingFactoryCalls, isEmpty);
  });
}

final _publicTestAddress = InternetAddress('93.184.216.34');

AppWebFetchClient _tlsClient(
  AppRuntimeInfo runtimeInfo, {
  SecurityContext? trustContext,
  AppHostResolver? resolveHost,
}) {
  final realClients = _RealHttpOverrides();
  return AppWebFetchClient.forTesting(
    runtimeInfo,
    createNativeClient: () => realClients.createHttpClient(null),
    resolveHost: resolveHost ?? (_) async => [_publicTestAddress],
    connectSocket: (_, port) =>
        Socket.startConnect(InternetAddress.loopbackIPv4, port),
    tlsSecurityContext: trustContext ?? _trustedClientContext(),
    connectionTimeout: const Duration(seconds: 2),
  );
}

Future<HttpServer> _secureServer() {
  return HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    _serverContext(),
  );
}

SecurityContext _serverContext() {
  return _tlsFixture.serverContext();
}

SecurityContext _trustedClientContext() {
  return _tlsFixture.trustedClientContext();
}

final class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}
