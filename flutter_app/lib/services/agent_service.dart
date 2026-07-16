import 'dart:async';
import 'package:uuid/uuid.dart';
import '../models/chat_models.dart';
import '../models/structured_result.dart';
import 'llm_content_sanitizer.dart';
import 'legacy_skill_compatibility.dart';
import 'llm_service.dart';
import 'privacy_filter.dart';
import 'runtime_debug_events.dart';
import 'skill_capability_policy.dart';
import 'skill_service.dart';
import 'tools/tool_argument_preflight.dart';
import 'tools/tool_policy.dart';
import 'tools/tool_registry.dart';
import 'tools/tool_result_formatter.dart';

sealed class AgentEvent {
  const AgentEvent();
}

class AgentThinking extends AgentEvent {}

class AgentTextDelta extends AgentEvent {
  final String text;
  AgentTextDelta(this.text);
}

class AgentReasoningDelta extends AgentEvent {
  final String text;
  AgentReasoningDelta(this.text);
}

/// Indicates that guarded assistant output exists without carrying any of it.
///
/// Tool-capable responses remain buffered until their completed tool structure
/// can be inspected. Consumers may use this signal for control-flow decisions,
/// but must not render or persist it as assistant content.
class AgentGuardedOutputObserved extends AgentEvent {
  const AgentGuardedOutputObserved();
}

class AgentStreamReset extends AgentEvent {
  const AgentStreamReset();
}

class AgentToolStart extends AgentEvent {
  final String toolUseId;
  final String operationId;
  final String toolName;
  final Map<String, dynamic> input;
  AgentToolStart(
    this.toolUseId,
    this.toolName,
    this.input, {
    required this.operationId,
  });
}

class AgentToolDone extends AgentEvent {
  final String toolUseId;
  final String operationId;
  final String output;
  final bool isError;
  AgentToolDone(
    this.toolUseId,
    this.output, {
    required this.operationId,
    this.isError = false,
  });
}

class AgentIterationDone extends AgentEvent {
  final List<Map<String, dynamic>> messages;
  AgentIterationDone(this.messages);
}

class AgentComplete extends AgentEvent {
  final String finalText;
  final int? inputTokens;
  final int? outputTokens;
  final LlmUsage? usage;
  final bool hadToolCalls;
  AgentComplete(
    this.finalText, {
    this.inputTokens,
    this.outputTokens,
    this.usage,
    this.hadToolCalls = false,
  });
}

class AgentError extends AgentEvent {
  final String message;
  final Object? cause;
  AgentError(this.message, {this.cause});
}

class ToolAttemptUpdate {
  final String runAttemptId;
  final String operationId;
  final String toolName;
  final ToolRisk risk;
  final ToolAttemptLifecycle lifecycle;
  final DateTime timestamp;
  final bool executionOutcomeKnown;

  const ToolAttemptUpdate({
    required this.runAttemptId,
    required this.operationId,
    required this.toolName,
    required this.risk,
    required this.lifecycle,
    required this.timestamp,
    required this.executionOutcomeKnown,
  });
}

class AgentCancellationSnapshot {
  final Set<String> inFlightOperationIds;

  const AgentCancellationSnapshot({
    this.inFlightOperationIds = const {},
  });

  bool get hasInFlightToolExecution => inFlightOperationIds.isNotEmpty;
}

typedef ToolAttemptObserver = FutureOr<void> Function(
  ToolAttemptUpdate update,
);

typedef AgentMessagesUpdatedCallback = FutureOr<void> Function(
  List<Map<String, dynamic>> messages,
);

/// Typed, awaited handoff for structured-result persistence.
///
/// The sink is owned by [ChatProvider]. It is the sole writer of the matching
/// user tool-result message and validated UI-only content; generic tools never
/// receive a SessionStorage dependency.
typedef StructuredResultDeliverySink = Future<bool> Function(
  StructuredResultDelivery delivery,
);

final class StructuredResultPresentation {
  const StructuredResultPresentation({
    required this.toolUseId,
    required this.operationId,
    required this.document,
    this.skillProvenance,
  });

  final String toolUseId;
  final String operationId;
  final StructuredResultDocument document;
  final StructuredResultSkillProvenance? skillProvenance;
}

final class StructuredResultDelivery {
  StructuredResultDelivery({
    required this.runAttemptId,
    required this.agentMessageCount,
    required List<Map<String, dynamic>> toolResults,
    required List<StructuredResultPresentation> presentations,
  })  : toolResults = List.unmodifiable(
          toolResults.map(Map<String, dynamic>.unmodifiable),
        ),
        presentations = List.unmodifiable(presentations);

  final String runAttemptId;
  final int agentMessageCount;
  final List<Map<String, dynamic>> toolResults;
  final List<StructuredResultPresentation> presentations;
}

class AgentService {
  final LlmService _llm;
  final ToolRegistry _tools;
  final String _systemPrompt;
  final ToolPolicy _toolPolicy;
  final SkillCapabilityPolicy? _skillCapabilityPolicy;
  final int maxIterations;
  final bool parallelTools;
  final bool privacyMode;
  final bool supportsTools;
  final Map<String, String> envVars;
  final RuntimeDebugEventService? runtimeDebugEvents;
  final String? runtimeTraceId;
  final String? sessionId;
  final String runAttemptId;
  final ToolAttemptObserver? onToolAttemptUpdate;
  final StructuredResultDeliverySink? onStructuredResultDelivery;
  final Uuid _uuid;
  final ToolArgumentPreflight _toolArgumentPreflight;
  final SkillActivationReference? _historicalSkillActivation;
  ToolCancellationSignal _toolCancellationSignal = ToolCancellationSignal();
  final Map<String, _ToolAttemptContext> _inFlightToolAttempts = {};
  final Map<String, _HistoricalSkillCall> _historicalSkillCalls = {};
  final Map<String, String> _ephemeralEnvVarValues = {};
  bool _cancelled = false;
  List<Map<String, dynamic>> _lastMessages = [];

  AgentService({
    required LlmService llm,
    required ToolRegistry tools,
    required String systemPrompt,
    ToolPolicy? toolPolicy,
    SkillCapabilityPolicy? skillCapabilityPolicy,
    this.maxIterations = 25,
    this.parallelTools = false,
    this.privacyMode = true,
    this.supportsTools = true,
    this.envVars = const {},
    this.runtimeDebugEvents,
    this.runtimeTraceId,
    this.sessionId,
    String? runAttemptId,
    this.onToolAttemptUpdate,
    this.onStructuredResultDelivery,
    Uuid? uuid,
    ToolArgumentPreflight? toolArgumentPreflight,
    SkillActivationReference? historicalSkillActivation,
  })  : _llm = llm,
        _tools = tools,
        _systemPrompt = systemPrompt,
        _toolPolicy = toolPolicy ?? const ToolPolicy(),
        _skillCapabilityPolicy = skillCapabilityPolicy,
        runAttemptId = runAttemptId ?? const Uuid().v4(),
        _uuid = uuid ?? const Uuid(),
        _historicalSkillActivation = historicalSkillActivation,
        _toolArgumentPreflight =
            toolArgumentPreflight ?? const ToolArgumentPreflight();

  AgentCancellationSnapshot cancel() {
    final snapshot = AgentCancellationSnapshot(
      inFlightOperationIds:
          Set<String>.unmodifiable(_inFlightToolAttempts.keys),
    );
    _cancelled = true;
    _ephemeralEnvVarValues.clear();
    _toolCancellationSignal.cancel();
    _llm.dispose();
    return snapshot;
  }

  bool get isCancelled => _cancelled;
  bool get hasInFlightToolExecution => _inFlightToolAttempts.isNotEmpty;
  List<Map<String, dynamic>> get messages => _lastMessages;

  /// Runs the agentic tool-use loop, streaming [AgentEvent]s as it progresses.
  ///
  /// [messages] is mutated in place during the agent loop -- the caller's list
  /// will contain all intermediate messages (assistant responses, tool results)
  /// when the stream completes. A reference is also kept in [_lastMessages] so
  /// that callers can inspect the final conversation via the [messages] getter.
  Stream<AgentEvent> runAgentLoop(
    List<Map<String, dynamic>> messages, {
    AgentMessagesUpdatedCallback? onMessagesUpdated,
  }) async* {
    _cancelled = false;
    _toolCancellationSignal = ToolCancellationSignal();
    _inFlightToolAttempts.clear();
    _ephemeralEnvVarValues.clear();
    _lastMessages = messages;
    await _restoreHistoricalSkillContext(messages);
    var toolDefs = <ToolDefinition>[];
    final effectiveMaxIterations = maxIterations.clamp(1, 99).toInt();
    int iteration = 0;
    var hadToolCalls = false;

    while (!_cancelled) {
      toolDefs = supportsTools
          ? _tools.getToolDefinitions(
              sessionId: sessionId,
              includeXds: _skillCapabilityPolicy?.activeSkill != null,
            )
          : <ToolDefinition>[];
      iteration++;
      if (iteration > effectiveMaxIterations) {
        yield AgentError(
          'Agent loop exceeded maximum iterations ($effectiveMaxIterations)',
        );
        return;
      }
      yield AgentThinking();

      LlmResponse? response;
      final guardedStreamEvents = <AgentEvent>[];
      var guardedOutputObserved = false;
      var guardedSecretConfigurationObserved = false;

      try {
        await for (final event in _llm.chatStream(
          system: _systemPrompt,
          // Keep [messages] raw for UI/session storage; the LLM receives only
          // the safe tool-result projection.
          messages: _messagesForLlm(messages),
          tools: toolDefs,
        )) {
          if (_cancelled) return;

          if (event is TextDelta) {
            final safeEvent = AgentTextDelta(
              _maskConfiguredSecrets(event.text),
            );
            if (supportsTools) {
              guardedStreamEvents.add(safeEvent);
              if (safeEvent.text.isNotEmpty && !guardedOutputObserved) {
                guardedOutputObserved = true;
                yield const AgentGuardedOutputObserved();
              }
            } else {
              yield safeEvent;
            }
          } else if (event is ReasoningDelta) {
            final safeEvent = AgentReasoningDelta(
              _maskConfiguredSecrets(event.text),
            );
            if (supportsTools) {
              guardedStreamEvents.add(safeEvent);
              if (safeEvent.text.isNotEmpty && !guardedOutputObserved) {
                guardedOutputObserved = true;
                yield const AgentGuardedOutputObserved();
              }
            } else {
              yield safeEvent;
            }
          } else if (event is StreamReset) {
            guardedStreamEvents.clear();
            guardedOutputObserved = false;
            guardedSecretConfigurationObserved = false;
            yield const AgentStreamReset();
          } else if (event is ToolUseStart && event.name == 'set_env_var') {
            // Bind the whole assistant turn to structural redaction as soon as
            // the tool identity is known. Do not wait for StreamDone: a
            // malformed final response must not release earlier narrative.
            guardedSecretConfigurationObserved = true;
          } else if (event is StreamDone) {
            response = event.response;
          } else if (event is StreamError) {
            yield AgentError(event.message, cause: event.cause);
            return;
          }
        }
      } catch (e) {
        yield AgentError('LLM request failed: $e', cause: e);
        return;
      }

      if (response == null) {
        yield AgentError('No LLM response received');
        return;
      }

      final hasSecretConfiguration = guardedSecretConfigurationObserved ||
          response.content.any((block) {
            final json = block.toJson();
            return json['type'] == 'tool_use' && json['name'] == 'set_env_var';
          });
      if (supportsTools) {
        if (hasSecretConfiguration) {
          if (guardedStreamEvents.isNotEmpty) {
            yield AgentTextDelta(_secretConfigurationMarker);
          }
        } else {
          for (final event in guardedStreamEvents) {
            yield event;
          }
        }
        guardedStreamEvents.clear();
      }
      messages.add({
        'role': 'assistant',
        'content': response.content
            .map((block) => _sanitizeAssistantBlockForPersistence(
                  block.toJson(),
                  redactNarrative: hasSecretConfiguration,
                ))
            .toList(),
      });
      if (onMessagesUpdated != null) {
        await onMessagesUpdated(messages);
      }

      if (response.stopReason != 'tool_use') {
        final finalText = hasSecretConfiguration
            ? _secretConfigurationMarker
            : response.content
                .where((b) => b.type == 'text')
                .map((b) => b.text ?? '')
                .join();
        yield AgentComplete(
          _maskConfiguredSecrets(finalText),
          inputTokens: response.inputTokens,
          outputTokens: response.outputTokens,
          usage: response.usage,
          hadToolCalls: hadToolCalls,
        );
        return;
      }

      final toolBlocks =
          response.content.where((b) => b.type == 'tool_use').toList();
      if (toolBlocks.isNotEmpty) hadToolCalls = true;
      final toolResults = <Map<String, dynamic>>[];
      final deferredStructuredResults = <_ToolResult>[];

      final toolInputs = <ContentBlock, Map<String, dynamic>>{};
      final toolAttempts = <ContentBlock, _ToolAttemptContext>{};
      for (final block in toolBlocks) {
        final toolUseId = block.toolUseId;
        final toolName = block.toolName;
        if (toolUseId == null || toolName == null) continue;
        final preflightInput = _preflightToolInput(
          toolName,
          toolName == StructuredResultIngress.toolName
              ? block.toolInput ?? const <String, dynamic>{}
              : block.rawToolInputJson ?? block.toolInput ?? {},
        );
        final attempt = _ToolAttemptContext(
          operationId: _uuid.v4(),
          toolUseId: toolUseId,
          toolName: toolName,
          risk: _tools.riskFor(toolName),
        );
        toolAttempts[block] = attempt;
        await _reportToolAttempt(
          attempt,
          ToolAttemptLifecycle.proposed,
          executionOutcomeKnown: false,
        );
        final toolInput = _ingestToolInput(attempt, preflightInput);
        toolInputs[block] = toolInput;
        final eventInput = hasSecretConfiguration && toolName != 'set_env_var'
            ? const <String, dynamic>{'redacted': true}
            : toolInput;
        yield AgentToolStart(
          toolUseId,
          toolName,
          Map<String, dynamic>.from(
            _maskConfiguredSecretsInValue(eventInput) as Map,
          ),
          operationId: attempt.operationId,
        );
      }

      final skillBatchPlan = hasSecretConfiguration
          ? const _SkillBatchPlan()
          : await _prepareSkillBatch(
              toolBlocks,
              toolInputs,
              toolAttempts,
            );
      ToolDenyDecision? secretBatchDenialFor(ContentBlock block) =>
          hasSecretConfiguration && block.toolName != 'set_env_var'
              ? const ToolDenyDecision(
                  ruleType: 'secret_operation',
                  ruleId: 'secret_operation_batch_exclusive',
                  message:
                      'Other tools cannot run in the same response as secret configuration.',
                )
              : null;

      if (parallelTools &&
          toolBlocks.length > 1 &&
          !hasSecretConfiguration &&
          !skillBatchPlan.requiresSequentialExecution) {
        final futures = toolBlocks.map((block) async {
          if (_cancelled) return null;
          final toolUseId = block.toolUseId;
          final toolName = block.toolName;
          if (toolUseId == null || toolName == null) return null;
          final toolInput = toolInputs[block] ?? block.toolInput ?? {};
          final attempt = toolAttempts[block];
          if (attempt == null) return null;
          return _executeToolWithPolicy(
            attempt,
            toolInput,
            forcedDenial:
                secretBatchDenialFor(block) ?? skillBatchPlan.denialFor(block),
            preparedSkillActivation: skillBatchPlan.preparedFor(block),
          );
        }).toList();
        final results = await Future.wait(futures);
        if (_cancelled) return;
        for (final r in results) {
          if (r == null) continue;
          if (r.structuredResult == null) {
            yield AgentToolDone(
              r.id,
              r.output,
              operationId: r.operationId,
              isError: r.isError,
            );
          } else {
            deferredStructuredResults.add(r);
          }
          toolResults.add(r.toJson());
        }
      } else {
        for (final block in toolBlocks) {
          if (_cancelled) return;
          final toolUseId = block.toolUseId;
          final toolName = block.toolName;
          if (toolUseId == null || toolName == null) continue;
          final toolInput = toolInputs[block] ?? block.toolInput ?? {};
          final attempt = toolAttempts[block];
          if (attempt == null) continue;

          final result = await _executeToolWithPolicy(
            attempt,
            toolInput,
            forcedDenial:
                secretBatchDenialFor(block) ?? skillBatchPlan.denialFor(block),
            preparedSkillActivation: skillBatchPlan.preparedFor(block),
          );
          if (_cancelled) return;
          if (result.structuredResult == null) {
            yield AgentToolDone(
              result.id,
              result.output,
              operationId: result.operationId,
              isError: result.isError,
            );
          } else {
            deferredStructuredResults.add(result);
          }
          toolResults.add(result.toJson());
        }
      }

      var structuredDeliveryPersisted = false;
      if (deferredStructuredResults.isNotEmpty) {
        final sink = onStructuredResultDelivery;
        if (sink != null) {
          try {
            structuredDeliveryPersisted = await sink(StructuredResultDelivery(
              runAttemptId: runAttemptId,
              agentMessageCount: messages.length + 1,
              toolResults: toolResults,
              presentations: deferredStructuredResults
                  .map(
                    (result) => StructuredResultPresentation(
                      toolUseId: result.id,
                      operationId: result.operationId,
                      document: result.structuredResult!.document,
                      skillProvenance: result.structuredResultSkillProvenance,
                    ),
                  )
                  .toList(growable: false),
            ));
          } catch (_) {
            structuredDeliveryPersisted = false;
          }
        }
        if (structuredDeliveryPersisted) {
          for (final result in deferredStructuredResults) {
            final attempt = toolAttempts.values
                .where((item) => item.operationId == result.operationId)
                .firstOrNull;
            if (attempt != null) {
              await _reportToolAttempt(
                attempt,
                ToolAttemptLifecycle.completed,
                executionOutcomeKnown: true,
              );
            }
            yield AgentToolDone(
              result.id,
              result.output,
              operationId: result.operationId,
              isError: false,
            );
          }
        } else {
          for (final result in deferredStructuredResults) {
            final index = toolResults.indexWhere((item) =>
                item['metadata'] is Map &&
                (item['metadata'] as Map)['operationId'] == result.operationId);
            final failure = await _structuredResultSinkFailure(result);
            if (index >= 0) toolResults[index] = failure.toJson();
            yield AgentToolDone(
              failure.id,
              failure.output,
              operationId: failure.operationId,
              isError: true,
            );
          }
        }
      }

      messages.add({
        'role': 'user',
        'content': toolResults,
      });
      if (!structuredDeliveryPersisted && onMessagesUpdated != null) {
        await onMessagesUpdated(messages);
      }
      if (structuredDeliveryPersisted || onMessagesUpdated != null) {
        for (final result in toolResults) {
          final operationId = result['metadata'] is Map
              ? (result['metadata'] as Map)['operationId']?.toString()
              : null;
          if (operationId == null) continue;
          final attempt = toolAttempts.values
              .where((candidate) => candidate.operationId == operationId)
              .firstOrNull;
          if (attempt != null) {
            await _reportToolAttempt(
              attempt,
              ToolAttemptLifecycle.resultPersisted,
              executionOutcomeKnown: true,
            );
          }
        }
      }
      yield AgentIterationDone(messages);
    }
  }

  List<Map<String, dynamic>> _messagesForLlm(
    List<Map<String, dynamic>> messages,
  ) {
    return messages.map((msg) {
      final content = msg['content'];
      if (content is! List) return msg;

      var changed = false;
      final filteredContent = content
          .map((block) {
            if (block is Map && block['type'] == 'tool_result') {
              final id = block['tool_use_id']?.toString();
              if (id == null || id.isEmpty) {
                changed = true;
                return null;
              }
              changed = true;
              final skillCall = _skillHistoryCall(block, id);
              final projected = <String, dynamic>{
                'type': 'tool_result',
                'tool_use_id': id,
                'content': skillCall == null
                    ? _safeToolResultContent(block)
                    : _verifiedHistoricalSkillContent(block, skillCall),
                if (block['is_error'] == true) 'is_error': true,
              };
              return projected;
            }
            return block;
          })
          .where((block) => block != null)
          .toList();

      if (!changed) return msg;
      return {
        ...msg,
        'content': filteredContent,
      };
    }).toList();
  }

  _HistoricalSkillCall? _skillHistoryCall(
    Map<dynamic, dynamic> block,
    String id,
  ) {
    final metadata = block['metadata'];
    if (metadata is Map && metadata['skillId'] is String) {
      return _HistoricalSkillCall(
        id: metadata['skillId'] as String,
        path: metadata['skillEntrypoint'] as String?,
      );
    }
    return _historicalSkillCalls[id];
  }

  String _verifiedHistoricalSkillContent(
    Map<dynamic, dynamic> block,
    _HistoricalSkillCall call,
  ) {
    final active = _skillCapabilityPolicy?.activeSkill;
    final metadata = block['metadata'];
    final expectedDigest =
        metadata is Map ? metadata['skillTrustDigest']?.toString() : null;
    if (active == null ||
        (call.id != null && active.id != call.id) ||
        (call.path != null && active.path != call.path) ||
        (expectedDigest != null && expectedDigest != active.trustDigest)) {
      return 'Historical skill content unavailable: consent is missing or stale.';
    }
    final refreshed = _formatVerifiedSkillRead(
      active.skillContent,
      const <String, dynamic>{},
    );
    final sanitized = const LlmContentSanitizer().sanitizeText(refreshed).text;
    return _maskConfiguredSecrets(sanitized);
  }

  String _safeToolResultContent(Map<dynamic, dynamic> block) {
    final raw = ToolResultPayload.stringifyContent(
      block['for_llm'] ?? block['content'] ?? block['output'],
    );
    final sanitized = const LlmContentSanitizer().sanitizeText(raw).text;
    return _maskConfiguredSecrets(sanitized);
  }

  Future<_ToolResult> _executeToolWithPolicy(
    _ToolAttemptContext attempt,
    Map<String, dynamic> toolInput, {
    ToolDenyDecision? forcedDenial,
    VerifiedSkillUse? preparedSkillActivation,
  }) async {
    final toolUseId = attempt.toolUseId;
    final toolName = attempt.toolName;
    if (!_tools.hasTool(toolName)) {
      _clearEphemeralToolInput(attempt.operationId);
      const output = 'Tool error: Unknown tool';
      await _reportToolAttempt(
        attempt,
        ToolAttemptLifecycle.failed,
        executionOutcomeKnown: true,
      );
      return _ToolResult(
        toolUseId,
        attempt.operationId,
        ToolResultPayload(
          forUser: '$output: $toolName',
          forLlm: '$output: $toolName',
          summary: '$output: $toolName',
          metadata: const {'toolName': 'unknown', 'status': 'error'},
        ),
        true,
      );
    }

    StructuredResultIngress? structuredResult;
    if (toolName == StructuredResultIngress.toolName) {
      try {
        structuredResult = StructuredResultIngress.parseOuter(toolInput);
      } on StructuredResultParseException {
        await _reportToolAttempt(
          attempt,
          ToolAttemptLifecycle.failed,
          executionOutcomeKnown: true,
        );
        return _invalidStructuredResult(attempt);
      }
    }
    final request = ToolApprovalRequest(
      toolName: toolName,
      arguments: Map<String, dynamic>.from(toolInput),
      risk: _tools.riskFor(toolName),
      runAttemptId: runAttemptId,
      operationId: attempt.operationId,
    );
    if (forcedDenial != null) {
      return _denyToolForPolicy(attempt, forcedDenial);
    }
    if (toolName != 'set_env_var' &&
        _valueContainsConfiguredSecret(toolInput)) {
      return _denyToolForPolicy(
        attempt,
        const ToolDenyDecision(
          ruleType: 'skill_capability',
          ruleId: 'secret_tool_argument',
          message: 'Configured secret values cannot be passed to tools.',
        ),
      );
    }
    VerifiedSkillUse? verifiedSkillRead = preparedSkillActivation;
    try {
      verifiedSkillRead ??=
          await _skillCapabilityPolicy?.prepareSkillActivation(request);
    } on SkillCapabilityViolation catch (violation) {
      return _denyToolForPolicy(
        attempt,
        ToolDenyDecision(
          ruleType: 'skill_capability',
          ruleId: violation.ruleId,
          message: violation.message,
        ),
      );
    } catch (_) {
      return _denyToolForPolicy(
        attempt,
        const ToolDenyDecision(
          ruleType: 'skill_capability',
          ruleId: 'skill_grant_invalid',
          message: 'Skill is disabled, changed, or no longer consented.',
        ),
      );
    }
    final denyDecision = _toolPolicy.denyFor(request);
    if (denyDecision != null) {
      return _denyToolForPolicy(attempt, denyDecision);
    }
    if (preparedSkillActivation == null &&
        _toolPolicy.requiresApproval(request.risk)) {
      await _reportToolAttemptBeforeSecretExecution(
        attempt,
        ToolAttemptLifecycle.approvalPending,
        executionOutcomeKnown: false,
      );
    }
    late final bool approved;
    try {
      approved = preparedSkillActivation != null
          ? true
          : await _toolPolicy.approve(request);
    } catch (_) {
      return _denyToolForPolicy(
        attempt,
        const ToolDenyDecision(
          ruleType: 'approval',
          ruleId: 'approval_failed',
          message: 'Tool approval failed closed.',
        ),
      );
    }
    if (!approved) {
      _clearEphemeralToolInput(attempt.operationId);
      await _reportToolAttempt(
        attempt,
        ToolAttemptLifecycle.failed,
        executionOutcomeKnown: true,
      );
      return _ToolResult(
        toolUseId,
        attempt.operationId,
        ToolResultPayload(
          forUser: 'tool execution denied by user: $toolName',
          forLlm: 'tool execution denied by user: $toolName',
          summary: 'tool execution denied by user: $toolName',
          metadata: {'toolName': toolName, 'status': 'error'},
        ),
        true,
      );
    }
    await _reportToolAttemptBeforeSecretExecution(
      attempt,
      ToolAttemptLifecycle.approvedNotStarted,
      executionOutcomeKnown: false,
    );
    if (_cancelled) {
      _clearEphemeralToolInput(attempt.operationId);
      await _reportToolAttempt(
        attempt,
        ToolAttemptLifecycle.failed,
        executionOutcomeKnown: true,
      );
      return _cancelledToolResult(attempt);
    }
    _inFlightToolAttempts[attempt.operationId] = attempt;
    await _reportToolAttemptBeforeSecretExecution(
      attempt,
      ToolAttemptLifecycle.started,
      executionOutcomeKnown: false,
    );

    try {
      if (structuredResult != null) {
        final activeSkill = _skillCapabilityPolicy?.activeSkill;
        return _ToolResult(
          toolUseId,
          attempt.operationId,
          ToolResultPayload(
            forUser: 'Structured result ready.',
            forLlm: structuredResult.document.projection,
            summary: 'Structured result stored.',
            metadata: {
              'status': 'ok',
              'toolName': StructuredResultIngress.toolName,
              'resultId': structuredResult.document.resultId,
              'schemaVersion': structuredResult.document.schemaVersion,
            },
          ),
          false,
          structuredResult: structuredResult,
          structuredResultSkillProvenance: activeSkill == null
              ? null
              : StructuredResultSkillProvenance(
                  skillId: activeSkill.id,
                  trustDigest: activeSkill.trustDigest,
                ),
        );
      }
      if (verifiedSkillRead != null) {
        _skillCapabilityPolicy?.activate(verifiedSkillRead);
        final output = _formatVerifiedSkillRead(
          verifiedSkillRead.skillContent,
          toolInput,
        );
        final formatted = ToolResultFormatter.format(
          toolName: 'load_skill',
          input: toolInput,
          output: output,
        );
        final payload = _protectToolResultPayload(ToolResultPayload(
          forUser: formatted.forUser,
          forLlm: formatted.forLlm,
          summary: formatted.summary,
          metadata: {
            ...formatted.metadata,
            'skillId': verifiedSkillRead.id,
            'skillTrustDigest': verifiedSkillRead.trustDigest,
            'skillEntrypoint': verifiedSkillRead.path,
            'skillRunAttemptId': runAttemptId,
          },
        ));
        await _reportToolAttempt(
          attempt,
          ToolAttemptLifecycle.completed,
          executionOutcomeKnown: true,
        );
        return _ToolResult(toolUseId, attempt.operationId, payload, false);
      }
      final executionInput = _consumeExecutionInput(attempt, toolInput);
      var rawPayload = await _tools.executeToolResult(
        toolName,
        executionInput,
        sessionId: sessionId,
        operationId: attempt.operationId,
        cancellationSignal: _toolCancellationSignal,
        allowedNetworkDomains: _skillCapabilityPolicy
            ?.activeSkill?.capabilities.networkDomains
            .toSet(),
        allowedFilesystemReadScopes: _skillCapabilityPolicy
            ?.activeSkill?.capabilities.filesystemRead
            .toSet(),
        allowedFilesystemWriteScopes: _skillCapabilityPolicy
            ?.activeSkill?.capabilities.filesystemWrite
            .toSet(),
      );
      final operationSecret = _ephemeralEnvVarValues[attempt.operationId];
      if (operationSecret != null && operationSecret.isNotEmpty) {
        rawPayload = _redactOperationSecret(rawPayload, operationSecret);
      }
      final payload = _protectToolResultPayload(rawPayload);
      if (_cancelled) return _cancelledToolResult(attempt);
      await _reportToolAttempt(
        attempt,
        ToolAttemptLifecycle.completed,
        executionOutcomeKnown: true,
      );
      return _ToolResult(toolUseId, attempt.operationId, payload, false);
    } on ToolExecutionCancelledException catch (e) {
      await _reportToolAttempt(
        attempt,
        ToolAttemptLifecycle.failed,
        executionOutcomeKnown: e.sideEffectsPrevented,
      );
      return _cancelledToolResult(attempt);
    } catch (e) {
      await _reportToolAttempt(
        attempt,
        ToolAttemptLifecycle.failed,
        executionOutcomeKnown: false,
      );
      final safeError = toolName == 'set_env_var'
          ? e is StateError && e.message.toString().contains('unavailable')
              ? 'Tool error: secret value unavailable after restart; enter it again.'
              : 'Tool error: secret operation failed.'
          : _maskConfiguredSecrets('Tool error: $e');
      return _ToolResult(
        toolUseId,
        attempt.operationId,
        ToolResultPayload(
          forUser: safeError,
          forLlm: safeError,
          summary: safeError,
          metadata: {'toolName': toolName, 'status': 'error'},
        ),
        true,
      );
    } finally {
      _clearEphemeralToolInput(attempt.operationId);
      _inFlightToolAttempts.remove(attempt.operationId);
    }
  }

  Future<_ToolResult> _denyToolForPolicy(
    _ToolAttemptContext attempt,
    ToolDenyDecision decision,
  ) async {
    _clearEphemeralToolInput(attempt.operationId);
    _recordRuntimeEvent('tool.execution.denied', {
      'runAttemptId': runAttemptId,
      'operationId': attempt.operationId,
      'ruleType': decision.ruleType,
      'ruleId': decision.ruleId,
    });
    await _reportToolAttempt(
      attempt,
      ToolAttemptLifecycle.failed,
      executionOutcomeKnown: true,
    );
    return _ToolResult(
      attempt.toolUseId,
      attempt.operationId,
      ToolResultPayload(
        forUser: decision.message,
        forLlm: decision.message,
        summary: decision.message,
        metadata: {
          'status': 'error',
          'denyRuleType': decision.ruleType,
          'denyRuleId': decision.ruleId,
        },
      ),
      true,
    );
  }

  Future<_ToolResult> _structuredResultSinkFailure(_ToolResult result) async {
    final attempt = _ToolAttemptContext(
      operationId: result.operationId,
      toolUseId: result.id,
      toolName: StructuredResultIngress.toolName,
      risk: ToolRisk.safe,
    );
    await _reportToolAttempt(
      attempt,
      ToolAttemptLifecycle.failed,
      executionOutcomeKnown: true,
    );
    return _ToolResult(
      result.id,
      result.operationId,
      const ToolResultPayload(
        forUser: 'Structured result rejected: persistence unavailable.',
        forLlm: 'Structured result rejected: persistence unavailable.',
        summary: 'Structured result persistence failed.',
        metadata: {
          'status': 'error',
          'reasonCode': 'structured_result_persistence_failed',
        },
      ),
      true,
    );
  }

  _ToolResult _invalidStructuredResult(_ToolAttemptContext attempt) =>
      _ToolResult(
        attempt.toolUseId,
        attempt.operationId,
        const ToolResultPayload(
          forUser: 'Structured result rejected: invalid_structured_result.',
          forLlm: 'Structured result rejected: invalid_structured_result.',
          summary: 'Structured result rejected.',
          metadata: {
            'status': 'error',
            'reasonCode': 'invalid_structured_result',
          },
        ),
        true,
      );

  String _formatVerifiedSkillRead(
    String content,
    Map<String, dynamic> input,
  ) {
    final offset = (input['offset'] as num?)?.toInt() ?? 1;
    final limit = (input['limit'] as num?)?.toInt() ?? 2000;
    final lines = content.split('\n');
    final start = (offset - 1).clamp(0, lines.length).toInt();
    final end = (start + limit.clamp(1, 2000)).clamp(0, lines.length).toInt();
    final buffer = StringBuffer();
    for (var index = start; index < end; index++) {
      buffer.writeln('${index + 1}\t${lines[index]}');
      if (buffer.length > 100000) break;
    }
    final result = buffer.toString();
    return result.length <= 100000
        ? result
        : '${result.substring(0, 100000)}\n\n[File truncated]';
  }

  Future<void> _restoreHistoricalSkillContext(
    List<Map<String, dynamic>> messages,
  ) async {
    _historicalSkillCalls.clear();
    final latestId = _historicalSkillActivation?.id;
    final latestDigest = _historicalSkillActivation?.trustDigest;
    for (final message in messages) {
      final content = message['content'];
      if (content is! List) continue;
      for (final rawBlock in content) {
        if (rawBlock is! Map) continue;
        if (rawBlock['type'] == 'tool_use') {
          final toolName = rawBlock['name'] ?? rawBlock['tool_name'];
          final input = rawBlock['input'] ?? rawBlock['tool_input'];
          final id = rawBlock['id'] ?? rawBlock['tool_use_id'];
          final path = input is Map ? input['path'] : null;
          final skillId = input is Map ? input['id'] : null;
          if (toolName == 'load_skill' && id is String && skillId is String) {
            _historicalSkillCalls[id] = _HistoricalSkillCall(id: skillId);
          } else if (toolName == 'read_file' &&
              id is String &&
              path is String &&
              SkillService.isInstalledSkillEntrypoint(path)) {
            _historicalSkillCalls[id] = _HistoricalSkillCall(path: path);
          }
        }
      }
    }
    final policy = _skillCapabilityPolicy;
    if (policy == null || latestId == null) return;
    try {
      await policy.restoreGrantedSkill(
        latestId,
        expectedTrustDigest: latestDigest,
      );
    } catch (_) {
      policy.markHistoricalRestoreFailed();
      // _messagesForLlm replaces historical skill bytes with a closed error.
    }
  }

  Future<_SkillBatchPlan> _prepareSkillBatch(
    List<ContentBlock> toolBlocks,
    Map<ContentBlock, Map<String, dynamic>> toolInputs,
    Map<ContentBlock, _ToolAttemptContext> toolAttempts,
  ) async {
    final policy = _skillCapabilityPolicy;
    if (policy == null) return const _SkillBatchPlan();
    final activations = <ContentBlock>[];
    for (final block in toolBlocks) {
      if (block.toolName == 'load_skill') activations.add(block);
      if (block.toolName == 'read_file') {
        final path = toolInputs[block]?['path'];
        if (path is String && SkillService.isInstalledSkillEntrypoint(path)) {
          return _SkillBatchPlan.failed(
            toolBlocks,
            const ToolDenyDecision(
              ruleType: 'skill_capability',
              ruleId: 'skill_activation_required',
              message: 'Skills can only be activated with load_skill.',
            ),
          );
        }
      }
    }
    if (activations.isEmpty) return const _SkillBatchPlan();
    if (activations.length != 1) {
      return _SkillBatchPlan.failed(
        toolBlocks,
        const ToolDenyDecision(
          ruleType: 'skill_capability',
          ruleId: 'skill_activation_ambiguous',
          message: 'A tool batch may activate exactly one skill.',
        ),
      );
    }
    final activation = activations.single;
    final activationAttempt = toolAttempts[activation];
    if (activationAttempt == null) {
      return _SkillBatchPlan.failed(
        toolBlocks,
        const ToolDenyDecision(
          ruleType: 'approval',
          ruleId: 'approval_identity_missing',
          message: 'Tool approval identity is unavailable.',
        ),
      );
    }
    final activationIndex = toolBlocks.indexOf(activation);
    final input = toolInputs[activation] ?? const <String, dynamic>{};
    final request = ToolApprovalRequest(
      toolName: 'load_skill',
      arguments: Map<String, dynamic>.from(input),
      risk: _tools.riskFor('load_skill'),
      runAttemptId: runAttemptId,
      operationId: activationAttempt.operationId,
    );
    final globalDenial = _toolPolicy.denyFor(request);
    if (globalDenial != null) {
      return _SkillBatchPlan.failed(toolBlocks, globalDenial);
    }
    try {
      final verified = await policy.prepareSkillActivation(request);
      if (verified == null) {
        throw StateError('Skill activation was not prepared.');
      }
      if (_toolPolicy.requiresApproval(request.risk)) {
        await _reportToolAttempt(
          activationAttempt,
          ToolAttemptLifecycle.approvalPending,
          executionOutcomeKnown: false,
        );
      }
      if (!await _toolPolicy.approve(request)) {
        return _SkillBatchPlan.failed(
          toolBlocks,
          const ToolDenyDecision(
            ruleType: 'skill_capability',
            ruleId: 'skill_activation_denied',
            message: 'Skill activation was denied.',
          ),
        );
      }
      policy.activate(verified);
      return _SkillBatchPlan(
        activationBlock: activation,
        preparedActivation: verified,
        preActivationBlocks: toolBlocks.take(activationIndex).toSet(),
      );
    } catch (_) {
      return _SkillBatchPlan.failed(
        toolBlocks,
        const ToolDenyDecision(
          ruleType: 'skill_capability',
          ruleId: 'skill_grant_invalid',
          message: 'Skill is disabled, changed, or no longer consented.',
        ),
      );
    }
  }

  _ToolResult _cancelledToolResult(_ToolAttemptContext attempt) {
    const message = 'Tool execution cancelled';
    return _ToolResult(
      attempt.toolUseId,
      attempt.operationId,
      const ToolResultPayload(
        forUser: message,
        forLlm: message,
        summary: message,
        metadata: {'status': 'cancelled'},
      ),
      true,
    );
  }

  Future<void> _reportToolAttempt(
    _ToolAttemptContext attempt,
    ToolAttemptLifecycle lifecycle, {
    required bool executionOutcomeKnown,
  }) async {
    final timestamp = DateTime.now();
    final observer = onToolAttemptUpdate;
    if (observer != null) {
      await observer(ToolAttemptUpdate(
        runAttemptId: runAttemptId,
        operationId: attempt.operationId,
        toolName: _safeToolNameForMetadata(attempt.toolName),
        risk: attempt.risk,
        lifecycle: lifecycle,
        timestamp: timestamp,
        executionOutcomeKnown: executionOutcomeKnown,
      ));
    }
    _recordRuntimeEvent('tool.attempt.${lifecycle.name}', {
      'runAttemptId': runAttemptId,
      'operationId': attempt.operationId,
      'toolName': _safeToolNameForMetadata(attempt.toolName),
      'risk': attempt.risk.name,
    });
  }

  Future<void> _reportToolAttemptBeforeSecretExecution(
    _ToolAttemptContext attempt,
    ToolAttemptLifecycle lifecycle, {
    required bool executionOutcomeKnown,
  }) async {
    try {
      await _reportToolAttempt(
        attempt,
        lifecycle,
        executionOutcomeKnown: executionOutcomeKnown,
      );
    } catch (_) {
      _clearEphemeralToolInput(attempt.operationId);
      _inFlightToolAttempts.remove(attempt.operationId);
      rethrow;
    }
  }

  String _safeToolNameForMetadata(String toolName) {
    if (toolName.isEmpty ||
        toolName.length > 120 ||
        !RegExp(r'^[a-zA-Z0-9._:-]+$').hasMatch(toolName)) {
      return 'unknown';
    }
    return toolName;
  }

  Map<String, dynamic> _preflightToolInput(
    String toolName,
    Object? rawToolInput,
  ) {
    if (toolName == StructuredResultIngress.toolName) {
      // This ingress is intentionally excluded from generic coercion, field
      // renaming, and JSON-closure repair. The provider-decoded outer map must
      // already be the one-field schema before the inner raw JSON is parsed.
      try {
        return {
          'documentJson':
              StructuredResultIngress.parseOuter(rawToolInput).documentJson,
        };
      } on StructuredResultParseException {
        return const <String, dynamic>{};
      }
    }
    if (toolName == LegacySkillCompatibility.xdsToolName) {
      // XDS has a closed operation schema. Preserve the provider-decoded map
      // exactly so generic field-name/type repair cannot turn an unsupported
      // request into a valid remote call.
      return rawToolInput is Map
          ? Map<String, dynamic>.from(rawToolInput)
          : const <String, dynamic>{};
    }
    final schema = _tools.inputSchemaFor(toolName, sessionId: sessionId);
    if (schema == null) {
      return rawToolInput is Map
          ? Map<String, dynamic>.from(rawToolInput)
          : const {};
    }
    final result = _toolArgumentPreflight.repair(rawToolInput, schema);
    if (result.repaired) {
      _recordRuntimeEvent('tool.preflight.repaired', {
        'repairCount': result.repairCounts.values
            .fold<int>(0, (sum, count) => sum + count),
        if (result.repairCounts['json_closure'] case final count?)
          'jsonClosureRepairCount': count,
        if (result.repairCounts['field_name'] case final count?)
          'fieldNameRepairCount': count,
        if (result.repairCounts['type_coercion'] case final count?)
          'typeCoercionRepairCount': count,
      });
    }
    return result.arguments;
  }

  void _recordRuntimeEvent(String type, Map<String, Object?> data) {
    final service = runtimeDebugEvents;
    final id = sessionId;
    if (service == null || id == null) return;
    try {
      service.record(RuntimeDebugEvent(
        type: type,
        sessionId: id,
        traceId: runtimeTraceId,
        data: data,
      ));
    } catch (_) {
      // Debug events must never affect tool execution.
    }
  }

  String _maskConfiguredSecrets(String value) =>
      envVars.isEmpty ? value : PrivacyFilter.maskEnvVarValues(value, envVars);

  bool _valueContainsConfiguredSecret(Object? value) {
    if (envVars.isEmpty) return false;
    if (value is String) {
      return envVars.values.any(
        (secret) =>
            PrivacyFilter.isDistinctiveSecret(secret) && value.contains(secret),
      );
    }
    if (value is Map) {
      return value.values.any(_valueContainsConfiguredSecret);
    }
    if (value is Iterable) {
      return value.any(_valueContainsConfiguredSecret);
    }
    return false;
  }

  Object? _maskConfiguredSecretsInValue(Object? value) {
    if (value is String) return _maskConfiguredSecrets(value);
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          if (entry.key is String)
            entry.key as String: _maskConfiguredSecretsInValue(entry.value),
      };
    }
    if (value is Iterable) {
      return value.map(_maskConfiguredSecretsInValue).toList();
    }
    return value;
  }

  Map<String, dynamic> _sanitizeAssistantBlockForPersistence(
      Map<String, dynamic> block,
      {required bool redactNarrative}) {
    final sanitized = Map<String, dynamic>.from(
      _maskConfiguredSecretsInValue(block) as Map,
    );
    if (redactNarrative && sanitized['type'] == 'text') {
      return const <String, dynamic>{
        'type': 'text',
        'text': _secretConfigurationMarker,
      };
    }
    if (redactNarrative &&
        sanitized['type'] == 'tool_use' &&
        sanitized['name'] != 'set_env_var') {
      sanitized['input'] = const <String, dynamic>{'redacted': true};
      return sanitized;
    }
    if (sanitized['type'] != 'tool_use' || sanitized['name'] != 'set_env_var') {
      return sanitized;
    }
    final input = sanitized['input'];
    if (input is Map && input.containsKey('value')) {
      sanitized['input'] = <String, dynamic>{
        for (final entry in input.entries)
          if (entry.key is String)
            entry.key as String: entry.key == 'value'
                ? ToolUseContent.redactedSecretValue
                : entry.value,
      };
    }
    return sanitized;
  }

  Map<String, dynamic> _ingestToolInput(
    _ToolAttemptContext attempt,
    Map<String, dynamic> input,
  ) {
    if (attempt.toolName != 'set_env_var' || !input.containsKey('value')) {
      return input;
    }
    final sanitized = Map<String, dynamic>.from(input);
    final rawValue = input['value']?.toString() ?? '';
    final action = input['action']?.toString().trim().toLowerCase();
    if (action != 'delete' && rawValue != ToolUseContent.redactedSecretValue) {
      _ephemeralEnvVarValues[attempt.operationId] = rawValue;
    }
    sanitized['value'] = ToolUseContent.redactedSecretValue;
    return sanitized;
  }

  Map<String, dynamic> _consumeExecutionInput(
    _ToolAttemptContext attempt,
    Map<String, dynamic> sanitizedInput,
  ) {
    if (attempt.toolName != 'set_env_var' ||
        !sanitizedInput.containsKey('value')) {
      return sanitizedInput;
    }
    final executionInput = Map<String, dynamic>.from(sanitizedInput);
    final action = sanitizedInput['action']?.toString().trim().toLowerCase();
    if (action == 'delete') {
      executionInput.remove('value');
      return executionInput;
    }
    if (!_ephemeralEnvVarValues.containsKey(attempt.operationId)) {
      throw StateError(
        'Secret value is unavailable after restart; enter it again.',
      );
    }
    executionInput['value'] = _ephemeralEnvVarValues[attempt.operationId];
    return executionInput;
  }

  void _clearEphemeralToolInput(String operationId) {
    _ephemeralEnvVarValues.remove(operationId);
  }

  ToolResultPayload _redactOperationSecret(
    ToolResultPayload payload,
    String secret,
  ) {
    String redact(String value) =>
        value.replaceAll(secret, ToolUseContent.redactedSecretValue);
    Object? redactValue(Object? value) {
      if (value is String) return redact(value);
      if (value is Map) {
        return <String, dynamic>{
          for (final entry in value.entries)
            if (entry.key is String)
              entry.key as String: redactValue(entry.value),
        };
      }
      if (value is Iterable) return value.map(redactValue).toList();
      return value;
    }

    return ToolResultPayload(
      forUser: redact(payload.forUser),
      forLlm: payload.forLlm == null ? null : redact(payload.forLlm!),
      summary: payload.summary == null ? null : redact(payload.summary!),
      metadata: Map<String, dynamic>.from(
        redactValue(payload.metadata) as Map,
      ),
    );
  }

  ToolResultPayload _protectToolResultPayload(ToolResultPayload payload) =>
      ToolResultPayload(
        forUser: _maskConfiguredSecrets(payload.forUser),
        forLlm: payload.forLlm == null
            ? null
            : _maskConfiguredSecrets(payload.forLlm!),
        summary: payload.summary == null
            ? null
            : _maskConfiguredSecrets(payload.summary!),
        metadata: Map<String, dynamic>.from(
          _maskConfiguredSecretsInValue(payload.metadata) as Map,
        ),
      );

  static const _secretConfigurationMarker =
      '[Secret configuration request redacted]';
}

class _ToolResult {
  final String id;
  final String operationId;
  final ToolResultPayload payload;
  final bool isError;
  final StructuredResultIngress? structuredResult;
  final StructuredResultSkillProvenance? structuredResultSkillProvenance;

  _ToolResult(
    this.id,
    this.operationId,
    this.payload,
    this.isError, {
    this.structuredResult,
    this.structuredResultSkillProvenance,
  });

  String get output => payload.forUser;

  Map<String, dynamic> toJson() => {
        'type': 'tool_result',
        'tool_use_id': id,
        'content': payload.llmOutput,
        'output': payload.forUser,
        if (payload.forLlm != null) 'for_llm': payload.forLlm,
        if (payload.summary != null) 'summary': payload.summary,
        'metadata': {
          ...payload.metadata,
          'operationId': operationId,
        },
        if (isError) 'is_error': true,
      };
}

class _ToolAttemptContext {
  final String operationId;
  final String toolUseId;
  final String toolName;
  final ToolRisk risk;

  const _ToolAttemptContext({
    required this.operationId,
    required this.toolUseId,
    required this.toolName,
    required this.risk,
  });
}

class _HistoricalSkillCall {
  final String? id;
  final String? path;

  const _HistoricalSkillCall({this.id, this.path});
}

class _SkillBatchPlan {
  final ContentBlock? activationBlock;
  final VerifiedSkillUse? preparedActivation;
  final Set<ContentBlock> preActivationBlocks;
  final Map<ContentBlock, ToolDenyDecision> forcedDenials;

  const _SkillBatchPlan({
    this.activationBlock,
    this.preparedActivation,
    this.preActivationBlocks = const {},
    this.forcedDenials = const {},
  });

  factory _SkillBatchPlan.failed(
    Iterable<ContentBlock> blocks,
    ToolDenyDecision denial,
  ) =>
      _SkillBatchPlan(
        forcedDenials: {for (final block in blocks) block: denial},
      );

  bool get requiresSequentialExecution =>
      activationBlock != null || forcedDenials.isNotEmpty;

  ToolDenyDecision? denialFor(ContentBlock block) {
    final forced = forcedDenials[block];
    if (forced != null) return forced;
    if (preActivationBlocks.contains(block)) {
      return const ToolDenyDecision(
        ruleType: 'skill_capability',
        ruleId: 'skill_activation_order',
        message: 'Tool calls before skill activation fail closed.',
      );
    }
    return null;
  }

  VerifiedSkillUse? preparedFor(ContentBlock block) =>
      identical(block, activationBlock) ? preparedActivation : null;
}
