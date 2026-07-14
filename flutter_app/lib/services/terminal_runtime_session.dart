import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

import 'native_bridge.dart';
import 'terminal_service.dart';

abstract interface class TerminalProcessHandle {
  Stream<List<int>> get output;
  Future<int> get exitCode;
  int get pid;
  void write(List<int> data);
  void resize(int rows, int columns);
  bool kill();
}

final class FlutterPtyProcessHandle implements TerminalProcessHandle {
  FlutterPtyProcessHandle(this._pty);

  final Pty _pty;

  @override
  Stream<List<int>> get output => _pty.output.cast<List<int>>();

  @override
  Future<int> get exitCode => _pty.exitCode;

  @override
  int get pid => _pty.pid;

  @override
  bool kill() => _pty.kill();

  @override
  void resize(int rows, int columns) => _pty.resize(rows, columns);

  @override
  void write(List<int> data) => _pty.write(Uint8List.fromList(data));
}

abstract interface class TerminalContinuationBackend {
  Future<TerminalContinuationStartResult> replace({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required Duration timeout,
  });

  Future<bool> isCurrent({
    required String operationId,
    required String sessionId,
    required String candidateId,
  });

  Future<TerminalLaunchGate?> prepareLaunch({
    required String operationId,
    required String sessionId,
    required String candidateId,
  });

  Future<bool> validateLaunchCapability({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required String attemptId,
    required String launchToken,
  });

  Future<bool> acknowledgeLaunchAbandoned({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required String attemptId,
    required String launchToken,
  });

  Future<TerminalCandidateReceipt> attachProcess({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required String attemptId,
    required String launchToken,
    required int processId,
  });

  Future<TerminalCandidateReceipt> queryReceipt({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required int processId,
  });

  Future<TerminalCandidateReceipt> disposeCandidate({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required int processId,
  });

  Future<TerminalCandidateReceipt> finish({
    required String operationId,
    required String sessionId,
    required String candidateId,
  });

  Future<TerminalCandidateReceipt> cancel({
    required String operationId,
    required String sessionId,
    required String candidateId,
  });

  Future<TerminalCandidateReceipt> acknowledgeFinalReceipt({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required TerminalCandidateReceipt expectedReceipt,
  });
}

enum TerminalContinuationStartOutcome {
  newOperation,
  alreadyActive,
  retired,
  acknowledged,
  cleanupPending,
  conflict,
}

enum TerminalContinuationReason {
  coordinatorUnavailable('COORDINATOR_UNAVAILABLE'),
  ledgerCorrupt('LEDGER_CORRUPT'),
  activeSessionRecord('ACTIVE_SESSION_RECORD'),
  registryRetry('REGISTRY_RETRY'),
  registryConflict('REGISTRY_CONFLICT'),
  cleanupRejected('CLEANUP_REJECTED'),
  serviceNotReady('SERVICE_NOT_READY'),
  unknown('UNKNOWN');

  const TerminalContinuationReason(this.wireName);

  final String wireName;

  static TerminalContinuationReason? fromWire(Object? value) {
    if (value is! String) return null;
    return TerminalContinuationReason.values.firstWhere(
      (reason) => reason.wireName == value,
      orElse: () => TerminalContinuationReason.unknown,
    );
  }
}

final class TerminalContinuationStartResult {
  const TerminalContinuationStartResult(this.outcome, {this.reason});

  final TerminalContinuationStartOutcome outcome;
  final TerminalContinuationReason? reason;
}

final class TerminalLaunchGate {
  const TerminalLaunchGate({
    required this.wrapperPath,
    required this.attemptDirectoryPath,
    required this.stagingPath,
    required this.goPath,
    required this.parentProcessId,
    required this.appUid,
    required this.attemptId,
    required this.launchToken,
  });

  final String wrapperPath;
  final String attemptDirectoryPath;
  final String stagingPath;
  final String goPath;
  final int parentProcessId;
  final int appUid;
  final String attemptId;
  final String launchToken;
}

/// Durable receipt from the native candidate SSOT.
///
/// Only [callerOwns] authorizes Dart to kill. [unknown] and [conflict] are
/// reconciliation states and never imply disposal.
enum TerminalCandidateReceipt {
  nativeOwns,
  nativeDisposed,
  callerOwns,
  acknowledged,
  unknown,
  conflict,
}

extension on TerminalCandidateReceipt {
  bool get isDurable =>
      this == TerminalCandidateReceipt.nativeOwns ||
      this == TerminalCandidateReceipt.nativeDisposed ||
      this == TerminalCandidateReceipt.callerOwns ||
      this == TerminalCandidateReceipt.acknowledged;
}

final class NativeTerminalContinuationBackend
    implements TerminalContinuationBackend {
  const NativeTerminalContinuationBackend();

  @override
  Future<TerminalContinuationStartResult> replace({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required Duration timeout,
  }) async {
    final value = await NativeBridge.replaceTerminalSession(
      operationId: operationId,
      sessionId: sessionId,
      candidateId: candidateId,
      timeout: timeout,
    );
    final outcome = switch (value['outcome']) {
      'NEW' => TerminalContinuationStartOutcome.newOperation,
      'ALREADY_ACTIVE' => TerminalContinuationStartOutcome.alreadyActive,
      'RETIRED' => TerminalContinuationStartOutcome.retired,
      'ACKNOWLEDGED' => TerminalContinuationStartOutcome.acknowledged,
      'RETRYABLE_UNKNOWN' => TerminalContinuationStartOutcome.cleanupPending,
      _ => TerminalContinuationStartOutcome.conflict,
    };
    return TerminalContinuationStartResult(
      outcome,
      reason: TerminalContinuationReason.fromWire(value['reason']),
    );
  }

  @override
  Future<bool> isCurrent({
    required String operationId,
    required String sessionId,
    required String candidateId,
  }) =>
      NativeBridge.isTerminalOperationCurrent(
        operationId: operationId,
        sessionId: sessionId,
        candidateId: candidateId,
      );

  @override
  Future<TerminalLaunchGate?> prepareLaunch({
    required String operationId,
    required String sessionId,
    required String candidateId,
  }) async {
    final value = await NativeBridge.prepareTerminalLaunch(
      operationId: operationId,
      sessionId: sessionId,
      candidateId: candidateId,
    );
    if (value['outcome'] != 'DURABLY_REGISTERED_BACKSTOP_SCHEDULED') {
      throw StateError(
        'durable terminal launch unavailable: '
        '${value['failureReason'] ?? value['outcome'] ?? 'UNKNOWN'}',
      );
    }
    final wrapperPath = value['wrapperPath'];
    final attemptDirectoryPath = value['attemptDirectoryPath'];
    final stagingPath = value['stagingPath'];
    final goPath = value['goPath'];
    final parentProcessId = value['parentProcessId'];
    final appUid = value['appUid'];
    final attemptId = value['attemptId'];
    final launchToken = value['launchToken'];
    if (wrapperPath is! String ||
        attemptDirectoryPath is! String ||
        stagingPath is! String ||
        goPath is! String ||
        parentProcessId is! int ||
        parentProcessId <= 0 ||
        appUid is! int ||
        appUid < 0 ||
        attemptId is! String ||
        attemptId.isEmpty ||
        launchToken is! String ||
        launchToken.isEmpty) {
      return null;
    }
    return TerminalLaunchGate(
      wrapperPath: wrapperPath,
      attemptDirectoryPath: attemptDirectoryPath,
      stagingPath: stagingPath,
      goPath: goPath,
      parentProcessId: parentProcessId,
      appUid: appUid,
      attemptId: attemptId,
      launchToken: launchToken,
    );
  }

  @override
  Future<bool> validateLaunchCapability({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required String attemptId,
    required String launchToken,
  }) =>
      NativeBridge.validateTerminalLaunchCapability(
        operationId: operationId,
        sessionId: sessionId,
        candidateId: candidateId,
        attemptId: attemptId,
        launchToken: launchToken,
      );

  @override
  Future<bool> acknowledgeLaunchAbandoned({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required String attemptId,
    required String launchToken,
  }) =>
      NativeBridge.acknowledgeTerminalLaunchAbandoned(
        operationId: operationId,
        sessionId: sessionId,
        candidateId: candidateId,
        attemptId: attemptId,
        launchToken: launchToken,
      );

  @override
  Future<TerminalCandidateReceipt> attachProcess({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required String attemptId,
    required String launchToken,
    required int processId,
  }) async =>
      _parseReceipt(await NativeBridge.attachTerminalProcess(
        operationId: operationId,
        sessionId: sessionId,
        candidateId: candidateId,
        attemptId: attemptId,
        launchToken: launchToken,
        processId: processId,
      ));

  @override
  Future<TerminalCandidateReceipt> queryReceipt({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required int processId,
  }) async =>
      _parseReceipt(await NativeBridge.terminalCandidateReceipt(
        operationId: operationId,
        sessionId: sessionId,
        candidateId: candidateId,
        processId: processId,
      ));

  @override
  Future<TerminalCandidateReceipt> disposeCandidate({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required int processId,
  }) async =>
      _parseReceipt(await NativeBridge.disposeTerminalProcessCandidate(
        operationId: operationId,
        sessionId: sessionId,
        candidateId: candidateId,
        processId: processId,
      ));

  @override
  Future<TerminalCandidateReceipt> finish({
    required String operationId,
    required String sessionId,
    required String candidateId,
  }) async =>
      _parseReceipt(await NativeBridge.finishTerminalService(
        operationId: operationId,
        sessionId: sessionId,
        candidateId: candidateId,
      ));

  @override
  Future<TerminalCandidateReceipt> cancel({
    required String operationId,
    required String sessionId,
    required String candidateId,
  }) async =>
      _parseReceipt(await NativeBridge.cancelTerminalService(
        operationId: operationId,
        sessionId: sessionId,
        candidateId: candidateId,
      ));

  @override
  Future<TerminalCandidateReceipt> acknowledgeFinalReceipt({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required TerminalCandidateReceipt expectedReceipt,
  }) async =>
      _parseReceipt(await NativeBridge.acknowledgeTerminalFinalReceipt(
        operationId: operationId,
        sessionId: sessionId,
        candidateId: candidateId,
        expectedReceipt: switch (expectedReceipt) {
          TerminalCandidateReceipt.nativeDisposed => 'NATIVE_DISPOSED',
          TerminalCandidateReceipt.callerOwns => 'CALLER_OWNS',
          _ => 'UNKNOWN',
        },
      ));

  static TerminalCandidateReceipt _parseReceipt(String value) =>
      switch (value) {
        'NATIVE_OWNS' => TerminalCandidateReceipt.nativeOwns,
        'NATIVE_DISPOSED' => TerminalCandidateReceipt.nativeDisposed,
        'CALLER_OWNS' => TerminalCandidateReceipt.callerOwns,
        'ACKNOWLEDGED' => TerminalCandidateReceipt.acknowledged,
        'CONFLICT' => TerminalCandidateReceipt.conflict,
        _ => TerminalCandidateReceipt.unknown,
      };
}

typedef TerminalProcessLauncher = TerminalProcessHandle Function(
  Map<String, String> config, {
  required TerminalLaunchGate launchGate,
  required int columns,
  required int rows,
});

/// Process owner for the interactive terminal.
///
/// A screen is only an attachment. Ambiguous native responses retain the exact
/// candidate ID and PTY handle until the durable native receipt is replayed.
class TerminalRuntimeSession {
  TerminalRuntimeSession({
    Terminal? terminal,
    TerminalContinuationBackend backend =
        const NativeTerminalContinuationBackend(),
    Future<Map<String, String>> Function()? configLoader,
    TerminalProcessLauncher? processLauncher,
    String Function()? operationIdFactory,
    String Function()? candidateIdFactory,
    Future<void> Function(Duration)? reconciliationDelay,
    this.receiptCallTimeout = const Duration(seconds: 2),
    this.continuationTimeout = const Duration(minutes: 30),
  })  : terminal = terminal ?? Terminal(maxLines: 10000),
        _backend = backend,
        _configLoader = configLoader ?? TerminalService.getProotShellConfig,
        _processLauncher = processLauncher ?? _launchPty,
        _operationIdFactory = operationIdFactory ?? const Uuid().v4,
        _candidateIdFactory = candidateIdFactory ?? const Uuid().v4,
        _reconciliationDelay = reconciliationDelay ?? Future<void>.delayed;

  static final TerminalRuntimeSession shared = TerminalRuntimeSession();
  static const sessionId = 'interactive-terminal';
  static const _retryDelay = Duration(milliseconds: 250);

  final Terminal terminal;
  final TerminalContinuationBackend _backend;
  final Future<Map<String, String>> Function() _configLoader;
  final TerminalProcessLauncher _processLauncher;
  final String Function() _operationIdFactory;
  final String Function() _candidateIdFactory;
  final Future<void> Function(Duration) _reconciliationDelay;
  final Duration continuationTimeout;
  final Duration receiptCallTimeout;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  TerminalProcessHandle? _process;
  StreamSubscription<List<int>>? _outputSubscription;
  Future<void>? _starting;
  String? _operationId;
  String? _candidateId;
  DateTime? _deadline;
  int _generation = 0;
  bool _loading = false;
  String? _error;

  Stream<void> get changes => _changes.stream;
  bool get loading => _loading;
  String? get error => _error;
  bool get hasActiveProcess => _process != null;
  String? get operationId => _operationId;
  String? get candidateId => _candidateId;

  Future<void> ensureStarted({required int columns, required int rows}) {
    if (_process != null) return Future.value();
    return _starting ??= _start(columns: columns, rows: rows);
  }

  Future<void> restart({required int columns, required int rows}) async {
    await cancel();
    await ensureStarted(columns: columns, rows: rows);
  }

  Future<void> cancel() async {
    ++_generation;
    _loading = true;
    _notify();
    final starting = _starting;
    if (starting != null) {
      final operationId = _operationId;
      final candidateId = _candidateId;
      if (operationId != null && candidateId != null) {
        await _tryReceipt(() => _backend.cancel(
              operationId: operationId,
              sessionId: sessionId,
              candidateId: candidateId,
            ));
      }
      await starting;
      return;
    }

    final process = _process;
    final operationId = _operationId;
    final candidateId = _candidateId;
    if (process == null || operationId == null || candidateId == null) {
      _clearRuntimeState();
      _notify();
      return;
    }
    await _outputSubscription?.cancel();
    _outputSubscription = null;
    await _reconcileCancellation(
      process: process,
      operationId: operationId,
      candidateId: candidateId,
    );
    _clearRuntimeState();
    _notify();
  }

  void write(List<int> data) => _process?.write(data);

  void resize(int rows, int columns) => _process?.resize(rows, columns);

  Future<void> _start({required int columns, required int rows}) async {
    final generation = ++_generation;
    _loading = true;
    _error = null;
    _notify();
    final operationId = _operationIdFactory();
    final candidateId = _candidateIdFactory();
    _operationId = operationId;
    _candidateId = candidateId;
    _deadline = DateTime.now().add(continuationTimeout);
    var leaseStarted = false;
    TerminalLaunchGate? preparedLaunch;
    try {
      final startResult = await _reserveCandidate(
        operationId: operationId,
        candidateId: candidateId,
        generation: generation,
      );
      final startOutcome = startResult.outcome;
      leaseStarted =
          startOutcome == TerminalContinuationStartOutcome.newOperation ||
              startOutcome == TerminalContinuationStartOutcome.alreadyActive;
      if (startOutcome == TerminalContinuationStartOutcome.retired) {
        await _reconcileUnlaunchedCancellation(operationId, candidateId);
      }
      if (generation != _generation) {
        if (leaseStarted) {
          await _reconcileUnlaunchedCancellation(operationId, candidateId);
        }
        return;
      }
      if (!leaseStarted) {
        throw StateError(
          'foreground continuation unavailable: '
          '${startResult.reason?.wireName ?? startOutcome.name}',
        );
      }

      final config = await _configLoader();
      if (generation != _generation) {
        await _reconcileUnlaunchedCancellation(operationId, candidateId);
        return;
      }
      final current = await _backend
          .isCurrent(
            operationId: operationId,
            sessionId: sessionId,
            candidateId: candidateId,
          )
          .timeout(receiptCallTimeout, onTimeout: () => false);
      if (!current) {
        throw StateError('terminal replacement was superseded');
      }
      if (generation != _generation) {
        await _reconcileUnlaunchedCancellation(operationId, candidateId);
        return;
      }
      final launchGate = await _backend
          .prepareLaunch(
            operationId: operationId,
            sessionId: sessionId,
            candidateId: candidateId,
          )
          .timeout(receiptCallTimeout);
      if (launchGate == null) {
        throw StateError('durable terminal launch backstop unavailable');
      }
      preparedLaunch = launchGate;
      if (generation != _generation) {
        await _acknowledgeLaunchAbandoned(
          operationId,
          candidateId,
          launchGate,
        );
        preparedLaunch = null;
        await _reconcileUnlaunchedCancellation(operationId, candidateId);
        return;
      }
      final capabilityCurrent = await _backend
          .validateLaunchCapability(
            operationId: operationId,
            sessionId: sessionId,
            candidateId: candidateId,
            attemptId: launchGate.attemptId,
            launchToken: launchGate.launchToken,
          )
          .timeout(receiptCallTimeout, onTimeout: () => false);
      if (!capabilityCurrent || generation != _generation) {
        await _acknowledgeLaunchAbandoned(
          operationId,
          candidateId,
          launchGate,
        );
        preparedLaunch = null;
        await _reconcileUnlaunchedCancellation(operationId, candidateId);
        return;
      }
      final process = _processLauncher(
        config,
        launchGate: launchGate,
        columns: columns,
        rows: rows,
      );
      preparedLaunch = null;
      _process = process;
      final receipt = await _reconcileLaunchedCandidate(
        process: process,
        operationId: operationId,
        candidateId: candidateId,
        generation: generation,
        launchGate: launchGate,
      );
      if (receipt != TerminalCandidateReceipt.nativeOwns ||
          generation != _generation) {
        if (receipt == TerminalCandidateReceipt.nativeOwns) {
          await _reconcileCancellation(
            process: process,
            operationId: operationId,
            candidateId: candidateId,
          );
        }
        leaseStarted = false;
        _clearRuntimeState();
        if (generation == _generation) {
          throw StateError('foreground continuation lost before PTY attach');
        }
        return;
      }

      _outputSubscription = process.output.listen((data) {
        terminal.write(utf8.decode(data, allowMalformed: true));
      });
      unawaited(process.exitCode.then((code) async {
        if (generation != _generation || !identical(_process, process)) return;
        await _outputSubscription?.cancel();
        _outputSubscription = null;
        terminal.write('\r\n[Process exited with code $code]\r\n');
        await _reconcileFinished(operationId, candidateId, process.pid);
        _clearRuntimeState();
        _notify();
      }));
      _loading = false;
      _notify();
    } catch (e) {
      final abandoned = preparedLaunch;
      if (abandoned != null) {
        await _acknowledgeLaunchAbandoned(
          operationId,
          candidateId,
          abandoned,
        );
        preparedLaunch = null;
      }
      if (leaseStarted && _process == null) {
        await _reconcileUnlaunchedCancellation(operationId, candidateId);
      }
      if (generation == _generation) {
        _clearRuntimeState();
        _error = 'Failed to start terminal: $e';
        _notify();
      }
    } finally {
      _starting = null;
    }
  }

  Future<void> _acknowledgeLaunchAbandoned(
    String operationId,
    String candidateId,
    TerminalLaunchGate launchGate,
  ) async {
    try {
      await _backend
          .acknowledgeLaunchAbandoned(
            operationId: operationId,
            sessionId: sessionId,
            candidateId: candidateId,
            attemptId: launchGate.attemptId,
            launchToken: launchGate.launchToken,
          )
          .timeout(receiptCallTimeout);
    } catch (_) {
      // The durable parent-generation record remains fail-closed and the
      // coordinator/job retries after process or parent loss.
    }
  }

  Future<TerminalContinuationStartResult> _reserveCandidate({
    required String operationId,
    required String candidateId,
    required int generation,
  }) async {
    TerminalContinuationReason? pendingReason;
    while (true) {
      if (generation != _generation || _deadlineExpired) {
        final receipt = await _tryReceipt(() => _backend.cancel(
              operationId: operationId,
              sessionId: sessionId,
              candidateId: candidateId,
            ));
        if (receipt == TerminalCandidateReceipt.callerOwns) {
          await _acknowledgeFinalReceipt(operationId, candidateId, receipt);
          return TerminalContinuationStartResult(
            TerminalContinuationStartOutcome.retired,
            reason: pendingReason,
          );
        }
        if (receipt == TerminalCandidateReceipt.nativeDisposed) {
          await _acknowledgeFinalReceipt(operationId, candidateId, receipt);
          return TerminalContinuationStartResult(
            TerminalContinuationStartOutcome.retired,
            reason: pendingReason,
          );
        }
        if (receipt == TerminalCandidateReceipt.acknowledged) {
          return TerminalContinuationStartResult(
            TerminalContinuationStartOutcome.acknowledged,
            reason: pendingReason,
          );
        }
        if (receipt == TerminalCandidateReceipt.unknown) {
          // Materialize this exact candidate before retrying cancellation.
          // This closes cancel-before-reserve without inventing CALLER_OWNS
          // for an old acknowledged candidate.
          try {
            await _backend
                .replace(
                  operationId: operationId,
                  sessionId: sessionId,
                  candidateId: candidateId,
                  timeout: continuationTimeout,
                )
                .timeout(receiptCallTimeout);
          } catch (_) {
            // The next exact cancel/replace retry reconciles lost replies.
          }
        }
        await _reconciliationDelay(_retryDelay);
        continue;
      }
      try {
        final result = await _backend
            .replace(
              operationId: operationId,
              sessionId: sessionId,
              candidateId: candidateId,
              timeout: continuationTimeout,
            )
            .timeout(receiptCallTimeout);
        if (result.outcome == TerminalContinuationStartOutcome.cleanupPending) {
          pendingReason = result.reason ?? pendingReason;
          await _reconciliationDelay(_retryDelay);
          continue;
        }
        return result;
      } catch (_) {
        await _reconciliationDelay(_retryDelay);
      }
    }
  }

  Future<TerminalCandidateReceipt> _reconcileLaunchedCandidate({
    required TerminalProcessHandle process,
    required String operationId,
    required String candidateId,
    required int generation,
    required TerminalLaunchGate launchGate,
  }) async {
    var phase = 0;
    var callerKilled = false;
    while (true) {
      final cancelling = generation != _generation || _deadlineExpired;
      late final TerminalCandidateReceipt receipt;
      if (cancelling) {
        receipt = await _tryReceipt(() => _backend.cancel(
              operationId: operationId,
              sessionId: sessionId,
              candidateId: candidateId,
            ));
      } else if (phase % 3 == 0) {
        receipt = await _tryReceipt(() => _backend.attachProcess(
              operationId: operationId,
              sessionId: sessionId,
              candidateId: candidateId,
              attemptId: launchGate.attemptId,
              launchToken: launchGate.launchToken,
              processId: process.pid,
            ));
      } else if (phase % 3 == 1) {
        receipt = await _tryReceipt(() => _backend.queryReceipt(
              operationId: operationId,
              sessionId: sessionId,
              candidateId: candidateId,
              processId: process.pid,
            ));
      } else {
        receipt = await _tryReceipt(() => _backend.disposeCandidate(
              operationId: operationId,
              sessionId: sessionId,
              candidateId: candidateId,
              processId: process.pid,
            ));
      }
      phase++;
      if (receipt == TerminalCandidateReceipt.callerOwns) {
        if (!callerKilled) {
          process.kill();
          callerKilled = true;
        }
        if (identical(_process, process)) _process = null;
        await _acknowledgeFinalReceipt(operationId, candidateId, receipt);
        return receipt;
      }
      if (receipt == TerminalCandidateReceipt.nativeDisposed) {
        if (identical(_process, process)) _process = null;
        await _acknowledgeFinalReceipt(operationId, candidateId, receipt);
        return receipt;
      }
      if (receipt == TerminalCandidateReceipt.acknowledged) {
        if (identical(_process, process)) _process = null;
        return receipt;
      }
      if (receipt == TerminalCandidateReceipt.nativeOwns && !cancelling) {
        return receipt;
      }
      await _reconciliationDelay(_retryDelay);
    }
  }

  Future<void> _reconcileCancellation({
    required TerminalProcessHandle process,
    required String operationId,
    required String candidateId,
  }) async {
    var callerKilled = false;
    while (true) {
      var receipt = await _tryReceipt(() => _backend.cancel(
            operationId: operationId,
            sessionId: sessionId,
            candidateId: candidateId,
          ));
      if (!receipt.isDurable ||
          receipt == TerminalCandidateReceipt.nativeOwns) {
        receipt = await _tryReceipt(() => _backend.queryReceipt(
              operationId: operationId,
              sessionId: sessionId,
              candidateId: candidateId,
              processId: process.pid,
            ));
      }
      if (receipt == TerminalCandidateReceipt.callerOwns) {
        if (!callerKilled) {
          process.kill();
          callerKilled = true;
        }
        if (identical(_process, process)) _process = null;
        await _acknowledgeFinalReceipt(operationId, candidateId, receipt);
        return;
      }
      if (receipt == TerminalCandidateReceipt.nativeDisposed) {
        if (identical(_process, process)) _process = null;
        await _acknowledgeFinalReceipt(operationId, candidateId, receipt);
        return;
      }
      if (receipt == TerminalCandidateReceipt.acknowledged) {
        if (identical(_process, process)) _process = null;
        return;
      }
      await _reconciliationDelay(_retryDelay);
    }
  }

  Future<void> _reconcileUnlaunchedCancellation(
    String operationId,
    String candidateId,
  ) async {
    while (true) {
      final receipt = await _tryReceipt(() => _backend.cancel(
            operationId: operationId,
            sessionId: sessionId,
            candidateId: candidateId,
          ));
      if (receipt == TerminalCandidateReceipt.callerOwns) {
        await _acknowledgeFinalReceipt(operationId, candidateId, receipt);
        return;
      }
      if (receipt == TerminalCandidateReceipt.nativeDisposed) {
        await _acknowledgeFinalReceipt(operationId, candidateId, receipt);
        return;
      }
      if (receipt == TerminalCandidateReceipt.acknowledged) return;
      await _reconciliationDelay(_retryDelay);
    }
  }

  Future<void> _reconcileFinished(
    String operationId,
    String candidateId,
    int processId,
  ) async {
    while (true) {
      var receipt = await _tryReceipt(() => _backend.finish(
            operationId: operationId,
            sessionId: sessionId,
            candidateId: candidateId,
          ));
      if (receipt == TerminalCandidateReceipt.callerOwns) {
        _process = null;
        await _acknowledgeFinalReceipt(operationId, candidateId, receipt);
        return;
      }
      if (receipt == TerminalCandidateReceipt.nativeDisposed) {
        _process = null;
        await _acknowledgeFinalReceipt(operationId, candidateId, receipt);
        return;
      }
      if (receipt == TerminalCandidateReceipt.acknowledged) {
        _process = null;
        return;
      }
      receipt = await _tryReceipt(() => _backend.queryReceipt(
            operationId: operationId,
            sessionId: sessionId,
            candidateId: candidateId,
            processId: processId,
          ));
      if (receipt == TerminalCandidateReceipt.nativeDisposed) {
        _process = null;
        await _acknowledgeFinalReceipt(operationId, candidateId, receipt);
        return;
      }
      if (receipt == TerminalCandidateReceipt.acknowledged) {
        _process = null;
        return;
      }
      await _reconciliationDelay(_retryDelay);
    }
  }

  Future<void> _acknowledgeFinalReceipt(
    String operationId,
    String candidateId,
    TerminalCandidateReceipt expectedReceipt,
  ) async {
    while (true) {
      final receipt = await _tryReceipt(() => _backend.acknowledgeFinalReceipt(
            operationId: operationId,
            sessionId: sessionId,
            candidateId: candidateId,
            expectedReceipt: expectedReceipt,
          ));
      if (receipt == expectedReceipt ||
          receipt == TerminalCandidateReceipt.acknowledged) {
        return;
      }
      await _reconciliationDelay(_retryDelay);
    }
  }

  Future<TerminalCandidateReceipt> _tryReceipt(
    Future<TerminalCandidateReceipt> Function() action,
  ) async {
    try {
      return await action().timeout(receiptCallTimeout);
    } catch (_) {
      return TerminalCandidateReceipt.unknown;
    }
  }

  bool get _deadlineExpired {
    final deadline = _deadline;
    return deadline != null && !DateTime.now().isBefore(deadline);
  }

  void _clearRuntimeState() {
    _process = null;
    _operationId = null;
    _candidateId = null;
    _deadline = null;
    _loading = false;
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static TerminalProcessHandle _launchPty(
    Map<String, String> config, {
    required TerminalLaunchGate launchGate,
    required int columns,
    required int rows,
  }) {
    final args = TerminalService.buildProotArgs(
      config,
      columns: columns,
      rows: rows,
    );
    return FlutterPtyProcessHandle(Pty.start(
      '/system/bin/sh',
      arguments: <String>[
        launchGate.wrapperPath,
        launchGate.attemptDirectoryPath,
        launchGate.launchToken,
        launchGate.parentProcessId.toString(),
        launchGate.appUid.toString(),
        '--',
        config['executable']!,
        ...args,
      ],
      environment: TerminalService.buildHostEnv(config),
      columns: columns,
      rows: rows,
    ));
  }
}
