import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:uuid/uuid.dart';
import '../constants.dart';
import '../models/workspace_import_receipt.dart';
import 'attachment_budget.dart';
import 'bounded_file_reader.dart';
import 'shared_content.dart';

typedef HostFileImportBroker = Future<Map<String, dynamic>> Function(
  String path,
  String destinationPath,
  String operationId,
  int maxBytes,
);

typedef RootfsBoundedReadBroker = Future<Uint8List?> Function(
  String path,
  String operationId,
  int maxBytes,
);

typedef WorkspaceImportLifecycleBroker = Future<bool> Function(
  WorkspaceImportReceipt receipt,
  bool discard,
);

typedef PendingWorkspaceImportLister = Future<List<WorkspaceImportReceipt>>
    Function();

typedef UpdateSignatureVerifier = Future<bool> Function(
  Uint8List payload,
  String signature,
  String algorithm,
  String keyId,
);

typedef ApkInstallerHandoff = Future<bool> Function(
  String path,
  int size,
  String sha256,
);

class NativeBridge {
  static const _channel = MethodChannel(AppConstants.channelName);
  static const _agentCallbackChannel =
      MethodChannel('${AppConstants.channelName}/agent_callbacks');
  static const _shareCallbackChannel =
      MethodChannel('${AppConstants.channelName}/share_callbacks');
  static void Function({String? sessionId})? _agentStopRequestedHandler;
  static Future<bool> Function({
    required String sessionId,
    required String approvalId,
    required bool approved,
  })? _toolApprovalDecisionHandler;
  static void Function(String sessionId)? _navigateToSessionHandler;
  static Future<void> Function(SharedContent content)? _shareIntentHandler;
  static bool _agentCallbackInitialized = false;
  static bool _nativeCallbackInitialized = false;
  static Stream<List<int>> Function(String path)? _importReadStreamForTesting;
  static BoundedFileIdentityProbe? _importIdentityProbeForTesting;
  static HostFileImportBroker? _hostFileImportBrokerForTesting;
  static RootfsBoundedReadBroker? _rootfsBoundedReadBrokerForTesting;
  static WorkspaceImportLifecycleBroker?
      _workspaceImportLifecycleBrokerForTesting;
  static PendingWorkspaceImportLister? _pendingWorkspaceImportListerForTesting;
  static UpdateSignatureVerifier? _updateSignatureVerifierForTesting;
  static ApkInstallerHandoff? _apkInstallerHandoffForTesting;
  static final Set<String> _testWorkspaceImportOperations = {};

  static void setShareIntentHandler(
    Future<void> Function(SharedContent content)? handler,
  ) {
    _shareIntentHandler = handler;
    if (handler == null) return;
    _ensureNativeCallbackHandler();
    consumePendingShareIntent().then((content) {
      if (content != null && content.hasPayload) {
        _shareIntentHandler?.call(content);
      }
    }).catchError((_) => null);
  }

  static void _ensureNativeCallbackHandler() {
    if (_nativeCallbackInitialized) return;
    _nativeCallbackInitialized = true;
    _shareCallbackChannel.setMethodCallHandler((call) async {
      if (call.method == 'onShareIntent') {
        final args = call.arguments;
        final content = SharedContent.fromNative(args is Map ? args : null);
        if (!content.hasPayload) return false;
        final handler = _shareIntentHandler;
        if (handler == null) return false;
        await handler(content);
        return true;
      }
      return null;
    });
  }

  @visibleForTesting
  static void resetShareIntentHandlerForTesting() {
    _shareIntentHandler = null;
    if (_nativeCallbackInitialized) {
      _shareCallbackChannel.setMethodCallHandler(null);
      _nativeCallbackInitialized = false;
    }
  }

  static void setAgentStopRequestedHandler(
    void Function({String? sessionId})? handler,
  ) {
    _agentStopRequestedHandler = handler;
    _ensureAgentCallbackHandler();
  }

  static void setToolApprovalDecisionHandler(
    Future<bool> Function({
      required String sessionId,
      required String approvalId,
      required bool approved,
    })? handler,
  ) {
    _toolApprovalDecisionHandler = handler;
    _ensureAgentCallbackHandler();
  }

  static void setNavigateToSessionHandler(
    void Function(String sessionId)? handler,
  ) {
    _navigateToSessionHandler = handler;
    _ensureAgentCallbackHandler();
    if (handler != null) {
      consumePendingNavigateToSession().then((sessionId) {
        if (sessionId != null && sessionId.isNotEmpty) {
          _navigateToSessionHandler?.call(sessionId);
        }
      });
    }
  }

  static void _ensureAgentCallbackHandler() {
    if (_agentCallbackInitialized) return;
    _agentCallbackInitialized = true;
    _agentCallbackChannel.setMethodCallHandler((call) async {
      if (call.method == 'onAgentStopRequested') {
        final args = call.arguments;
        final sessionId = args is Map ? args['sessionId'] as String? : null;
        _agentStopRequestedHandler?.call(sessionId: sessionId);
      } else if (call.method == 'onToolApprovalDecision') {
        final args = call.arguments;
        if (args is! Map) return false;
        final sessionId = args['sessionId'] as String?;
        final approvalId = args['approvalId'] as String?;
        final approved = args['approved'] as bool?;
        final handler = _toolApprovalDecisionHandler;
        if (sessionId == null ||
            sessionId.isEmpty ||
            approvalId == null ||
            approvalId.isEmpty ||
            approved == null ||
            handler == null) {
          return false;
        }
        return handler(
          sessionId: sessionId,
          approvalId: approvalId,
          approved: approved,
        );
      } else if (call.method == 'navigateToSession') {
        final args = call.arguments;
        final sessionId = args is Map ? args['sessionId'] as String? : null;
        if (sessionId != null && sessionId.isNotEmpty) {
          _navigateToSessionHandler?.call(sessionId);
        }
      }
    });
  }

  static Future<String> getProotPath() async {
    return (await _channel.invokeMethod<String>('getProotPath'))!;
  }

  static Future<String> getArch() async {
    return (await _channel.invokeMethod<String>('getArch'))!;
  }

  static Future<String> getFilesDir() async {
    return (await _channel.invokeMethod<String>('getFilesDir'))!;
  }

  static Future<String> getNativeLibDir() async {
    return (await _channel.invokeMethod<String>('getNativeLibDir'))!;
  }

  static Future<bool> verifyUpdateSignature({
    required Uint8List payload,
    required String signature,
    required String algorithm,
    required String keyId,
  }) async {
    final verifier = _updateSignatureVerifierForTesting;
    if (verifier != null) {
      return verifier(payload, signature, algorithm, keyId);
    }
    return await _channel.invokeMethod<bool>('verifyUpdateSignature', {
          'payload': base64Encode(payload),
          'signature': signature,
          'algorithm': algorithm,
          'keyId': keyId,
        }) ??
        false;
  }

  static Future<bool> handoffVerifiedApk({
    required String path,
    required int size,
    required String sha256,
  }) async {
    final handoff = _apkInstallerHandoffForTesting;
    if (handoff != null) return handoff(path, size, sha256);
    return await _channel.invokeMethod<bool>('handoffVerifiedApk', {
          'path': path,
          'size': size,
          'sha256': sha256,
        }) ??
        false;
  }

  @visibleForTesting
  static void setUpdateBrokersForTesting({
    UpdateSignatureVerifier? signatureVerifier,
    ApkInstallerHandoff? apkInstallerHandoff,
  }) {
    _updateSignatureVerifierForTesting = signatureVerifier;
    _apkInstallerHandoffForTesting = apkInstallerHandoff;
  }

  @visibleForTesting
  static void resetUpdateBrokersForTesting() {
    _updateSignatureVerifierForTesting = null;
    _apkInstallerHandoffForTesting = null;
  }

  static Future<bool> isBootstrapComplete() async {
    return (await _channel.invokeMethod<bool>('isBootstrapComplete'))!;
  }

  static Future<String?> consumePendingNavigateToSession() async {
    return _channel.invokeMethod<String>('consumePendingNavigateToSession');
  }

  static Future<SharedContent?> consumePendingShareIntent() async {
    final result = await _channel.invokeMethod<dynamic>(
      'consumePendingShareIntent',
    );
    if (result is! Map) return null;
    final content = SharedContent.fromNative(result);
    return content.hasPayload ? content : null;
  }

  static Future<Map<String, dynamic>> getBootstrapStatus() async {
    final result = await _channel.invokeMethod<Map>('getBootstrapStatus');
    return Map<String, dynamic>.from(result!);
  }

  static Future<bool> extractRootfs(String tarPath) async {
    return (await _channel
        .invokeMethod<bool>('extractRootfs', {'tarPath': tarPath}))!;
  }

  static Future<String> runInProot(
    String command, {
    int timeout = 900,
    bool mountStorage = false,
    String? operationId,
    String? continuationSessionId,
    bool requireBackgroundContinuation = false,
    bool larkCliCredentialScope = false,
    Map<String, String>? scopedEnvironment,
  }) async {
    return (await _channel.invokeMethod<String>('runInProot', {
      'command': command,
      'timeout': timeout,
      'mountStorage': mountStorage,
      if (operationId != null) 'operationId': operationId,
      if (continuationSessionId != null)
        'continuationSessionId': continuationSessionId,
      'requireBackgroundContinuation': requireBackgroundContinuation,
      'larkCliCredentialScope': larkCliCredentialScope,
      if (scopedEnvironment != null && scopedEnvironment.isNotEmpty)
        'scopedEnvironment': Map<String, String>.from(scopedEnvironment),
    }))!;
  }

  static Future<void> cancelProotOperation({
    required String operationId,
    required String sessionId,
    bool requireBackgroundContinuation = false,
  }) async {
    await _channel.invokeMethod<bool>('cancelProotOperation', {
      'operationId': operationId,
      'sessionId': sessionId,
      'requireBackgroundContinuation': requireBackgroundContinuation,
    });
  }

  static Future<void> cancelImportOperation(String operationId) async {
    try {
      await _channel.invokeMethod<bool>('cancelImportOperation', {
        'operationId': operationId,
      });
    } on MissingPluginException {
      // Test and non-Android runtimes have no cancellable native operation.
    }
  }

  static Future<void> finishImportOperation(String operationId) async {
    try {
      await _channel.invokeMethod<bool>('finishImportOperation', {
        'operationId': operationId,
      });
    } on MissingPluginException {
      // Test and non-Android runtimes have no native operation registry.
    }
  }

  static Future<bool> setupDirs() async {
    return (await _channel.invokeMethod<bool>('setupDirs'))!;
  }

  static Future<bool> writeResolv() async {
    return (await _channel.invokeMethod<bool>('writeResolv'))!;
  }

  static Future<Map<String, Object?>> replaceTerminalSession({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required Duration timeout,
  }) async {
    final value =
        await _channel.invokeMethod<Object?>('replaceTerminalSession', {
      'operationId': operationId,
      'sessionId': sessionId,
      'candidateId': candidateId,
      'timeoutSeconds': timeout.inSeconds,
    });
    if (value is String) {
      return <String, Object?>{'outcome': value, 'reason': null};
    }
    if (value is Map) {
      return <String, Object?>{
        'outcome': value['outcome'] as String? ?? 'CONFLICT',
        'reason': value['reason'] as String?,
      };
    }
    return <String, Object?>{'outcome': 'CONFLICT', 'reason': null};
  }

  static Future<String> attachTerminalProcess({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required String attemptId,
    required String launchToken,
    required int processId,
  }) async {
    return await _channel.invokeMethod<String>('attachTerminalProcess', {
          'operationId': operationId,
          'sessionId': sessionId,
          'candidateId': candidateId,
          'attemptId': attemptId,
          'launchToken': launchToken,
          'processId': processId,
        }) ??
        'UNKNOWN';
  }

  static Future<Map<String, Object?>> prepareTerminalLaunch({
    required String operationId,
    required String sessionId,
    required String candidateId,
  }) async {
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'prepareTerminalLaunch',
      {
        'operationId': operationId,
        'sessionId': sessionId,
        'candidateId': candidateId,
      },
    );
    return <String, Object?>{
      'outcome': value?['outcome'] as String?,
      'failureReason': value?['failureReason'] as String?,
      'wrapperPath': value?['wrapperPath'] as String?,
      'attemptDirectoryPath': value?['attemptDirectoryPath'] as String?,
      'stagingPath': value?['stagingPath'] as String?,
      'goPath': value?['goPath'] as String?,
      'parentProcessId': value?['parentProcessId'] as int?,
      'appUid': value?['appUid'] as int?,
      'attemptId': value?['attemptId'] as String?,
      'launchToken': value?['launchToken'] as String?,
    };
  }

  static Future<bool> validateTerminalLaunchCapability({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required String attemptId,
    required String launchToken,
  }) async {
    return await _channel.invokeMethod<bool>(
          'validateTerminalLaunchCapability',
          {
            'operationId': operationId,
            'sessionId': sessionId,
            'candidateId': candidateId,
            'attemptId': attemptId,
            'launchToken': launchToken,
          },
        ) ??
        false;
  }

  static Future<bool> acknowledgeTerminalLaunchAbandoned({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required String attemptId,
    required String launchToken,
  }) async {
    return await _channel.invokeMethod<bool>(
          'acknowledgeTerminalLaunchAbandoned',
          {
            'operationId': operationId,
            'sessionId': sessionId,
            'candidateId': candidateId,
            'attemptId': attemptId,
            'launchToken': launchToken,
          },
        ) ??
        false;
  }

  static Future<bool> isTerminalOperationCurrent({
    required String operationId,
    required String sessionId,
    required String candidateId,
  }) async {
    return await _channel.invokeMethod<bool>('isTerminalOperationCurrent', {
          'operationId': operationId,
          'sessionId': sessionId,
          'candidateId': candidateId,
        }) ??
        false;
  }

  static Future<String> terminalCandidateReceipt({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required int processId,
  }) async {
    return await _channel.invokeMethod<String>('terminalCandidateReceipt', {
          'operationId': operationId,
          'sessionId': sessionId,
          'candidateId': candidateId,
          'processId': processId,
        }) ??
        'UNKNOWN';
  }

  static Future<String> disposeTerminalProcessCandidate({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required int processId,
  }) async {
    return await _channel.invokeMethod<String>(
          'disposeTerminalProcessCandidate',
          {
            'operationId': operationId,
            'sessionId': sessionId,
            'candidateId': candidateId,
            'processId': processId,
          },
        ) ??
        'UNKNOWN';
  }

  static Future<String> finishTerminalService({
    required String operationId,
    required String sessionId,
    required String candidateId,
  }) async {
    return await _channel.invokeMethod<String>('finishTerminalService', {
          'operationId': operationId,
          'sessionId': sessionId,
          'candidateId': candidateId,
        }) ??
        'UNKNOWN';
  }

  static Future<String> cancelTerminalService({
    required String operationId,
    required String sessionId,
    required String candidateId,
  }) async {
    return await _channel.invokeMethod<String>('cancelTerminalService', {
          'operationId': operationId,
          'sessionId': sessionId,
          'candidateId': candidateId,
        }) ??
        'UNKNOWN';
  }

  static Future<String> acknowledgeTerminalFinalReceipt({
    required String operationId,
    required String sessionId,
    required String candidateId,
    required String expectedReceipt,
  }) async {
    return await _channel.invokeMethod<String>(
          'acknowledgeTerminalFinalReceipt',
          {
            'operationId': operationId,
            'sessionId': sessionId,
            'candidateId': candidateId,
            'expectedReceipt': expectedReceipt,
          },
        ) ??
        'UNKNOWN';
  }

  static Future<bool> startTerminalService() async {
    return (await _channel.invokeMethod<bool>('startTerminalService'))!;
  }

  static Future<bool> stopTerminalService({String? sessionId}) async {
    return (await _channel.invokeMethod<bool>('stopTerminalService', {
      if (sessionId != null) 'sessionId': sessionId,
    }))!;
  }

  static Future<bool> isTerminalServiceRunning() async {
    return (await _channel.invokeMethod<bool>('isTerminalServiceRunning'))!;
  }

  static Future<bool> startAgentService({
    required String sessionId,
    required String sessionTitle,
    String text = 'AI 正在执行任务...',
  }) async {
    return (await _channel.invokeMethod<bool>(
      'startAgentService',
      {
        'text': text,
        'sessionId': sessionId,
        'sessionTitle': sessionTitle,
      },
    ))!;
  }

  static Future<bool> stopAgentService() async {
    return (await _channel.invokeMethod<bool>('stopAgentService'))!;
  }

  static Future<bool> stopAgentServiceForSession(String sessionId) async {
    return (await _channel.invokeMethod<bool>(
      'stopAgentServiceForSession',
      {'sessionId': sessionId},
    ))!;
  }

  static Future<bool> updateAgentNotification({
    required String sessionId,
    required String sessionTitle,
    required String status,
    String previewText = '',
    String? toolName,
    bool overlayVisible = false,
  }) async {
    return await _channel.invokeMethod<bool>('updateAgentNotification', {
          'sessionId': sessionId,
          'sessionTitle': sessionTitle,
          'status': status,
          'previewText': previewText,
          if (toolName != null) 'toolName': toolName,
          'overlayVisible': overlayVisible,
        }) ??
        false;
  }

  static Future<bool> showToolApprovalNotification({
    required String sessionId,
    required String sessionTitle,
    required String approvalId,
    required String toolName,
    required String risk,
  }) async {
    return await _channel.invokeMethod<bool>('showToolApprovalNotification', {
          'sessionId': sessionId,
          'sessionTitle': sessionTitle,
          'approvalId': approvalId,
          'toolName': toolName,
          'risk': risk,
        }) ??
        false;
  }

  static Future<bool> clearToolApprovalNotification({
    required String sessionId,
    required String approvalId,
  }) async {
    return await _channel.invokeMethod<bool>('clearToolApprovalNotification', {
          'sessionId': sessionId,
          'approvalId': approvalId,
        }) ??
        false;
  }

  static Future<bool> hasAgentOverlayPermission() async {
    return await _channel.invokeMethod<bool>('hasAgentOverlayPermission') ??
        false;
  }

  static Future<bool> requestAgentOverlayPermissionIfNeeded() async {
    return await _channel
            .invokeMethod<bool>('requestAgentOverlayPermissionIfNeeded') ??
        false;
  }

  static Future<bool> setAgentOverlayVisible(bool visible) async {
    return await _channel.invokeMethod<bool>(
          'setAgentOverlayVisible',
          {'visible': visible},
        ) ??
        false;
  }

  static Future<Map<String, dynamic>> getBatteryStatus() async {
    final result = await _channel.invokeMethod<Map>('getBatteryStatus');
    return Map<String, dynamic>.from(result!);
  }

  static Future<bool> requestBatteryOptimization() async {
    return (await _channel.invokeMethod<bool>('requestBatteryOptimization'))!;
  }

  static Future<bool> isBatteryOptimized() async {
    return (await _channel.invokeMethod<bool>('isBatteryOptimized'))!;
  }

  static Future<bool> startSetupService() async {
    return (await _channel.invokeMethod<bool>('startSetupService'))!;
  }

  static Future<bool> updateSetupNotification(String text,
      {int progress = -1}) async {
    return (await _channel.invokeMethod<bool>(
        'updateSetupNotification', {'text': text, 'progress': progress}))!;
  }

  static Future<bool> showToolAutoApprovedNotification(String toolName) async {
    return await _channel.invokeMethod<bool>(
          'showToolAutoApprovedNotification',
          {'toolName': toolName},
        ) ??
        false;
  }

  static Future<void> showAgentCompleteNotification({
    required String sessionId,
    required String sessionTitle,
    required String preview,
  }) async {
    await _channel.invokeMethod<void>(
      'showAgentCompleteNotification',
      {
        'sessionId': sessionId,
        'sessionTitle': sessionTitle,
        'preview': preview,
        'summary': preview,
      },
    );
  }

  static Future<bool> stopSetupService() async {
    return (await _channel.invokeMethod<bool>('stopSetupService'))!;
  }

  static Future<bool> requestStoragePermission() async {
    return (await _channel.invokeMethod<bool>('requestStoragePermission'))!;
  }

  static Future<bool> hasStoragePermission() async {
    return (await _channel.invokeMethod<bool>('hasStoragePermission'))!;
  }

  static Future<String> getExternalStoragePath() async {
    return (await _channel.invokeMethod<String>('getExternalStoragePath'))!;
  }

  static Future<String?> readRootfsFile(
    String path, {
    Iterable<String>? allowedRoots,
  }) async {
    return await _channel.invokeMethod<String?>('readRootfsFile', {
      'path': path,
      if (allowedRoots != null) 'allowedRoots': allowedRoots.toList(),
    });
  }

  static Future<bool> writeRootfsFile(
    String path,
    String content, {
    Iterable<String>? allowedRoots,
    bool createNew = false,
  }) async {
    return (await _channel.invokeMethod<bool>('writeRootfsFile', {
      'path': path,
      'content': content,
      if (allowedRoots != null) 'allowedRoots': allowedRoots.toList(),
      'createNew': createNew,
    }))!;
  }

  static Future<bool> writeRootfsBytes(
    String path,
    Uint8List bytes, {
    Iterable<String>? allowedRoots,
    bool createNew = false,
  }) async {
    return (await _channel.invokeMethod<bool>('writeRootfsBytes', {
      'path': path,
      'bytes': bytes,
      if (allowedRoots != null) 'allowedRoots': allowedRoots.toList(),
      'createNew': createNew,
    }))!;
  }

  static Future<Map<String, dynamic>> phoneIntent(
      String action, Map<String, dynamic> params,
      {bool allowed = false}) async {
    final result = await _channel.invokeMethod<Map>('phoneIntent', {
      'action': action,
      'params': params,
      'allowed': allowed,
    });
    return Map<String, dynamic>.from(result ?? {});
  }

  static Future<bool> hasAudioPermission() async {
    return await _channel.invokeMethod<bool>('hasAudioPermission') ?? false;
  }

  static Future<bool> requestAudioPermission() async {
    return await _channel.invokeMethod<bool>('requestAudioPermission') ?? false;
  }

  static Future<String?> startSpeechRecognition({
    String language = 'zh-CN',
  }) async {
    return await _channel.invokeMethod<String>('startSpeechRecognition', {
      'language': language,
    });
  }

  static Future<bool> cancelSpeechRecognition() async {
    return await _channel.invokeMethod<bool>('cancelSpeechRecognition') ??
        false;
  }

  static Future<bool> shareText({
    required String text,
    String? subject,
  }) async {
    return await _channel.invokeMethod<bool>('shareText', {
          'text': text,
          if (subject != null) 'subject': subject,
        }) ??
        false;
  }

  static Future<bool> openHtmlFile(String path) async {
    return await _channel.invokeMethod<bool>('openHtmlFile', {'path': path}) ??
        false;
  }

  static Future<bool> bringToForeground() async {
    return (await _channel.invokeMethod<bool>('bringToForeground'))!;
  }

  /// Copy a host file into the proot workspace.
  ///
  /// Production copies are performed entirely by the Android descriptor
  /// broker. Raw bytes never cross the MethodChannel or return to Dart.
  ///
  /// [sourcePath] is the absolute path on the host filesystem (e.g. from file_picker cache).
  /// [destFilename] is the desired filename inside /root/workspace/uploads/.
  /// Returns an unacknowledged receipt. The caller must acknowledge only after
  /// a durable reference exists, or discard when the draft/import is abandoned.
  static Future<WorkspaceImportReceipt> importFileToWorkspace(
    String sourcePath,
    String destFilename, {
    String? operationId,
  }) async {
    final normalizedName =
        destFilename.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final safeName = normalizedName.isEmpty ? 'attachment' : normalizedName;
    const destDir = 'root/workspace/uploads';
    final effectiveOperationId = operationId ?? _newOperationId();
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(effectiveOperationId)) {
      throw ArgumentError.value(operationId, 'operationId');
    }
    final storedName = _operationScopedFileName(safeName, effectiveOperationId);
    final destPath = '$destDir/$storedName';
    final testRead = _importReadStreamForTesting != null ||
        _importIdentityProbeForTesting != null;
    if (testRead) {
      final bytes = await _importFileToWorkspaceForTesting(
        sourcePath,
        safeName,
        destPath,
      );
      final receipt = WorkspaceImportReceipt(
        operationId: effectiveOperationId,
        storedPath: '/root/workspace/uploads/$storedName',
        size: bytes.length,
        sha256: crypto.sha256.convert(bytes).toString(),
        displayName: safeName.substring(
          0,
          safeName.length.clamp(0, 180).toInt(),
        ),
      );
      _testWorkspaceImportOperations.add(receipt.operationId);
      return receipt;
    }

    final broker = _hostFileImportBrokerForTesting;
    final response = broker == null
        ? await _channel.invokeMethod<Map<Object?, Object?>>(
            'importHostFileToWorkspace',
            {
              'path': sourcePath,
              'destinationPath': destPath,
              'allowedRoot': '/root/workspace/uploads',
              'operationId': effectiveOperationId,
              'maxBytes': AttachmentBudget.maxWorkspaceImportBytes,
            },
          )
        : await broker(
            sourcePath,
            destPath,
            effectiveOperationId,
            AttachmentBudget.maxWorkspaceImportBytes,
          );
    if (response == null) {
      throw FileSystemException(
        'Descriptor-bound workspace import is unavailable',
        sourcePath,
      );
    }
    final metadata = Map<String, dynamic>.from(response);
    final storedPath = metadata['storedPath'] as String?;
    final size = metadata['size'] as int?;
    final sha256 = metadata['sha256'] as String?;
    final sourceIdentity = metadata['sourceIdentity'] as String?;
    if (storedPath != '/$destPath' ||
        size == null ||
        size < 0 ||
        size > AttachmentBudget.maxWorkspaceImportBytes ||
        sha256 == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
        sourceIdentity == null ||
        sourceIdentity.isEmpty) {
      throw FileSystemException(
        'Descriptor-bound workspace import metadata is invalid',
        sourcePath,
      );
    }
    return WorkspaceImportReceipt(
      operationId: effectiveOperationId,
      storedPath: storedPath!,
      size: size,
      sha256: sha256,
      displayName: safeName.substring(
        0,
        safeName.length.clamp(0, 180).toInt(),
      ),
    );
  }

  static Future<void> acknowledgeWorkspaceImport(
    WorkspaceImportReceipt receipt,
  ) async {
    if (_testWorkspaceImportOperations.remove(receipt.operationId)) return;
    final broker = _workspaceImportLifecycleBrokerForTesting;
    final acknowledged = broker == null
        ? await _channel.invokeMethod<bool>('acknowledgeHostFileImport', {
            'operationId': receipt.operationId,
            'storedPath': receipt.storedPath,
            'size': receipt.size,
            'sha256': receipt.sha256,
          })
        : await broker(receipt, false);
    if (acknowledged != true) {
      throw FileSystemException(
        'Workspace import acknowledgement failed',
        receipt.storedPath,
      );
    }
  }

  static Future<void> discardWorkspaceImport(
    WorkspaceImportReceipt receipt,
  ) async {
    if (_testWorkspaceImportOperations.remove(receipt.operationId)) return;
    final broker = _workspaceImportLifecycleBrokerForTesting;
    final discarded = broker == null
        ? await _channel.invokeMethod<bool>('discardHostFileImport', {
            'operationId': receipt.operationId,
            'storedPath': receipt.storedPath,
            'size': receipt.size,
            'sha256': receipt.sha256,
          })
        : await broker(receipt, true);
    if (discarded != true) {
      throw FileSystemException(
        'Workspace import discard failed',
        receipt.storedPath,
      );
    }
  }

  static Future<List<WorkspaceImportReceipt>>
      listPendingWorkspaceImports() async {
    final testLister = _pendingWorkspaceImportListerForTesting;
    if (testLister != null) return testLister();
    const limit = 64;
    final receipts = <String, WorkspaceImportReceipt>{};
    try {
      for (var batchIndex = 0; batchIndex < 4; batchIndex++) {
        final raw = await _channel.invokeMethod<List<Object?>>(
              'listPendingWorkspaceImports',
              {'limit': limit},
            ) ??
            const [];
        var added = 0;
        for (final item in raw) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          final operationId = map['operationId'] as String? ?? '';
          final storedPath = map['storedPath'] as String? ?? '';
          final component = storedPath.split('/').last;
          final marker = '_$operationId';
          final markerIndex = component.lastIndexOf(marker);
          if (markerIndex <= 0) continue;
          final displayName =
              '${component.substring(0, markerIndex)}${component.substring(markerIndex + marker.length)}';
          final receipt = WorkspaceImportReceipt(
            operationId: operationId,
            storedPath: storedPath,
            size: map['size'] as int? ?? -1,
            sha256: map['sha256'] as String? ?? '',
            displayName: displayName.substring(
              0,
              displayName.length.clamp(0, 180).toInt(),
            ),
          );
          if (!receipts.containsKey(operationId)) added++;
          receipts[operationId] = receipt;
        }
        if (raw.length < limit || added == 0) break;
      }
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    } catch (_) {
      return const [];
    }
    return List.unmodifiable(receipts.values);
  }

  static Future<Uint8List?> readRootfsFileBounded(
    String path, {
    required String operationId,
    required int maxBytes,
  }) async {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(operationId) ||
        maxBytes < 0 ||
        maxBytes > 1024 * 1024) {
      throw ArgumentError('Invalid bounded rootfs read arguments');
    }
    final broker = _rootfsBoundedReadBrokerForTesting;
    final bytes = broker == null
        ? await _channel.invokeMethod<Uint8List>('readRootfsFileBounded', {
            'path': path,
            'allowedRoot': '/root/workspace/.skill-import-staging',
            'operationId': operationId,
            'maxBytes': maxBytes,
          })
        : await broker(path, operationId, maxBytes);
    if (bytes != null && bytes.length > maxBytes) {
      throw FileSystemException('Bounded rootfs read exceeded its limit', path);
    }
    return bytes;
  }

  static String _newOperationId() => const Uuid().v4().replaceAll('-', '');

  static String _operationScopedFileName(
    String safeName,
    String operationId,
  ) {
    final dot = safeName.lastIndexOf('.');
    final hasExtension = dot > 0 && dot < safeName.length - 1;
    final rawStem = hasExtension ? safeName.substring(0, dot) : safeName;
    final rawExtension = hasExtension ? safeName.substring(dot) : '';
    final stem = rawStem.substring(0, rawStem.length.clamp(0, 159).toInt());
    final extension =
        rawExtension.substring(0, rawExtension.length.clamp(0, 20).toInt());
    return '${stem}_$operationId$extension';
  }

  static Future<Uint8List> _importFileToWorkspaceForTesting(
    String sourcePath,
    String safeName,
    String destPath,
  ) async {
    final bytes = await BoundedFileReader.readBytes(
      sourcePath,
      validateBytes: (byteLength) {
        const AttachmentBudget().checkWorkspaceImportBytes(
          byteLength,
          fileName: safeName,
        );
      },
      streamFactory: _importReadStreamForTesting,
      identityProbe: _importIdentityProbeForTesting,
    );
    const AttachmentBudget().checkWorkspaceImportBytes(
      bytes.length,
      fileName: safeName,
    );
    final extension = safeName.split('.').last.toLowerCase();
    const textExtensions = {
      'txt',
      'md',
      'json',
      'yaml',
      'yml',
      'xml',
      'csv',
      'py',
      'js',
      'ts',
      'dart',
      'sh',
      'html',
      'css',
      'toml',
      'cfg',
      'ini',
      'log',
      'sql',
    };
    if (textExtensions.contains(extension)) {
      await writeRootfsFile(
        destPath,
        utf8.decode(bytes),
        allowedRoots: const ['/root/workspace/uploads'],
        createNew: true,
      );
    } else {
      await writeRootfsBytes(
        destPath,
        bytes,
        allowedRoots: const ['/root/workspace/uploads'],
        createNew: true,
      );
    }
    return bytes;
  }

  @visibleForTesting
  static void resetImportReadStreamForTesting() {
    _importReadStreamForTesting = null;
    _importIdentityProbeForTesting = null;
    _hostFileImportBrokerForTesting = null;
    _rootfsBoundedReadBrokerForTesting = null;
    _workspaceImportLifecycleBrokerForTesting = null;
    _pendingWorkspaceImportListerForTesting = null;
    _testWorkspaceImportOperations.clear();
  }

  @visibleForTesting
  static void setImportReadStreamForTesting(
    Stream<List<int>> Function(String path) streamFactory,
  ) {
    _importReadStreamForTesting = streamFactory;
  }

  @visibleForTesting
  static void setImportIdentityProbeForTesting(
    BoundedFileIdentityProbe identityProbe,
  ) {
    _importIdentityProbeForTesting = identityProbe;
  }

  @visibleForTesting
  static void setHostFileImportBrokerForTesting(
    HostFileImportBroker broker,
  ) {
    _hostFileImportBrokerForTesting = broker;
  }

  @visibleForTesting
  static void setWorkspaceImportLifecycleBrokerForTesting(
    WorkspaceImportLifecycleBroker broker,
  ) {
    _workspaceImportLifecycleBrokerForTesting = broker;
  }

  @visibleForTesting
  static void setPendingWorkspaceImportListerForTesting(
    PendingWorkspaceImportLister lister,
  ) {
    _pendingWorkspaceImportListerForTesting = lister;
  }

  @visibleForTesting
  static void setRootfsBoundedReadBrokerForTesting(
    RootfsBoundedReadBroker broker,
  ) {
    _rootfsBoundedReadBrokerForTesting = broker;
  }
}
