import 'dart:async';

import 'package:clawchat/models/mcp_server_config.dart';
import 'package:clawchat/services/mcp_proot_bridge.dart';
import 'package:clawchat/services/mcp_stdio_client.dart';
import 'package:clawchat/services/native_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    NativeBridge.resetMcpStdioLatchForTesting();
    NativeBridge.setMcpStdioBridgeBrokerForTesting(null);
  });

  tearDown(() {
    NativeBridge.resetMcpStdioLatchForTesting();
    NativeBridge.setMcpStdioBridgeBrokerForTesting(null);
  });

  group('McpStdioSessionLatch wiring', () {
    test('an event that arrives before the session binds is replayed', () {
      NativeBridge.expectMcpStdioSession(runId: 'run-1', serverId: 'server-1');
      NativeBridge.deliverMcpStdioEventForTesting({
        'event': 'line',
        'runId': 'run-1',
        'serverId': 'server-1',
        'sessionToken': 'token-1',
        'stream': 'stdout',
        'line': '{"jsonrpc":"2.0","id":1,"result":{}}',
      });
      NativeBridge.deliverMcpStdioEventForTesting({
        'event': 'exit',
        'runId': 'run-1',
        'serverId': 'server-1',
        'sessionToken': 'token-1',
        'exitCode': 7,
      });

      final lines = <String>[];
      final stderr = <String>[];
      var exitCode = -1;
      NativeBridge.registerMcpStdioSession(
        runId: 'run-1',
        serverId: 'server-1',
        sessionToken: 'token-1',
        onStdoutLine: lines.add,
        onStderrLine: stderr.add,
        onExit: (code) => exitCode = code,
      );

      // Arrival order is preserved and nothing is dropped.
      expect(lines, ['{"jsonrpc":"2.0","id":1,"result":{}}']);
      expect(stderr, isEmpty);
      expect(exitCode, 7);
      expect(NativeBridge.mcpStdioSessionCountForTesting, 1);
    });

    test('events for a session that was never started are dropped', () {
      NativeBridge.deliverMcpStdioEventForTesting({
        'event': 'exit',
        'runId': 'run-unknown',
        'serverId': 'server-unknown',
        'sessionToken': 'token-unknown',
        'exitCode': 0,
      });

      final lines = <String>[];
      var exitCode = -1;
      NativeBridge.registerMcpStdioSession(
        runId: 'run-unknown',
        serverId: 'server-unknown',
        sessionToken: 'token-unknown',
        onStdoutLine: lines.add,
        onStderrLine: lines.add,
        onExit: (code) => exitCode = code,
      );

      expect(lines, isEmpty);
      expect(exitCode, -1);
    });

    test('unregistering drops buffered events instead of leaking them', () {
      NativeBridge.expectMcpStdioSession(runId: 'run-2', serverId: 'server-2');
      NativeBridge.deliverMcpStdioEventForTesting({
        'event': 'exit',
        'runId': 'run-2',
        'serverId': 'server-2',
        'sessionToken': 'token-2',
        'exitCode': 0,
      });
      NativeBridge.unregisterMcpStdioSession(
        runId: 'run-2',
        serverId: 'server-2',
      );
      NativeBridge.registerMcpStdioSession(
        runId: 'run-2',
        serverId: 'server-2',
        sessionToken: 'token-2',
        onStdoutLine: (_) {},
        onStderrLine: (_) {},
        onExit: (_) {},
      );

      // Nothing was replayed into the re-registered session.
      expect(NativeBridge.mcpStdioSessionCountForTesting, 1);
    });
  });

  group('immediate child exit', () {
    test('a child that dies before the start returns settles its caller',
        () async {
      final broker = _ControlledStartBroker();
      NativeBridge.setMcpStdioBridgeBrokerForTesting(broker);
      final bridge = McpProotBridge(
        host: NativeMcpProotProcessHost(),
        readinessProbe: () async => const McpProotReadiness.ready(),
      );
      final client = McpStdioClient(
        config: const McpServerConfig(
          id: 'server-1',
          displayName: 'Fake',
          enabled: true,
          command: 'fake',
        ),
        processStarter: (config) => bridge.start(config, runId: 'run-exit'),
        requestTimeout: const Duration(seconds: 30),
      );
      final started = DateTime.now();

      final connectFuture = client.connect();
      await broker.startRequested;
      // The child died while the platform start call was still in flight: its
      // exit can only be delivered as an event.
      NativeBridge.deliverMcpStdioEventForTesting({
        'event': 'exit',
        'runId': 'run-exit',
        'serverId': 'server-1',
        'sessionToken': 'token-immediate',
        'exitCode': 0,
      });
      broker.complete({'ok': true, 'sessionToken': 'token-immediate'});

      // Without the latch this would wait out the 30s request timeout. Either
      // the replayed exit settles the request first, or the frame write is
      // refused because the child is already gone: both are definite and fast.
      Object? failure;
      try {
        await connectFuture;
      } catch (error) {
        failure = error;
      }

      expect(failure, isNotNull);
      expect(
        failure,
        anyOf(isA<StateError>(), isA<McpStdinWriteException>()),
      );
      expect(DateTime.now().difference(started).inSeconds, lessThan(5));
      await client.dispose();
    });
  });

  test('an event from a previous child of the same key is not replayed', () {
    NativeBridge.expectMcpStdioSession(runId: 'run-3', serverId: 'server-3');
    NativeBridge.deliverMcpStdioEventForTesting({
      'event': 'exit',
      'runId': 'run-3',
      'serverId': 'server-3',
      'sessionToken': 'token-stale',
      'exitCode': 9,
    });
    NativeBridge.deliverMcpStdioEventForTesting({
      'event': 'line',
      'runId': 'run-3',
      'serverId': 'server-3',
      'sessionToken': 'token-live',
      'stream': 'stdout',
      'line': '{"jsonrpc":"2.0","id":5,"result":{}}',
    });

    final lines = <String>[];
    var exitCode = -1;
    NativeBridge.registerMcpStdioSession(
      runId: 'run-3',
      serverId: 'server-3',
      sessionToken: 'token-live',
      onStdoutLine: lines.add,
      onStderrLine: (_) {},
      onExit: (code) => exitCode = code,
    );

    // The old child's exit is dropped; the live child's own event arrives.
    expect(exitCode, -1);
    expect(lines, ['{"jsonrpc":"2.0","id":5,"result":{}}']);

    // A late event from the old child is dropped even after binding.
    NativeBridge.deliverMcpStdioEventForTesting({
      'event': 'exit',
      'runId': 'run-3',
      'serverId': 'server-3',
      'sessionToken': 'token-stale',
      'exitCode': 9,
    });
    expect(exitCode, -1);
  });

  test('a start without a session token is refused', () async {
    final broker = _ControlledStartBroker();
    NativeBridge.setMcpStdioBridgeBrokerForTesting(broker);
    final bridge = McpProotBridge(
      host: NativeMcpProotProcessHost(),
      readinessProbe: () async => const McpProotReadiness.ready(),
    );

    final start = bridge.start(
      const McpServerConfig(
        id: 'server-1',
        displayName: 'Fake',
        enabled: true,
        command: 'fake',
      ),
      runId: 'run-no-token',
    );
    await broker.startRequested;
    broker.complete({'ok': true});

    await expectLater(
      start,
      throwsA(
        isA<McpBridgeException>().having(
          (McpBridgeException error) => error.reasonCode,
          'reasonCode',
          'mcp_start_failed',
        ),
      ),
    );
  });
}

class _ControlledStartBroker implements McpStdioBridgeBroker {
  final _startRequested = Completer<void>();
  final _startCompleted = Completer<Map<String, dynamic>>();
  final _stopped = <String>[];
  final _stoppedTokens = <Set<String>?>[];

  List<Set<String>?> get stoppedTokens => _stoppedTokens;

  Future<void> get startRequested => _startRequested.future;

  void complete(Map<String, dynamic> result) {
    if (!_startCompleted.isCompleted) _startCompleted.complete(result);
  }

  @override
  Future<Map<String, dynamic>> start({
    required String runId,
    required String serverId,
    required String command,
    required List<String> args,
    required Map<String, String> environment,
    required int timeoutSeconds,
  }) {
    if (!_startRequested.isCompleted) _startRequested.complete();
    return _startCompleted.future;
  }

  @override
  Future<void> writeLine({
    required String runId,
    required String serverId,
    required String line,
  }) async {}

  @override
  Future<void> closeStdin({
    required String runId,
    required String serverId,
  }) async {}

  @override
  Future<void> stopServer({
    required String runId,
    required String serverId,
  }) async {
    _stopped.add('$runId:$serverId');
  }

  @override
  Future<void> stopRun(String runId, {Set<String>? sessionTokens}) async {
    _stopped.add(runId);
    _stoppedTokens.add(sessionTokens);
  }
}
