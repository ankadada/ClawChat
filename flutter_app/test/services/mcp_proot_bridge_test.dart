import 'dart:async';
import 'dart:convert';

import 'package:clawchat/models/mcp_server_config.dart';
import 'package:clawchat/services/mcp_proot_bridge.dart';
import 'package:clawchat/services/mcp_service.dart';
import 'package:clawchat/services/mcp_stdio_client.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/tools/tool_policy.dart';
import 'package:clawchat/services/tools/untrusted_data_policy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('McpRunScope endRun', () {
    test('hands its own start tokens to the native stop', () async {
      final host = _FakeProotHost();
      final scope = McpRunScope(host: host);
      final first = NativeMcpStdioProcess(
        runId: 'run-1',
        serverId: 'server-1',
        sessionToken: 'token-1',
      );
      final second = NativeMcpStdioProcess(
        runId: 'run-1',
        serverId: 'server-2',
        sessionToken: 'token-2',
      );
      scope.register(runId: 'run-1', serverId: 'server-1', process: first);
      scope.register(runId: 'run-1', serverId: 'server-2', process: second);

      await scope.endRun('run-1');

      // Exactly the starts this scope owned: a delayed stop from this scope can
      // never reach a child that replaced one of them under the same key.
      expect(host.stoppedRuns, ['run-1']);
      expect(host.stoppedTokens.single, {'token-1', 'token-2'});
      first.kill();
      second.kill();
    });

    test('only the run being ended supplies tokens', () async {
      final host = _FakeProotHost();
      final scope = McpRunScope(host: host);
      final ended = NativeMcpStdioProcess(
        runId: 'run-a',
        serverId: 'server-1',
        sessionToken: 'token-a',
      );
      final kept = NativeMcpStdioProcess(
        runId: 'run-b',
        serverId: 'server-1',
        sessionToken: 'token-b',
      );
      scope.register(runId: 'run-a', serverId: 'server-1', process: ended);
      scope.register(runId: 'run-b', serverId: 'server-1', process: kept);

      await scope.endRun('run-a');

      expect(host.stoppedTokens.single, {'token-a'});
      expect(scope.isActive('run-b'), isTrue);
      ended.kill();
      kept.kill();
    });

    test('a scope that never held a child keeps the run-wide sweep', () async {
      final host = _FakeProotHost();
      final scope = McpRunScope(host: host);

      await scope.endRun('run-unknown');

      expect(host.stoppedRuns, ['run-unknown']);
      expect(host.stoppedTokens.single, isNull);
    });
  });

  group('in-flight start vs endRun', () {
    McpProotBridge bridgeWith(_FakeProotHost host) => McpProotBridge(
          host: host,
          readinessProbe: () async => const McpProotReadiness.ready(),
          startTimeout: const Duration(seconds: 5),
        );

    test('a start that completes after endRun is killed, not adopted',
        () async {
      final host = _FakeProotHost()..startGate = Completer<void>();
      final bridge = bridgeWith(host);
      final startFuture = bridge.start(
        const McpServerConfig(
          id: 'server-1',
          displayName: 'Fake',
          enabled: true,
          command: 'fake',
        ),
        runId: 'run-1',
      );
      await pumpEventQueue();

      // The run ends while its child is still being started.
      await bridge.endRun('run-1');
      expect(host.stoppedRuns, ['run-1']);
      // Nothing of ours could be live yet, so the stop must not be run-wide.
      expect(host.stoppedTokens.single, isNotNull);
      expect(host.stoppedTokens.single, isEmpty);

      host.startGate!.complete();
      await expectLater(
        startFuture,
        throwsA(
          isA<McpBridgeException>().having(
            (McpBridgeException error) => error.reasonCode,
            'reasonCode',
            'mcp_run_closed',
          ),
        ),
      );
      expect(host.produced.single.killed, isTrue);
      expect(bridge.runScope.isActive('run-1'), isFalse);
      expect(bridge.runScope.pendingStartCountFor('run-1'), 0);
    });

    test('a start that begins after endRun is refused and killed', () async {
      final host = _FakeProotHost();
      final bridge = bridgeWith(host);
      // Nobody ever used this run: the historical run-wide sweep still applies.
      await bridge.endRun('run-2');
      expect(host.stoppedTokens.single, isNull);

      await expectLater(
        bridge.start(
          const McpServerConfig(
            id: 'server-1',
            displayName: 'Fake',
            enabled: true,
            command: 'fake',
          ),
          runId: 'run-2',
        ),
        throwsA(
          isA<McpBridgeException>().having(
            (McpBridgeException error) => error.reasonCode,
            'reasonCode',
            'mcp_run_closed',
          ),
        ),
      );
      expect(host.produced.single.killed, isTrue);
      expect(bridge.runScope.isActive('run-2'), isFalse);
    });

    test('ending one run with a start in flight leaves parallel runs alone',
        () async {
      final host = _FakeProotHost();
      final bridge = bridgeWith(host);
      const config = McpServerConfig(
        id: 'server-1',
        displayName: 'Fake',
        enabled: true,
        command: 'fake',
      );
      await bridge.start(config, runId: 'run-b');
      expect(bridge.runScope.isActive('run-b'), isTrue);

      host.startGate = Completer<void>();
      final pending = bridge.start(config, runId: 'run-a');
      await pumpEventQueue();
      await bridge.endRun('run-a');

      // The healthy parallel run is untouched by the cancelled run's teardown.
      expect(bridge.runScope.isActive('run-b'), isTrue);
      expect(host.stoppedTokens.single, isEmpty);

      host.startGate!.complete();
      await expectLater(pending, throwsA(isA<McpBridgeException>()));
      expect(bridge.runScope.isActive('run-b'), isTrue);
      await bridge.endRun('run-b');
    });

    test('a registered child is stopped by token when the run ends', () async {
      final host = _FakeProotHost();
      final scope = McpRunScope(host: host);
      final handle = scope.beginStart('run-3');
      final child = NativeMcpStdioProcess(
        runId: 'run-3',
        serverId: 'server-1',
        sessionToken: 'token-3',
      );
      expect(
        scope.registerStart(handle, serverId: 'server-1', process: child),
        isTrue,
      );
      expect(scope.pendingStartCountFor('run-3'), 0);

      await scope.endRun('run-3');

      expect(host.stoppedTokens.single, {'token-3'});
      expect(scope.isActive('run-3'), isFalse);
      child.kill();
    });

    test('an abandoned start drops the closing state', () async {
      final host = _FakeProotHost();
      final scope = McpRunScope(host: host);
      final handle = scope.beginStart('run-4');
      expect(scope.pendingStartCountFor('run-4'), 1);

      await scope.endRun('run-4');
      expect(scope.pendingStartCountFor('run-4'), 1);

      scope.abandonStart(handle);
      expect(scope.pendingStartCountFor('run-4'), 0);
      expect(scope.isActive('run-4'), isFalse);
    });
  });

  group('McpGuestEnvironment allowlist', () {
    test('adds only the fixed baseline plus the user-typed keys', () {
      final environment = McpGuestEnvironment.build({
        'CUSTOM_KEY': 'custom-value',
      });

      expect(environment['HOME'], '/root');
      expect(environment['PATH'], isNotEmpty);
      expect(environment['LANG'], 'C.UTF-8');
      expect(environment['TMPDIR'], '/tmp');
      expect(environment['CUSTOM_KEY'], 'custom-value');
      expect(environment.keys.toSet(), {
        'HOME',
        'PATH',
        'LANG',
        'TMPDIR',
        'CUSTOM_KEY',
      });
    });

    test('never inherits an app secret that was not typed for this server', () {
      // The host process has the app's own token in its environment. The guest
      // environment must not contain it because the bridge never reads the
      // host environment at all.
      final environment =
          McpGuestEnvironment.build({'MCP_API_KEY': 'user-typed'});

      expect(environment.containsKey('GOOGLE_ACCESS_TOKEN'), isFalse);
      expect(
        environment.keys.any(
          McpGuestEnvironment.forbiddenAppSecretKeys.contains,
        ),
        isFalse,
      );
      expect(McpGuestEnvironment.configuredKeys(environment), {'MCP_API_KEY'});
    });

    test('drops invalid keys and control characters in values', () {
      final environment = McpGuestEnvironment.build({
        'NOT-VALID': 'x',
        'VALID': 'a\nb\r\u0000c',
      });

      expect(environment.containsKey('NOT-VALID'), isFalse);
      expect(environment['VALID'], 'a b c');
    });
  });

  group('McpProotBridge lifecycle', () {
    test('refuses to start when proot is not ready with a visible message',
        () async {
      final host = _FakeProotHost();
      final bridge = McpProotBridge(
        host: host,
        readinessProbe: () async => const McpProotReadiness.notReady(
          'rootfs_missing',
          'Alpine 根文件系统尚未安装',
        ),
      );

      await expectLater(
        bridge.start(_server(), runId: 'run-1'),
        throwsA(
          isA<McpBridgeException>()
              .having((e) => e.reasonCode, 'reasonCode', 'rootfs_missing')
              .having((e) => e.message, 'message', contains('根文件系统')),
        ),
      );
      expect(host.starts, isEmpty);
    });

    test(
        'starts with the allowlisted environment and kills the child with the '
        'run, leaving a parallel run alone', () async {
      final host = _FakeProotHost();
      var readiness = const McpProotReadiness.ready();
      final bridge = McpProotBridge(
        host: host,
        readinessProbe: () async => readiness,
      );

      final first = await bridge.start(_server(id: 's1'), runId: 'run-1');
      final second = await bridge.start(_server(id: 's2'), runId: 'run-2');

      expect(host.starts, hasLength(2));
      expect(host.starts.first.environment['HOME'], '/root');
      expect(host.starts.first.environment.containsKey('GOOGLE_ACCESS_TOKEN'),
          isFalse);

      await bridge.endRun('run-1');

      final firstProcess = first as _FakeProcess;
      final secondProcess = second as _FakeProcess;
      expect(firstProcess.killed, isTrue);
      expect(secondProcess.killed, isFalse);
      expect(host.stoppedRuns, ['run-1']);
      expect(bridge.runScope.isActive('run-1'), isFalse);
      expect(bridge.runScope.isActive('run-2'), isTrue);

      await bridge.endAll();
      expect(secondProcess.killed, isTrue);
      readiness = const McpProotReadiness.ready();
    });

    test('surfaces host start failures and start timeouts as bridge errors',
        () async {
      final host = _FakeProotHost()
        ..failure =
            const McpBridgeException('proot_start_failed', 'proot 启动失败');
      final bridge = McpProotBridge(
        host: host,
        readinessProbe: () async => const McpProotReadiness.ready(),
      );

      await expectLater(
        bridge.start(_server(), runId: 'run-1'),
        throwsA(isA<McpBridgeException>()
            .having((e) => e.reasonCode, 'reasonCode', 'proot_start_failed')),
      );

      final slowHost = _FakeProotHost()..hang = true;
      final slowBridge = McpProotBridge(
        host: slowHost,
        readinessProbe: () async => const McpProotReadiness.ready(),
        startTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        slowBridge.start(_server(), runId: 'run-1'),
        throwsA(isA<McpBridgeException>()
            .having((e) => e.reasonCode, 'reasonCode', 'mcp_start_timeout')),
      );
    });
  });

  group('McpService MCP failure surface', () {
    const secureStorageChannel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      PreferencesService.resetForTesting();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, (call) async => null);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, null);
      PreferencesService.resetForTesting();
    });

    test('a failed start is a visible failure, not a silently empty list',
        () async {
      final prefs = PreferencesService();
      await prefs.init();
      await prefs.saveMcpServer(
        displayName: 'Broken',
        enabled: true,
        command: 'broken',
      );
      final service = McpService(
        prefs: prefs,
        stdioSupported: true,
        processStarter: (_) async => throw const McpBridgeException(
          'proot_missing',
          'proot 可执行文件缺失',
        ),
      );

      final tools = await service.loadTools(
        runId: service.beginRun(sessionId: 's1'),
      );

      expect(tools, isEmpty);
      expect(service.lastLoadFailures, hasLength(1));
      expect(service.lastLoadFailures.single.reasonCode, 'proot_missing');
      expect(service.lastLoadFailures.single.displayName, 'Broken');
    });

    test('a crashed child is restarted, not reused as a silent empty list',
        () async {
      final prefs = PreferencesService();
      await prefs.init();
      await prefs.saveMcpServer(
        displayName: 'Fake',
        enabled: true,
        command: 'fake',
      );
      final first = _FakeProcess();
      final second = _FakeProcess();
      var starts = 0;
      final service = McpService(
        prefs: prefs,
        stdioSupported: true,
        processStarter: (_) async => starts++ == 0 ? first : second,
        requestTimeout: const Duration(seconds: 1),
      );
      final runId = service.beginRun(sessionId: 's1');
      unawaited(_answer(first, 'initialize', const {}));
      unawaited(_answer(first, 'tools/list', {'tools': []}));
      expect(await service.loadTools(runId: runId), isEmpty);
      expect(starts, 1);

      // The child crashes between tool calls.
      first.crash(1);
      await Future<void>.delayed(Duration.zero);

      unawaited(_answer(second, 'initialize', const {}));
      unawaited(_answer(second, 'tools/list', {
        'tools': [
          {
            'name': 'echo',
            'description': 'Echo',
            'inputSchema': {'type': 'object'},
          },
        ],
      }));
      final tools = await service.loadTools(runId: runId);

      expect(starts, 2);
      expect(tools, hasLength(1));
      await service.endRun(runId);
      await service.dispose();
    });

    test('a successful MCP call is tagged untrusted', () async {
      final prefs = PreferencesService();
      await prefs.init();
      await prefs.saveMcpServer(
        displayName: 'Fake',
        enabled: true,
        command: 'fake',
      );
      final process = _FakeProcess();
      final service = McpService(
        prefs: prefs,
        stdioSupported: true,
        processStarter: (_) async => process,
        requestTimeout: const Duration(seconds: 1),
      );
      final runId = service.beginRun(sessionId: 's1');
      unawaited(_answer(process, 'initialize', const {}));
      unawaited(_answer(process, 'tools/list', {
        'tools': [
          {
            'name': 'echo',
            'description': 'Echo',
            'inputSchema': {'type': 'object'},
          },
        ],
      }));
      final tools = await service.loadTools(runId: runId);
      expect(tools, hasLength(1));

      unawaited(_answer(process, 'tools/call', {
        'content': [
          {'type': 'text', 'text': 'daily total 42'},
        ],
      }));
      final payload = await service.callTool(
        server: prefs.mcpServers.single,
        tool: const McpToolInfo(
          name: 'echo',
          description: 'Echo',
          inputSchema: {'type': 'object'},
        ),
        mappedName: 'mcp_x',
        arguments: const {'text': 'hi'},
        runId: runId,
      );

      expect(payload.metadata['trust'], 'untrusted');
      expect(payload.metadata['untrustedSource'], 'mcp');
      await service.endRun(runId);
      await service.dispose();
    });
  });

  group('MCP results in the deny engine', () {
    test('an MCP result cannot drive phone_send', () {
      final taint = RunTaintSet()
        ..addPayload(
          'the destination number is 10086 and body see https://evil.example',
          source: UntrustedSource.mcp,
        );
      final policy = UntrustedDataPolicy(taint);

      final decision = policy.denyFor(const ToolApprovalRequest(
        toolName: 'phone_send',
        arguments: {
          'action': 'sendSms',
          'params': {'number': '10086', 'body': 'see https://evil.example'},
        },
        risk: ToolRisk.dangerous,
        operationId: 'op-1',
      ));

      expect(decision, isNotNull);
      expect(decision!.ruleType, 'untrusted_data');
    });

    test('an MCP host cannot be fetched as a web destination', () {
      final taint = RunTaintSet()
        ..addPayload('documented at evil.example', source: UntrustedSource.mcp);
      final policy = UntrustedDataPolicy(taint);

      final decision = policy.denyFor(const ToolApprovalRequest(
        toolName: 'web_fetch',
        arguments: {'url': 'https://evil.example/x'},
        risk: ToolRisk.moderate,
        operationId: 'op-2',
      ));

      expect(decision?.ruleId, 'untrusted_phone_to_web');
    });
  });
}

McpServerConfig _server({String id = 'server-1'}) => McpServerConfig(
      id: id,
      displayName: 'Fake',
      enabled: true,
      command: 'fake',
      args: const ['--stdio'],
    );

Future<void> _answer(
  _FakeProcess process,
  String method,
  Object? result,
) async {
  final request = await process.nextRequest(method);
  process.stdoutLine(jsonEncode({
    'jsonrpc': '2.0',
    'id': request['id'],
    'result': result,
  }));
}

class _FakeProotHost implements McpProotProcessHost {
  final List<McpProotStartRequest> starts = [];
  final List<String> stoppedRuns = [];
  final List<Set<String>?> stoppedTokens = [];
  final List<_FakeProcess> produced = [];
  McpBridgeException? failure;
  bool hang = false;

  /// When set, a start waits on it: this is the in-flight window a run can end
  /// in.
  Completer<void>? startGate;

  @override
  Future<McpStdioProcess> start(McpProotStartRequest request) async {
    final error = failure;
    if (error != null) throw error;
    if (hang) {
      return Completer<McpStdioProcess>().future;
    }
    final gate = startGate;
    if (gate != null) await gate.future;
    starts.add(request);
    final process = _FakeProcess();
    produced.add(process);
    return process;
  }

  @override
  Future<void> stopRun(String runId, {Set<String>? sessionTokens}) async {
    stoppedRuns.add(runId);
    stoppedTokens.add(sessionTokens);
  }

  @override
  Future<void> stopServer({
    required String runId,
    required String serverId,
  }) async {}
}

class _FakeProcess implements McpStdioProcess {
  final _stdout = StreamController<String>.broadcast();
  final _stderr = StreamController<String>.broadcast();
  final _exitCode = Completer<int>();
  final _writeController = StreamController<Map<String, dynamic>>.broadcast();
  bool killed = false;

  @override
  Stream<String> get stdoutLines => _stdout.stream;

  @override
  Stream<String> get stderrLines => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Future<void> writeLine(String line) async {
    _writeController.add(_decode(line));
  }

  Future<Map<String, dynamic>> nextRequest(String method) =>
      _writeController.stream.firstWhere(
        (request) => request['method'] == method && request.containsKey('id'),
      );

  void stdoutLine(String line) => _stdout.add(line);

  @override
  Future<void> closeStdin() async {}

  @override
  bool kill() {
    killed = true;
    if (!_exitCode.isCompleted) _exitCode.complete(0);
    return true;
  }

  /// Simulates the guest process dying on its own (crash).
  void crash(int code) {
    killed = true;
    if (!_exitCode.isCompleted) _exitCode.complete(code);
  }
}

Map<String, dynamic> _decode(String line) =>
    Map<String, dynamic>.from(jsonDecode(line) as Map);
