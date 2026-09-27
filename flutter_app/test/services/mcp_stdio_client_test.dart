import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/models/mcp_server_config.dart';
import 'package:clawchat/services/mcp_service.dart';
import 'package:clawchat/services/mcp_stdio_client.dart';
import 'package:clawchat/services/mcp_stdio_line_transformer.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('McpStdioClient', () {
    test('initializes, lists tools, and calls tools with matching ids',
        () async {
      final process = _FakeMcpProcess();
      final client = McpStdioClient(
        config: const McpServerConfig(
          id: 'server-1',
          displayName: 'Fake',
          enabled: true,
          command: 'fake',
        ),
        processStarter: (_) async => process,
        requestTimeout: const Duration(seconds: 1),
      );

      unawaited(_processRequest(process, 'initialize', {
        'protocolVersion': '2025-03-26',
        'serverInfo': {'name': 'fake'},
      }));
      await client.connect();

      unawaited(_processRequest(process, 'tools/list', {
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
      }));
      final tools = await client.listTools();
      expect(tools.single.name, 'echo');
      expect(tools.single.inputSchema['type'], 'object');

      unawaited(_processRequest(process, 'tools/call', {
        'content': [
          {'type': 'text', 'text': 'hello'},
        ],
      }));
      final result = await client.callTool('echo', {'text': 'hello'});
      expect(result.output, 'hello');
      expect(result.isError, isFalse);

      expect(
        process.writes.map((line) => jsonDecode(line)['id']).whereType<int>(),
        [1, 2, 3],
      );
      await client.dispose();
    });

    test('sanitizes json-rpc errors and stderr tail', () async {
      final process = _FakeMcpProcess();
      final client = McpStdioClient(
        config: const McpServerConfig(
          id: 'server-1',
          displayName: 'Fake',
          enabled: true,
          command: 'fake',
        ),
        processStarter: (_) async => process,
        requestTimeout: const Duration(seconds: 1),
      );

      unawaited(_processRequest(process, 'initialize', const {}));
      final connectFuture = client.connect();
      await Future<void>.delayed(Duration.zero);
      process.stderrLine('token=super-secret-value');
      await connectFuture;

      unawaited(_processError(
        process,
        'tools/list',
        'sk-secret-secret-secret',
      ));
      await expectLater(
          client.listTools(), throwsA(isA<McpJsonRpcException>()));
      expect(client.sanitizedStderrTail, isNot(contains('super-secret-value')));
      await client.dispose();
    });

    test('cleans up timed out initialize and allows retry', () async {
      final first = _FakeMcpProcess();
      final second = _FakeMcpProcess();
      var starts = 0;
      final client = McpStdioClient(
        config: const McpServerConfig(
          id: 'server-1',
          displayName: 'Fake',
          enabled: true,
          command: 'fake',
        ),
        processStarter: (_) async => starts++ == 0 ? first : second,
        requestTimeout: const Duration(milliseconds: 20),
        connectTimeout: const Duration(milliseconds: 50),
      );

      await expectLater(client.connect(), throwsA(isA<TimeoutException>()));
      expect(first.killed, isTrue);
      expect(first.closeCount, greaterThanOrEqualTo(1));

      unawaited(_processRequest(second, 'initialize', const {}));
      await client.connect();

      expect(starts, 2);
      await client.dispose();
    });

    test('rejects an oversized stdin frame before it reaches the child',
        () async {
      final process = _FakeMcpProcess();
      final client = McpStdioClient(
        config: const McpServerConfig(
          id: 'server-1',
          displayName: 'Fake',
          enabled: true,
          command: 'fake',
        ),
        processStarter: (_) async => process,
        requestTimeout: const Duration(seconds: 1),
      );

      unawaited(_processRequest(process, 'initialize', const {}));
      await client.connect();
      final writesAfterConnect = process.writes.length;

      await expectLater(
        client.callTool('echo', {
          'text': 'x' * (McpStdioLimits.maxStdinLineBytes + 1),
        }),
        throwsA(isA<McpStdinWriteException>()),
      );
      expect(process.writes, hasLength(writesAfterConnect));
      await client.dispose();
    });

    test('an over-limit stdout line settles pending and stops the child',
        () async {
      final process = _FakeMcpProcess();
      final client = McpStdioClient(
        config: const McpServerConfig(
          id: 'server-1',
          displayName: 'Fake',
          enabled: true,
          command: 'fake',
        ),
        processStarter: (_) async => process,
        requestTimeout: const Duration(seconds: 30),
      );

      final pendingConnect = client.connect();
      await process.nextRequest('initialize');
      final started = DateTime.now();
      // What BoundedUtf8LineTransformer reports when a child never terminates a
      // line: the client must stop the child now, not wait out the timeout.
      process.stdoutError(
        const McpLineTooLongException('stdout', McpStdioLimits.maxLineBytes),
      );

      await expectLater(pendingConnect, throwsA(isA<StateError>()));
      expect(DateTime.now().difference(started).inSeconds, lessThan(5));
      expect(process.killed, isTrue);
      await client.dispose();
    });

    test('a stderr stream failure also stops the child', () async {
      final process = _FakeMcpProcess();
      final client = McpStdioClient(
        config: const McpServerConfig(
          id: 'server-1',
          displayName: 'Fake',
          enabled: true,
          command: 'fake',
        ),
        processStarter: (_) async => process,
        requestTimeout: const Duration(seconds: 30),
      );

      final pendingConnect = client.connect();
      await process.nextRequest('initialize');
      process.stderrError(
        const McpLineTooLongException('stderr', McpStdioLimits.maxLineBytes),
      );

      await expectLater(pendingConnect, throwsA(isA<StateError>()));
      expect(process.killed, isTrue);
      await client.dispose();
    });

    test('concurrent requests never interleave their stdin frames', () async {
      final process = _FakeMcpProcess()
        ..writeDelay = const Duration(milliseconds: 10);
      final client = McpStdioClient(
        config: const McpServerConfig(
          id: 'server-1',
          displayName: 'Fake',
          enabled: true,
          command: 'fake',
        ),
        processStarter: (_) async => process,
        requestTimeout: const Duration(milliseconds: 30),
      );

      unawaited(_processRequest(process, 'initialize', const {}));
      await client.connect();
      final results = await Future.wait<Object?>([
        client.callTool('echo', {'a': 1}).then<Object?>(
          (value) => value,
          onError: (Object error) => error,
        ),
        client.callTool('echo', {'b': 2}).then<Object?>(
          (value) => value,
          onError: (Object error) => error,
        ),
      ]);

      expect(results.whereType<Object>(), hasLength(2));
      expect(process.maxConcurrentWrites, 1);
      expect(
        process.writes.map((line) => jsonDecode(line)['method']),
        ['initialize', 'notifications/initialized', 'tools/call', 'tools/call'],
      );
      await client.dispose();
    });

    test('the stdin cap is the whole frame including its newline', () async {
      final process = _FakeMcpProcess();
      final client = McpStdioClient(
        config: const McpServerConfig(
          id: 'server-1',
          displayName: 'Fake',
          enabled: true,
          command: 'fake',
        ),
        processStarter: (_) async => process,
        requestTimeout: const Duration(milliseconds: 50),
      );

      unawaited(_processRequest(process, 'initialize', const {}));
      await client.connect();
      const cap = McpStdioLimits.maxStdinLineBytes;

      // The fake never answers a tool call: what matters here is which frames
      // reached it, so the answer (a timeout) is returned instead of thrown.
      Future<Object?> send(String note) async {
        try {
          await client.callTool('echo', {'note': note});
          return null;
        } catch (error) {
          return error;
        }
      }

      expect(await send('x'), isA<TimeoutException>());
      final base = utf8.encode(process.writes.last).length;
      final padding = cap - 1 - base;
      expect(padding, greaterThan(0));

      // Payload + newline == cap: the largest frame that still fits.
      expect(await send('x' * (padding + 1)), isA<TimeoutException>());
      expect(utf8.encode(process.writes.last).length, cap - 1);
      final writesAtCap = process.writes.length;

      // One byte more is over the cap, not "exactly at" it.
      expect(
        await send('x' * (padding + 2)),
        isA<McpStdinWriteException>(),
      );
      expect(process.writes, hasLength(writesAtCap));
      await client.dispose();
    });

    test('a real desktop child with a long unterminated line is bounded',
        () async {
      if (Platform.isWindows) return;
      final process = await Process.start('sh', [
        '-c',
        'head -c 2097152 /dev/zero | tr "\\0" a',
      ]);
      final dartProcess = DartMcpStdioProcess(process);
      Object? failure;

      try {
        await dartProcess.stdoutLines.toList();
      } catch (error) {
        failure = error;
      } finally {
        process.kill();
      }

      expect(failure, isA<McpLineTooLongException>());
    });

    test('stdin write failure settles the pending request immediately',
        () async {
      final process = _FakeMcpProcess();
      final client = McpStdioClient(
        config: const McpServerConfig(
          id: 'server-1',
          displayName: 'Fake',
          enabled: true,
          command: 'fake',
        ),
        processStarter: (_) async => process,
        requestTimeout: const Duration(seconds: 30),
      );

      unawaited(_processRequest(process, 'initialize', const {}));
      await client.connect();
      process.writeFailure = const McpStdinWriteException('child closed stdin');
      final started = DateTime.now();

      await expectLater(
        client.callTool('echo', const {}),
        throwsA(isA<McpStdinWriteException>()),
      );
      // The failure must settle the request instead of waiting for the 30s
      // request timeout.
      expect(DateTime.now().difference(started).inSeconds, lessThan(5));
      expect(process.killed, isTrue);
      await client.dispose();
    });
  });

  group('McpService', () {
    const secureStorageChannel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    late Map<String, String> secureStorage;

    setUp(() {
      secureStorage = {};
      SharedPreferences.setMockInitialValues({});
      PreferencesService.resetForTesting();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, (call) async {
        final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
        final key = args['key']?.toString();
        switch (call.method) {
          case 'read':
            return key == null ? null : secureStorage[key];
          case 'write':
            if (key != null) {
              secureStorage[key] = args['value']?.toString() ?? '';
            }
            return null;
          case 'delete':
            if (key != null) secureStorage.remove(key);
            return null;
          case 'deleteAll':
            secureStorage.clear();
            return null;
          case 'containsKey':
            return key != null && secureStorage.containsKey(key);
          case 'readAll':
            return Map<String, String>.from(secureStorage);
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, null);
      PreferencesService.resetForTesting();
    });

    test('removes failed client entries so refresh retries', () async {
      final prefs = PreferencesService();
      await prefs.init();
      await prefs.saveMcpServer(
        displayName: 'Fake',
        enabled: true,
        command: 'fake',
      );
      final first = _FakeMcpProcess();
      final second = _FakeMcpProcess();
      var starts = 0;
      final service = McpService(
        prefs: prefs,
        stdioSupported: true,
        processStarter: (_) async => starts++ == 0 ? first : second,
        requestTimeout: const Duration(milliseconds: 20),
        connectTimeout: const Duration(milliseconds: 50),
      );

      final runId = service.beginRun(sessionId: 's1');
      final firstTools = await service.loadTools(runId: runId);
      expect(firstTools, isEmpty);
      expect(first.killed, isTrue);

      unawaited(_processRequest(second, 'initialize', const {}));
      unawaited(_processRequest(second, 'tools/list', {
        'tools': [
          {
            'name': 'echo',
            'description': 'Echo',
            'inputSchema': {'type': 'object'},
          },
        ],
      }));
      final secondTools = await service.loadTools(runId: runId);

      expect(starts, 2);
      expect(secondTools, hasLength(1));
      expect(secondTools.single.name, startsWith('mcp_'));
      await service.dispose();
    });

    test('stdio unsupported platform guard exposes no tools', () async {
      final prefs = PreferencesService();
      await prefs.init();
      await prefs.saveMcpServer(
        displayName: 'Fake',
        enabled: true,
        command: 'fake',
      );
      var starts = 0;
      final service = McpService(
        prefs: prefs,
        stdioSupported: false,
        processStarter: (_) async {
          starts++;
          return _FakeMcpProcess();
        },
      );

      final tools = await service.loadTools();

      expect(tools, isEmpty);
      expect(starts, 0);
    });
  });
}

Future<void> _processRequest(
  _FakeMcpProcess process,
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

Future<void> _processError(
  _FakeMcpProcess process,
  String method,
  String message,
) async {
  final request = await process.nextRequest(method);
  process.stdoutLine(jsonEncode({
    'jsonrpc': '2.0',
    'id': request['id'],
    'error': {'code': -32000, 'message': message},
  }));
}

class _FakeMcpProcess implements McpStdioProcess {
  final _stdout = StreamController<String>.broadcast();
  final _stderr = StreamController<String>.broadcast();
  final _exitCode = Completer<int>();
  final writes = <String>[];
  final _writeController = StreamController<Map<String, dynamic>>.broadcast();
  var killed = false;
  var closeCount = 0;
  Duration writeDelay = Duration.zero;
  McpStdinWriteException? writeFailure;
  int _activeWrites = 0;
  int maxConcurrentWrites = 0;

  @override
  Stream<String> get stdoutLines => _stdout.stream;

  @override
  Stream<String> get stderrLines => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Future<void> writeLine(String line) async {
    _activeWrites++;
    if (_activeWrites > maxConcurrentWrites) {
      maxConcurrentWrites = _activeWrites;
    }
    try {
      if (writeDelay > Duration.zero) {
        await Future<void>.delayed(writeDelay);
      }
      final failure = writeFailure;
      if (failure != null) throw failure;
      writes.add(line);
      _writeController.add(jsonDecode(line) as Map<String, dynamic>);
    } finally {
      _activeWrites--;
    }
  }

  Future<Map<String, dynamic>> nextRequest(String method) {
    return _writeController.stream.firstWhere(
      (request) => request['method'] == method && request.containsKey('id'),
    );
  }

  void stdoutLine(String line) => _stdout.add(line);

  void stderrLine(String line) => _stderr.add(line);

  /// Fails the stdout stream the way the bounded transformer does.
  void stdoutError(Object error) {
    _stdout.addError(error);
  }

  void stderrError(Object error) {
    _stderr.addError(error);
  }

  @override
  Future<void> closeStdin() async {
    closeCount++;
  }

  @override
  bool kill() {
    killed = true;
    if (!_exitCode.isCompleted) _exitCode.complete(0);
    return true;
  }
}
