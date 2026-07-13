import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/models/remote_agent_connector.dart';
import 'package:clawchat/services/app_http.dart';
import 'package:clawchat/services/remote_agent_connector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../helpers/tls_test_fixture.dart';

late TlsTestFixture _tlsFixture;

void main() {
  setUpAll(() async => _tlsFixture = await TlsTestFixture.create());
  tearDownAll(() => _tlsFixture.dispose());
  const credential = 'credential-value-used-only-in-memory';
  final reference = RemoteAgentCredentialReference.parse(
    'cred_0123456789abcdefghijklmnopqrstuv',
  );
  final config = _config(reference: reference);
  final consent = _consent(config);
  final request = RemoteAgentRequest(
    localSessionId: 'local-session-1',
    messages: [RemoteAgentMessage(role: 'user', text: 'hello')],
  );

  test('production path uses pinned transport, fixed UA, and opaque session',
      () async {
    final server = await _secureServer();
    final runtimeInfo = AppRuntimeInfo.forTesting();
    final client = _pinnedClient(runtimeInfo);
    final captured = Completer<Map<String, Object?>>();
    server.listen((incoming) async {
      final body = jsonDecode(await utf8.decoder.bind(incoming).join())
          as Map<String, Object?>;
      captured.complete({
        'authorization':
            incoming.headers.value(HttpHeaders.authorizationHeader),
        'user_agent': incoming.headers.value(HttpHeaders.userAgentHeader),
        'body': body,
      });
      incoming.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      incoming.response.write(
        'data: {"choices":[{"delta":{"content":"safe reply"}}]}\n',
      );
      incoming.response.write('data: [DONE]\n\n');
      await incoming.response.close();
    });
    final liveConfig = _config(
      reference: reference,
      baseUrl: 'https://public.example:${server.port}/v1/chat/completions',
    );
    try {
      final events = await OpenClawGatewayRemoteAgentConnector(
        client: client,
        credentialResolver: const _CredentialResolver(credential),
      ).send(liveConfig, _consent(liveConfig), request).toList();
      final observed = await captured.future;
      final body = observed['body']! as Map<String, Object?>;

      expect(events, [isA<RemoteAgentComplete>()]);
      expect((events.single as RemoteAgentComplete).text, 'safe reply');
      expect(observed['authorization'], 'Bearer $credential');
      expect(observed['user_agent'], runtimeInfo.userAgent);
      expect(body['model'], 'openclaw/agent-1');
      expect(body['stream'], isTrue);
      expect(body['messages'], [
        {'role': 'user', 'content': 'hello'},
      ]);
      expect(body['user'], isNot(request.localSessionId));
      expect(body, isNot(contains('bot_id')));
      expect(body, isNot(contains('auto_save_history')));
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('production pinned transport rejects private DNS results before connect',
      () async {
    var connectCalls = 0;
    final client = AppWebFetchClient.forTesting(
      AppRuntimeInfo.forTesting(),
      tlsSecurityContext: _trustedClientContext(),
      resolveHost: (_) async => [InternetAddress.loopbackIPv4],
      connectSocket: (_, __) {
        connectCalls += 1;
        throw StateError('must not connect');
      },
    );
    try {
      await expectLater(
        OpenClawGatewayRemoteAgentConnector(
          client: client,
          credentialResolver: const _CredentialResolver(credential),
        ).send(config, consent, request).toList(),
        throwsA(_failure(RemoteAgentErrorCode.transportFailure)),
      );
      expect(connectCalls, 0);
    } finally {
      client.close();
    }
  });

  test(
      'explicit OpenClaw target permits Tailscale CGNAT without widening WebFetch',
      () async {
    final server = await _secureServer();
    var connectCalls = 0;
    final client = AppWebFetchClient.forTesting(
      AppRuntimeInfo.forTesting(),
      tlsSecurityContext: _trustedClientContext(),
      resolveHost: (_) async => [InternetAddress('100.64.12.34')],
      connectSocket: (_, port) {
        connectCalls += 1;
        return Socket.startConnect(InternetAddress.loopbackIPv4, port);
      },
    );
    server.listen((incoming) async {
      await incoming.drain<void>();
      incoming.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      incoming.response.write(
        'data: {"choices":[{"delta":{"content":"tailnet reply"}}]}\n',
      );
      incoming.response.write('data: [DONE]\n\n');
      await incoming.response.close();
    });
    final liveConfig = _config(
      reference: reference,
      baseUrl: 'https://public.example:${server.port}/v1/chat/completions',
    );
    try {
      await expectLater(
        client.send(http.Request('GET', Uri.parse(liveConfig.baseUrl))),
        throwsA(isA<SocketException>()),
      );
      expect(connectCalls, 0);

      final events = await OpenClawGatewayRemoteAgentConnector(
        client: client,
        credentialResolver: const _CredentialResolver(credential),
      ).send(liveConfig, _consent(liveConfig), request).toList();

      expect((events.single as RemoteAgentComplete).text, 'tailnet reply');
      expect(connectCalls, 1);
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('missing disclosure fails before credential resolution', () async {
    final resolver = _CountingCredentialResolver(credential);
    final client = _pinnedClient(AppRuntimeInfo.forTesting());
    try {
      await expectLater(
        OpenClawGatewayRemoteAgentConnector(
          client: client,
          credentialResolver: resolver,
        ).send(config, null, request).toList(),
        throwsA(_failure(RemoteAgentErrorCode.consentRequired)),
      );
      expect(resolver.calls, 0);
    } finally {
      client.close();
    }
  });

  test('missing credential fails before any network request', () async {
    final client = _pinnedClient(AppRuntimeInfo.forTesting());
    try {
      await expectLater(
        OpenClawGatewayRemoteAgentConnector(
          client: client,
          credentialResolver: const _NullCredentialResolver(),
        ).send(config, consent, request).toList(),
        throwsA(_failure(RemoteAgentErrorCode.credentialUnavailable)),
      );
    } finally {
      client.close();
    }
  });

  test('authorization revoked during credential resolution sends no request',
      () async {
    var authorized = true;
    var connectCalls = 0;
    final client = AppWebFetchClient.forTesting(
      AppRuntimeInfo.forTesting(),
      tlsSecurityContext: _trustedClientContext(),
      resolveHost: (_) async => [_publicTestAddress],
      connectSocket: (_, __) {
        connectCalls += 1;
        throw StateError('network must not start');
      },
    );
    try {
      await expectLater(
        OpenClawGatewayRemoteAgentConnector(
          client: client,
          credentialResolver: _RevokingCredentialResolver(
            credential,
            () => authorized = false,
          ),
        )
            .send(
              config,
              consent,
              request,
              authorizationGuard: () => authorized,
            )
            .toList(),
        throwsA(_failure(RemoteAgentErrorCode.consentRequired)),
      );
      expect(connectCalls, 0);
    } finally {
      client.close();
    }
  });

  test('complete SSE delta at EOF without terminal fails closed', () async {
    await expectLater(
      _decodeSse('data: {"content":"not committed"}\n\n'),
      throwsA(_failure(RemoteAgentErrorCode.unsupportedResponse)),
    );
  });

  test('official OpenClaw SSE chunks and terminal succeed', () async {
    expect(
      await _decodeSse(
        'data: {"choices":[{"delta":{"role":"assistant"}}]}\n\n'
        'data: {"choices":[{"delta":{"content":"one"}}]}\n\n'
        'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
        'data: [DONE]\n\n',
      ),
      'one',
    );
  });

  test('malformed duplicate conflicting and post-terminal SSE fail', () async {
    for (final body in [
      'data: {not-json}\n\ndata: [DONE]\n\n',
      'data: {"content":"x"}\n\ndata: [DONE]\n\ndata: [DONE]\n\n',
      'event: conversation.message.delta\ndata: [DONE]\n\n',
      'data: {"content":"x"}\n\ndata: [DONE]\n\ndata: {"content":"y"}\n\n',
      'data: {"content":"x"}\n\ndata: [DONE]\n\nignored',
      'data: {"content":"x"}\n\nevent: conversation.chat.completed\n'
          'data: {"content":"conflict"}\n\n',
      'event: conversation.message.completed\n'
          'data: {"content":"x"}\n\n'
          'event: conversation.message.completed\n'
          'data: {"content":"x"}\n\n'
          'data: [DONE]\n\n',
      'event: conversation.message.completed\n'
          'data: {"content":"x"}\n\n'
          'event: conversation.message.delta\n'
          'data: {"content":"y"}\n\n'
          'data: [DONE]\n\n',
      'data: {"content":"x"}\n\n'
          'event: conversation.message.completed\n'
          'data: {"content":"different"}\n\n'
          'data: [DONE]\n\n',
    ]) {
      await expectLater(
        _decodeSse(body),
        throwsA(_failure(RemoteAgentErrorCode.unsupportedResponse)),
      );
    }
  });

  test('provider failure after delta produces no commit-eligible result',
      () async {
    RemoteAgentComplete? durable;
    try {
      final text = await _decodeSse(
        'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n'
        'data: {"error":{"type":"api_error"}}\n\n',
      );
      durable = RemoteAgentComplete(text: text);
    } on RemoteAgentFailure catch (error) {
      expect(error.code, RemoteAgentErrorCode.providerRejected);
    }
    expect(durable, isNull);
  });

  test('never-settling body exits on explicit cancel with no event', () async {
    final server = await _secureServer();
    final client = _pinnedClient(AppRuntimeInfo.forTesting());
    final deltaFlushed = Completer<void>();
    final release = Completer<void>();
    var requestCount = 0;
    server.listen((incoming) async {
      requestCount += 1;
      await incoming.drain<void>();
      incoming.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      incoming.response.write(
        'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n',
      );
      await incoming.response.flush();
      deltaFlushed.complete();
      await release.future;
      try {
        await incoming.response.close();
      } on Object {
        // Cancellation owns the socket teardown.
      }
    });
    final liveConfig = _config(
      reference: reference,
      baseUrl: 'https://public.example:${server.port}/v1/chat/completions',
    );
    final cancellation = RemoteAgentCancellation();
    final events = <RemoteAgentEvent>[];
    Object? caught;
    final finished = Completer<void>();
    final resolver = _CountingCredentialResolver(credential);
    final connector = OpenClawGatewayRemoteAgentConnector(
      client: client,
      credentialResolver: resolver,
    );
    final subscription = connector
        .send(
      liveConfig,
      _consent(liveConfig),
      request,
      cancellation: cancellation,
    )
        .listen(
      events.add,
      onError: (Object error) {
        caught = error;
        if (!finished.isCompleted) finished.complete();
      },
      onDone: () {
        if (!finished.isCompleted) finished.complete();
      },
    );
    try {
      await deltaFlushed.future;
      await expectLater(
        connector
            .send(
              liveConfig,
              _consent(liveConfig),
              request,
              cancellation: cancellation,
            )
            .toList(),
        throwsA(_failure(RemoteAgentErrorCode.cancelled)),
      );
      expect(resolver.calls, 1);
      expect(requestCount, 1);
      expect(cancellation.isCancelled, isFalse);
      cancellation.cancel();
      await finished.future.timeout(const Duration(seconds: 2));
      expect(caught, _failure(RemoteAgentErrorCode.cancelled));
      expect(events, isEmpty);
    } finally {
      if (!release.isCompleted) release.complete();
      await subscription.cancel();
      client.close();
      await server.close(force: true);
    }
  });

  test('never-settling body exits on real deadline with no event', () async {
    final server = await _secureServer();
    final client = _pinnedClient(AppRuntimeInfo.forTesting());
    final deltaFlushed = Completer<void>();
    final release = Completer<void>();
    var requestCount = 0;
    server.listen((incoming) async {
      requestCount += 1;
      await incoming.drain<void>();
      incoming.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      incoming.response.write(
        'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n',
      );
      await incoming.response.flush();
      deltaFlushed.complete();
      await release.future;
      try {
        await incoming.response.close();
      } on Object {
        // Deadline cancellation owns the socket teardown.
      }
    });
    final liveConfig = _config(
      reference: reference,
      baseUrl: 'https://public.example:${server.port}/v1/chat/completions',
    );
    final cancellation = RemoteAgentCancellation();
    final resolver = _CountingCredentialResolver(credential);
    final connector = OpenClawGatewayRemoteAgentConnector(
      client: client,
      credentialResolver: resolver,
      totalDeadline: const Duration(milliseconds: 200),
    );
    final future = connector
        .send(
          liveConfig,
          _consent(liveConfig),
          request,
          cancellation: cancellation,
        )
        .toList();
    try {
      await deltaFlushed.future;
      await expectLater(
        connector
            .send(
              liveConfig,
              _consent(liveConfig),
              request,
              cancellation: cancellation,
            )
            .toList(),
        throwsA(_failure(RemoteAgentErrorCode.cancelled)),
      );
      expect(resolver.calls, 1);
      expect(requestCount, 1);
      expect(cancellation.isCancelled, isFalse);
      await expectLater(
        future,
        throwsA(_failure(RemoteAgentErrorCode.deadlineExceeded)),
      );
    } finally {
      if (!release.isCompleted) release.complete();
      client.close();
      await server.close(force: true);
    }
  });

  test('late cancellation controls are inert after successful commit',
      () async {
    final server = await _completedServer();
    final client = _pinnedClient(AppRuntimeInfo.forTesting());
    final cancellation = RemoteAgentCancellation();
    final liveConfig = _config(
      reference: reference,
      baseUrl: 'https://public.example:${server.port}/v1/chat/completions',
    );
    try {
      final events = await OpenClawGatewayRemoteAgentConnector(
        client: client,
        credentialResolver: const _CredentialResolver(credential),
      )
          .send(
            liveConfig,
            _consent(liveConfig),
            request,
            cancellation: cancellation,
          )
          .toList();
      expect(events, hasLength(1));
      expect(cancellation.isCancelled, isFalse);
      cancellation.cancel();
      expect(cancellation.isCancelled, isFalse);
      expect(cancellation.isDeadlineExpired, isFalse);
      await expectLater(
        OpenClawGatewayRemoteAgentConnector(
          client: client,
          credentialResolver: const _CredentialResolver(credential),
        )
            .send(
              liveConfig,
              _consent(liveConfig),
              request,
              cancellation: cancellation,
            )
            .toList(),
        throwsA(_failure(RemoteAgentErrorCode.cancelled)),
      );
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('production connector blocks cross-origin redirect before second hop',
      () async {
    final server = await _secureServer();
    final client = _pinnedClient(AppRuntimeInfo.forTesting());
    var requestCount = 0;
    server.listen((incoming) async {
      requestCount += 1;
      await incoming.drain<void>();
      incoming.response.statusCode = HttpStatus.temporaryRedirect;
      incoming.response.headers.set(
        HttpHeaders.locationHeader,
        'https://other.example/v1/chat/completions',
      );
      await incoming.response.close();
    });
    final liveConfig = _config(
      reference: reference,
      baseUrl: 'https://public.example:${server.port}/v1/chat/completions',
    );
    try {
      await expectLater(
        OpenClawGatewayRemoteAgentConnector(
          client: client,
          credentialResolver: const _CredentialResolver(credential),
        ).send(liveConfig, _consent(liveConfig), request).toList(),
        throwsA(_failure(RemoteAgentErrorCode.redirectBlocked)),
      );
      expect(requestCount, 1);
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('response and output bounds and unsafe output fail closed', () async {
    await expectLater(
      const OpenClawGatewayResponseDecoder(maxResponseBytes: 8).decode(
        _response(
          'application/json',
          '{"choices":[{"message":{"content":"too large"}}]}',
        ),
      ),
      throwsA(_failure(RemoteAgentErrorCode.responseTooLarge)),
    );
    await expectLater(
      const OpenClawGatewayResponseDecoder(maxOutputCharacters: 3).decode(
        _response(
          'application/json',
          '{"choices":[{"message":{"content":"four"}}]}',
        ),
      ),
      throwsA(_failure(RemoteAgentErrorCode.responseTooLarge)),
    );
    await expectLater(
      const OpenClawGatewayResponseDecoder().decode(
        _response(
          'application/json',
          '{"choices":[{"message":{"content":"authorization: Bearer $credential"}}]}',
        ),
      ),
      throwsA(_failure(RemoteAgentErrorCode.unsafeOutput)),
    );
  });

  test('SSE line bound checks complete lines and accepts exact boundary',
      () async {
    const lineLimit = 64;
    const prefix = 'data: {"choices":[{"delta":{"content":"';
    const suffix = '"}}]}';
    final exactContent = 'x' * (lineLimit - prefix.length - suffix.length);
    final exactLine = '$prefix$exactContent$suffix';
    expect(utf8.encode(exactLine), hasLength(lineLimit));
    const decoder = OpenClawGatewayResponseDecoder(
      maxSseLineBytes: lineLimit,
    );
    expect(
      await decoder.decode(
        _response(
          'text/event-stream',
          '$exactLine\n\ndata: [DONE]\n\n',
        ),
      ),
      exactContent,
    );
    await expectLater(
      decoder.decode(
        _response(
          'text/event-stream',
          '${exactLine}x\n\ndata: [DONE]\n\n',
        ),
      ),
      throwsA(_failure(RemoteAgentErrorCode.responseTooLarge)),
    );
  });

  test('many tiny deltas stay bounded and cooperatively cancellable', () async {
    const responseLimit = 128 * 1024;
    const frame = 'data: {"choices":[{"delta":{"content":"x"}}]}\n\n';
    const terminal = 'data: [DONE]\n\n';
    const frameCount = (responseLimit - terminal.length) ~/ frame.length - 1;
    final frames = List.filled(frameCount, frame).join();
    final completeBody = '${frames}data: [DONE]\n\n';
    final metrics = RemoteAgentParserMetrics();
    final output = await OpenClawGatewayResponseDecoder(
      maxResponseBytes: responseLimit,
      maxOutputCharacters: frameCount,
      cooperativeYieldEvery: 16,
      metrics: metrics,
    ).decode(_response('text/event-stream', completeBody));
    final encodedLength = utf8.encode(completeBody).length;
    expect(encodedLength, lessThan(responseLimit));
    expect(encodedLength, greaterThan(responseLimit * 0.95));
    expect(output, hasLength(frameCount));
    expect(metrics.inputBytesScanned, encodedLength);
    expect(
      metrics.lineBytesDecoded + metrics.completedLines,
      metrics.inputBytesScanned,
    );

    var checks = 0;
    await expectLater(
      OpenClawGatewayResponseDecoder(
        maxResponseBytes: responseLimit,
        maxOutputCharacters: frameCount,
        cooperativeYieldEvery: 8,
        cooperativeAbortCheck: () {
          checks += 1;
          if (checks == 4) {
            throw const RemoteAgentFailure(RemoteAgentErrorCode.cancelled);
          }
        },
      ).decode(_response('text/event-stream', completeBody)),
      throwsA(_failure(RemoteAgentErrorCode.cancelled)),
    );
  });

  test('consent binding covers every routing field and disclosure version', () {
    final original = RemoteAgentConsent.bindingFor(config);
    final edits = [
      _config(reference: reference, kind: RemoteAgentConnectorKind.cozeOpenApi),
      _config(reference: reference, id: 'connector-2'),
      _config(
          reference: reference,
          baseUrl: 'https://replacement.example/v1/chat/completions'),
      _config(reference: reference, remoteAgentId: 'agent-2'),
      _config(
        reference: RemoteAgentCredentialReference.parse(
          'cred_abcdefghijklmnopqrstuvwxyz012345',
        ),
      ),
    ];
    for (final edited in edits) {
      expect(RemoteAgentConsent.bindingFor(edited), isNot(original));
      expect(consent.allows(edited), isFalse);
    }
    expect(
      RemoteAgentConsent.bindingFor(config, disclosureVersion: 2),
      isNot(original),
    );
  });

  test('endpoint canonicalization makes consent binding stable', () {
    final canonical = _config(
      reference: reference,
      baseUrl: 'https://AGENT.EXAMPLE:443',
    );
    final equivalent = _config(
      reference: reference,
      baseUrl: 'https://agent.example/v1/../v1/chat/completions',
    );
    expect(canonical.baseUrl, equivalent.baseUrl);
    expect(
      RemoteAgentConsent.bindingFor(canonical),
      RemoteAgentConsent.bindingFor(equivalent),
    );
    expect(
      _config(
        reference: reference,
        baseUrl: 'https://agent.example/v1',
      ).baseUrl,
      'https://agent.example/v1/chat/completions',
    );
    expect(
      _config(
        reference: reference,
        baseUrl: 'https://agent.example/openclaw',
      ).baseUrl,
      'https://agent.example/openclaw/v1/chat/completions',
    );
    final reversedJson = Map<String, Object?>.fromEntries(
      canonical.toJson().entries.toList().reversed,
    );
    expect(
      RemoteAgentConsent.bindingFor(
        RemoteAgentConnectorConfig.fromJson(reversedJson),
      ),
      RemoteAgentConsent.bindingFor(canonical),
    );
  });

  test('endpoint factory rejects non-HTTPS and credential-bearing syntax', () {
    for (final invalid in [
      'http://agent.example/v1/chat/completions',
      'https://user@agent.example/v1/chat/completions',
      'https://agent.example/v1/chat/completions?key=value',
      ' https://agent.example/v1/chat/completions',
    ]) {
      expect(
        () => _config(reference: reference, baseUrl: invalid),
        throwsFormatException,
      );
    }
  });

  test('endpoint factory enforces encoded journal input bounds', () {
    expect(
      () => canonicalizeRemoteAgentEndpoint(
        'https://example.invalid/${'a' * 2050}',
      ),
      throwsFormatException,
    );
    expect(
      () => canonicalizeRemoteAgentEndpoint(
        'https://example.invalid/${'a' * 1025}',
      ),
      throwsFormatException,
    );
  });

  test('config and consent enforce exact persisted schemas and round trip', () {
    final configJson = config.toJson();
    final consentJson = consent.toJson();
    expect(
        RemoteAgentConnectorConfig.fromJson(configJson).toJson(), configJson);
    expect(RemoteAgentConsent.fromJson(consentJson).toJson(), consentJson);

    for (final invalid in [
      {...configJson, 'api_key': 'forbidden'},
      {...configJson}..remove('enabled'),
      {...configJson, 'enabled': 'true'},
      {...configJson, 'kind': 'unknown'},
    ]) {
      expect(
        () => RemoteAgentConnectorConfig.fromJson(invalid),
        throwsFormatException,
      );
    }
    for (final invalid in [
      {...consentJson, 'secret': 'forbidden'},
      {...consentJson}..remove('accepted'),
      {...consentJson, 'disclosure_version': 2},
      {...consentJson, 'configuration_binding': 'abcd'},
      {...consentJson, 'accepted': 1},
    ]) {
      expect(() => RemoteAgentConsent.fromJson(invalid), throwsFormatException);
    }
  });

  test('credential references reject tokens URLs whitespace and secret words',
      () {
    for (final invalid in [
      'raw-token-value',
      'https://credential.example/value',
      'cred_short',
      'cred_0123456789abcd efghijklmnopqrstuv',
      'cred_0123456789abcd\ne fghijklmnopqrstuv',
      'cred_secret_0123456789abcdefghijklmnop',
      'cred_sk-proj-${'0123456789abcdefghijklmnop'}',
    ]) {
      expect(
        () => RemoteAgentCredentialReference.parse(invalid),
        throwsFormatException,
      );
    }
    expect(reference.toString(), isNot(contains(reference.value)));
    expect(jsonEncode(config.toDiagnosticJson()),
        isNot(contains(reference.value)));
    expect(
        jsonEncode(config.toDiagnosticJson()), isNot(contains(config.baseUrl)));
  });

  test('failures expose only sanitized local metadata', () {
    const failure = RemoteAgentFailure(RemoteAgentErrorCode.transportFailure);
    final exported = '${failure.toString()}${failure.publicMessage}'
        '${jsonEncode(failure.toDiagnosticJson())}'
        '${jsonEncode(failure.toAssistantError().toJson())}';
    expect(exported, isNot(contains(credential)));
    expect(exported, isNot(contains(config.baseUrl)));
    expect(exported, isNot(contains(reference.value)));
  });
}

RemoteAgentConnectorConfig _config({
  required RemoteAgentCredentialReference reference,
  RemoteAgentConnectorKind kind = RemoteAgentConnectorKind.openClawGateway,
  String id = 'connector-1',
  String baseUrl = 'https://agent.example/v1/chat/completions',
  String remoteAgentId = 'agent-1',
}) {
  return RemoteAgentConnectorConfig(
    kind: kind,
    id: id,
    displayName: 'Remote agent',
    baseUrl: baseUrl,
    credentialReference: reference,
    remoteAgentId: remoteAgentId,
    enabled: true,
  );
}

RemoteAgentConsent _consent(RemoteAgentConnectorConfig config) =>
    RemoteAgentConsent.grant(
      config,
      acceptedAt: DateTime.utc(2026, 7, 11),
    );

Matcher _failure(RemoteAgentErrorCode code) =>
    isA<RemoteAgentFailure>().having((error) => error.code, 'code', code);

Future<String> _decodeSse(String body) =>
    const OpenClawGatewayResponseDecoder().decode(
      _response('text/event-stream', body),
    );

http.StreamedResponse _response(String contentType, String body) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      headers: {'content-type': contentType},
    );

class _CredentialResolver implements RemoteAgentCredentialResolver {
  const _CredentialResolver(this.value);
  final String value;

  @override
  Future<String?> resolve(RemoteAgentCredentialReference reference) async =>
      value;
}

class _CountingCredentialResolver extends _CredentialResolver {
  _CountingCredentialResolver(super.value);
  int calls = 0;

  @override
  Future<String?> resolve(RemoteAgentCredentialReference reference) async {
    calls += 1;
    return super.resolve(reference);
  }
}

class _RevokingCredentialResolver extends _CredentialResolver {
  _RevokingCredentialResolver(super.value, this.onResolve);
  final void Function() onResolve;

  @override
  Future<String?> resolve(RemoteAgentCredentialReference reference) async {
    onResolve();
    return super.resolve(reference);
  }
}

class _NullCredentialResolver implements RemoteAgentCredentialResolver {
  const _NullCredentialResolver();

  @override
  Future<String?> resolve(RemoteAgentCredentialReference reference) async =>
      null;
}

final _publicTestAddress = InternetAddress('93.184.216.34');

AppWebFetchClient _pinnedClient(AppRuntimeInfo runtimeInfo) {
  final realClients = _RealHttpOverrides();
  return AppWebFetchClient.forTesting(
    runtimeInfo,
    createNativeClient: () => realClients.createHttpClient(null),
    resolveHost: (_) async => [_publicTestAddress],
    connectSocket: (_, port) =>
        Socket.startConnect(InternetAddress.loopbackIPv4, port),
    tlsSecurityContext: _trustedClientContext(),
    connectionTimeout: const Duration(seconds: 2),
  );
}

Future<HttpServer> _secureServer() => HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      _tlsFixture.serverContext(),
    );

Future<HttpServer> _completedServer() async {
  final server = await _secureServer();
  server.listen((incoming) async {
    await incoming.drain<void>();
    incoming.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    incoming.response.write(
      'data: {"choices":[{"delta":{"content":"complete"}}]}\n',
    );
    incoming.response.write('data: [DONE]\n\n');
    await incoming.response.close();
  });
  return server;
}

SecurityContext _trustedClientContext() => _tlsFixture.trustedClientContext();

final class _RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}
