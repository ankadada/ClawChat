import 'dart:async';
import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/extension_manifest.dart';
import 'package:clawchat/models/structured_result.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:clawchat/services/skill_capability_policy.dart';
import 'package:clawchat/services/skill_service.dart';
import 'package:clawchat/services/structured_action_registry.dart';
import 'package:clawchat/services/tools/memory_tools.dart';
import 'package:clawchat/services/tools/tool_registry.dart';
import 'package:clawchat/services/tools/tool_policy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const nativeChannel = MethodChannel(AppConstants.channelName);
  late Directory tempDir;
  late Map<String, String> secureStorage;

  Future<void> installPlatformMocks({
    Set<String> deniedTools = const {},
  }) async {
    PreferencesService.resetForTesting();
    SharedPreferences.setMockInitialValues({
      'tool_approval_policy': PreferencesService.toolApprovalAlways,
      if (deniedTools.isNotEmpty) 'denied_tool_names': deniedTools.toList(),
    });
    secureStorage = {};
    tempDir = await Directory.systemTemp.createTemp('structured_action_test_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return tempDir.path;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(secureStorageChannel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      final key = args['key']?.toString();
      switch (call.method) {
        case 'read':
          return key == null ? null : secureStorage[key];
        case 'write':
          if (key != null) secureStorage[key] = args['value']?.toString() ?? '';
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
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      switch (call.method) {
        case 'consumePendingNavigateToSession':
        case 'listPendingWorkspaceImports':
          return call.method == 'listPendingWorkspaceImports' ? const [] : null;
        case 'runInProot':
          return '';
        case 'readRootfsFile':
          return null;
        case 'writeRootfsFile':
          return true;
      }
      return true;
    });
  }

  Future<void> clearPlatformMocks() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    messenger.setMockMethodCallHandler(secureStorageChannel, null);
    messenger.setMockMethodCallHandler(nativeChannel, null);
    PreferencesService.resetForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  }

  Future<ChatProvider> providerWithAction(
    _RecordingMemoryWriteTool tool, {
    SkillCapabilityPolicyFactory? skillPolicyFactory,
    bool includeSkillProvenance = false,
    SessionStorage? storage,
    StructuredResultDocument document = _document,
  }) async {
    final registry = ToolRegistry()..register(tool, risk: ToolRisk.moderate);
    final provider = ChatProvider(
      storage: storage,
      toolRegistry: registry,
      skillCapabilityPolicyFactory: skillPolicyFactory,
    );
    addTearDown(provider.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final session = await provider.createSession();
    session.messages.add(ChatMessage.userContent([
      ToolResultContent(
        toolUseId: 'present-1',
        output: 'Structured result ready.',
        forLlm: document.projection,
        metadata: {
          'toolName': StructuredResultIngress.toolName,
          'resultId': document.resultId,
          'schemaVersion': document.schemaVersion,
        },
      ),
      StructuredResultContent(
        document: document,
        skillProvenance: includeSkillProvenance ? _skillProvenance : null,
        toolUseId: 'present-1',
      ),
    ]));
    return provider;
  }

  Future<void> approvePending(ChatProvider provider) async {
    await _waitUntil(() => provider.pendingApproval != null);
    final request = provider.pendingApproval!;
    expect(
      provider.currentSession!.structuredActionReceipts.last.state,
      ToolAttemptLifecycle.approvalPending.name,
    );
    expect(
        provider.resolveToolApproval(
          operationId: request.operationId,
          approved: true,
        ),
        isTrue);
  }

  setUp(() async => installPlatformMocks());
  tearDown(clearPlatformMocks);

  test('hard deny persists a receipt before any memory execution', () async {
    await clearPlatformMocks();
    await installPlatformMocks(deniedTools: {'memory_write'});
    final tool = _RecordingMemoryWriteTool();
    final provider = await providerWithAction(tool);

    await provider.executeStructuredAction(
      resultId: _document.resultId,
      actionId: 'save-1',
    );

    expect(tool.calls, isEmpty);
    expect(provider.pendingApproval, isNull);
    final receipt = provider.currentSession!.structuredActionReceipts.single;
    expect(receipt.state, ToolAttemptLifecycle.resultPersisted.name);
    expect(receipt.outcome, 'denied');
    expect(receipt.hardDeny, 'denied');
    expect(receipt.skillDeny, 'not_checked');
    expect(receipt.approval, 'not_requested');
  });

  test('a standalone structured payload cannot bypass the matched tool result',
      () async {
    final tool = _RecordingMemoryWriteTool();
    final provider = await providerWithAction(tool);
    final session = provider.currentSession!;
    session.messages
      ..clear()
      ..add(ChatMessage.userContent([
        const StructuredResultContent(
          document: _document,
          toolUseId: 'unmatched-present',
        ),
      ]));

    await provider.executeStructuredAction(
      resultId: _document.resultId,
      actionId: 'save-1',
    );

    expect(tool.calls, isEmpty);
    expect(session.structuredActionReceipts, isEmpty);
  });

  test('skill deny is additive and happens before approval or execution',
      () async {
    final tool = _RecordingMemoryWriteTool();
    final provider = await providerWithAction(
      tool,
      skillPolicyFactory: (_) => SkillCapabilityPolicy(
        loader: (_) async => _verifiedSkill(
          tools: const [StructuredResultIngress.toolName],
        ),
      ),
      includeSkillProvenance: true,
    );

    await provider.executeStructuredAction(
      resultId: _document.resultId,
      actionId: 'save-1',
    );

    expect(tool.calls, isEmpty);
    expect(provider.pendingApproval, isNull);
    final receipt = provider.currentSession!.structuredActionReceipts.single;
    expect(receipt.state, ToolAttemptLifecycle.resultPersisted.name);
    expect(receipt.outcome, 'denied');
    expect(receipt.skillDeny, 'denied');
  });

  test(
      'approval uses the shared operation identity and save starts after receipt',
      () async {
    late ChatProvider provider;
    final tool = _RecordingMemoryWriteTool(onExecute: () {
      final receipt = provider.currentSession!.structuredActionReceipts.single;
      expect(receipt.state, ToolAttemptLifecycle.started.name);
      expect(receipt.outcomeKnown, isFalse);
    });
    provider = await providerWithAction(tool);

    final execution = provider.executeStructuredAction(
      resultId: _document.resultId,
      actionId: 'save-1',
    );
    await approvePending(provider);
    await execution;

    expect(tool.calls, [
      {'fact': 'Only local, consented data may be saved.'},
    ]);
    final receipt = provider.currentSession!.structuredActionReceipts.single;
    expect(receipt.state, ToolAttemptLifecycle.resultPersisted.name);
    expect(receipt.outcome, 'success');
    expect(receipt.outcomeKnown, isTrue);
    expect(receipt.safeSummary, 'Saved to local memory.');
  });

  test('stale session approval cannot execute the old operation', () async {
    final tool = _RecordingMemoryWriteTool();
    final provider = await providerWithAction(tool);
    final oldSession = provider.currentSession!;

    final execution = provider.executeStructuredAction(
      resultId: _document.resultId,
      actionId: 'save-1',
    );
    await _waitUntil(() => provider.pendingApproval != null);
    final operationId = provider.pendingApproval!.operationId;
    await provider.createSession();
    expect(
        provider.resolveToolApproval(operationId: operationId, approved: true),
        isTrue);
    await execution;

    expect(tool.calls, isEmpty);
    final receipt = oldSession.structuredActionReceipts.single;
    expect(receipt.state, ToolAttemptLifecycle.resultPersisted.name);
    expect(receipt.outcome, 'cancelled');
    expect(receipt.approval, 'stale');
    expect(receipt.safeSummary, 'Local memory action is no longer current.');
  });

  test('known memory save failure is persisted without claiming success',
      () async {
    final tool = _RecordingMemoryWriteTool(
      output: '{"ok":false,"error":"memory_disabled"}',
    );
    final provider = await providerWithAction(tool);

    final execution = provider.executeStructuredAction(
      resultId: _document.resultId,
      actionId: 'save-1',
    );
    await approvePending(provider);
    await execution;

    expect(tool.calls, hasLength(1));
    final receipt = provider.currentSession!.structuredActionReceipts.single;
    expect(receipt.state, ToolAttemptLifecycle.resultPersisted.name);
    expect(receipt.outcome, 'failed');
    expect(receipt.safeSummary, 'Local memory was not saved.');
  });

  test('each explicit retry allocates a fresh operation receipt', () async {
    final tool = _RecordingMemoryWriteTool();
    final provider = await providerWithAction(tool);

    for (var index = 0; index < 2; index++) {
      final execution = provider.executeStructuredAction(
        resultId: _document.resultId,
        actionId: 'save-1',
      );
      await approvePending(provider);
      await execution;
    }

    final receipts = provider.currentSession!.structuredActionReceipts;
    expect(receipts, hasLength(2));
    expect(
        receipts.map((receipt) => receipt.operationId).toSet(), hasLength(2));
  });

  test('deny added while approval is pending blocks the effect boundary',
      () async {
    final tool = _RecordingMemoryWriteTool();
    final provider = await providerWithAction(tool);

    final execution = provider.executeStructuredAction(
      resultId: _document.resultId,
      actionId: 'save-1',
    );
    await _waitUntil(() => provider.pendingApproval != null);
    PreferencesService().deniedToolNames = {'memory_write'};
    await approvePending(provider);
    await execution;

    expect(tool.calls, isEmpty);
    final receipt = provider.currentSession!.structuredActionReceipts.single;
    expect(receipt.hardDeny, 'denied');
    expect(receipt.approval, 'stale');
    expect(receipt.outcome, 'denied');
  });

  test('active action owns session mutation across proposed and approval gaps',
      () async {
    var blockNextCommit = false;
    final receiptCommitBlocked = Completer<void>();
    final releaseReceiptCommit = Completer<void>();
    final storage = SessionStorage(beforeCommitForTesting: (_) async {
      if (!blockNextCommit) return;
      blockNextCommit = false;
      if (!receiptCommitBlocked.isCompleted) receiptCommitBlocked.complete();
      await releaseReceiptCommit.future;
    });
    final tool = _RecordingMemoryWriteTool();
    final provider = await providerWithAction(tool, storage: storage);
    final session = provider.currentSession!;
    final originalMessageCount = session.messages.length;

    blockNextCommit = true;
    final action = provider.executeStructuredAction(
      resultId: _document.resultId,
      actionId: 'save-1',
    );
    await receiptCommitBlocked.future;
    await provider.sendMessage('message during proposed receipt commit');
    expect(provider.isSessionSending(session.id), isFalse);
    expect(session.messages, hasLength(originalMessageCount));
    releaseReceiptCommit.complete();
    await _waitUntil(() => provider.pendingApproval != null);
    expect(
      session.structuredActionReceipts.single.state,
      ToolAttemptLifecycle.approvalPending.name,
    );
    await provider.sendMessage('message during approval');
    expect(session.messages, hasLength(originalMessageCount));
    final operationId = provider.pendingApproval!.operationId;
    expect(
      provider.resolveToolApproval(
        operationId: operationId,
        approved: false,
      ),
      isTrue,
    );
    await action;

    expect(tool.calls, isEmpty);
    expect(session.messages, hasLength(originalMessageCount));
    final receipt = session.structuredActionReceipts.single;
    expect(receipt.state, ToolAttemptLifecycle.resultPersisted.name);
    expect(receipt.outcome, 'cancelled');
    expect(
        session.messages.any((message) =>
            message.content.whereType<StructuredResultContent>().isNotEmpty),
        isTrue);
    final persisted = await storage.getSession(session.id);
    expect(persisted, isNotNull);
    expect(persisted!.messages, hasLength(originalMessageCount));
    expect(persisted.structuredActionReceipts.single.state,
        ToolAttemptLifecycle.resultPersisted.name);
  });

  test('canonical whitespace input executes and survives receipt restart',
      () async {
    final tool = _RecordingMemoryWriteTool();
    final provider = await providerWithAction(
      tool,
      document: _whitespaceDocument,
    );

    final execution = provider.executeStructuredAction(
      resultId: _whitespaceDocument.resultId,
      actionId: 'save-spaced',
    );
    await approvePending(provider);
    await execution;

    expect(tool.calls.single, {'fact': 'Remember this across restart'});
    final restored = ChatSession.fromJson(provider.currentSession!.toJson());
    expect(restored.structuredActionReceipts.single.state,
        ToolAttemptLifecycle.resultPersisted.name);
    expect(
      restored.structuredActionReceipts.single.canonicalInputDigest,
      structuredActionInputDigest(
        (_whitespaceDocument.blocks.single as StructuredActionListBlock)
            .actions
            .single,
      ),
    );
  });

  test('restart reconciles a nonterminal receipt without executing', () async {
    final storage = SessionStorage();
    final tool = _RecordingMemoryWriteTool();
    final registry = ToolRegistry()..register(tool, risk: ToolRisk.moderate);
    final session = ChatSession(
      id: 'structured_restart_unknown',
      messages: [_structuredMessage(_whitespaceDocument)],
      structuredActionReceipts: [
        _pendingReceipt(_whitespaceDocument),
      ],
    );
    await storage.saveSession(session);
    final provider = ChatProvider(storage: storage, toolRegistry: registry);
    addTearDown(provider.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    await provider.selectSession(session.id);

    expect(tool.calls, isEmpty);
    final receipt = provider.currentSession!.structuredActionReceipts.single;
    expect(receipt.state, ToolAttemptLifecycle.interruptedUnknown.name);
    expect(receipt.outcome, 'unknown_outcome');
    expect(receipt.outcomeKnown, isFalse);
    expect(receipt.approval, 'stale');
    expect(receipt.safeSummary, contains('will not be retried automatically'));
    final reloaded = ChatSession.fromJson(provider.currentSession!.toJson());
    expect(reloaded.structuredActionReceipts.single.state,
        ToolAttemptLifecycle.interruptedUnknown.name);
    expect(tool.calls, isEmpty);
  });
}

const _document = StructuredResultDocument(
  schemaVersion: 1,
  resultId: '123e4567-e89b-42d3-a456-426614174000',
  blocks: [
    StructuredActionListBlock(
      actions: [
        StructuredResultAction(
          actionId: 'save-1',
          label: 'Save to local memory',
          kind: 'save_to_memory',
          payload: {'fact': 'Only local, consented data may be saved.'},
        ),
      ],
    ),
  ],
);

const _whitespaceDocument = StructuredResultDocument(
  schemaVersion: 1,
  resultId: '123e4567-e89b-42d3-a456-426614174010',
  blocks: [
    StructuredActionListBlock(
      actions: [
        StructuredResultAction(
          actionId: 'save-spaced',
          label: 'Save spaced fact',
          kind: 'save_to_memory',
          payload: {'fact': '  Remember   this\nacross   restart  '},
        ),
      ],
    ),
  ],
);

ChatMessage _structuredMessage(StructuredResultDocument document) =>
    ChatMessage.userContent([
      ToolResultContent(
        toolUseId: 'present-restart',
        output: 'Structured result ready.',
        forLlm: document.projection,
        metadata: {
          'toolName': StructuredResultIngress.toolName,
          'resultId': document.resultId,
          'schemaVersion': document.schemaVersion,
        },
      ),
      StructuredResultContent(
        document: document,
        toolUseId: 'present-restart',
      ),
    ]);

StructuredActionReceipt _pendingReceipt(StructuredResultDocument document) {
  final action =
      (document.blocks.single as StructuredActionListBlock).actions.single;
  final timestamp = DateTime.utc(2026, 7, 15);
  return StructuredActionReceipt(
    schemaVersion: 1,
    receiptId: '123e4567-e89b-42d3-a456-426614174011',
    operationId: '123e4567-e89b-42d3-a456-426614174012',
    sourceKind: 'structured_result',
    resultId: document.resultId,
    actionId: action.actionId,
    actionKind: action.kind,
    toolName: 'memory_write',
    canonicalInputDigest: structuredActionInputDigest(action),
    createdAt: timestamp,
    updatedAt: timestamp,
    hardDeny: 'not_denied',
    skillDeny: 'not_applicable',
    approval: 'pending',
    state: ToolAttemptLifecycle.approvalPending.name,
    outcome: 'pending',
    outcomeKnown: false,
    safeSummary: 'Waiting for local memory approval.',
  );
}

const _skillProvenance = StructuredResultSkillProvenance(
  skillId: 'test-skill',
  trustDigest:
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
);

VerifiedSkillUse _verifiedSkill({required List<String> tools}) =>
    VerifiedSkillUse(
      id: _skillProvenance.skillId,
      name: 'Test skill',
      path: '/root/workspace/skills/test-skill/SKILL.md',
      skillContent: '# Test',
      capabilities: ExtensionCapabilitySnapshot(
        tools: tools,
        commands: const [],
        networkDomains: const [],
        filesystemRead: const [],
        filesystemWrite: const [],
        androidIntents: const [],
        androidPermissions: const [],
        secretNames: const [],
        runtimes: const [],
        subprocessRequired: false,
        riskTier: 'low',
        updatePolicy: 'manual',
      ),
      manifestDigest:
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      contentDigest:
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      trustDigest: _skillProvenance.trustDigest,
      legacy: false,
    );

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final class _RecordingMemoryWriteTool extends Tool {
  _RecordingMemoryWriteTool({
    this.output = '{"ok":true,"added":true,"index":0,"count":1}',
    this.onExecute,
  });

  final String output;
  final void Function()? onExecute;
  final List<Map<String, dynamic>> calls = [];

  @override
  String get name => StructuredActionRegistry.memoryWriteToolName;

  @override
  String get description => 'Test memory tool';

  @override
  Map<String, dynamic> get inputSchema =>
      MemoryWriteTool.structuredActionInputSchema;

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    calls.add(Map<String, dynamic>.from(input));
    onExecute?.call();
    return output;
  }
}
