import 'dart:async';
import 'dart:convert';

import 'package:clawchat/models/mcp_server_config.dart';
import 'package:clawchat/services/mcp_service.dart';
import 'package:clawchat/services/mcp_stdio_client.dart';
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

      final firstTools = await service.loadTools();
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
      final secondTools = await service.loadTools();

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

  @override
  Stream<String> get stdoutLines => _stdout.stream;

  @override
  Stream<String> get stderrLines => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void writeLine(String line) {
    writes.add(line);
    _writeController.add(jsonDecode(line) as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> nextRequest(String method) {
    return _writeController.stream.firstWhere(
      (request) => request['method'] == method && request.containsKey('id'),
    );
  }

  void stdoutLine(String line) => _stdout.add(line);

  void stderrLine(String line) => _stderr.add(line);

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
