import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/services/app_http.dart';
import 'package:clawchat/services/tools/web_fetch_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final runtimeInfo = AppRuntimeInfo.forTesting();

  test('cross-origin redirect forwards only explicitly safe headers', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final targetHeaders = Completer<Map<String, String>>();
    target.listen((request) async {
      if (!targetHeaders.isCompleted) {
        targetHeaders.complete(_flattenHeaders(request.headers));
      }
      await request.drain<void>();
      request.response.write('ok');
      await request.response.close();
    });
    source.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://target.example:${target.port}/final',
      );
      await request.response.close();
    });
    final client = _pinnedTestClient(runtimeInfo);
    try {
      final result = await _tool(client).execute({
        'url': 'http://source.example:${source.port}/start',
        'headers': {
          'Authorization': 'Bearer dummy-secret',
          'Proxy-Authorization': 'Basic dummy-secret',
          'Cookie': 'session=dummy-secret',
          'Cookie2': 'legacy=dummy-secret',
          'X-Api-Key': 'dummy-secret',
          'X-Custom-Token': 'dummy-secret',
          'Host': 'attacker.invalid',
          'Origin': 'https://origin.invalid',
          'Accept': 'application/json',
          'X-Safe': 'same-origin-only',
          'User-Agent': 'caller-agent',
        },
      });
      final headers = await targetHeaders.future;

      expect(result, contains('Status: 200'));
      expect(headers['authorization'], isNull);
      expect(headers['proxy-authorization'], isNull);
      expect(headers['cookie'], isNull);
      expect(headers['cookie2'], isNull);
      expect(headers['x-api-key'], isNull);
      expect(headers['x-custom-token'], isNull);
      expect(headers['origin'], isNull);
      expect(headers['x-safe'], isNull);
      expect(headers['accept'], 'application/json');
      expect(headers['host'], 'target.example:${target.port}');
      expect(headers['user-agent'], runtimeInfo.userAgent);
    } finally {
      client.close();
      await source.close(force: true);
      await target.close(force: true);
    }
  });

  test('same-origin redirect preserves non-hop request headers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final finalHeaders = Completer<Map<String, String>>();
    server.listen((request) async {
      await request.drain<void>();
      if (request.uri.path == '/start') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/final');
      } else {
        finalHeaders.complete(_flattenHeaders(request.headers));
        request.response.write('ok');
      }
      await request.response.close();
    });
    final client = _pinnedTestClient(runtimeInfo);
    try {
      await _tool(client).execute({
        'url': 'http://same.example:${server.port}/start',
        'headers': {
          'Authorization': 'Bearer same-origin',
          'X-Safe': 'survives',
          'Host': 'attacker.invalid',
        },
      });
      final headers = await finalHeaders.future;

      expect(headers['authorization'], 'Bearer same-origin');
      expect(headers['x-safe'], 'survives');
      expect(headers['host'], 'same.example:${server.port}');
      expect(headers['user-agent'], runtimeInfo.userAgent);
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('POST 302 becomes GET and drops body headers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final finalExchange = Completer<_RequestCapture>();
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      if (request.uri.path == '/start') {
        expect(request.method, 'POST');
        expect(body, 'dummy-body');
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/final');
      } else {
        finalExchange.complete(_RequestCapture(
          request.method,
          body,
          _flattenHeaders(request.headers),
        ));
        request.response.write('ok');
      }
      await request.response.close();
    });
    final client = _pinnedTestClient(runtimeInfo);
    try {
      await _tool(client).execute({
        'url': 'http://post.example:${server.port}/start',
        'method': 'POST',
        'body': 'dummy-body',
        'headers': {
          'Content-Type': 'text/plain',
          'Content-Encoding': 'identity',
          'X-Safe': 'survives-same-origin',
        },
      });
      final capture = await finalExchange.future;

      expect(capture.method, 'GET');
      expect(capture.body, isEmpty);
      expect(capture.headers['content-type'], isNull);
      expect(capture.headers['content-encoding'], isNull);
      expect(capture.headers['x-safe'], 'survives-same-origin');
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('cross-origin 307 and 308 unsafe preservation fails closed', () async {
    for (final testCase in const [
      (status: 307, method: 'POST', body: 'dummy-body', withAuth: false),
      (status: 308, method: 'GET', body: null, withAuth: true),
    ]) {
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var targetRequests = 0;
      target.listen((request) async {
        targetRequests += 1;
        await request.drain<void>();
        request.response.write('unexpected');
        await request.response.close();
      });
      source.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = testCase.status;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://target.example:${target.port}/final',
        );
        await request.response.close();
      });
      final client = _pinnedTestClient(runtimeInfo);
      try {
        final result = await _tool(client).execute({
          'url': 'http://source.example:${source.port}/start',
          'method': testCase.method,
          if (testCase.body != null) 'body': testCase.body,
          if (testCase.withAuth) 'headers': {'Authorization': 'Bearer dummy'},
        });

        expect(result, contains('Unsafe cross-origin redirect blocked'));
        expect(targetRequests, 0);
      } finally {
        client.close();
        await source.close(force: true);
        await target.close(force: true);
      }
    }
  });

  test('declared-domain policy denies a redirect before its request', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var targetRequests = 0;
    target.listen((request) async {
      targetRequests += 1;
      await request.drain<void>();
      await request.response.close();
    });
    source.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://denied.example:${target.port}/final',
      );
      await request.response.close();
    });
    final client = _pinnedTestClient(runtimeInfo);
    try {
      final result = await _tool(client).executeWithAllowedDomains(
        {'url': 'http://allowed.example:${source.port}/start'},
        allowedDomains: {'allowed.example'},
      );

      expect(result, contains('declared-domain policy'));
      expect(targetRequests, 0);
    } finally {
      client.close();
      await source.close(force: true);
      await target.close(force: true);
    }
  });

  test('redirect loops and redirect limits fail closed', () async {
    final loopServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var loopRequests = 0;
    loopServer.listen((request) async {
      loopRequests += 1;
      await request.drain<void>();
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        request.uri.path == '/a' ? '/b' : '/a',
      );
      await request.response.close();
    });
    final loopClient = _pinnedTestClient(runtimeInfo);
    try {
      final result = await _tool(loopClient).execute({
        'url': 'http://loop.example:${loopServer.port}/a',
      });
      expect(result, contains('Redirect loop blocked'));
      expect(loopRequests, 2);
    } finally {
      loopClient.close();
      await loopServer.close(force: true);
    }

    final limitServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var limitRequests = 0;
    limitServer.listen((request) async {
      limitRequests += 1;
      await request.drain<void>();
      final index = int.parse(request.uri.path.substring(1));
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        '/${index + 1}',
      );
      await request.response.close();
    });
    final limitClient = _pinnedTestClient(runtimeInfo);
    try {
      final result = await _tool(limitClient).execute({
        'url': 'http://limit.example:${limitServer.port}/0',
      });
      expect(result, contains('Redirect limit exceeded'));
      expect(limitRequests, 5);
    } finally {
      limitClient.close();
      await limitServer.close(force: true);
    }
  });

  test('URL credentials and query secrets never appear in returned errors',
      () async {
    final client = _pinnedTestClient(runtimeInfo);
    try {
      final result = await _tool(client).execute({
        'url': 'http://user:dummy-password@safe.example/path?token=dummy-token',
      });

      expect(result, contains('Invalid or disallowed URL'));
      expect(result, isNot(contains('dummy-password')));
      expect(result, isNot(contains('dummy-token')));
    } finally {
      client.close();
    }
  });
}

WebFetchTool _tool(AppWebFetchClient client) => WebFetchTool(
      client: client,
      validateUrl: (_) async {},
      upgradeInsecureUrls: false,
    );

AppWebFetchClient _pinnedTestClient(AppRuntimeInfo runtimeInfo) {
  final realClients = _RealHttpOverrides();
  return AppWebFetchClient(
    runtimeInfo,
    createNativeClient: () => realClients.createHttpClient(null),
    resolveHost: (_) async => [InternetAddress('93.184.216.34')],
    connectSocket: (_, port) =>
        Socket.startConnect(InternetAddress.loopbackIPv4, port),
  );
}

Map<String, String> _flattenHeaders(HttpHeaders headers) {
  final result = <String, String>{};
  headers.forEach((name, values) {
    result[name.toLowerCase()] = values.join(',');
  });
  return result;
}

final class _RequestCapture {
  const _RequestCapture(this.method, this.body, this.headers);

  final String method;
  final String body;
  final Map<String, String> headers;
}

final class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}
