import 'dart:async';
import 'dart:convert';

import 'package:clawchat/models/mcp_server_config.dart';
import 'package:clawchat/services/mcp_service.dart';
import 'package:clawchat/services/mcp_stdio_client.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/tools/tool_registry.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The regression the full review found: `McpService._clients` was keyed only
/// by server id, so a second concurrent run disposed the first run's live MCP
/// child. The cache is now keyed by `(runId, serverId)`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.anka.clawbot/native');
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late PreferencesService prefs;
  late _MultiProcessStarter starter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async => null);
    prefs = PreferencesService();
    await prefs.init();
    await prefs.setMcpServers([
      const McpServerConfig(
        id: 'server-1',
        displayName: 'Fake',
        enabled: true,
        command: 'fake',
      ),
    ]);
    starter = _MultiProcessStarter();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    PreferencesService.resetForTesting();
  });

  test(
      'two concurrent runs keep one child each: ending B does not dispose A\'s '
      'client or stop A\'s native run', () async {
    final service = McpService(
      prefs: prefs,
      processStarter: starter.start,
      stdioSupported: true,
    );
    final registry = ToolRegistry(mcpService: service);

    // Run A starts its child.
    final runA = registry.beginMcpRun(sessionId: 'run-a');
    await registry.refreshMcpTools(runId: runA);
    expect(starter.processes, hasLength(1));
    // A's tool comes from A's own load, so the call is bound to that run.
    final toolA = (await service.loadTools(runId: runA)).single;
    expect(starter.processes, hasLength(1),
        reason: 're-listing run A reuses its cached client');

    // Run B starts while A is live. A's child must not be disposed.
    final runB = registry.beginMcpRun(sessionId: 'run-b');
    await registry.refreshMcpTools(runId: runB);
    expect(starter.processes, hasLength(2));
    final processA = starter.processes[0];
    final processB = starter.processes[1];
    expect(processA.killed, isFalse,
        reason: 'starting run B must not kill run A\'s child');

    // A's tool call uses A's child even while B is active.
    final firstCall = await toolA.executeResult(const {'text': 'from-a'});
    expect(firstCall.forUser, contains('from-a'));
    expect(processA.callCount, 1);
    expect(processB.callCount, 0);

    // Ending B disposes only B's client and stops only B's native run.
    await registry.endMcpRun(runB);
    expect(processB.killed, isTrue);
    expect(processA.killed, isFalse,
        reason: 'endRun(B) must not dispose A\'s client');
    // The native `stopRun(runId)` scoping is covered by mcp_proot_bridge_test
    // (`stoppedRuns == ['run-1']`); here the injected starter owns processes.

    // A's tool still works after B ended.
    final secondCall = await toolA.executeResult(const {'text': 'from-a-again'});
    expect(secondCall.forUser, contains('from-a-again'));
    expect(processA.callCount, 2,
        reason: 'the second call must reuse A\'s existing child');
    expect(starter.processes, hasLength(2),
        reason: 'no new child was started for A');

    await registry.endMcpRun(runA);
    expect(processA.killed, isTrue);
    await service.dispose();
  });

  test(
      'a refresh with no run id never touches a live run\'s child, even after '
      'that server\'s config changed', () async {
    final service = McpService(
      prefs: prefs,
      processStarter: starter.start,
      stdioSupported: true,
    );
    final registry = ToolRegistry(mcpService: service);

    // Run A starts its child.
    final runA = registry.beginMcpRun(sessionId: 'run-a');
    await registry.refreshMcpTools(runId: runA);
    expect(starter.processes, hasLength(1));
    final processA = starter.processes.single;
    final toolA = (await service.loadTools(runId: runA)).single;

    // The server config changes (env edit) while run A is live. This is what
    // makes the old code dispose A's client when the fingerprint differs.
    await prefs.setMcpServers([
      const McpServerConfig(
        id: 'server-1',
        displayName: 'Fake',
        enabled: true,
        command: 'fake',
        env: {'CHANGED': 'yes'},
      ),
    ]);

    // The pre-loop refresh chat_provider does, with no run id.
    await registry.refreshMcpTools();

    expect(processA.killed, isFalse,
        reason: 'a no-run-id refresh must not dispose a live run\'s child');
    expect(starter.processes, hasLength(1),
        reason: 'a no-run-id refresh must not start a child');

    // A's tool still works and reuses A's existing child.
    final payload = await toolA.executeResult(const {'text': 'still-a'});
    expect(payload.forUser, contains('still-a'));
    expect(processA.callCount, 1);
    expect(processA.killed, isFalse);
    expect(starter.processes, hasLength(1),
        reason: 'reusing A\'s child must not start another process');

    await registry.endMcpRun(runA);
    expect(processA.killed, isTrue);
    await service.dispose();
  });

  test('ending a run leaves the other run\'s registered tool in place',
      () async {
    final service = McpService(
      prefs: prefs,
      processStarter: starter.start,
      stdioSupported: true,
    );
    final registry = ToolRegistry(mcpService: service);

    final runA = registry.beginMcpRun(sessionId: 'run-a');
    await registry.refreshMcpTools(runId: runA);
    final name = registry.availableTools.firstWhere((n) => n.startsWith('mcp_'));

    final runB = registry.beginMcpRun(sessionId: 'run-b');
    await registry.refreshMcpTools(runId: runB);
    expect(registry.availableTools, contains(name));

    await registry.endMcpRun(runB);
    expect(registry.availableTools, contains(name),
        reason: 'run A still owns this tool name');

    await registry.endMcpRun(runA);
    expect(registry.availableTools, isNot(contains(name)));
    await service.dispose();
  });
}

/// A process starter that records every child, so the test can tell which child
/// served a call and whether it was killed.
final class _MultiProcessStarter {
  final List<_FakeMcpProcess> processes = [];

  Future<McpStdioProcess> start(McpServerConfig config) async {
    final process = _FakeMcpProcess();
    processes.add(process);
    // Subscribe to the handshake synchronously, before the client writes, so no
    // broadcast event is missed.
    _drive(process);
    return process;
  }

  void _drive(_FakeMcpProcess process) {
    // Every listener is attached synchronously, before the client writes, and
    // answers every matching request (a run may list tools more than once).
    process.requestsWhere('initialize').listen((request) {
      process.stdoutLine(jsonEncode({
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': {
          'protocolVersion': '2025-03-26',
          'serverInfo': {'name': 'fake'},
        },
      }));
    });
    process.requestsWhere('tools/list').listen((request) {
      process.stdoutLine(jsonEncode({
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': {
          'tools': [
            {
              'name': 'echo',
              'description': 'Echo input',
              'inputSchema': {
                'type': 'object',
                'properties': {
                  'text': {'type': 'string'},
                },
              },
            },
          ],
        },
      }));
    });
    process.requestsWhere('tools/call').listen((call) {
      process.callCount++;
      final text = (call['params'] as Map?)?['arguments']?['text'] ?? 'no-text';
      process.stdoutLine(jsonEncode({
        'jsonrpc': '2.0',
        'id': call['id'],
        'result': {
          'content': [
            {'type': 'text', 'text': text},
          ],
        },
      }));
    });
  }
}

final class _FakeMcpProcess implements McpStdioProcess {
  final _stdout = StreamController<String>.broadcast();
  final _stderr = StreamController<String>.broadcast();
  final _exitCode = Completer<int>();
  final _writeController = StreamController<Map<String, dynamic>>.broadcast();
  var killed = false;
  var callCount = 0;

  @override
  Stream<String> get stdoutLines => _stdout.stream;

  @override
  Stream<String> get stderrLines => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Future<void> writeLine(String line) async {
    _writeController.add(jsonDecode(line) as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> nextRequest(String method) {
    return requestsWhere(method).first;
  }

  Stream<Map<String, dynamic>> requestsWhere(String method) {
    return _writeController.stream.where(
      (request) => request['method'] == method && request.containsKey('id'),
    );
  }

  void stdoutLine(String line) => _stdout.add(line);

  @override
  Future<void> closeStdin() async {}

  @override
  bool kill() {
    killed = true;
    if (!_exitCode.isCompleted) _exitCode.complete(0);
    return true;
  }
}
