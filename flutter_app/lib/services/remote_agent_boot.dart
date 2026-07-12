import 'dart:async';

import 'package:flutter/foundation.dart';

import 'remote_agent_configuration_service.dart';

enum RemoteAgentBootStatus { initializing, recovery, ready, localOnly }

typedef RemoteAgentConfigurationLoader = Future<RemoteAgentConfigurationService>
    Function();
typedef RemoteAgentEvidenceResetter = Future<void> Function();
typedef RemoteAgentBootTransition = Future<void> Function(
  RemoteAgentBootStatus status,
  RemoteAgentConfigurationService? configuration,
);

/// Owns the fallible optional Remote Agent boot dependency without delaying
/// the first Flutter frame or weakening configuration evidence validation.
final class RemoteAgentBootController extends ChangeNotifier {
  RemoteAgentBootController({
    required RemoteAgentConfigurationLoader loader,
    RemoteAgentEvidenceResetter? resetter,
  })  : _loader = loader,
        _resetter = resetter;

  final RemoteAgentConfigurationLoader _loader;
  final RemoteAgentEvidenceResetter? _resetter;

  RemoteAgentBootStatus _status = RemoteAgentBootStatus.initializing;
  RemoteAgentConfigurationService? _configuration;
  Future<void>? _inFlight;
  String? _failureCode;
  int _attemptCount = 0;
  bool _disposed = false;
  RemoteAgentBootTransition? _transition;

  RemoteAgentBootStatus get status => _status;
  RemoteAgentConfigurationService? get configuration => _configuration;
  String? get failureCode => _failureCode;
  int get attemptCount => _attemptCount;
  bool get isAttempting => _inFlight != null;
  bool get isLocalOnly => _status == RemoteAgentBootStatus.localOnly;
  bool get canResetEvidence => _resetter != null;

  void bindRuntimeTransition(RemoteAgentBootTransition transition) {
    if (_transition != null && !identical(_transition, transition)) {
      throw StateError('Remote boot transition is already bound.');
    }
    _transition = transition;
  }

  Future<void> start() => _initialize(preserveLocalMode: false);

  Future<void> retry() => _initialize(
        preserveLocalMode: _status == RemoteAgentBootStatus.localOnly,
      );

  Future<void> useLocalOnly() async {
    if ((_status != RemoteAgentBootStatus.recovery &&
            _status != RemoteAgentBootStatus.ready) ||
        isAttempting) {
      return;
    }
    await _transition?.call(RemoteAgentBootStatus.localOnly, null);
    _configuration = null;
    _status = RemoteAgentBootStatus.localOnly;
    _notifyListeners();
  }

  Future<void> resetEvidenceAndRetry() async {
    final resetter = _resetter;
    if (resetter == null || isAttempting) return;
    _status = RemoteAgentBootStatus.initializing;
    _failureCode = null;
    _notifyListeners();
    try {
      await resetter();
    } catch (_) {
      _status = RemoteAgentBootStatus.recovery;
      _failureCode = 'remote_configuration_reset_failed';
      _notifyListeners();
      return;
    }
    await _initialize(preserveLocalMode: false);
  }

  Future<void> _initialize({required bool preserveLocalMode}) {
    final active = _inFlight;
    if (active != null) return active;
    final completer = Completer<void>();
    _inFlight = completer.future;
    _attemptCount += 1;
    if (!preserveLocalMode) {
      _status = RemoteAgentBootStatus.initializing;
    }
    _failureCode = null;
    _notifyListeners();
    () async {
      try {
        final configuration = await _loader();
        await _transition?.call(RemoteAgentBootStatus.ready, configuration);
        _configuration = configuration;
        _status = RemoteAgentBootStatus.ready;
      } catch (_) {
        _configuration = null;
        _failureCode = 'remote_configuration_evidence_invalid';
        final failureStatus = preserveLocalMode
            ? RemoteAgentBootStatus.localOnly
            : RemoteAgentBootStatus.recovery;
        try {
          await _transition?.call(failureStatus, null);
        } catch (_) {
          // The runtime remains fail-closed even if cleanup reports failure.
        }
        _status = failureStatus;
      } finally {
        _inFlight = null;
        _notifyListeners();
        completer.complete();
      }
    }();
    return completer.future;
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
