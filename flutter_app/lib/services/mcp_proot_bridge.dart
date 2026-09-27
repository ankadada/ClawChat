import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/mcp_server_config.dart';
import 'mcp_stdio_client.dart';
import 'native_bridge.dart';

/// I5 — run-scoped MCP stdio bridge.
///
/// MCP servers are not a durable background service. One child starts for the
/// agent run that needs its tools and is killed when that run ends, is
/// cancelled, or the foreground-service lease drops. There is no MCP
/// supervisor and no restart after process death.
///
/// All three of the security rules from the iteration plan live here so they
/// are unit-testable without a device:
///   1. the guest environment is an allowlist, never inheritance;
///   2. a start that could not happen is a visible error, never an empty tool
///      list;
///   3. a child is owned by exactly one run and dies with it.

/// Fixed non-secret guest baseline added to every MCP child.
///
/// These are the only keys the bridge adds on its own. Anything else comes
/// from the user's `McpServerConfig.env` exactly as typed. App-process
/// environment variables (`GOOGLE_ACCESS_TOKEN` and friends) are never copied
/// in, because the bridge runs the child with a cleared environment.
///
/// The child is an Alpine Linux process: it holds no Android runtime
/// permission, so it cannot read SMS or contacts and cannot place a call, no
/// matter what the server config asks for.
class McpGuestEnvironment {
  const McpGuestEnvironment._();

  static const String home = '/root';
  static const String path =
      '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';
  static const String lang = 'C.UTF-8';
  static const String tmpDir = '/tmp';

  /// The baseline keys the bridge owns. A configured key with the same name
  /// wins, because the user typed it for this server.
  static const Map<String, String> baseline = {
    'HOME': home,
    'PATH': path,
    'LANG': lang,
    'TMPDIR': tmpDir,
  };

  /// Keys that must never appear in a guest environment. Only reachable if a
  /// caller bypasses [_sanitize]; kept as a defense-in-depth assertion.
  static const Set<String> forbiddenAppSecretKeys = {
    'GOOGLE_ACCESS_TOKEN',
    'GOOGLE_REFRESH_TOKEN',
    'LARKSUITE_CLI_APP_ID',
    'LARKSUITE_CLI_APP_SECRET',
  };

  /// Builds the child environment: baseline plus the server's configured keys.
  ///
  /// Host process variables are never consulted. Values are trimmed of NUL and
  /// newline characters because they are passed to a POSIX `execve` argument
  /// vector.
  static Map<String, String> build(Map<String, String> configured) {
    final environment = <String, String>{...baseline};
    for (final entry in configured.entries) {
      final key = sanitizeEnvKey(entry.key);
      if (key.isEmpty) continue;
      environment[key] = sanitizeEnvValue(entry.value);
    }
    return environment;
  }

  /// Keys that were actually taken from [configured] (i.e. the user's own
  /// values). Used by tests and diagnostics to prove no app secret leaked.
  static Set<String> configuredKeys(Map<String, String> environment) =>
      environment.keys.where((key) => !baseline.containsKey(key)).toSet();

  static String sanitizeEnvKey(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final valid = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
    return valid.hasMatch(trimmed) ? trimmed : '';
  }

  static String sanitizeEnvValue(String raw) =>
      raw.replaceAll('\u0000', '').replaceAll('\n', ' ').replaceAll('\r', ' ');
}

/// Readiness of the Alpine/proot runtime, as the bridge sees it.
@immutable
class McpProotReadiness {
  final bool ready;
  final String reasonCode;
  final String message;

  const McpProotReadiness({
    required this.ready,
    required this.reasonCode,
    required this.message,
  });

  const McpProotReadiness.ready()
      : ready = true,
        reasonCode = 'ready',
        message = 'proot runtime ready';

  const McpProotReadiness.notReady(this.reasonCode, this.message)
      : ready = false;

  /// User-visible error for settings and for a failed tool call. A failure to
  /// start is shown, never turned into an empty tool list.
  String get visibleMessage =>
      '无法启动 MCP 服务器：$message（$reasonCode）。请在系统健康页修复 Alpine 运行时后重试。';
}

/// Where the readiness answer comes from. Production uses the native bootstrap
/// status; tests inject a fixed value.
typedef McpProotReadinessProbe = Future<McpProotReadiness> Function();

/// One start request handed to a process host.
@immutable
class McpProotStartRequest {
  final String runId;
  final String serverId;
  final String command;
  final List<String> args;
  final Map<String, String> environment;

  /// How long this start may take, including the initialize handshake. It
  /// bounds the start only: the child is left running afterwards, so a long
  /// tool call or an idle server is never killed for taking time.
  final Duration timeout;

  const McpProotStartRequest({
    required this.runId,
    required this.serverId,
    required this.command,
    required this.args,
    required this.environment,
    required this.timeout,
  });
}

/// Starts and stops guest MCP children. The production implementation talks to
/// the Android proot bridge; tests use a fake.
abstract class McpProotProcessHost {
  Future<McpStdioProcess> start(McpProotStartRequest request);

  /// Ends every child of [runId].
  ///
  /// [sessionTokens] are the starts this scope owns. Passing them keeps a
  /// delayed endRun from stopping a child that replaced the same
  /// (runId, serverId) after this scope last looked; omitting them keeps the
  /// run-wide sweep.
  Future<void> stopRun(String runId, {Set<String>? sessionTokens});

  Future<void> stopServer({required String runId, required String serverId});
}

/// A start the user must see. Never swallowed into an empty tool list.
class McpBridgeException implements Exception {
  final String reasonCode;
  final String message;

  const McpBridgeException(this.reasonCode, this.message);

  @override
  String toString() => 'McpBridgeException($reasonCode): $message';
}

/// Owns the run scope for MCP children.
///
/// A child is registered under exactly one run id. [endRun] kills every child
/// of that run and is called when the run completes, is cancelled, or its
/// foreground lease drops. Children of other runs are untouched, so a
/// cancelled run cannot take a healthy parallel run down with it.
/// One run's live MCP state.
///
/// [pendingStarts] counts starts that were handed to the process host but have
/// not registered a child yet: while any of them is in flight the run cannot be
/// swept run-wide, because the child that start is about to produce is not part
/// of any snapshot taken now.
class _McpRunState {
  _McpRunState(this.runId);

  final String runId;
  final Map<String, McpStdioProcess> children = {};
  final Map<String, String> tokens = {};
  int pendingStarts = 0;

  /// Set by [McpRunScope.endRun]: a start that completes after this must not be
  /// adopted, and its child must be killed by the caller.
  bool closing = false;
  bool everHeldChild = false;
}

/// A start that has begun but has not produced a child yet.
class McpRunStart {
  McpRunStart._(this.runId, this._state);

  /// The run was already ended before this start began.
  McpRunStart._closed(this.runId) : _state = null;

  final String runId;
  final _McpRunState? _state;
}

/// Owns the run scope for MCP children.
///
/// A child is registered under exactly one run id. [endRun] kills every child of
/// that run and is called when the run completes, is cancelled, or its
/// foreground lease drops. Children of other runs are untouched, so a cancelled
/// run cannot take a healthy parallel run down with it.
///
/// A start can still be in flight when its run ends. The run is marked closing
/// first, so that start cannot register afterwards: its child is killed instead
/// of escaping the run, and the stop stays token-scoped (a run-wide sweep is
/// only used when the scope never had a child or a pending start).
class McpRunScope {
  /// Ended runs are remembered so a late start cannot reopen one. The list is
  /// bounded (it only holds run ids) and exists to refuse starts that no live
  /// caller owns any more.
  static const int _maxRememberedClosedRuns = 256;

  final McpProotProcessHost host;
  final Map<String, _McpRunState> _runs = {};
  final Set<String> _closedRuns = <String>{};
  final List<String> _closedRunOrder = <String>[];

  McpRunScope({required this.host});

  Iterable<String> get activeRunIds => _runs.values
      .where((state) => !state.closing && state.children.isNotEmpty)
      .map((state) => state.runId);

  @visibleForTesting
  bool isActive(String runId) {
    final state = _runs[runId];
    return state != null && !state.closing && state.children.isNotEmpty;
  }

  @visibleForTesting
  int pendingStartCountFor(String runId) => _runs[runId]?.pendingStarts ?? 0;

  /// Opens a start for [runId]. Every call must end in [registerStart] or
  /// [abandonStart].
  McpRunStart beginStart(String runId) {
    if (_closedRuns.contains(runId)) {
      // The run already ended: the child this start produces is refused later.
      return McpRunStart._closed(runId);
    }
    final state = _runs.putIfAbsent(runId, () => _McpRunState(runId));
    state.pendingStarts++;
    return McpRunStart._(runId, state);
  }

  /// The start failed before it produced a child.
  void abandonStart(McpRunStart handle) {
    final state = handle._state;
    if (state == null) return;
    _completeStart(state);
  }

  /// Adopts the child of a finished start.
  ///
  /// Returns false when the run ended while the start was in flight, in which
  /// case the caller must kill [process] itself: this scope will not adopt a
  /// child whose run is already over.
  bool registerStart(
    McpRunStart handle, {
    required String serverId,
    required McpStdioProcess process,
  }) {
    final state = handle._state;
    if (state == null || state.closing) {
      if (state != null) _completeStart(state);
      return false;
    }
    final previous = state.children[serverId];
    state.children[serverId] = process;
    state.everHeldChild = true;
    if (process is NativeMcpStdioProcess) {
      state.tokens[serverId] = process.sessionToken;
    } else {
      state.tokens.remove(serverId);
    }
    _completeStart(state);
    if (previous != null && !identical(previous, process)) {
      previous.kill();
    }
    return true;
  }

  /// Registers a child whose start already finished (used by callers that do not
  /// model the in-flight window).
  void register({
    required String runId,
    required String serverId,
    required McpStdioProcess process,
  }) {
    final adopted = registerStart(
      beginStart(runId),
      serverId: serverId,
      process: process,
    );
    if (!adopted) process.kill();
  }

  void forget({required String runId, required String serverId}) {
    final state = _runs[runId];
    if (state == null) return;
    state.children.remove(serverId);
    state.tokens.remove(serverId);
    if (state.children.isEmpty && state.pendingStarts == 0 && !state.closing) {
      _runs.remove(runId);
    }
  }

  Future<void> endRun(String runId) async {
    _rememberClosedRun(runId);
    final state = _runs[runId];
    Set<String>? sessionTokens;
    if (state == null) {
      // This scope never started anything for the run: keep the historical
      // run-wide sweep, which also collects children left by a dead process.
      sessionTokens = null;
    } else {
      // Close first: a start that is still in flight must not be adopted when it
      // completes, and the child it produced is killed by that caller.
      state.closing = true;
      final tokens = state.tokens.values.toSet();
      // A run-wide sweep is only safe when nothing of ours is live and nothing
      // of ours may still become live.
      sessionTokens =
          (state.everHeldChild || state.pendingStarts > 0) ? tokens : null;
      for (final process in state.children.values) {
        process.kill();
      }
      state.children.clear();
      state.tokens.clear();
      if (state.pendingStarts == 0) _runs.remove(runId);
    }
    await host.stopRun(runId, sessionTokens: sessionTokens);
  }

  Future<void> endAll() async {
    final runIds = _runs.keys.toList(growable: false);
    for (final runId in runIds) {
      await endRun(runId);
    }
  }

  void _completeStart(_McpRunState state) {
    if (state.pendingStarts > 0) state.pendingStarts--;
    if (state.pendingStarts == 0 && (state.closing || state.children.isEmpty)) {
      _runs.remove(state.runId);
    }
  }

  void _rememberClosedRun(String runId) {
    if (!_closedRuns.add(runId)) return;
    _closedRunOrder.add(runId);
    while (_closedRunOrder.length > _maxRememberedClosedRuns) {
      _closedRuns.remove(_closedRunOrder.removeAt(0));
    }
  }
}

/// The bridge: readiness gate, environment allowlist, and run-scoped children.
class McpProotBridge {
  final McpProotProcessHost host;
  final McpProotReadinessProbe readinessProbe;
  final McpRunScope runScope;

  /// How long the start call itself may take. It bounds the start and the
  /// initialize handshake only: once a child answered, it runs for as long as
  /// its run needs it and is never killed for being slow.
  final Duration startTimeout;

  McpProotBridge({
    required this.host,
    required this.readinessProbe,
    this.startTimeout = const Duration(seconds: 30),
  }) : runScope = McpRunScope(host: host);

  /// Starts one server for [runId].
  ///
  /// Throws [McpBridgeException] with a visible message when proot is not
  /// ready or the child cannot start. Throws [TimeoutException] when the child
  /// does not answer within [startTimeout].
  Future<McpStdioProcess> start(
    McpServerConfig config, {
    required String runId,
  }) async {
    final readiness = await readinessProbe();
    if (!readiness.ready) {
      throw McpBridgeException(readiness.reasonCode, readiness.visibleMessage);
    }
    final environment = McpGuestEnvironment.build(config.env);
    // The start is announced before it is awaited: an endRun that lands while
    // this child is coming up marks the run closing, and the child is then
    // killed instead of being adopted after its run already ended.
    final startHandle = runScope.beginStart(runId);
    final startFuture = host.start(McpProotStartRequest(
      runId: runId,
      serverId: config.id,
      command: config.command,
      args: config.args,
      environment: environment,
      timeout: startTimeout,
    ));
    final McpStdioProcess process;
    try {
      process = await startFuture.timeout(startTimeout, onTimeout: () {
        return Future.error(McpBridgeException(
          'mcp_start_timeout',
          'MCP 服务器启动超时（${startTimeout.inSeconds}s）',
        ));
      });
    } catch (_) {
      runScope.abandonStart(startHandle);
      // A child that shows up after this call gave up was never adopted by
      // anyone: stop it as soon as it exists instead of leaking it.
      unawaited(
        startFuture.then(
          (late) => late.kill(),
          onError: (Object _) {},
        ),
      );
      rethrow;
    }
    if (!runScope.registerStart(
      startHandle,
      serverId: config.id,
      process: process,
    )) {
      // The run ended while this child was starting.
      process.kill();
      throw const McpBridgeException(
        'mcp_run_closed',
        '运行已结束，MCP 服务器已停止',
      );
    }
    return process;
  }

  Future<void> endRun(String runId) => runScope.endRun(runId);

  Future<void> endAll() => runScope.endAll();
}

/// Production process host: the Android proot stdio bridge.
class NativeMcpProotProcessHost implements McpProotProcessHost {
  NativeMcpProotProcessHost();

  @override
  Future<McpStdioProcess> start(McpProotStartRequest request) async {
    // Announce the session before the native start. A child that fails at once
    // can emit its stdout lines and its exit event before this call returns and
    // before NativeMcpStdioProcess exists to receive them; the latch keeps them
    // and replays them when the session binds.
    NativeBridge.expectMcpStdioSession(
      runId: request.runId,
      serverId: request.serverId,
    );
    final Map<String, dynamic> result;
    try {
      result = await NativeBridge.startMcpStdioProcess(
        runId: request.runId,
        serverId: request.serverId,
        command: request.command,
        args: request.args,
        environment: request.environment,
        timeoutSeconds: request.timeout.inSeconds,
      );
    } catch (_) {
      NativeBridge.cancelMcpStdioSessionExpectation(
        runId: request.runId,
        serverId: request.serverId,
      );
      rethrow;
    }
    if (result['ok'] != true) {
      // No child exists, so no event will ever arrive for this key.
      NativeBridge.cancelMcpStdioSessionExpectation(
        runId: request.runId,
        serverId: request.serverId,
      );
      throw McpBridgeException(
        result['reasonCode']?.toString() ?? 'mcp_start_failed',
        result['message']?.toString() ?? 'MCP 服务器启动失败',
      );
    }
    final sessionToken = result['sessionToken']?.toString() ?? '';
    if (sessionToken.isEmpty) {
      // Without the token this Dart side cannot tell this child's events from a
      // previous child's, so the start is refused rather than run unbounded.
      NativeBridge.cancelMcpStdioSessionExpectation(
        runId: request.runId,
        serverId: request.serverId,
      );
      throw const McpBridgeException(
        'mcp_start_failed',
        'MCP 服务器未返回会话标识',
      );
    }
    return NativeMcpStdioProcess(
      runId: request.runId,
      serverId: request.serverId,
      sessionToken: sessionToken,
    );
  }

  @override
  Future<void> stopRun(String runId, {Set<String>? sessionTokens}) =>
      NativeBridge.stopMcpRun(runId, sessionTokens: sessionTokens);

  @override
  Future<void> stopServer({
    required String runId,
    required String serverId,
  }) =>
      NativeBridge.stopMcpServer(runId: runId, serverId: serverId);
}

/// A running guest child. Output arrives from the native bridge as line events;
/// input is written back over the same channel.
class NativeMcpStdioProcess implements McpStdioProcess {
  final String runId;
  final String serverId;

  /// Identifies this one native start: late events, writes, and stops that
  /// carry another token belong to a previous child of the same key and are
  /// ignored by the native side.
  final String sessionToken;

  final _stdout = StreamController<String>.broadcast();
  final _stderr = StreamController<String>.broadcast();
  final _exitCode = Completer<int>();
  var _killed = false;

  /// Serializes frames for this child. The native side also serializes, but
  /// ordering and failure propagation belong to the caller's request objects.
  Future<void> _writeChain = Future<void>.value();

  NativeMcpStdioProcess({
    required this.runId,
    required this.serverId,
    required this.sessionToken,
  }) {
    NativeBridge.registerMcpStdioSession(
      runId: runId,
      serverId: serverId,
      sessionToken: sessionToken,
      onStdoutLine: _stdout.add,
      onStderrLine: _stderr.add,
      onExit: (code) {
        if (!_exitCode.isCompleted) _exitCode.complete(code);
        _closeStreams();
      },
    );
  }

  @override
  Stream<String> get stdoutLines => _stdout.stream;

  @override
  Stream<String> get stderrLines => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Future<void> writeLine(String line) {
    if (_killed) {
      return Future.error(
        const McpStdinWriteException('MCP child is not running'),
      );
    }
    final next = _writeChain.then((_) async {
      if (_killed) {
        throw const McpStdinWriteException('MCP child is not running');
      }
      final written = await NativeBridge.writeMcpStdioLine(
        runId: runId,
        serverId: serverId,
        line: line,
        sessionToken: sessionToken,
      );
      if (!written) {
        throw const McpStdinWriteException('native bridge rejected the frame');
      }
    });
    // Keep the chain usable after a failure; the failing caller still sees it.
    _writeChain = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  @override
  Future<void> closeStdin() => NativeBridge.closeMcpStdioStdin(
        runId: runId,
        serverId: serverId,
        sessionToken: sessionToken,
      );

  @override
  bool kill() {
    if (_killed) return false;
    _killed = true;
    // Best-effort teardown: a destroyed activity/engine already kills the
    // child, so a platform error here must not become an unhandled async error.
    unawaited(
      NativeBridge.stopMcpServer(
        runId: runId,
        serverId: serverId,
        sessionToken: sessionToken,
      ).catchError((_) {}),
    );
    if (!_exitCode.isCompleted) _exitCode.complete(-1);
    _closeStreams();
    return true;
  }

  void _closeStreams() {
    NativeBridge.unregisterMcpStdioSession(runId: runId, serverId: serverId);
    if (!_stdout.isClosed) _stdout.close();
    if (!_stderr.isClosed) _stderr.close();
  }
}

/// Readiness probe backed by the native bootstrap status.
class NativeMcpProotReadinessProbe {
  const NativeMcpProotReadinessProbe();

  Future<McpProotReadiness> call() async {
    try {
      final prootPath = await NativeBridge.getProotPath();
      if (prootPath.trim().isEmpty) {
        return const McpProotReadiness.notReady(
          'proot_missing',
          'proot 可执行文件缺失',
        );
      }
      final status = await NativeBridge.getBootstrapStatus();
      final rootfsExists = status['rootfsExists'] == true;
      final complete = status['complete'] == true;
      if (!rootfsExists) {
        return const McpProotReadiness.notReady(
          'rootfs_missing',
          'Alpine 根文件系统尚未安装',
        );
      }
      if (!complete) {
        return const McpProotReadiness.notReady(
          'bootstrap_incomplete',
          'Alpine 运行时尚未完成初始化',
        );
      }
      return const McpProotReadiness.ready();
    } catch (error) {
      return const McpProotReadiness.notReady(
        'bootstrap_status_unavailable',
        '无法读取 Alpine 运行时状态',
      );
    }
  }
}

/// Serializes the environment for a diagnostic line, redacting values.
String describeMcpGuestEnvironment(Map<String, String> environment) {
  final keys = environment.keys.toList()..sort();
  return jsonEncode({for (final key in keys) key: '<set>'});
}
