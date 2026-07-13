import 'dart:async';
import 'dart:io';

import 'package:clawchat/services/terminal_runtime_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'CLI loopback callback completes in background and recreation does not duplicate',
      () async {
    final callbackServer =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(callbackServer.close);
    var configuredCommits = 0;
    final callbackHandled = Completer<void>();
    callbackServer.listen((request) async {
      configuredCommits++;
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      if (!callbackHandled.isCompleted) callbackHandled.complete();
    });

    final backend = _FakeContinuationBackend();
    final process = _FakeTerminalProcess(71);
    var launches = 0;
    final runtime = _runtime(
      backend: backend,
      operationId: 'terminal-loopback-operation',
      candidateId: 'terminal-loopback-candidate',
      processLauncher: () {
        launches++;
        return process;
      },
    );

    await runtime.ensureStarted(columns: 80, rows: 24);
    await runtime.ensureStarted(columns: 120, rows: 40);
    await runtime.ensureStarted(columns: 60, rows: 20);
    expect(launches, 1);
    expect(backend.attachedCandidates, ['terminal-loopback-candidate']);

    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.getUrl(Uri.parse(
      'http://${callbackServer.address.address}:${callbackServer.port}/callback',
    ));
    final response = await request.close();
    await response.drain<void>();
    await callbackHandled.future;
    expect(configuredCommits, 1);

    process.complete(0);
    await pumpEventQueue();
    expect(backend.finishes, ['terminal-loopback-candidate']);
    expect(runtime.hasActiveProcess, isFalse);
  });

  test('foreground notification failure is fail closed before PTY launch',
      () async {
    final backend = _FakeContinuationBackend(
      replaceOutcome: TerminalContinuationStartOutcome.conflict,
    );
    var launches = 0;
    final runtime = _runtime(
      backend: backend,
      operationId: 'failed-operation',
      candidateId: 'failed-candidate',
      processLauncher: () {
        launches++;
        return _FakeTerminalProcess(8);
      },
    );
    await runtime.ensureStarted(columns: 80, rows: 24);
    expect(launches, 0);
    expect(runtime.error, contains('foreground continuation unavailable'));
  });

  test('durable launch scheduler rejection creates no PTY child', () async {
    final backend = _FakeContinuationBackend()..launchGate = null;
    var launches = 0;
    final runtime = _runtime(
      backend: backend,
      operationId: 'operation-scheduler-rejected',
      candidateId: 'candidate-scheduler-rejected',
      processLauncher: () {
        launches++;
        return _FakeTerminalProcess(12);
      },
    );

    await runtime.ensureStarted(columns: 80, rows: 24);

    expect(launches, 0);
    expect(runtime.error, contains('durable terminal launch backstop'));
    expect(runtime.hasActiveProcess, isFalse);
  });

  test('revoked exact capability is revalidated before PTY factory', () async {
    final backend = _FakeContinuationBackend()..capabilityValid = false;
    var launches = 0;
    final runtime = _runtime(
      backend: backend,
      operationId: 'operation-revoked-capability',
      candidateId: 'candidate-revoked-capability',
      processLauncher: () {
        launches++;
        return _FakeTerminalProcess(13);
      },
    );

    await runtime.ensureStarted(columns: 80, rows: 24);

    expect(launches, 0);
    expect(runtime.hasActiveProcess, isFalse);
    expect(backend.abandonedLaunchAcks, 1);
  });

  test('PTY factory failure exact-acks issued capability as abandoned',
      () async {
    final backend = _FakeContinuationBackend();
    final runtime = _runtime(
      backend: backend,
      operationId: 'operation-pty-factory-failure',
      candidateId: 'candidate-pty-factory-failure',
      processLauncher: () => throw StateError('injected pre-spawn failure'),
    );

    await runtime.ensureStarted(columns: 80, rows: 24);

    expect(backend.abandonedLaunchAcks, 1);
    expect(runtime.hasActiveProcess, isFalse);
    expect(runtime.error, contains('injected pre-spawn failure'));
  });

  test('replacement cleanup pending retries exact candidate before PTY launch',
      () async {
    final backend = _FakeContinuationBackend()
      ..replacePlan.add(TerminalContinuationStartOutcome.cleanupPending);
    var launches = 0;
    final runtime = _runtime(
      backend: backend,
      operationId: 'cleanup-pending-operation',
      candidateId: 'cleanup-pending-candidate',
      processLauncher: () {
        launches++;
        return _FakeTerminalProcess(9);
      },
    );
    await runtime.ensureStarted(columns: 80, rows: 24);
    expect(backend.replaceCalls, 2);
    expect(backend.currentCandidateId, 'cleanup-pending-candidate');
    expect(launches, 1);
  });

  test('fresh engine atomically retires old candidate before replacement',
      () async {
    final backend = _FakeContinuationBackend(
      initialOperationId: 'old-operation',
      initialCandidateId: 'old-candidate',
      initialReceipt: TerminalCandidateReceipt.nativeOwns,
    );
    final process = _FakeTerminalProcess(17);
    final runtime = _runtime(
      backend: backend,
      operationId: 'new-operation',
      candidateId: 'new-candidate',
      processLauncher: () => process,
    );
    await runtime.ensureStarted(columns: 80, rows: 24);
    expect(backend.receipts['old-candidate'],
        TerminalCandidateReceipt.nativeDisposed);
    expect(backend.nativeKillCount, 1);
    expect(runtime.candidateId, 'new-candidate');
    expect(runtime.hasActiveProcess, isTrue);
  });

  test('explicit cancel after native ownership never kills from Dart',
      () async {
    final backend = _FakeContinuationBackend();
    final process = _FakeTerminalProcess(11);
    final runtime = _runtime(
      backend: backend,
      operationId: 'cancelled-operation',
      candidateId: 'cancelled-candidate',
      processLauncher: () => process,
    );
    await runtime.ensureStarted(columns: 80, rows: 24);
    await runtime.cancel();
    expect(process.killCount, 0);
    expect(backend.nativeKillCount, 1);
    expect(backend.receipts['cancelled-candidate'],
        TerminalCandidateReceipt.nativeDisposed);
    expect(backend.acknowledgedCandidates, ['cancelled-candidate']);
    expect(
      await backend.cancel(
        operationId: 'cancelled-operation',
        sessionId: TerminalRuntimeSession.sessionId,
        candidateId: 'cancelled-candidate',
      ),
      TerminalCandidateReceipt.acknowledged,
    );
    expect(process.killCount, 0);
  });

  test('stale runtime clears without kill after another path acknowledges',
      () async {
    final backend = _FakeContinuationBackend();
    final process = _FakeTerminalProcess(12);
    final runtime = _runtime(
      backend: backend,
      operationId: 'externally-acknowledged-operation',
      candidateId: 'externally-acknowledged-candidate',
      processLauncher: () => process,
    );
    await runtime.ensureStarted(columns: 80, rows: 24);
    backend.nativeCancel('externally-acknowledged-candidate');
    expect(
      await backend.acknowledgeFinalReceipt(
        operationId: 'externally-acknowledged-operation',
        sessionId: TerminalRuntimeSession.sessionId,
        candidateId: 'externally-acknowledged-candidate',
        expectedReceipt: TerminalCandidateReceipt.nativeDisposed,
      ),
      TerminalCandidateReceipt.nativeDisposed,
    );

    await runtime.cancel();
    expect(process.killCount, 0);
    expect(backend.nativeKillCount, 1);
    expect(runtime.hasActiveProcess, isFalse);
  });

  test('two fresh engines supersede before older PTY launch', () async {
    final backend = _FakeContinuationBackend();
    final firstConfig = Completer<Map<String, String>>();
    var firstLaunches = 0;
    final first = TerminalRuntimeSession(
      backend: backend,
      operationIdFactory: () => 'engine-one',
      candidateIdFactory: () => 'candidate-one',
      configLoader: () => firstConfig.future,
      reconciliationDelay: (_) async {},
      processLauncher: (
        _, {
        required launchGate,
        required columns,
        required rows,
      }) {
        firstLaunches++;
        return _FakeTerminalProcess(101);
      },
    );
    final secondProcess = _FakeTerminalProcess(202);
    final second = _runtime(
      backend: backend,
      operationId: 'engine-two',
      candidateId: 'candidate-two',
      processLauncher: () => secondProcess,
    );
    final firstStart = first.ensureStarted(columns: 80, rows: 24);
    await pumpEventQueue();
    await second.ensureStarted(columns: 80, rows: 24);
    firstConfig.complete(const {});
    await firstStart;
    expect(firstLaunches, 0);
    expect(backend.currentCandidateId, 'candidate-two');
    expect(backend.attachedCandidates, ['candidate-two']);
    expect(
        backend.receipts['candidate-one'], TerminalCandidateReceipt.callerOwns);
  });

  test('cancel while replacement reply is pending reconciles late reservation',
      () async {
    final replacement = Completer<TerminalContinuationStartOutcome>();
    final backend = _FakeContinuationBackend()
      ..replaceFuture = replacement.future;
    final process = _FakeTerminalProcess(250);
    final runtime = _runtime(
      backend: backend,
      operationId: 'late-reservation',
      candidateId: 'candidate-late-reservation',
      processLauncher: () => process,
    );
    final starting = runtime.ensureStarted(columns: 80, rows: 24);
    await pumpEventQueue();
    final cancelling = runtime.cancel();
    await pumpEventQueue();
    replacement.complete(TerminalContinuationStartOutcome.newOperation);
    await Future.wait([starting, cancelling]);
    expect(process.killCount, 0);
    expect(backend.receipts['candidate-late-reservation'],
        TerminalCandidateReceipt.callerOwns);
    expect(runtime.hasActiveProcess, isFalse);
  });

  test('native rejection transfers disposal to Dart exactly once', () async {
    final backend = _FakeContinuationBackend()
      ..attachPlan.add(_Response.value(TerminalCandidateReceipt.callerOwns));
    final process = _FakeTerminalProcess(303);
    final runtime = _runtime(
      backend: backend,
      operationId: 'rejected-attach',
      candidateId: 'rejected-candidate',
      processLauncher: () => process,
    );
    await runtime.ensureStarted(columns: 80, rows: 24);
    expect(process.killCount, 1);
    expect(backend.nativeKillCount, 0);
    expect(runtime.hasActiveProcess, isFalse);
    expect(backend.acknowledgedCandidates, ['rejected-candidate']);
    expect(
      await backend.queryReceipt(
        operationId: 'rejected-attach',
        sessionId: TerminalRuntimeSession.sessionId,
        candidateId: 'rejected-candidate',
        processId: process.pid,
      ),
      TerminalCandidateReceipt.acknowledged,
    );
    expect(process.killCount, 1);
  });

  test(
      'attach query and dispose unavailable retain exact handle until caller receipt',
      () async {
    final eventual = Completer<TerminalCandidateReceipt>();
    final backend = _FakeContinuationBackend()
      ..attachPlan.add(_Response.failure())
      ..queryPlan.add(_Response.failure())
      ..disposePlan.add(_Response.failure())
      ..attachPlan.add(_Response.future(eventual.future));
    final process = _FakeTerminalProcess(401);
    final runtime = _runtime(
      backend: backend,
      operationId: 'before-delivery',
      candidateId: 'candidate-before-delivery',
      processLauncher: () => process,
    );
    final starting = runtime.ensureStarted(columns: 80, rows: 24);
    await pumpEventQueue(times: 20);
    expect(runtime.hasActiveProcess, isTrue);
    expect(runtime.candidateId, 'candidate-before-delivery');
    expect(process.killCount, 0);
    eventual.complete(TerminalCandidateReceipt.callerOwns);
    await starting;
    expect(process.killCount, 1);
    expect(runtime.hasActiveProcess, isFalse);
  });

  test(
      'accepted attach reply lost then cancel consumes durable native disposed receipt',
      () async {
    final blockedQuery = Completer<TerminalCandidateReceipt>();
    final backend = _FakeContinuationBackend()
      ..attachPlan.add(_Response.lost(TerminalCandidateReceipt.nativeOwns))
      ..queryPlan.add(_Response.future(blockedQuery.future));
    final process = _FakeTerminalProcess(402);
    final runtime = _runtime(
      backend: backend,
      operationId: 'accepted-lost',
      candidateId: 'candidate-accepted-lost',
      processLauncher: () => process,
    );
    final starting = runtime.ensureStarted(columns: 80, rows: 24);
    await pumpEventQueue(times: 10);
    expect(backend.receipts['candidate-accepted-lost'],
        TerminalCandidateReceipt.nativeOwns);
    final cancelling = runtime.cancel();
    await pumpEventQueue();
    expect(backend.receipts['candidate-accepted-lost'],
        TerminalCandidateReceipt.nativeDisposed);
    blockedQuery.complete(TerminalCandidateReceipt.nativeDisposed);
    await Future.wait([starting, cancelling]);
    expect(process.killCount, 0);
    expect(backend.nativeKillCount, 1);
  });

  test('fresh engine replacement resolves older lost attach without Dart kill',
      () async {
    final oldQuery = Completer<TerminalCandidateReceipt>();
    final backend = _FakeContinuationBackend()
      ..attachPlan.add(_Response.lost(TerminalCandidateReceipt.nativeOwns))
      ..queryPlan.add(_Response.future(oldQuery.future));
    final oldProcess = _FakeTerminalProcess(405);
    final oldRuntime = _runtime(
      backend: backend,
      operationId: 'old-lost-operation',
      candidateId: 'old-lost-candidate',
      processLauncher: () => oldProcess,
    );
    final oldStart = oldRuntime.ensureStarted(columns: 80, rows: 24);
    await pumpEventQueue(times: 10);
    expect(backend.receipts['old-lost-candidate'],
        TerminalCandidateReceipt.nativeOwns);

    final newProcess = _FakeTerminalProcess(406);
    final newRuntime = _runtime(
      backend: backend,
      operationId: 'new-retry-operation',
      candidateId: 'new-retry-candidate',
      processLauncher: () => newProcess,
    );
    await newRuntime.ensureStarted(columns: 80, rows: 24);
    expect(backend.receipts['old-lost-candidate'],
        TerminalCandidateReceipt.nativeDisposed);
    oldQuery.complete(TerminalCandidateReceipt.nativeDisposed);
    await oldStart;
    expect(oldProcess.killCount, 0);
    expect(backend.nativeKillCount, 1);
    expect(newRuntime.hasActiveProcess, isTrue);
  });

  test('dispose CONFLICT is not treated as native disposal', () async {
    final dispose = Completer<TerminalCandidateReceipt>();
    final eventual = Completer<TerminalCandidateReceipt>();
    final backend = _FakeContinuationBackend()
      ..attachPlan.add(_Response.failure())
      ..queryPlan.add(_Response.value(TerminalCandidateReceipt.unknown))
      ..disposePlan.add(_Response.future(dispose.future))
      ..attachPlan.add(_Response.future(eventual.future));
    final process = _FakeTerminalProcess(403);
    final runtime = _runtime(
      backend: backend,
      operationId: 'dispose-conflict',
      candidateId: 'candidate-dispose-conflict',
      processLauncher: () => process,
    );
    final starting = runtime.ensureStarted(columns: 80, rows: 24);
    await pumpEventQueue();
    dispose.complete(TerminalCandidateReceipt.conflict);
    await pumpEventQueue(times: 10);
    expect(process.killCount, 0);
    expect(runtime.hasActiveProcess, isTrue);
    eventual.complete(TerminalCandidateReceipt.callerOwns);
    await starting;
    expect(process.killCount, 1);
  });

  test('cancellation during unknown keeps reconciliation until later receipt',
      () async {
    final blockedAttach = Completer<TerminalCandidateReceipt>();
    final laterCancel = Completer<TerminalCandidateReceipt>();
    final backend = _FakeContinuationBackend()
      ..attachPlan.add(_Response.future(blockedAttach.future))
      ..cancelPlan.add(_Response.failure())
      ..cancelPlan.add(_Response.future(laterCancel.future));
    final process = _FakeTerminalProcess(404);
    final runtime = _runtime(
      backend: backend,
      operationId: 'pending-cancel',
      candidateId: 'candidate-pending-cancel',
      receiptCallTimeout: const Duration(milliseconds: 5),
      processLauncher: () => process,
    );
    final starting = runtime.ensureStarted(columns: 80, rows: 24);
    await pumpEventQueue();
    final cancelling = runtime.cancel();
    await pumpEventQueue();
    expect(runtime.hasActiveProcess, isTrue);
    expect(process.killCount, 0);
    laterCancel.complete(TerminalCandidateReceipt.callerOwns);
    await Future.wait([starting, cancelling]);
    expect(process.killCount, 1);
    expect(runtime.hasActiveProcess, isFalse);
    if (!blockedAttach.isCompleted) {
      blockedAttach.complete(TerminalCandidateReceipt.unknown);
    }
  });

  test('ack after expiry with lost reply replays after another 35m pause',
      () async {
    final backend = _FakeContinuationBackend()
      ..attachPlan.add(_Response.lost(TerminalCandidateReceipt.nativeOwns))
      ..loseNextAckReply = true
      ..pauseChannelAfterLostAck = true;
    final process = _FakeTerminalProcess(407);
    late final TerminalRuntimeSession runtime;
    backend.beforeAcknowledge = (candidateId, receipt) {
      expect(candidateId, 'candidate-long-pause');
      expect(receipt, TerminalCandidateReceipt.nativeDisposed);
      expect(runtime.hasActiveProcess, isFalse);
      expect(process.killCount, 0);
    };
    runtime = _runtime(
      backend: backend,
      operationId: 'operation-long-pause',
      candidateId: 'candidate-long-pause',
      receiptCallTimeout: const Duration(milliseconds: 5),
      processLauncher: () => process,
    );

    final starting = runtime.ensureStarted(columns: 80, rows: 24);
    await pumpEventQueue(times: 10);
    expect(backend.receipts['candidate-long-pause'],
        TerminalCandidateReceipt.nativeOwns);

    backend.channelsAvailable = false;
    backend.nativeCancel('candidate-long-pause');
    final cancelling = runtime.cancel();
    await pumpEventQueue(times: 20);
    backend.advance(const Duration(minutes: 36));
    expect(backend.receipts['candidate-long-pause'],
        TerminalCandidateReceipt.nativeDisposed);
    expect(backend.acknowledgedCandidates, isEmpty);
    expect(backend.nativeKillCount, 1);
    expect(process.killCount, 0);
    expect(runtime.hasActiveProcess, isTrue);

    backend.channelsAvailable = true;
    await pumpEventQueue(times: 30);
    expect(backend.acknowledgedCandidates, ['candidate-long-pause']);
    expect(backend.channelsAvailable, isFalse);
    expect(runtime.hasActiveProcess, isFalse);
    backend.advance(const Duration(minutes: 36));
    expect(backend.receipts['candidate-long-pause'],
        TerminalCandidateReceipt.nativeDisposed);
    backend.channelsAvailable = true;
    await Future.wait([starting, cancelling]);
    expect(backend.acknowledgedCandidates, ['candidate-long-pause']);
    expect(backend.ackCalls, greaterThanOrEqualTo(2));
    expect(backend.receipts['candidate-long-pause'],
        TerminalCandidateReceipt.nativeDisposed);
    expect(backend.nativeKillCount, 1);
    expect(process.killCount, 0);
    expect(runtime.hasActiveProcess, isFalse);
    expect(
      await backend.queryReceipt(
        operationId: 'operation-long-pause',
        sessionId: TerminalRuntimeSession.sessionId,
        candidateId: 'candidate-long-pause',
        processId: process.pid,
      ),
      TerminalCandidateReceipt.acknowledged,
    );
    expect(
      await backend.acknowledgeFinalReceipt(
        operationId: 'operation-long-pause',
        sessionId: TerminalRuntimeSession.sessionId,
        candidateId: 'candidate-long-pause',
        expectedReceipt: TerminalCandidateReceipt.nativeDisposed,
      ),
      TerminalCandidateReceipt.nativeDisposed,
    );
  });
}

TerminalRuntimeSession _runtime({
  required _FakeContinuationBackend backend,
  required String operationId,
  required String candidateId,
  required _FakeTerminalProcess Function() processLauncher,
  Duration receiptCallTimeout = const Duration(seconds: 2),
}) =>
    TerminalRuntimeSession(
      backend: backend,
      operationIdFactory: () => operationId,
      candidateIdFactory: () => candidateId,
      receiptCallTimeout: receiptCallTimeout,
      configLoader: () async => const {},
      reconciliationDelay: (_) async {
        await Future<void>.delayed(Duration.zero);
      },
      processLauncher: (
        _, {
        required launchGate,
        required columns,
        required rows,
      }) =>
          processLauncher(),
    );

final class _Response {
  const _Response._(this.receipt, this.error, this.future, this.lostReply);

  factory _Response.value(TerminalCandidateReceipt receipt) =>
      _Response._(receipt, null, null, false);
  factory _Response.failure() =>
      _Response._(null, StateError('transport unavailable'), null, false);
  factory _Response.future(Future<TerminalCandidateReceipt> future) =>
      _Response._(null, null, future, false);
  factory _Response.lost(TerminalCandidateReceipt applied) =>
      _Response._(applied, null, null, true);

  final TerminalCandidateReceipt? receipt;
  final Object? error;
  final Future<TerminalCandidateReceipt>? future;
  final bool lostReply;
}

final class _FakeContinuationBackend implements TerminalContinuationBackend {
  _FakeContinuationBackend({
    this.replaceOutcome = TerminalContinuationStartOutcome.newOperation,
    String? initialOperationId,
    String? initialCandidateId,
    TerminalCandidateReceipt? initialReceipt,
  })  : currentOperationId = initialOperationId,
        currentCandidateId = initialCandidateId {
    if (initialCandidateId != null && initialReceipt != null) {
      receipts[initialCandidateId] = initialReceipt;
    }
  }

  final TerminalContinuationStartOutcome replaceOutcome;
  TerminalLaunchGate? launchGate = const TerminalLaunchGate(
    wrapperPath: '/private/wrapper',
    attemptDirectoryPath: '/private/attempt',
    stagingPath: '/private/candidate.pid',
    goPath: '/private/candidate.go',
    parentProcessId: 1234,
    appUid: 10000,
    attemptId: 'attempt-id',
    launchToken: 'launch-token',
  );
  int replaceCalls = 0;
  final List<TerminalContinuationStartOutcome> replacePlan = [];
  Future<TerminalContinuationStartOutcome>? replaceFuture;
  String? currentOperationId;
  String? currentCandidateId;
  int nativeKillCount = 0;
  int _nowMs = 0;
  bool channelsAvailable = true;
  bool capabilityValid = true;
  int abandonedLaunchAcks = 0;
  bool loseNextAckReply = false;
  bool pauseChannelAfterLostAck = false;
  int ackCalls = 0;
  void Function(String, TerminalCandidateReceipt)? beforeAcknowledge;
  final Map<String, TerminalCandidateReceipt> receipts = {};
  final Map<String, int> _receiptExpiryMs = {};
  final Set<String> _acknowledged = {};
  final List<String> acknowledgedCandidates = [];
  final List<String> attachedCandidates = [];
  final List<String> finishes = [];
  final List<_Response> attachPlan = [];
  final List<_Response> queryPlan = [];
  final List<_Response> disposePlan = [];
  final List<_Response> cancelPlan = [];

  @override
  Future<TerminalContinuationStartOutcome> replace({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required Duration timeout,
  }) async {
    _requireChannel();
    replaceCalls++;
    if (_acknowledged.contains(candidateId)) {
      return TerminalContinuationStartOutcome.acknowledged;
    }
    if (replacePlan.isNotEmpty) return replacePlan.removeAt(0);
    if (replaceOutcome != TerminalContinuationStartOutcome.newOperation) {
      return replaceOutcome;
    }
    final oldCandidate = currentCandidateId;
    if (oldCandidate != null && oldCandidate != candidateId) {
      if (receipts[oldCandidate] == TerminalCandidateReceipt.nativeOwns) {
        nativeKillCount++;
        receipts[oldCandidate] = TerminalCandidateReceipt.nativeDisposed;
      } else {
        receipts[oldCandidate] = TerminalCandidateReceipt.callerOwns;
      }
    }
    currentOperationId = operationId;
    currentCandidateId = candidateId;
    _receiptExpiryMs[candidateId] = _nowMs +
        timeout.inMilliseconds +
        const Duration(minutes: 5).inMilliseconds;
    return replaceFuture ?? TerminalContinuationStartOutcome.newOperation;
  }

  @override
  Future<bool> isCurrent({
    required String operationId,
    required String sessionId,
    required String candidateId,
  }) async =>
      channelsAvailable &&
      currentOperationId == operationId &&
      currentCandidateId == candidateId;

  @override
  Future<TerminalLaunchGate?> prepareLaunch({
    required String operationId,
    required String sessionId,
    required String candidateId,
  }) async =>
      launchGate;

  @override
  Future<bool> validateLaunchCapability({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required String attemptId,
    required String launchToken,
  }) async =>
      channelsAvailable &&
      capabilityValid &&
      launchGate?.attemptId == attemptId &&
      launchGate?.launchToken == launchToken;

  @override
  Future<bool> acknowledgeLaunchAbandoned({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required String attemptId,
    required String launchToken,
  }) async {
    abandonedLaunchAcks++;
    return launchGate?.attemptId == attemptId &&
        launchGate?.launchToken == launchToken;
  }

  @override
  Future<TerminalCandidateReceipt> attachProcess({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required String attemptId,
    required String launchToken,
    required int processId,
  }) async {
    _requireChannel();
    attachedCandidates.add(candidateId);
    if (_acknowledged.contains(candidateId)) {
      return TerminalCandidateReceipt.acknowledged;
    }
    if (attachPlan.isNotEmpty) {
      return _respond(attachPlan.removeAt(0), candidateId, apply: true);
    }
    if (currentOperationId != operationId ||
        currentCandidateId != candidateId) {
      return receipts[candidateId] ?? TerminalCandidateReceipt.conflict;
    }
    receipts[candidateId] = TerminalCandidateReceipt.nativeOwns;
    return TerminalCandidateReceipt.nativeOwns;
  }

  @override
  Future<TerminalCandidateReceipt> queryReceipt({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required int processId,
  }) async {
    _requireChannel();
    if (queryPlan.isNotEmpty) {
      return _respond(queryPlan.removeAt(0), candidateId);
    }
    return _ordinaryReceipt(candidateId);
  }

  @override
  Future<TerminalCandidateReceipt> disposeCandidate({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required int processId,
  }) async {
    _requireChannel();
    if (_acknowledged.contains(candidateId)) {
      return TerminalCandidateReceipt.acknowledged;
    }
    if (disposePlan.isNotEmpty) {
      return _respond(disposePlan.removeAt(0), candidateId, apply: true);
    }
    if (currentOperationId != operationId ||
        currentCandidateId != candidateId) {
      return receipts[candidateId] ?? TerminalCandidateReceipt.conflict;
    }
    _nativeDispose(candidateId);
    return TerminalCandidateReceipt.nativeDisposed;
  }

  @override
  Future<TerminalCandidateReceipt> finish({
    required String operationId,
    required String sessionId,
    required String candidateId,
  }) async {
    _requireChannel();
    finishes.add(candidateId);
    if (_acknowledged.contains(candidateId)) {
      return TerminalCandidateReceipt.acknowledged;
    }
    _setFinal(candidateId, TerminalCandidateReceipt.nativeDisposed);
    if (currentCandidateId == candidateId) currentCandidateId = null;
    return TerminalCandidateReceipt.nativeDisposed;
  }

  @override
  Future<TerminalCandidateReceipt> cancel({
    required String operationId,
    required String sessionId,
    required String candidateId,
  }) async {
    _requireChannel();
    if (_acknowledged.contains(candidateId)) {
      return TerminalCandidateReceipt.acknowledged;
    }
    if (cancelPlan.isNotEmpty) {
      return _respond(cancelPlan.removeAt(0), candidateId, apply: true);
    }
    final existing = receipts[candidateId];
    if (existing == TerminalCandidateReceipt.nativeOwns) {
      _nativeDispose(candidateId);
      return TerminalCandidateReceipt.nativeDisposed;
    }
    if (existing == TerminalCandidateReceipt.nativeDisposed) return existing!;
    _setFinal(candidateId, TerminalCandidateReceipt.callerOwns);
    return TerminalCandidateReceipt.callerOwns;
  }

  @override
  Future<TerminalCandidateReceipt> acknowledgeFinalReceipt({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required TerminalCandidateReceipt expectedReceipt,
  }) async {
    _requireChannel();
    ackCalls++;
    final receipt = receipts[candidateId] ?? TerminalCandidateReceipt.unknown;
    if (receipt != expectedReceipt) return TerminalCandidateReceipt.conflict;
    if (_acknowledged.add(candidateId)) {
      beforeAcknowledge?.call(candidateId, receipt);
      acknowledgedCandidates.add(candidateId);
    }
    if (loseNextAckReply) {
      loseNextAckReply = false;
      if (pauseChannelAfterLostAck) channelsAvailable = false;
      throw StateError('ack reply lost after durable transition');
    }
    return receipt;
  }

  Future<TerminalCandidateReceipt> _respond(
    _Response response,
    String candidateId, {
    bool apply = false,
  }) async {
    if (response.error != null) throw response.error!;
    final receipt =
        response.future == null ? response.receipt! : await response.future!;
    if (apply) _apply(candidateId, receipt);
    if (response.lostReply) throw StateError('reply lost after delivery');
    return receipt;
  }

  void _apply(String candidateId, TerminalCandidateReceipt receipt) {
    if (receipt == TerminalCandidateReceipt.nativeOwns) {
      receipts[candidateId] = receipt;
    } else if (receipt == TerminalCandidateReceipt.nativeDisposed) {
      _nativeDispose(candidateId);
    } else if (receipt == TerminalCandidateReceipt.callerOwns) {
      _setFinal(candidateId, receipt);
    }
  }

  void _nativeDispose(String candidateId) {
    if (receipts[candidateId] != TerminalCandidateReceipt.nativeDisposed) {
      if (receipts[candidateId] == TerminalCandidateReceipt.nativeOwns) {
        nativeKillCount++;
      }
      _setFinal(candidateId, TerminalCandidateReceipt.nativeDisposed);
    }
  }

  void nativeCancel(String candidateId) => _nativeDispose(candidateId);

  void advance(Duration duration) {
    _nowMs += duration.inMilliseconds;
  }

  void _setFinal(String candidateId, TerminalCandidateReceipt receipt) {
    receipts[candidateId] = receipt;
    _receiptExpiryMs.putIfAbsent(
      candidateId,
      () => _nowMs + const Duration(minutes: 5).inMilliseconds,
    );
    _acknowledged.remove(candidateId);
  }

  TerminalCandidateReceipt _ordinaryReceipt(String candidateId) =>
      _acknowledged.contains(candidateId)
          ? TerminalCandidateReceipt.acknowledged
          : receipts[candidateId] ?? TerminalCandidateReceipt.unknown;

  void _requireChannel() {
    if (!channelsAvailable) throw StateError('channel unavailable');
  }
}

final class _FakeTerminalProcess implements TerminalProcessHandle {
  _FakeTerminalProcess(this.pid);

  @override
  final int pid;
  final StreamController<List<int>> _output = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();
  int killCount = 0;

  @override
  Stream<List<int>> get output => _output.stream;

  @override
  Future<int> get exitCode => _exit.future;

  void complete(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
    unawaited(_output.close());
  }

  @override
  bool kill() {
    killCount++;
    return true;
  }

  @override
  void resize(int rows, int columns) {}

  @override
  void write(List<int> data) {}
}
