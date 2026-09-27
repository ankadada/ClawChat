import 'package:flutter/foundation.dart';

/// Buffers native MCP stdio events that arrive before Dart has a session.
///
/// A child that dies at once (or that answers a request at once) can emit its
/// line, error, and exit events before the platform call that started it has
/// even returned, which is also before NativeMcpStdioProcess exists to receive
/// them. Without this latch those events are dropped, and the client waits on a
/// child that is already gone until its request timeout expires.
///
/// Every event carries the session token of the start it belongs to. A token
/// that does not match the bound session belongs to a previous child of the same
/// (runId, serverId) and is dropped: restarting a server must never deliver the
/// old child's late stdout or exit to the new one.
///
/// Only sessions Dart has announced with [expect] are buffered: an event for a
/// key that was never started, or that is already forgotten, is dropped, so the
/// latch cannot grow from stray native traffic.
class McpStdioSessionLatch {
  /// Most events held for one session that has not been bound yet.
  final int maxPendingEvents;

  /// Most characters of pending line output held for one session.
  final int maxPendingTextChars;

  final _pending = <String, List<_PendingEvent>>{};
  final _handlers = <String, _BoundSession>{};

  McpStdioSessionLatch({
    this.maxPendingEvents = 256,
    this.maxPendingTextChars = 128 * 1024,
  });

  /// Declares that a session for [key] is being started.
  void expect(String key) {
    _pending.putIfAbsent(key, () => <_PendingEvent>[]);
  }

  /// The start behind [key] failed: drop the expectation and its buffer.
  void cancelExpectation(String key) {
    if (_handlers.containsKey(key)) return;
    _pending.remove(key);
  }

  /// Turns an event for [key] into a handler call, or buffers it while the
  /// session is still expected. Returns true when a handler received it.
  bool deliver(
    String key, {
    required String? sessionToken,
    required Map<String, dynamic> event,
  }) {
    final bound = _handlers[key];
    if (bound != null) {
      if (bound.sessionToken != sessionToken) return false;
      bound.handler(event);
      return true;
    }
    final buffer = _pending[key];
    if (buffer == null) return false;
    buffer.add(_PendingEvent(sessionToken, Map<String, dynamic>.from(event)));
    _trim(buffer);
    return false;
  }

  /// Binds [handler] for the session that [sessionToken] identifies and replays
  /// what arrived before it existed, in arrival order.
  ///
  /// Events that carry another token are dropped: they belong to a previous
  /// child of the same key.
  void bind(
    String key, {
    required String? sessionToken,
    required void Function(Map<String, dynamic>) handler,
  }) {
    _handlers[key] = _BoundSession(sessionToken, handler);
    final buffered = _pending.remove(key);
    if (buffered == null) return;
    for (final pending in buffered) {
      if (pending.sessionToken != sessionToken) continue;
      handler(pending.event);
    }
  }

  /// Forgets [key] entirely: later events for it are dropped, not buffered.
  void forget(String key) {
    _handlers.remove(key);
    _pending.remove(key);
  }

  @visibleForTesting
  bool isExpected(String key) => _pending.containsKey(key);

  @visibleForTesting
  bool isBound(String key) => _handlers.containsKey(key);

  @visibleForTesting
  int bufferedCountFor(String key) => _pending[key]?.length ?? 0;

  @visibleForTesting
  int get expectedSessionCount => _pending.length;

  /// Keeps the buffer bounded. A terminal event is never evicted before a
  /// line, because the exit is what settles the caller.
  void _trim(List<_PendingEvent> buffer) {
    var textChars = 0;
    for (final pending in buffer) {
      textChars += (pending.event['line'] as String?)?.length ?? 0;
    }
    while (buffer.length > maxPendingEvents ||
        (textChars > maxPendingTextChars && buffer.length > 1)) {
      var index = buffer.indexWhere((pending) => !_isTerminal(pending.event));
      if (index < 0) index = 0;
      textChars -= (buffer[index].event['line'] as String?)?.length ?? 0;
      buffer.removeAt(index);
    }
  }

  static bool _isTerminal(Map<String, dynamic> event) =>
      event['event']?.toString() == 'exit';
}

class _PendingEvent {
  final String? sessionToken;
  final Map<String, dynamic> event;

  const _PendingEvent(this.sessionToken, this.event);
}

class _BoundSession {
  final String? sessionToken;
  final void Function(Map<String, dynamic>) handler;

  const _BoundSession(this.sessionToken, this.handler);
}
