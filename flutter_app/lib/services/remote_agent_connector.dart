import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/remote_agent_connector.dart';
import 'app_http.dart';
import 'llm_content_sanitizer.dart';

abstract interface class RemoteAgentConnector {
  Stream<RemoteAgentEvent> send(
    RemoteAgentConnectorConfig config,
    RemoteAgentConsent? consent,
    RemoteAgentRequest request, {
    RemoteAgentCancellation? cancellation,
    bool Function()? authorizationGuard,
  });
}

final class RemoteAgentCancellation {
  final Completer<void> _cancelled = Completer<void>();
  final Set<_RemoteAgentCancellationRegistration> _registrations = {};
  _RemoteAgentAbortReason? _reason;
  _RemoteAgentCancellationLifecycle _lifecycle =
      _RemoteAgentCancellationLifecycle.unused;
  _RemoteAgentCancellationClaim? _owner;

  Future<void> get whenCancelled => _cancelled.future;
  bool get isCancelled => _reason != null;
  bool get isDeadlineExpired =>
      _reason == _RemoteAgentAbortReason.deadlineExceeded;

  RemoteAgentCancellationRegistration onCancelled(void Function() callback) {
    final registration = _RemoteAgentCancellationRegistration(
      this,
      callback,
    );
    if (isCancelled) {
      registration._notify();
    } else {
      _registrations.add(registration);
    }
    return registration;
  }

  void cancel() => _abort(_RemoteAgentAbortReason.cancelled);

  void _expireDeadline() {
    _abort(_RemoteAgentAbortReason.deadlineExceeded);
  }

  _RemoteAgentCancellationClaim? _claim() {
    if (_lifecycle != _RemoteAgentCancellationLifecycle.unused) return null;
    _lifecycle = _RemoteAgentCancellationLifecycle.claimed;
    final claim = _RemoteAgentCancellationClaim._(this);
    _owner = claim;
    return claim;
  }

  void _abort(_RemoteAgentAbortReason reason) {
    if (_lifecycle == _RemoteAgentCancellationLifecycle.retired ||
        _reason != null) {
      return;
    }
    _reason = reason;
    _cancelled.complete();
    final registrations = _registrations.toList(growable: false);
    _registrations.clear();
    for (final registration in registrations) {
      registration._notify();
    }
  }

  void _retire(_RemoteAgentCancellationClaim claim) {
    if (_lifecycle != _RemoteAgentCancellationLifecycle.claimed ||
        !identical(_owner, claim)) {
      return;
    }
    _owner = null;
    _lifecycle = _RemoteAgentCancellationLifecycle.retired;
  }

  void _removeRegistration(_RemoteAgentCancellationRegistration registration) {
    _registrations.remove(registration);
  }
}

abstract interface class RemoteAgentCancellationRegistration {
  void dispose();
}

final class _RemoteAgentCancellationRegistration
    implements RemoteAgentCancellationRegistration {
  _RemoteAgentCancellationRegistration(this._owner, this._callback);

  RemoteAgentCancellation? _owner;
  void Function()? _callback;

  void _notify() {
    _owner = null;
    final callback = _callback;
    _callback = null;
    callback?.call();
  }

  @override
  void dispose() {
    final owner = _owner;
    _owner = null;
    _callback = null;
    owner?._removeRegistration(this);
  }
}

enum _RemoteAgentAbortReason { cancelled, deadlineExceeded }

enum _RemoteAgentCancellationLifecycle { unused, claimed, retired }

final class _RemoteAgentCancellationClaim {
  _RemoteAgentCancellationClaim._(this._token);
  final RemoteAgentCancellation _token;
  bool _released = false;

  void retire() {
    if (_released) return;
    _released = true;
    _token._retire(this);
  }
}

enum _SseState { accumulating, messageCompleted, streamTerminal }

final class RemoteAgentParserMetrics {
  int _inputBytesScanned = 0;
  int _lineBytesDecoded = 0;
  int _completedLines = 0;

  int get inputBytesScanned => _inputBytesScanned;
  int get lineBytesDecoded => _lineBytesDecoded;
  int get completedLines => _completedLines;
}

/// Decodes a bounded response and returns only terminally validated output.
/// It never exposes partial deltas, so failed/cancelled runs have no
/// commit-eligible connector event.
final class CozeOpenApiResponseDecoder {
  const CozeOpenApiResponseDecoder({
    this.maxResponseBytes = 512 * 1024,
    this.maxOutputCharacters = 64 * 1024,
    this.maxSseLineBytes = 64 * 1024,
    this.cooperativeYieldEvery = 128,
    this.cooperativeAbortCheck,
    this.metrics,
  });

  static const _terminalEvent = 'done';
  static const _deltaEvent = 'conversation.message.delta';
  static const _messageCompletedEvent = 'conversation.message.completed';
  static const _nonOutputEvents = {
    'conversation.chat.created',
    'conversation.chat.in_progress',
    'conversation.chat.completed',
  };
  static const _failureEvents = {
    'error',
    'conversation.chat.failed',
    'conversation.chat.requires_action',
  };

  final int maxResponseBytes;
  final int maxOutputCharacters;
  final int maxSseLineBytes;
  final int cooperativeYieldEvery;
  final void Function()? cooperativeAbortCheck;
  final RemoteAgentParserMetrics? metrics;

  Future<String> decode(http.StreamedResponse response) async {
    try {
      return await _decode(response);
    } on RemoteAgentFailure {
      rethrow;
    } on FormatException {
      throw const RemoteAgentFailure(
        RemoteAgentErrorCode.unsupportedResponse,
      );
    }
  }

  Future<String> _decode(http.StreamedResponse response) async {
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    final output = contentType.contains('text/event-stream')
        ? await _parseSse(response.stream)
        : contentType.contains('application/json') || contentType.isEmpty
            ? _textFromPayload(
                _decodeObject(await _readBounded(response.stream)),
                eventName: null,
              )
            : null;
    if (output == null || output.isEmpty) {
      throw const RemoteAgentFailure(
        RemoteAgentErrorCode.unsupportedResponse,
      );
    }
    _validateOutput(output);
    return output;
  }

  Future<String> _parseSse(Stream<List<int>> source) async {
    var totalBytes = 0;
    final lineBytes = <int>[];
    final output = StringBuffer();
    var outputLength = 0;
    String? eventName;
    var state = _SseState.accumulating;
    var terminalDelimiterSeen = false;
    var processedLines = 0;

    await for (final chunk in source) {
      cooperativeAbortCheck?.call();
      totalBytes += chunk.length;
      if (totalBytes > maxResponseBytes) {
        throw const RemoteAgentFailure(RemoteAgentErrorCode.responseTooLarge);
      }
      if (state == _SseState.streamTerminal &&
          terminalDelimiterSeen &&
          chunk.isNotEmpty) {
        throw const RemoteAgentFailure(
          RemoteAgentErrorCode.unsupportedResponse,
        );
      }
      for (final byte in chunk) {
        metrics?._inputBytesScanned += 1;
        if (byte != 10) {
          lineBytes.add(byte);
          if (lineBytes.length > maxSseLineBytes) {
            throw const RemoteAgentFailure(
              RemoteAgentErrorCode.responseTooLarge,
            );
          }
          continue;
        }
        metrics?._completedLines += 1;
        metrics?._lineBytesDecoded += lineBytes.length;
        if (lineBytes.length > maxSseLineBytes) {
          throw const RemoteAgentFailure(
            RemoteAgentErrorCode.responseTooLarge,
          );
        }
        final line = utf8.decode(lineBytes).trimRight();
        lineBytes.clear();
        processedLines += 1;
        if (cooperativeYieldEvery > 0 &&
            processedLines % cooperativeYieldEvery == 0) {
          cooperativeAbortCheck?.call();
          await Future<void>.delayed(Duration.zero);
          cooperativeAbortCheck?.call();
        }

        if (state == _SseState.streamTerminal) {
          if (!terminalDelimiterSeen && line.isEmpty) {
            terminalDelimiterSeen = true;
            continue;
          }
          throw const RemoteAgentFailure(
            RemoteAgentErrorCode.unsupportedResponse,
          );
        }
        if (line.isEmpty) {
          eventName = null;
          continue;
        }
        if (line.startsWith(':')) continue;
        if (line.startsWith('event:')) {
          if (eventName != null) {
            throw const RemoteAgentFailure(
              RemoteAgentErrorCode.unsupportedResponse,
            );
          }
          eventName = line.substring(6).trim();
          if (eventName.isEmpty) {
            throw const RemoteAgentFailure(
              RemoteAgentErrorCode.unsupportedResponse,
            );
          }
          continue;
        }
        if (!line.startsWith('data:')) {
          throw const RemoteAgentFailure(
            RemoteAgentErrorCode.unsupportedResponse,
          );
        }

        final data = line.substring(5).trim();
        if (data == '[DONE]') {
          if (eventName != null && eventName != _terminalEvent) {
            throw const RemoteAgentFailure(
              RemoteAgentErrorCode.unsupportedResponse,
            );
          }
          state = _SseState.streamTerminal;
          continue;
        }
        if (data.isEmpty) {
          throw const RemoteAgentFailure(
            RemoteAgentErrorCode.unsupportedResponse,
          );
        }
        if (_failureEvents.contains(eventName)) {
          throw const RemoteAgentFailure(
            RemoteAgentErrorCode.providerRejected,
            retryable: true,
          );
        }
        final payload = _decodeObject(data);
        if (eventName == _terminalEvent) {
          throw const RemoteAgentFailure(
            RemoteAgentErrorCode.unsupportedResponse,
          );
        }
        if (_nonOutputEvents.contains(eventName)) {
          if (payload is! Map ||
              _textFromPayload(payload, eventName: eventName) != null) {
            throw const RemoteAgentFailure(
              RemoteAgentErrorCode.unsupportedResponse,
            );
          }
          eventName = null;
          continue;
        }
        if (eventName == _messageCompletedEvent) {
          final completedText = _textFromPayload(payload, eventName: eventName);
          if (completedText == null ||
              completedText.isEmpty ||
              state == _SseState.messageCompleted ||
              (outputLength > 0 && output.toString() != completedText)) {
            throw const RemoteAgentFailure(
              RemoteAgentErrorCode.unsupportedResponse,
            );
          }
          if (outputLength == 0) {
            output.write(completedText);
            outputLength = completedText.length;
            _checkOutputLength(outputLength);
          }
          state = _SseState.messageCompleted;
          eventName = null;
          continue;
        }
        if (eventName != null && eventName != _deltaEvent) {
          throw const RemoteAgentFailure(
            RemoteAgentErrorCode.unsupportedResponse,
          );
        }
        final delta = _textFromPayload(payload, eventName: eventName);
        eventName = null;
        if (delta == null ||
            delta.isEmpty ||
            state == _SseState.messageCompleted) {
          throw const RemoteAgentFailure(
            RemoteAgentErrorCode.unsupportedResponse,
          );
        }
        output.write(delta);
        outputLength += delta.length;
        _checkOutputLength(outputLength);
      }
      if (lineBytes.length > maxSseLineBytes) {
        throw const RemoteAgentFailure(RemoteAgentErrorCode.responseTooLarge);
      }
      cooperativeAbortCheck?.call();
    }

    if (lineBytes.length > maxSseLineBytes) {
      throw const RemoteAgentFailure(RemoteAgentErrorCode.responseTooLarge);
    }
    if (lineBytes.isNotEmpty ||
        state != _SseState.streamTerminal ||
        !terminalDelimiterSeen ||
        outputLength == 0) {
      throw const RemoteAgentFailure(
        RemoteAgentErrorCode.unsupportedResponse,
      );
    }
    return output.toString();
  }

  Future<String> _readBounded(Stream<List<int>> source) async {
    final bytes = <int>[];
    await for (final chunk in source) {
      if (bytes.length + chunk.length > maxResponseBytes) {
        throw const RemoteAgentFailure(RemoteAgentErrorCode.responseTooLarge);
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  Object? _decodeObject(String input) => jsonDecode(input);

  String? _textFromPayload(Object? payload, {required String? eventName}) {
    if (payload is! Map) return null;
    final map = Map<String, Object?>.from(payload);
    final direct = map['content'];
    if (direct is String) return direct;
    final data = map['data'];
    if (data is Map && data['content'] is String) {
      return data['content']! as String;
    }
    final choices = map['choices'];
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      final choice = choices.first as Map;
      for (final key in ['delta', 'message']) {
        final container = choice[key];
        if (container is Map && container['content'] is String) {
          return container['content']! as String;
        }
      }
    }
    return null;
  }

  void _validateOutput(String output) {
    _checkOutputLength(output.length);
    if (output.contains('\u0000') ||
        const LlmContentSanitizer().sanitizeText(output).stats.hasRedactions) {
      throw const RemoteAgentFailure(RemoteAgentErrorCode.unsafeOutput);
    }
  }

  void _checkOutputLength(int length) {
    if (length > maxOutputCharacters) {
      throw const RemoteAgentFailure(RemoteAgentErrorCode.responseTooLarge);
    }
  }
}

/// Production Coze/OpenAPI connector. Its transport is structurally fixed to
/// the root-owned, DNS/IP-pinning [AppWebFetchClient].
final class CozeOpenApiRemoteAgentConnector implements RemoteAgentConnector {
  CozeOpenApiRemoteAgentConnector({
    required AppWebFetchClient client,
    required RemoteAgentCredentialResolver credentialResolver,
    this.totalDeadline = const Duration(seconds: 90),
    this.maxResponseBytes = 512 * 1024,
    this.maxOutputCharacters = 64 * 1024,
  })  : _client = client,
        _credentialResolver = credentialResolver;

  static const _maxRedirects = 2;

  final AppWebFetchClient _client;
  final RemoteAgentCredentialResolver _credentialResolver;
  final Duration totalDeadline;
  final int maxResponseBytes;
  final int maxOutputCharacters;

  @override
  Stream<RemoteAgentEvent> send(
    RemoteAgentConnectorConfig config,
    RemoteAgentConsent? consent,
    RemoteAgentRequest request, {
    RemoteAgentCancellation? cancellation,
    bool Function()? authorizationGuard,
  }) async* {
    final operationCancellation = cancellation ?? RemoteAgentCancellation();
    final claim = operationCancellation._claim();
    if (claim == null) {
      throw const RemoteAgentFailure(RemoteAgentErrorCode.cancelled);
    }
    Timer? deadlineTimer;

    try {
      _requireAuthorized(authorizationGuard);
      if (config.kind != RemoteAgentConnectorKind.cozeOpenApi) {
        throw const RemoteAgentFailure(
          RemoteAgentErrorCode.invalidConfiguration,
        );
      }
      if (consent == null || !consent.allows(config)) {
        throw const RemoteAgentFailure(RemoteAgentErrorCode.consentRequired);
      }
      final endpoint = Uri.parse(config.baseUrl);
      if (operationCancellation.isCancelled) {
        throw RemoteAgentFailure(
          operationCancellation.isDeadlineExpired
              ? RemoteAgentErrorCode.deadlineExceeded
              : RemoteAgentErrorCode.cancelled,
          retryable: operationCancellation.isDeadlineExpired,
        );
      }
      deadlineTimer =
          Timer(totalDeadline, operationCancellation._expireDeadline);
      final credential = await Future.any<String?>([
        _credentialResolver.resolve(config.credentialReference),
        operationCancellation.whenCancelled.then<String?>((_) {
          throw http.RequestAbortedException(endpoint);
        }),
      ]);
      _requireAuthorized(authorizationGuard);
      if (credential == null || credential.trim().isEmpty) {
        throw const RemoteAgentFailure(
          RemoteAgentErrorCode.credentialUnavailable,
        );
      }
      final response = await _sendWithRedirectPolicy(
        endpoint,
        credential.trim(),
        config,
        request,
        operationCancellation,
        authorizationGuard,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _discardBounded(response.stream);
        throw RemoteAgentFailure(
          RemoteAgentErrorCode.providerRejected,
          retryable: response.statusCode == 429 || response.statusCode >= 500,
        );
      }
      final output = await CozeOpenApiResponseDecoder(
        maxResponseBytes: maxResponseBytes,
        maxOutputCharacters: maxOutputCharacters,
        cooperativeAbortCheck: () {
          if (operationCancellation.isCancelled) {
            throw http.RequestAbortedException(endpoint);
          }
        },
      ).decode(response);
      _requireAuthorized(authorizationGuard);
      await Future<void>.delayed(Duration.zero);
      if (operationCancellation.isDeadlineExpired) {
        throw const RemoteAgentFailure(
          RemoteAgentErrorCode.deadlineExceeded,
          retryable: true,
        );
      }
      if (operationCancellation.isCancelled) {
        throw const RemoteAgentFailure(RemoteAgentErrorCode.cancelled);
      }
      yield RemoteAgentComplete(text: output);
    } on RemoteAgentFailure {
      rethrow;
    } on http.RequestAbortedException {
      throw RemoteAgentFailure(
        operationCancellation.isDeadlineExpired
            ? RemoteAgentErrorCode.deadlineExceeded
            : RemoteAgentErrorCode.cancelled,
        retryable: operationCancellation.isDeadlineExpired,
      );
    } on FormatException {
      throw const RemoteAgentFailure(
        RemoteAgentErrorCode.unsupportedResponse,
      );
    } on Object {
      if (operationCancellation.isCancelled) {
        throw RemoteAgentFailure(
          operationCancellation.isDeadlineExpired
              ? RemoteAgentErrorCode.deadlineExceeded
              : RemoteAgentErrorCode.cancelled,
          retryable: operationCancellation.isDeadlineExpired,
        );
      }
      throw const RemoteAgentFailure(
        RemoteAgentErrorCode.transportFailure,
        retryable: true,
      );
    } finally {
      deadlineTimer?.cancel();
      claim.retire();
    }
  }

  Future<http.StreamedResponse> _sendWithRedirectPolicy(
    Uri initialEndpoint,
    String credential,
    RemoteAgentConnectorConfig config,
    RemoteAgentRequest request,
    RemoteAgentCancellation cancellation,
    bool Function()? authorizationGuard,
  ) async {
    var endpoint = initialEndpoint;
    for (var redirectCount = 0;
        redirectCount <= _maxRedirects;
        redirectCount += 1) {
      if (cancellation.isCancelled) {
        throw const RemoteAgentFailure(RemoteAgentErrorCode.cancelled);
      }
      _requireAuthorized(authorizationGuard);
      final outgoing = http.AbortableRequest(
        'POST',
        endpoint,
        abortTrigger: cancellation.whenCancelled,
      )
        ..followRedirects = false
        ..headers.addAll({
          HttpHeaders.authorizationHeader: 'Bearer $credential',
          HttpHeaders.contentTypeHeader: 'application/json',
          HttpHeaders.acceptHeader: 'text/event-stream, application/json',
        })
        ..body = jsonEncode({
          'bot_id': config.remoteAgentId,
          'user_id': _opaqueLocalUserId(request.localSessionId),
          'stream': true,
          'auto_save_history': false,
          'additional_messages':
              request.messages.map((message) => message.toWireJson()).toList(),
        });
      final response = await _client.send(outgoing);
      if (!_isRedirect(response.statusCode)) return response;
      await _discardBounded(response.stream);
      final location = response.headers['location'];
      if ((response.statusCode != 307 && response.statusCode != 308) ||
          location == null ||
          redirectCount == _maxRedirects) {
        throw const RemoteAgentFailure(RemoteAgentErrorCode.redirectBlocked);
      }
      final next = endpoint.resolve(location);
      if (!_sameOrigin(endpoint, next) || next.scheme != 'https') {
        throw const RemoteAgentFailure(RemoteAgentErrorCode.redirectBlocked);
      }
      endpoint = next;
    }
    throw const RemoteAgentFailure(RemoteAgentErrorCode.redirectBlocked);
  }

  Future<void> _discardBounded(Stream<List<int>> source) async {
    var count = 0;
    await for (final chunk in source) {
      count += chunk.length;
      if (count > maxResponseBytes) {
        throw const RemoteAgentFailure(RemoteAgentErrorCode.responseTooLarge);
      }
    }
  }

  static String _opaqueLocalUserId(String localSessionId) {
    final digest = sha256.convert(utf8.encode(localSessionId));
    return 'local-$digest';
  }

  static bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  static bool _sameOrigin(Uri left, Uri right) =>
      left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;

  static void _requireAuthorized(bool Function()? guard) {
    if (guard?.call() == false) {
      throw const RemoteAgentFailure(
        RemoteAgentErrorCode.consentRequired,
        retryable: true,
      );
    }
  }
}
