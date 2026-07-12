import 'dart:convert';

import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/workspace_import_receipt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pending workspace import receipt survives durable session JSON', () {
    final receipt = WorkspaceImportReceipt(
      operationId: 'a' * 32,
      storedPath: '/root/workspace/uploads/report_${'a' * 32}.bin',
      size: 3,
      sha256: 'b' * 64,
      displayName: 'report.bin',
    );
    final session = ChatSession(
      id: 'workspace_receipt',
      messages: [ChatMessage.user(receipt.marker)],
      pendingWorkspaceImports: [receipt],
    );

    final restored = ChatSession.fromJson(session.toJson());

    expect(restored.pendingWorkspaceImports, hasLength(1));
    expect(restored.pendingWorkspaceImports.single.toJson(), receipt.toJson());
    expect(restored.messages.single.textContent, contains(receipt.storedPath));
    expect(
        restored.toApiMessages().toString(), isNot(contains(receipt.sha256)));
  });

  test('workspace import receipt parser rejects unknown or duplicate records',
      () {
    final receipt = WorkspaceImportReceipt(
      operationId: 'c' * 32,
      storedPath: '/root/workspace/uploads/report_${'c' * 32}.bin',
      size: 4,
      sha256: 'd' * 64,
      displayName: 'report.bin',
    );
    final unknown = receipt.toJson()..['extra'] = true;

    expect(
      () => WorkspaceImportReceipt.fromJson(unknown),
      throwsFormatException,
    );
    expect(
      () => ChatSession.fromJson({
        'id': 'duplicate_receipts',
        'messages': const [],
        'pendingWorkspaceImports': [receipt.toJson(), receipt.toJson()],
      }),
      throwsFormatException,
    );
  });

  test('unique workspace attachment paths remain stable in history JSON', () {
    const firstPath =
        '/root/workspace/uploads/report_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bin';
    const secondPath =
        '/root/workspace/uploads/report_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.bin';
    final session = ChatSession(
      id: 'immutable_attachment_paths',
      messages: [
        ChatMessage.user('[Attached: $firstPath (3 B)]'),
        ChatMessage.user('[Attached: $secondPath (3 B)]'),
      ],
    );

    final restored = ChatSession.fromJson(session.toJson());

    expect(restored.messages[0].textContent, contains(firstPath));
    expect(restored.messages[0].textContent, isNot(contains(secondPath)));
    expect(restored.messages[1].textContent, contains(secondPath));
  });

  test('set_env_var tool inputs are structurally redacted in history JSON', () {
    const sentinel = 'x';
    final content = ToolUseContent(
      id: 'tool-1',
      name: 'set_env_var',
      input: const {'name': 'NEW_TOKEN', 'value': sentinel},
    );

    expect(content.input['name'], 'NEW_TOKEN');
    expect(content.input['value'], ToolUseContent.redactedSecretValue);
    expect(content.toJson().toString(), isNot(contains(sentinel)));
    expect(content.toApiJson().toString(), isNot(contains(sentinel)));
  });

  group('ContextSummary', () {
    test('persists through ChatSession JSON', () {
      final summary = ContextSummary(
        version: 1,
        text: '## Goal\nKeep context',
        coveredMessageCount: 3,
        coveredDigest: 'abc123',
        sourceEstimatedTokens: 1200,
        summaryEstimatedTokens: 180,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
        model: 'claude-test',
        apiFormat: 'anthropic',
      );
      final session = ChatSession(
        id: 'summary_session',
        messages: [ChatMessage.user('hello')],
        contextSummary: summary,
      );

      final restored = ChatSession.fromJson(session.toJson());

      expect(restored.contextSummary, isNotNull);
      expect(restored.contextSummary!.text, summary.text);
      expect(restored.contextSummary!.coveredMessageCount, 3);
      expect(restored.contextSummary!.coveredDigest, 'abc123');
      expect(restored.contextSummary!.sourceEstimatedTokens, 1200);
      expect(restored.contextSummary!.summaryEstimatedTokens, 180);
      expect(restored.contextSummary!.model, 'claude-test');
      expect(restored.contextSummary!.apiFormat, 'anthropic');
    });

    test('loads legacy session without context summary', () {
      final restored = ChatSession.fromJson({
        'id': 'legacy',
        'title': 'Legacy',
        'createdAt': DateTime(2026).toIso8601String(),
        'updatedAt': DateTime(2026).toIso8601String(),
        'messages': [
          ChatMessage.user('old').toJson(),
        ],
      });

      expect(restored.contextSummary, isNull);
      expect(restored.messages.single.textContent, 'old');
    });
  });

  group('AgentRunRecoveryMarker', () {
    test('persists through ChatSession JSON', () {
      final startedAt = DateTime.utc(2026, 7, 7, 1, 2, 3);
      final session = ChatSession(
        id: 'agent_run_marker',
        messages: [ChatMessage.user('hello')],
        inFlightAgentRun: AgentRunRecoveryMarker(
          runAttemptId: 'run-1',
          startedAt: startedAt,
          updatedAt: startedAt,
          phase: AgentRunRecoveryPhase.toolInFlight,
          toolAttempts: [
            ToolAttemptRecoveryMetadata(
              operationId: 'operation-1',
              toolName: 'write_file',
              risk: RecoveryToolRisk.dangerous,
              lifecycle: ToolAttemptLifecycle.approvalPending,
              proposedAt: startedAt,
              updatedAt: startedAt,
            ),
          ],
          skillActivation: RecoverySkillActivationMetadata(
            sourceRunAttemptId: 'run-0',
            skillId: 'com.example.recovery',
            trustDigest: List.filled(64, 'c').join(),
          ),
        ),
      );

      final restored = ChatSession.fromJson(session.toJson());

      expect(restored.inFlightAgentRun, isNotNull);
      expect(restored.inFlightAgentRun!.startedAt, startedAt);
      expect(restored.inFlightAgentRun!.runAttemptId, 'run-1');
      expect(restored.inFlightAgentRun!.toolAttempts.single.operationId,
          'operation-1');
      expect(restored.inFlightAgentRun!.skillActivation!.sourceRunAttemptId,
          'run-0');
      expect(restored.inFlightAgentRun!.skillActivation!.skillId,
          'com.example.recovery');
      expect(restored.inFlightAgentRun!.recoveryKind,
          InterruptedRunRecoveryKind.reauthorizeAction);
    });

    test('migrates legacy startedAt-only marker with a stable attempt id', () {
      final startedAt = DateTime.utc(2026, 7, 7, 1, 2, 3);
      final json = {
        'startedAt': startedAt.toIso8601String(),
      };

      final first = AgentRunRecoveryMarker.fromJson(json);
      final second = AgentRunRecoveryMarker.fromJson(json);

      expect(first.version, AgentRunRecoveryMarker.currentVersion);
      expect(first.runAttemptId, second.runAttemptId);
      expect(first.runAttemptId, 'legacy_${startedAt.microsecondsSinceEpoch}');
      expect(first.metadataCorrupted, isFalse);
      expect(first.recoveryKind, InterruptedRunRecoveryKind.retryModelTurn);
    });

    test('corrupted recovery metadata loads fail closed without secrets', () {
      final marker = AgentRunRecoveryMarker.fromJson({
        'version': 2,
        'runAttemptId': 'bad id with spaces',
        'startedAt': 'invalid',
        'updatedAt': 'invalid',
        'phase': 'not-a-phase',
        'toolAttempts': [
          {
            'operationId': 'bad operation secret=value',
            'toolName': 'bash secret=value',
            'risk': 'not-a-risk',
            'lifecycle': 'not-a-state',
            'proposedAt': 'invalid',
            'updatedAt': 'invalid',
            'arguments': {'secret': 'must-not-load'},
          },
        ],
      });

      expect(marker.metadataCorrupted, isTrue);
      expect(marker.recoveryKind, InterruptedRunRecoveryKind.inspectOnly);
      expect(marker.toolAttempts.single.operationId, 'invalid_operation');
      expect(marker.toolAttempts.single.toolName, 'unknown');
      expect(marker.toJson().toString(), isNot(contains('must-not-load')));
      expect(marker.toJson().toString(), isNot(contains('secret=value')));
    });

    test('failed attempt after execution started has unknown outcome', () {
      final timestamp = DateTime.utc(2026, 7, 7);
      final marker = AgentRunRecoveryMarker(
        runAttemptId: 'failed-after-start',
        startedAt: timestamp,
        updatedAt: timestamp,
        phase: AgentRunRecoveryPhase.toolInFlight,
        toolAttempts: [
          ToolAttemptRecoveryMetadata(
            operationId: 'operation-failed',
            toolName: 'write_file',
            risk: RecoveryToolRisk.dangerous,
            lifecycle: ToolAttemptLifecycle.failed,
            proposedAt: timestamp,
            updatedAt: timestamp,
            executionStartedAt: timestamp,
          ),
        ],
      );

      expect(marker.recoveryKind, InterruptedRunRecoveryKind.unknownOutcome);
      expect(
        AgentRunRecoveryMarker.fromJson(marker.toJson()).recoveryKind,
        InterruptedRunRecoveryKind.unknownOutcome,
      );
    });

    test('positive terminal clear gate rejects corruption and unknown attempts',
        () {
      final timestamp = DateTime.utc(2026, 7, 7);
      final persisted = ToolAttemptRecoveryMetadata(
        operationId: 'persisted-operation',
        toolName: 'web_fetch',
        risk: RecoveryToolRisk.safe,
        lifecycle: ToolAttemptLifecycle.resultPersisted,
        proposedAt: timestamp,
        updatedAt: timestamp,
        executionStartedAt: timestamp,
        executionOutcomeKnown: true,
      );
      final unknown = ToolAttemptRecoveryMetadata(
        operationId: 'unknown-operation',
        toolName: 'write_file',
        risk: RecoveryToolRisk.dangerous,
        lifecycle: ToolAttemptLifecycle.interruptedUnknown,
        proposedAt: timestamp,
        updatedAt: timestamp,
        executionStartedAt: timestamp,
      );

      AgentRunRecoveryMarker marker({
        List<ToolAttemptRecoveryMetadata> attempts = const [],
        bool corrupted = false,
      }) =>
          AgentRunRecoveryMarker(
            runAttemptId: 'terminal-gate',
            startedAt: timestamp,
            updatedAt: timestamp,
            phase: attempts.any((attempt) => attempt.hasUnknownOutcome)
                ? AgentRunRecoveryPhase.toolInFlight
                : AgentRunRecoveryPhase.modelPending,
            toolAttempts: attempts,
            metadataCorrupted: corrupted,
          );

      expect(marker().canClearAfterPositiveTerminal, isTrue);
      expect(
          marker(attempts: [persisted]).canClearAfterPositiveTerminal, isTrue);
      expect(
          marker(attempts: [unknown]).canClearAfterPositiveTerminal, isFalse);
      expect(
        marker(attempts: [persisted, unknown]).canClearAfterPositiveTerminal,
        isFalse,
      );
      expect(marker(corrupted: true).canClearAfterPositiveTerminal, isFalse);
    });

    test('v2 strict parser rejects unknown keys and invalid invariants', () {
      Map<String, dynamic> clone(Map<String, dynamic> value) =>
          jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

      final cases = <Map<String, dynamic>>[];

      final markerFutureField = clone(_validRecoveryMarkerJson());
      markerFutureField['futureField'] = 'must fail closed';
      cases.add(markerFutureField);

      final legacyFutureField = <String, dynamic>{
        'startedAt': '2026-07-07T00:00:00.000Z',
        'futureField': 'must fail closed',
      };
      cases.add(legacyFutureField);

      final nonIntegerVersion = clone(_validRecoveryMarkerJson());
      nonIntegerVersion['version'] = 2.0;
      cases.add(nonIntegerVersion);

      final missingToolAttempts = clone(_validRecoveryMarkerJson())
        ..remove('toolAttempts');
      cases.add(missingToolAttempts);

      final attemptFutureField = clone(_validRecoveryMarkerJson());
      (attemptFutureField['toolAttempts'] as List).single['arguments'] = {
        'secret': 'must not load',
      };
      cases.add(attemptFutureField);

      final skillActivationFutureField = clone(_validRecoveryMarkerJson());
      skillActivationFutureField['skillActivation'] = {
        'sourceRunAttemptId': 'run-0',
        'skillId': 'com.example.recovery',
        'trustDigest': List.filled(64, 'c').join(),
        'futureField': true,
      };
      cases.add(skillActivationFutureField);

      final invalidSkillActivationDigest = clone(_validRecoveryMarkerJson());
      invalidSkillActivationDigest['skillActivation'] = {
        'sourceRunAttemptId': 'run-0',
        'skillId': 'com.example.recovery',
        'trustDigest': 'not-a-digest',
      };
      cases.add(invalidSkillActivationDigest);

      final attemptMissingRequiredField = clone(_validRecoveryMarkerJson());
      (attemptMissingRequiredField['toolAttempts'] as List)
          .single
          .remove('toolName');
      cases.add(attemptMissingRequiredField);

      final duplicateOperation = clone(_validRecoveryMarkerJson());
      (duplicateOperation['toolAttempts'] as List).add(
        clone((duplicateOperation['toolAttempts'] as List).single),
      );
      cases.add(duplicateOperation);

      final phaseMismatch = clone(_validRecoveryMarkerJson());
      phaseMismatch['phase'] = 'modelPending';
      cases.add(phaseMismatch);

      final markerTimeReversed = clone(_validRecoveryMarkerJson());
      markerTimeReversed['updatedAt'] = '2026-07-06T23:59:00.000Z';
      cases.add(markerTimeReversed);

      final attemptTimeReversed = clone(_validRecoveryMarkerJson());
      (attemptTimeReversed['toolAttempts'] as List).single['updatedAt'] =
          '2026-07-07T00:00:30.000Z';
      cases.add(attemptTimeReversed);

      final attemptBeforeRun = clone(_validRecoveryMarkerJson());
      (attemptBeforeRun['toolAttempts'] as List).single['proposedAt'] =
          '2026-07-06T23:59:00.000Z';
      cases.add(attemptBeforeRun);

      final resultPhaseMismatch = clone(_validRecoveryMarkerJson());
      resultPhaseMismatch['phase'] = 'toolInFlight';
      final persistedAttempt =
          (resultPhaseMismatch['toolAttempts'] as List).single;
      persistedAttempt['lifecycle'] = 'resultPersisted';
      persistedAttempt['executionOutcomeKnown'] = true;
      cases.add(resultPhaseMismatch);

      final resultOutcomeUnknown = clone(_validRecoveryMarkerJson());
      resultOutcomeUnknown['phase'] = 'modelPending';
      (resultOutcomeUnknown['toolAttempts'] as List).single['lifecycle'] =
          'resultPersisted';
      cases.add(resultOutcomeUnknown);

      final startedWithoutTimestamp = clone(_validRecoveryMarkerJson());
      (startedWithoutTimestamp['toolAttempts'] as List).single['lifecycle'] =
          'started';
      cases.add(startedWithoutTimestamp);

      final preStartKnownOutcome = clone(_validRecoveryMarkerJson());
      (preStartKnownOutcome['toolAttempts'] as List)
          .single['executionOutcomeKnown'] = true;
      cases.add(preStartKnownOutcome);

      final startedKnownOutcome = clone(_validRecoveryMarkerJson());
      final startedKnownAttempt =
          (startedKnownOutcome['toolAttempts'] as List).single;
      startedKnownAttempt['lifecycle'] = 'started';
      startedKnownAttempt['executionStartedAt'] = '2026-07-07T00:02:00.000Z';
      startedKnownAttempt['executionOutcomeKnown'] = true;
      cases.add(startedKnownOutcome);

      for (final json in cases) {
        final marker = AgentRunRecoveryMarker.fromJson(json);
        expect(marker.metadataCorrupted, isTrue, reason: json.toString());
        expect(
          marker.recoveryKind,
          InterruptedRunRecoveryKind.inspectOnly,
          reason: json.toString(),
        );
        expect(marker.toJson().toString(), isNot(contains('must not load')));
      }
    });

    test('loads legacy session without marker', () {
      final restored = ChatSession.fromJson({
        'id': 'legacy_marker',
        'title': 'Legacy',
        'createdAt': DateTime(2026).toIso8601String(),
        'updatedAt': DateTime(2026).toIso8601String(),
        'messages': [
          ChatMessage.user('old').toJson(),
        ],
      });

      expect(restored.inFlightAgentRun, isNull);
    });
  });

  group('ChatMessage reasoning_content', () {
    test('persists assistant text reasoning content through JSON', () {
      final message = ChatMessage.assistant([
        {
          'type': 'text',
          'text': 'answer',
          'reasoning_content': 'internal reasoning',
        },
      ]);

      final restored = ChatMessage.fromJson(message.toJson());

      expect(restored.textContent, 'answer');
      expect(
        (restored.content.single as TextContent).reasoningContent,
        'internal reasoning',
      );
    });

    test('preserves very long reasoning content through session JSON', () {
      final longReasoning = List.generate(
        2000,
        (index) => 'reasoning step $index',
      ).join('\n');
      final session = ChatSession(
        id: 'long_reasoning_session',
        messages: [
          ChatMessage.assistant([
            {
              'type': 'text',
              'text': 'final answer',
              'reasoning_content': longReasoning,
            },
          ]),
        ],
      );

      final restored = ChatSession.fromJson(session.toJson());
      final textContent = restored.messages.single.content.single;

      expect(restored.messages.single.textContent, 'final answer');
      expect(textContent, isA<TextContent>());
      expect((textContent as TextContent).reasoningContent, longReasoning);
    });

    test('loads legacy string content with top-level reasoning content', () {
      final restored = ChatMessage.fromJson({
        'role': 'assistant',
        'timestamp': DateTime(2026).toIso8601String(),
        'content': 'answer',
        'reasoning_content': 'internal reasoning',
      });

      expect(restored.textContent, 'answer');
      expect(
        (restored.content.single as TextContent).reasoningContent,
        'internal reasoning',
      );
    });

    test('includes reasoning_content in assistant API messages only', () {
      final assistant = ChatMessage(
        role: 'assistant',
        content: [
          TextContent(
            'answer',
            reasoningContent: 'internal reasoning',
          ),
        ],
      );
      final user = ChatMessage(
        role: 'user',
        content: [
          TextContent(
            'question',
            reasoningContent: 'should not be sent',
          ),
        ],
      );

      expect(assistant.toApiJson(), {
        'role': 'assistant',
        'content': 'answer',
        'reasoning_content': 'internal reasoning',
      });
      expect(user.toApiJson(), {
        'role': 'user',
        'content': 'question',
      });
    });
  });

  group('AssistantErrorMetadata', () {
    test('persists sanitized assistant error metadata through message JSON',
        () {
      final message = ChatMessage.assistantError(
        error: const AssistantErrorMetadata(
          message: 'OpenAI API error (503): temporarily unavailable',
          code: 'provider_unavailable',
          canRetry: true,
          source: 'provider_failure',
          fallbackReasonCode: 'no_configured_candidate',
        ),
        timestamp: DateTime.utc(2026, 1, 3),
      );

      final restored = ChatMessage.fromJson(message.toJson());

      expect(restored.hasAssistantError, isTrue);
      expect(restored.assistantError!.message, contains('503'));
      expect(restored.assistantError!.code, 'provider_unavailable');
      expect(restored.assistantError!.canRetry, isTrue);
      expect(restored.assistantError!.source, 'provider_failure');
      expect(
        restored.assistantError!.fallbackReasonCode,
        'no_configured_candidate',
      );
    });

    test('session API messages omit assistant error markers', () {
      final session = ChatSession(
        id: 'failed_session',
        messages: [
          ChatMessage.user('hello'),
          ChatMessage.assistantError(
            error: const AssistantErrorMetadata(
              message: 'provider failed',
              code: 'provider_unavailable',
              canRetry: true,
            ),
          ),
        ],
      );

      expect(session.toApiMessages(), [
        {'role': 'user', 'content': 'hello'},
      ]);
    });

    test('recovery retry provenance round-trips with safe identifiers', () {
      final message = ChatMessage.assistantError(
        error: const AssistantErrorMetadata(
          message: 'provider failed',
          code: 'provider_unavailable',
          canRetry: true,
          retryAction: AssistantRetryAction.continueRecovery,
          recoveryRunAttemptId: 'recovery-run-1',
        ),
      );

      final restored = ChatMessage.fromJson(message.toJson()).assistantError!;

      expect(restored.isRecoveryRetry, isTrue);
      expect(restored.recoveryRunAttemptId, 'recovery-run-1');
      expect(restored.retryAction, AssistantRetryAction.continueRecovery);
    });

    test('invalid recovery retry provenance disables retry fail closed', () {
      final restored = AssistantErrorMetadata.fromJson({
        'message': 'provider failed',
        'code': 'provider_unavailable',
        'can_retry': true,
        'retry_action': 'continueRecovery',
        'recovery_run_attempt_id': 'invalid id with spaces',
      });

      expect(restored.canRetry, isFalse);
      expect(restored.isRecoveryRetry, isFalse);
      expect(restored.recoveryRunAttemptId, isNull);
    });
  });

  group('ToolResultContent dual-track payload', () {
    test('round-trips new JSON while preserving ForUser output', () {
      final content = ToolResultContent(
        toolUseId: 'call_1',
        output: 'full user-visible output',
        forLlm: '{"output":"compact"}',
        summary: 'compact summary',
        metadata: const {
          'toolName': 'bash',
          'originalChars': 24,
        },
      );

      final restored = ToolResultContent.fromToolResultJson(content.toJson());

      expect(restored.output, 'full user-visible output');
      expect(restored.llmOutput, '{"output":"compact"}');
      expect(restored.summary, 'compact summary');
      expect(restored.metadata['toolName'], 'bash');
      expect(restored.toJson(), {
        'type': 'tool_result',
        'tool_use_id': 'call_1',
        'output': 'full user-visible output',
        'for_llm': '{"output":"compact"}',
        'summary': 'compact summary',
        'metadata': {
          'toolName': 'bash',
          'originalChars': 24,
        },
        'is_error': false,
      });
    });

    test('loads legacy output and API-like content fields', () {
      final legacy = ToolResultContent.fromToolResultJson({
        'type': 'tool_result',
        'tool_use_id': 'call_legacy',
        'output': 'legacy output',
      });
      final apiLike = ToolResultContent.fromToolResultJson({
        'type': 'tool_result',
        'tool_use_id': 'call_api',
        'content': ['line 1', 'line 2'],
      });

      expect(legacy.output, 'legacy output');
      expect(legacy.llmOutput, 'legacy output');
      expect(apiLike.output, 'line 1\nline 2');
      expect(apiLike.llmOutput, 'line 1\nline 2');
    });

    test('toApiJson sends ForLLM while toJson keeps ForUser', () {
      final message = ChatMessage.toolResults([
        {
          'type': 'tool_result',
          'tool_use_id': 'call_1',
          'content': 'compact for model',
          'output': 'complete user output',
          'for_llm': 'compact for model',
          'summary': 'short summary',
        },
      ]);

      expect(message.toApiJson(), {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'call_1',
            'content': 'compact for model',
          },
        ],
      });
      expect(message.toJson()['content'], [
        {
          'type': 'tool_result',
          'tool_use_id': 'call_1',
          'output': 'complete user output',
          'for_llm': 'compact for model',
          'summary': 'short summary',
          'is_error': false,
        },
      ]);
    });
  });

  group('ChatMessage alternatives', () {
    test('textContent follows active alternative without mutating latest text',
        () {
      final message = ChatMessage(
        role: 'assistant',
        content: [TextContent('latest')],
        alternatives: ['first'],
      );

      expect(message.textContent, 'latest');
      expect(message.displayIndex, 2);

      message.activeAlternative = 0;

      expect(message.textContent, 'first');
      expect(message.displayIndex, 1);
      expect((message.content.single as TextContent).text, 'latest');
    });

    test('API payload uses the active displayed alternative', () {
      final session = ChatSession(
        id: 'alt_api',
        messages: [
          ChatMessage(
            role: 'assistant',
            content: [TextContent('latest')],
            alternatives: ['first'],
            activeAlternative: 0,
          ),
        ],
      );

      expect(session.toApiMessages(), [
        {'role': 'assistant', 'content': 'first'},
      ]);
    });

    test('withNewAlternative preserves active alternative and latest text', () {
      final message = ChatMessage(
        role: 'assistant',
        content: [TextContent('latest')],
        alternatives: ['first'],
        activeAlternative: 0,
      );

      final updated = message.withNewAlternative([TextContent('new latest')]);

      expect(updated.textContent, 'new latest');
      expect(updated.alternatives, ['first', 'latest']);
    });
  });
}

Map<String, dynamic> _validRecoveryMarkerJson() => {
      'version': 2,
      'runAttemptId': 'strict-run',
      'startedAt': '2026-07-07T00:00:00.000Z',
      'updatedAt': '2026-07-07T00:10:00.000Z',
      'phase': 'toolInFlight',
      'toolAttempts': [
        {
          'operationId': 'strict-operation',
          'toolName': 'write_file',
          'risk': 'dangerous',
          'lifecycle': 'approvalPending',
          'proposedAt': '2026-07-07T00:01:00.000Z',
          'updatedAt': '2026-07-07T00:05:00.000Z',
        },
      ],
    };
