import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/chat_models.dart';
import '../models/model_capabilities.dart';
import 'chat_context_utils.dart';
import 'context_summary_service.dart';
import 'llm_content_sanitizer.dart';
import 'llm_service.dart';
import 'model_capability_registry.dart';
import 'provider_message_transform.dart';
import 'runtime_debug_events.dart';
import 'token_calibration_service.dart';

typedef ContextSummaryServiceFactory = ContextSummaryService Function();

typedef ProviderTransformPreflight = ProviderTransformResult Function(
  List<Map<String, dynamic>> messages,
  ProviderTransformOptions options,
);

enum ContextAssemblyMode { send, compare, recovery }

enum ContextNoticeType { summaryCompacted, summaryFailed, truncated }

class ContextNotice {
  final ContextNoticeType type;
  final int coveredMessageCount;
  final int droppedMessageCount;
  final int droppedBlockCount;
  final int estimatedTokens;

  const ContextNotice._({
    required this.type,
    this.coveredMessageCount = 0,
    this.droppedMessageCount = 0,
    this.droppedBlockCount = 0,
    this.estimatedTokens = 0,
  });

  const ContextNotice.summaryCompacted(int coveredMessageCount)
      : this._(
          type: ContextNoticeType.summaryCompacted,
          coveredMessageCount: coveredMessageCount,
        );

  const ContextNotice.summaryFailed()
      : this._(type: ContextNoticeType.summaryFailed);

  const ContextNotice.truncated({
    required int droppedMessageCount,
    required int droppedBlockCount,
    required int estimatedTokens,
  }) : this._(
          type: ContextNoticeType.truncated,
          droppedMessageCount: droppedMessageCount,
          droppedBlockCount: droppedBlockCount,
          estimatedTokens: estimatedTokens,
        );
}

class ContextSessionPatch {
  final bool hasSummaryUpdate;
  final ContextSummary? nextSummary;
  final List<ContextNotice> notices;

  const ContextSessionPatch({
    this.hasSummaryUpdate = false,
    this.nextSummary,
    this.notices = const [],
  });

  static const empty = ContextSessionPatch();

  bool get isEmpty => !hasSummaryUpdate && notices.isEmpty;
}

class ContextSummaryOutcome {
  final ContextSummary? summary;
  final bool generated;
  final bool reused;
  final bool failed;
  final int coveredMessageCount;

  const ContextSummaryOutcome({
    this.summary,
    this.generated = false,
    this.reused = false,
    this.failed = false,
    this.coveredMessageCount = 0,
  });
}

class ContextBudgetBreakdown {
  final int effectiveContextTokenBudget;
  final int systemTokens;
  final int toolDefinitionTokens;
  final int outputReserve;
  final int safetyMargin;
  final int messageBudget;

  const ContextBudgetBreakdown({
    required this.effectiveContextTokenBudget,
    required this.systemTokens,
    required this.toolDefinitionTokens,
    required this.outputReserve,
    required this.safetyMargin,
    required this.messageBudget,
  });
}

class ContextAssemblyResult {
  final String assemblyId;
  final ContextAssemblyMode mode;
  final String systemPrompt;
  final List<Map<String, dynamic>> messages;
  final int initialApiMsgCount;
  final ContextSessionPatch patch;
  final ContextSummaryOutcome summaryOutcome;
  final ContextBudgetBreakdown budget;
  final int finalTokenBudget;
  final TokenEstimator estimator;
  final ContextTruncationResult? truncation;
  final int compressedToolResultCount;

  const ContextAssemblyResult({
    required this.assemblyId,
    required this.mode,
    required this.systemPrompt,
    required this.messages,
    required this.initialApiMsgCount,
    required this.patch,
    required this.summaryOutcome,
    required this.budget,
    required this.finalTokenBudget,
    required this.estimator,
    this.truncation,
    this.compressedToolResultCount = 0,
  });
}

class ContextSendRequest {
  final String sessionId;
  final List<Map<String, dynamic>> fullApiMessages;
  final ContextSummary? existingSummary;
  final LlmConfig llmConfig;
  final String systemPrompt;
  final ModelCapabilities capabilities;
  final List<Map<String, dynamic>> toolDefinitions;
  final int contextTokenBudget;
  final bool autoCompact;
  final String? activeProfileId;
  final FutureOr<void> Function()? onSummaryGenerationStarted;

  const ContextSendRequest({
    required this.sessionId,
    required this.fullApiMessages,
    required this.llmConfig,
    required this.systemPrompt,
    required this.capabilities,
    required this.toolDefinitions,
    required this.contextTokenBudget,
    required this.autoCompact,
    this.existingSummary,
    this.activeProfileId,
    this.onSummaryGenerationStarted,
  });
}

class ContextCompareRequest {
  final String sessionId;
  final List<Map<String, dynamic>> sessionApiMessages;
  final String comparePrompt;
  final ContextSummary? existingSummary;
  final LlmConfig llmConfig;
  final String systemPrompt;
  final List<String> compareModels;
  final List<Map<String, dynamic>> toolDefinitions;
  final int contextTokenBudget;
  final bool autoCompact;

  const ContextCompareRequest({
    required this.sessionId,
    required this.sessionApiMessages,
    required this.comparePrompt,
    required this.llmConfig,
    required this.systemPrompt,
    required this.compareModels,
    required this.contextTokenBudget,
    required this.autoCompact,
    this.existingSummary,
    this.toolDefinitions = const [],
  });
}

class ContextRecoveryRequest {
  final String sessionId;
  final List<Map<String, dynamic>> messages;
  final LlmConfig llmConfig;
  final String systemPrompt;
  final int finalTokenBudget;
  final TokenEstimator estimator;
  final ModelCapabilities capabilities;
  final bool autoCompact;

  const ContextRecoveryRequest({
    required this.sessionId,
    required this.messages,
    required this.llmConfig,
    required this.systemPrompt,
    required this.finalTokenBudget,
    required this.estimator,
    required this.capabilities,
    required this.autoCompact,
  });
}

class ContextManualSummaryRequest {
  final String sessionId;
  final List<Map<String, dynamic>> apiPrefixMessages;
  final LlmConfig llmConfig;
  final int contextTokenBudget;
  final TokenEstimator estimator;

  const ContextManualSummaryRequest({
    required this.sessionId,
    required this.apiPrefixMessages,
    required this.llmConfig,
    required this.contextTokenBudget,
    this.estimator = const TokenEstimator(),
  });
}

class ContextManager {
  final ContextSummaryServiceFactory _contextSummaryServiceFactory;
  final ProviderTransformPreflight _providerTransformPreflight;
  final RuntimeDebugEventService runtimeDebugEvents;
  final TokenCalibrationService _tokenCalibration;
  final Map<String, _PendingTokenCalibration> _pendingTokenCalibration = {};
  int _assemblyCounter = 0;

  ContextManager({
    ContextSummaryServiceFactory? contextSummaryServiceFactory,
    ProviderTransformPreflight? providerTransformPreflight,
    RuntimeDebugEventService? runtimeDebugEvents,
    TokenCalibrationService? tokenCalibration,
  })  : _contextSummaryServiceFactory =
            contextSummaryServiceFactory ?? ContextSummaryService.new,
        _providerTransformPreflight = providerTransformPreflight ??
            const ProviderMessageTransform().transformCanonical,
        runtimeDebugEvents = runtimeDebugEvents ?? RuntimeDebugEventService(),
        _tokenCalibration = tokenCalibration ?? TokenCalibrationService();

  Future<void> init() async {
    await _tokenCalibration.init();
  }

  Future<ContextAssemblyResult> assembleForSend(
    ContextSendRequest request,
  ) async {
    final assemblyId = _nextAssemblyId();
    final estimator = _tokenEstimatorFor(
      request.llmConfig,
      activeProfileId: request.activeProfileId,
    );
    final budget = _resolveContextTokenBudget(
      llmConfig: request.llmConfig,
      capabilities: request.capabilities,
      systemPrompt: request.systemPrompt,
      estimator: estimator,
      toolDefinitions: request.toolDefinitions,
      contextTokenBudget: request.contextTokenBudget,
    );
    final summaryResult = await _prepareSummaryContext(request, budget);
    final notices = <ContextNotice>[
      if (summaryResult.summaryGenerated)
        ContextNotice.summaryCompacted(summaryResult.coveredMessageCount)
      else if (summaryResult.summaryFailed)
        const ContextNotice.summaryFailed(),
    ];
    final promptWithSummary = summaryResult.systemPrompt;
    final finalBudget = _resolveContextTokenBudget(
      llmConfig: request.llmConfig,
      capabilities: request.capabilities,
      systemPrompt: promptWithSummary,
      estimator: estimator,
      toolDefinitions: request.toolDefinitions,
      contextTokenBudget: request.contextTokenBudget,
    );
    final compressed = _compressOldToolResults(
      summaryResult.messages,
      estimator: estimator,
      sessionId: request.sessionId,
      autoCompact: request.autoCompact,
    );
    final truncation = _truncateToFit(
      compressed.messages,
      maxTokens: finalBudget.messageBudget,
      estimator: estimator,
      autoCompact: request.autoCompact,
      preserveLastMessages: 2,
    );
    if (truncation.wasTruncated) {
      _recordTruncationEvent(request.sessionId, truncation);
      notices.add(ContextNotice.truncated(
        droppedMessageCount: truncation.droppedMessageCount,
        droppedBlockCount: truncation.droppedBlockCount,
        estimatedTokens: truncation.estimatedTokens,
      ));
    }
    _recordProviderTransformWarningsBestEffort(
      sessionId: request.sessionId,
      messages: truncation.messages,
      options: ProviderTransformOptions(
        apiFormat: request.llmConfig.format == ApiFormat.anthropic
            ? 'anthropic'
            : 'openai',
        modelId: LlmService.modelIdFromDisplay(request.llmConfig.model),
        baseUrl: Uri.tryParse(request.llmConfig.baseUrl),
        capabilities: request.capabilities,
      ),
    );

    _pendingTokenCalibration[assemblyId] = _buildPendingTokenCalibration(
      sessionId: request.sessionId,
      llmConfig: request.llmConfig,
      activeProfileId: request.activeProfileId,
      estimator: estimator,
      messages: truncation.messages,
      systemPrompt: promptWithSummary,
      toolDefinitions: request.toolDefinitions,
    );

    return ContextAssemblyResult(
      assemblyId: assemblyId,
      mode: ContextAssemblyMode.send,
      systemPrompt: promptWithSummary,
      messages: truncation.messages,
      initialApiMsgCount: truncation.messages.length,
      patch: ContextSessionPatch(
        hasSummaryUpdate: summaryResult.summaryChanged,
        nextSummary: summaryResult.summary,
        notices: notices,
      ),
      summaryOutcome: ContextSummaryOutcome(
        summary: summaryResult.summary,
        generated: summaryResult.summaryGenerated,
        reused: summaryResult.summaryReused,
        failed: summaryResult.summaryFailed,
        coveredMessageCount: summaryResult.coveredMessageCount,
      ),
      budget: budget,
      finalTokenBudget: finalBudget.messageBudget,
      estimator: estimator,
      truncation: truncation,
      compressedToolResultCount: compressed.compressedCount,
    );
  }

  Future<ContextAssemblyResult> assembleForCompare(
    ContextCompareRequest request,
  ) async {
    final assemblyId = _nextAssemblyId();
    const estimator = TokenEstimator();
    final capabilities = _capabilitiesForCompareModels(
      format: request.llmConfig.format,
      baseUrl: request.llmConfig.baseUrl,
      models: request.compareModels,
    );
    final baseCompareMessages = [
      ...request.sessionApiMessages,
      {'role': 'user', 'content': request.comparePrompt},
    ];
    final baseBudget = _resolveContextTokenBudget(
      llmConfig: request.llmConfig,
      capabilities: capabilities,
      systemPrompt: request.systemPrompt,
      estimator: estimator,
      toolDefinitions: request.toolDefinitions,
      contextTokenBudget: request.contextTokenBudget,
    );
    final comparePlan = ChatContextUtils.planCompaction(
      baseCompareMessages,
      maxTokens: baseBudget.messageBudget,
      estimator: estimator,
    );
    final compareSummary = _summaryForCompare(
      request.existingSummary,
      baseCompareMessages,
      comparePlan,
      sessionId: request.sessionId,
    );
    if (compareSummary != null) {
      _recordRuntimeEvent(
        request.sessionId,
        'context.summary.reused',
        {
          'coveredMessageCount': compareSummary.coveredMessageCount,
          'summaryEstimatedTokens': compareSummary.summaryEstimatedTokens,
          'mode': ContextAssemblyMode.compare.name,
        },
      );
    }
    final compareSystemPrompt =
        _systemPromptWithSummary(request.systemPrompt, compareSummary);
    final comparePayloadMessages = compareSummary == null
        ? baseCompareMessages
        : baseCompareMessages.sublist(compareSummary.coveredMessageCount);
    final compressed = _compressOldToolResults(
      comparePayloadMessages,
      estimator: estimator,
      sessionId: request.sessionId,
      autoCompact: request.autoCompact,
    );
    final finalBudget = _resolveContextTokenBudget(
      llmConfig: request.llmConfig,
      capabilities: capabilities,
      systemPrompt: compareSystemPrompt,
      estimator: estimator,
      toolDefinitions: request.toolDefinitions,
      contextTokenBudget: request.contextTokenBudget,
    );
    final truncation = _truncateToFit(
      compressed.messages,
      maxTokens: finalBudget.messageBudget,
      estimator: estimator,
      autoCompact: request.autoCompact,
    );
    if (truncation.wasTruncated) {
      _recordTruncationEvent(request.sessionId, truncation);
    }
    _recordProviderTransformWarningsBestEffort(
      sessionId: request.sessionId,
      messages: truncation.messages,
      options: ProviderTransformOptions(
        apiFormat: request.llmConfig.format == ApiFormat.anthropic
            ? 'anthropic'
            : 'openai',
        modelId: LlmService.modelIdFromDisplay(request.llmConfig.model),
        baseUrl: Uri.tryParse(request.llmConfig.baseUrl),
        mode: ProviderTransformMode.compare,
        capabilities: capabilities,
      ),
    );
    return ContextAssemblyResult(
      assemblyId: assemblyId,
      mode: ContextAssemblyMode.compare,
      systemPrompt: compareSystemPrompt,
      messages: truncation.messages,
      initialApiMsgCount: truncation.messages.length,
      patch: ContextSessionPatch.empty,
      summaryOutcome: ContextSummaryOutcome(
        summary: compareSummary,
        reused: compareSummary != null,
        coveredMessageCount: compareSummary?.coveredMessageCount ?? 0,
      ),
      budget: baseBudget,
      finalTokenBudget: finalBudget.messageBudget,
      estimator: estimator,
      truncation: truncation,
      compressedToolResultCount: compressed.compressedCount,
    );
  }

  Future<ContextAssemblyResult> assembleForRecovery(
    ContextRecoveryRequest request,
  ) async {
    final assemblyId = _nextAssemblyId();
    final recoveryTransformResult =
        const ProviderMessageTransform().transformCanonical(
      request.messages,
      ProviderTransformOptions(
        apiFormat: request.llmConfig.format == ApiFormat.anthropic
            ? 'anthropic'
            : 'openai',
        modelId: LlmService.modelIdFromDisplay(request.llmConfig.model),
        baseUrl: Uri.tryParse(request.llmConfig.baseUrl),
        mode: ProviderTransformMode.recovery,
        capabilities: request.capabilities.copyWith(
          supportsImages: true,
          supportsReasoningContent: false,
        ),
      ),
    );
    _recordProviderTransformWarning(
      request.sessionId,
      recoveryTransformResult,
    );
    final recoveryTruncation = _truncateToFit(
      recoveryTransformResult.messages,
      maxTokens: request.finalTokenBudget,
      estimator: request.estimator,
      autoCompact: request.autoCompact,
      preserveLastMessages: 2,
    );
    return ContextAssemblyResult(
      assemblyId: assemblyId,
      mode: ContextAssemblyMode.recovery,
      systemPrompt: request.systemPrompt,
      messages: recoveryTruncation.messages,
      initialApiMsgCount: recoveryTruncation.messages.length,
      patch: ContextSessionPatch.empty,
      summaryOutcome: const ContextSummaryOutcome(),
      budget: ContextBudgetBreakdown(
        effectiveContextTokenBudget: 0,
        systemTokens: request.estimator.estimateText(request.systemPrompt),
        toolDefinitionTokens: 0,
        outputReserve: 0,
        safetyMargin: 0,
        messageBudget: request.finalTokenBudget,
      ),
      finalTokenBudget: request.finalTokenBudget,
      estimator: request.estimator,
      truncation: recoveryTruncation,
    );
  }

  Future<ContextSummary> buildManualSummary(
    ContextManualSummaryRequest request,
  ) async {
    final messages = request.apiPrefixMessages;
    if (messages.isEmpty) {
      throw ArgumentError.value(
        messages.length,
        'apiPrefixMessages',
        'Manual summary requires at least one API message.',
      );
    }
    final sourceEstimatedTokens = request.estimator.estimateMessages(messages);
    final summaryBudget = math.max(
      512,
      math.min(
        2048,
        math.max(768, (sourceEstimatedTokens * 0.25).round()),
      ),
    );
    final summaryRequest = ContextSummaryRequest(
      messages: messages,
      llmConfig: request.llmConfig,
      summaryBudget: summaryBudget,
      coveredDigest: ChatContextUtils.digestMessages(messages),
      coveredMessageCount: messages.length,
      sourceEstimatedTokens: sourceEstimatedTokens,
      estimator: request.estimator,
      maxInputTokens: (request.contextTokenBudget * 0.8).floor(),
    );
    final service = _contextSummaryServiceFactory();
    try {
      final summary = await service.generateSummary(summaryRequest);
      _recordRuntimeEvent(
        request.sessionId,
        'context.summary.manual.generated',
        {
          'coveredMessageCount': summary.coveredMessageCount,
          'sourceEstimatedTokens': summary.sourceEstimatedTokens,
          'summaryEstimatedTokens': summary.summaryEstimatedTokens,
        },
      );
      return summary;
    } catch (e) {
      _recordRuntimeEvent(
        request.sessionId,
        'context.summary.manual.failed',
        {
          'stage': 'llm',
          'errorType': e.runtimeType.toString(),
        },
      );
      final summary = service.extractiveFallback(summaryRequest);
      _recordRuntimeEvent(
        request.sessionId,
        'context.summary.manual.generated',
        {
          'coveredMessageCount': summary.coveredMessageCount,
          'sourceEstimatedTokens': summary.sourceEstimatedTokens,
          'summaryEstimatedTokens': summary.summaryEstimatedTokens,
          'fallback': true,
        },
      );
      return summary;
    }
  }

  TokenCalibrationRecordResult? recordCompletion({
    required String assemblyId,
    required LlmUsage? usage,
    required bool hadToolCalls,
  }) {
    final pendingCalibration = _pendingTokenCalibration.remove(assemblyId);
    if (pendingCalibration == null) return null;
    if (hadToolCalls) {
      _recordTokenCalibrationEvent(
        pendingCalibration.sessionId,
        TokenCalibrationRecordResult.skipped(
          sample: pendingCalibration.toSample(usage),
          reason: 'tool_call_turn',
        ),
      );
      return null;
    }
    final sample = pendingCalibration.toSample(usage);
    final calibrationResult = _tokenCalibration.recordSample(sample);
    _recordTokenCalibrationEvent(
      pendingCalibration.sessionId,
      calibrationResult,
    );
    return calibrationResult;
  }

  void discardCompletion(String assemblyId) {
    _pendingTokenCalibration.remove(assemblyId);
  }

  @visibleForTesting
  bool hasPendingCompletionForTesting(String assemblyId) {
    return _pendingTokenCalibration.containsKey(assemblyId);
  }

  void recordProviderTransformWarningsBestEffortForTesting({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required ProviderTransformOptions options,
  }) {
    _recordProviderTransformWarningsBestEffort(
      sessionId: sessionId,
      messages: messages,
      options: options,
    );
  }

  Future<_SummaryContextResult> _prepareSummaryContext(
    ContextSendRequest request,
    ContextBudgetBreakdown budget,
  ) async {
    final estimator = _tokenEstimatorFor(
      request.llmConfig,
      activeProfileId: request.activeProfileId,
    );
    if (!request.autoCompact ||
        request.fullApiMessages.isEmpty ||
        estimator.estimateMessages(request.fullApiMessages) <=
            budget.messageBudget) {
      return _SummaryContextResult(
        systemPrompt: request.systemPrompt,
        messages: request.fullApiMessages,
      );
    }

    final plan = ChatContextUtils.planCompaction(
      request.fullApiMessages,
      maxTokens: budget.messageBudget,
      estimator: estimator,
    );
    if (!plan.needsSummary || plan.headForSummary.isEmpty) {
      return _SummaryContextResult(
        systemPrompt: request.systemPrompt,
        messages: request.fullApiMessages,
      );
    }

    var summary = _validatedSummaryForPrefix(
      request.existingSummary,
      request.fullApiMessages,
    );
    var generated = false;
    var reused = false;
    var failed = false;
    var summaryChanged = false;
    if (!_canReuseSummary(summary, plan, request.fullApiMessages)) {
      if (request.existingSummary != null && summary == null) {
        _recordSummaryStaleEvent(
          request.sessionId,
          request.existingSummary!,
        );
      }
      final onSummaryGenerationStarted = request.onSummaryGenerationStarted;
      if (onSummaryGenerationStarted != null) {
        await Future<void>.sync(onSummaryGenerationStarted);
      }
      final summaryRequest = ContextSummaryRequest(
        messages: _messagesForSummaryGeneration(
          request.fullApiMessages,
          plan,
          summary,
        ),
        existingSummary: summary,
        llmConfig: request.llmConfig,
        summaryBudget: plan.summaryBudget,
        coveredDigest: plan.headDigest,
        coveredMessageCount: plan.headForSummary.length,
        sourceEstimatedTokens: plan.headEstimatedTokens,
        estimator: estimator,
        maxInputTokens: (budget.effectiveContextTokenBudget * 0.8).floor(),
      );
      final service = _contextSummaryServiceFactory();
      try {
        summary = await service.generateSummary(summaryRequest);
        generated = true;
        summaryChanged = true;
        _recordRuntimeEvent(
          request.sessionId,
          'context.summary.generated',
          {
            'coveredMessageCount': summary.coveredMessageCount,
            'sourceEstimatedTokens': summary.sourceEstimatedTokens,
            'summaryEstimatedTokens': summary.summaryEstimatedTokens,
            'reused': false,
          },
        );
      } catch (e) {
        debugPrint('Context summary generation failed: $e');
        failed = true;
        _recordRuntimeEvent(
          request.sessionId,
          'context.summary.failed',
          {
            'stage': 'llm',
            'errorType': e.runtimeType.toString(),
          },
        );
        try {
          summary = service.extractiveFallback(summaryRequest);
          summaryChanged = true;
        } catch (fallbackError) {
          debugPrint(
            'Context summary extractive fallback failed: $fallbackError',
          );
          _recordRuntimeEvent(
            request.sessionId,
            'context.summary.failed',
            {
              'stage': 'extractive',
              'errorType': fallbackError.runtimeType.toString(),
            },
          );
          return _SummaryContextResult(
            systemPrompt: request.systemPrompt,
            messages: request.fullApiMessages,
            summaryFailed: true,
          );
        }
      }
    } else if (summary != null) {
      reused = true;
      _recordRuntimeEvent(
        request.sessionId,
        'context.summary.reused',
        {
          'coveredMessageCount': summary.coveredMessageCount,
          'summaryEstimatedTokens': summary.summaryEstimatedTokens,
        },
      );
    }

    final promptWithSummary = _systemPromptWithSummary(
      request.systemPrompt,
      summary,
    );
    final summaryTokens = estimator.estimateText(promptWithSummary) -
        estimator.estimateText(request.systemPrompt);
    final finalTailBudget = math.max(0, budget.messageBudget - summaryTokens);
    final tailTruncation = _truncateToFit(
      plan.recentTail,
      maxTokens: finalTailBudget,
      estimator: estimator,
      autoCompact: request.autoCompact,
      preserveLastMessages: 2,
    );
    return _SummaryContextResult(
      systemPrompt: promptWithSummary,
      messages: tailTruncation.messages,
      summary: summary,
      summaryChanged: summaryChanged,
      summaryGenerated: generated,
      summaryReused: reused,
      summaryFailed: failed,
      coveredMessageCount: summary?.coveredMessageCount ?? 0,
    );
  }

  ContextTruncationResult _truncateToFit(
    List<Map<String, dynamic>> messages, {
    required int maxTokens,
    required TokenEstimator estimator,
    required bool autoCompact,
    int preserveLastMessages = 2,
  }) {
    return ChatContextUtils.truncateToFit(
      messages,
      maxTokens: maxTokens,
      estimator: estimator,
      autoCompact: autoCompact,
      preserveLastMessages: preserveLastMessages,
    );
  }

  _ToolCompressionResult _compressOldToolResults(
    List<Map<String, dynamic>> messages, {
    required TokenEstimator estimator,
    required String sessionId,
    required bool autoCompact,
  }) {
    if (!autoCompact) {
      return _ToolCompressionResult(messages: messages);
    }
    final compressed = ChatContextUtils.compressOldToolResults(
      messages,
      estimator: estimator,
    );
    final compressedCount = _countCompressedToolResults(messages, compressed);
    if (compressedCount > 0) {
      _recordRuntimeEvent(
        sessionId,
        'tool_result.compressed',
        {
          'compressedCount': compressedCount,
          'protectedTurnCount': 2,
          'thresholdTokens': 500,
        },
      );
    }
    return _ToolCompressionResult(
      messages: compressed,
      compressedCount: compressedCount,
    );
  }

  ContextBudgetBreakdown _resolveContextTokenBudget({
    required LlmConfig llmConfig,
    required ModelCapabilities capabilities,
    required String systemPrompt,
    required TokenEstimator estimator,
    required List<Map<String, dynamic>> toolDefinitions,
    required int contextTokenBudget,
  }) {
    final effectiveContextTokenBudget = _effectiveContextTokenBudget(
      capabilities,
      contextTokenBudget,
    );
    final systemTokens = estimator.estimateText(systemPrompt);
    final toolDefinitionTokens =
        estimator.estimateToolDefinitions(toolDefinitions);
    final configuredOutputReserve = llmConfig.maxTokens +
        (llmConfig.thinkingBudget > 0 ? llmConfig.thinkingBudget : 0);
    final maxOutputReserve = (effectiveContextTokenBudget * 0.5).floor();
    final outputReserve = math.min(configuredOutputReserve, maxOutputReserve);
    const safetyMargin = 1024;
    final messageBudget = effectiveContextTokenBudget -
        systemTokens -
        toolDefinitionTokens -
        outputReserve -
        safetyMargin;
    if (messageBudget <= 0) {
      debugPrint(
        'Context token budget exhausted: context=$effectiveContextTokenBudget, '
        'system=$systemTokens, tools=$toolDefinitionTokens, '
        'outputReserve=$outputReserve, safetyMargin=$safetyMargin.',
      );
      return ContextBudgetBreakdown(
        effectiveContextTokenBudget: effectiveContextTokenBudget,
        systemTokens: systemTokens,
        toolDefinitionTokens: toolDefinitionTokens,
        outputReserve: outputReserve,
        safetyMargin: safetyMargin,
        messageBudget: 0,
      );
    }
    return ContextBudgetBreakdown(
      effectiveContextTokenBudget: effectiveContextTokenBudget,
      systemTokens: systemTokens,
      toolDefinitionTokens: toolDefinitionTokens,
      outputReserve: outputReserve,
      safetyMargin: safetyMargin,
      messageBudget: messageBudget,
    );
  }

  int _effectiveContextTokenBudget(
    ModelCapabilities capabilities,
    int contextTokenBudget,
  ) {
    final maxContextTokens = capabilities.maxContextTokens;
    if (maxContextTokens == null) return contextTokenBudget;
    return math.min(contextTokenBudget, maxContextTokens);
  }

  ModelCapabilities _capabilitiesForCompareModels({
    required ApiFormat format,
    required String baseUrl,
    required List<String> models,
  }) {
    if (models.isEmpty) return const ModelCapabilities();
    final resolved = models
        .map((model) => CapabilityRegistry.instance
            .resolve(apiFormat: format, baseUrl: baseUrl, model: model)
            .capabilities)
        .toList();
    final knownWindows = resolved
        .map((capabilities) => capabilities.maxContextTokens)
        .whereType<int>()
        .toList();
    if (knownWindows.isEmpty) return resolved.first;
    knownWindows.sort();
    return resolved.first.copyWith(maxContextTokens: knownWindows.first);
  }

  bool _canReuseSummary(
    ContextSummary? summary,
    ContextCompactionPlan plan,
    List<Map<String, dynamic>> fullMessages,
  ) {
    final currentSummary = _validatedSummaryForPrefix(summary, fullMessages);
    return currentSummary != null &&
        currentSummary.coveredDigest == plan.headDigest &&
        currentSummary.coveredMessageCount == plan.headForSummary.length;
  }

  ContextSummary? _summaryForCompare(
    ContextSummary? summary,
    List<Map<String, dynamic>> fullMessages,
    ContextCompactionPlan plan, {
    required String sessionId,
  }) {
    final currentSummary = _validatedSummaryForPrefix(summary, fullMessages);
    if (summary != null && currentSummary == null) {
      _recordSummaryStaleEvent(sessionId, summary);
    }
    if (currentSummary == null || !plan.needsSummary) return null;
    if (currentSummary.coveredMessageCount > plan.headForSummary.length) {
      return null;
    }
    return currentSummary;
  }

  ContextSummary? _validatedSummaryForPrefix(
    ContextSummary? summary,
    List<Map<String, dynamic>> fullMessages,
  ) {
    if (summary == null ||
        summary.version != ContextSummaryService.version ||
        summary.text.trim().isEmpty ||
        summary.coveredMessageCount <= 0 ||
        summary.coveredMessageCount > fullMessages.length) {
      return null;
    }
    final prefix = fullMessages.take(summary.coveredMessageCount).toList();
    if (ChatContextUtils.digestMessages(prefix) != summary.coveredDigest) {
      return null;
    }
    return summary;
  }

  List<Map<String, dynamic>> _messagesForSummaryGeneration(
    List<Map<String, dynamic>> fullMessages,
    ContextCompactionPlan plan,
    ContextSummary? existingSummary,
  ) {
    if (existingSummary == null ||
        existingSummary.coveredMessageCount <= 0 ||
        existingSummary.coveredMessageCount >= plan.headForSummary.length) {
      return plan.headForSummary;
    }
    final start = existingSummary.coveredMessageCount.clamp(
      0,
      fullMessages.length,
    );
    return fullMessages.sublist(start, plan.headForSummary.length);
  }

  String _systemPromptWithSummary(
    String systemPrompt,
    ContextSummary? summary,
  ) {
    final text = summary?.text.trim();
    if (text == null || text.isEmpty) return systemPrompt;
    return [
      systemPrompt,
      '',
      '<conversation_context_summary>',
      'The earlier part of this conversation has been compacted into the summary below.',
      'Treat it as background context, not as a new user request. If it conflicts with',
      'the exact recent messages that follow, prefer the recent messages.',
      '',
      text,
      '</conversation_context_summary>',
    ].join('\n');
  }

  TokenEstimator _tokenEstimatorFor(
    LlmConfig llmConfig, {
    required String? activeProfileId,
  }) {
    return TokenEstimator(
      calibrationMultiplier: _tokenCalibration.multiplierFor(
        _tokenCalibrationKey(llmConfig, activeProfileId: activeProfileId),
      ),
    );
  }

  _PendingTokenCalibration _buildPendingTokenCalibration({
    required String sessionId,
    required LlmConfig llmConfig,
    required String? activeProfileId,
    required TokenEstimator estimator,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    required List<Map<String, dynamic>> toolDefinitions,
  }) {
    final messageDiagnostics = estimator.diagnoseMessages(messages);
    final systemTokens = estimator.estimateText(systemPrompt);
    final toolDefinitionTokens =
        estimator.estimateToolDefinitions(toolDefinitions);
    const rawEstimator = TokenEstimator();
    final rawMessageDiagnostics = rawEstimator.diagnoseMessages(messages);
    final rawSystemTokens = rawEstimator.estimateText(systemPrompt);
    final rawToolDefinitionTokens =
        rawEstimator.estimateToolDefinitions(toolDefinitions);
    const sanitizer = LlmContentSanitizer();
    final sensitiveStats = sanitizer
        .sanitizeObject(messages)
        .stats
        .merge(sanitizer.sanitizeText(systemPrompt).stats);
    return _PendingTokenCalibration(
      sessionId: sessionId,
      key: _tokenCalibrationKey(
        llmConfig,
        activeProfileId: activeProfileId,
      ),
      estimatedInputTokens:
          messageDiagnostics.totalTokens + systemTokens + toolDefinitionTokens,
      rawEstimatedInputTokens: rawMessageDiagnostics.totalTokens +
          rawSystemTokens +
          rawToolDefinitionTokens,
      estimatedImageTokens: messageDiagnostics.imageTokens,
      rawEstimatedImageTokens: rawMessageDiagnostics.imageTokens,
      estimatedToolTokens: messageDiagnostics.toolTokens + toolDefinitionTokens,
      rawEstimatedToolTokens:
          rawMessageDiagnostics.toolTokens + rawToolDefinitionTokens,
      largestBlockTokens: messageDiagnostics.largestBlockTokens,
      rawLargestBlockTokens: rawMessageDiagnostics.largestBlockTokens,
      skipReasonOverride:
          sensitiveStats.hasRedactions ? 'sensitive_data_redacted' : null,
    );
  }

  String _tokenCalibrationKey(
    LlmConfig llmConfig, {
    required String? activeProfileId,
  }) {
    final format = llmConfig.format.name;
    final host = _normalizedBaseUrlHost(llmConfig.baseUrl);
    final modelId = LlmService.modelIdFromDisplay(llmConfig.model);
    return '$format|$host|$activeProfileId|$modelId';
  }

  String _normalizedBaseUrlHost(String baseUrl) {
    final trimmed = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(trimmed);
    final host = uri?.host;
    if (host != null && host.isNotEmpty) return host.toLowerCase();
    return trimmed.toLowerCase();
  }

  void _recordRuntimeEvent(
    String sessionId,
    String type,
    Map<String, Object?> data,
  ) {
    try {
      runtimeDebugEvents.record(RuntimeDebugEvent(
        type: type,
        sessionId: sessionId,
        data: data,
      ));
    } catch (_) {
      // Debug events must never affect chat flow.
    }
  }

  void _recordTruncationEvent(
    String sessionId,
    ContextTruncationResult result,
  ) {
    _recordRuntimeEvent(
      sessionId,
      'context.truncated',
      {
        'droppedMessageCount': result.droppedMessageCount,
        'droppedBlockCount': result.droppedBlockCount,
        'estimatedTokens': result.estimatedTokens,
        'maxTokens': result.maxTokens,
        'overBudgetAfterTruncation': result.overBudgetAfterTruncation,
      },
    );
  }

  void _recordProviderTransformWarningsBestEffort({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required ProviderTransformOptions options,
  }) {
    try {
      _recordProviderTransformWarning(
        sessionId,
        _providerTransformPreflight(messages, options),
      );
    } catch (e) {
      debugPrint('Provider transform debug preflight failed: $e');
    }
  }

  void _recordProviderTransformWarning(
    String sessionId,
    ProviderTransformResult result,
  ) {
    if (result.sensitiveDataStats.hasRedactions) {
      _recordRuntimeEvent(
        sessionId,
        'llm.sensitive_data_redacted',
        {
          'stage': 'provider_payload',
          'totalCount': result.sensitiveDataStats.totalCount,
          'countByType': result.sensitiveDataStats.toJson(),
        },
      );
    }
    if (result.warnings.isEmpty) return;
    _recordRuntimeEvent(
      sessionId,
      'provider.transform.warning',
      {
        'warningCount': result.warnings.length,
        'firstWarning': result.warnings.first,
        'droppedBlockCount': result.droppedBlockCount,
      },
    );
  }

  void _recordTokenCalibrationEvent(
    String sessionId,
    TokenCalibrationRecordResult result,
  ) {
    if (result.updated) {
      _recordRuntimeEvent(
        sessionId,
        'token.calibration.updated',
        {
          'keyHash': _shortHash(result.key),
          'oldMultiplier': result.oldMultiplier,
          'ratio': result.ratio,
          'newMultiplier': result.newMultiplier,
        },
      );
      return;
    }
    _recordRuntimeEvent(
      sessionId,
      'token.calibration.skipped',
      {
        'reason': result.skipReason,
        'estimatedInputTokens': result.estimatedInputTokens,
        'actualInputTokens': result.actualInputTokens,
      },
    );
  }

  void _recordSummaryStaleEvent(
    String sessionId,
    ContextSummary summary,
  ) {
    final reason = summary.version != ContextSummaryService.version
        ? 'version_mismatch'
        : 'digest_mismatch';
    _recordRuntimeEvent(
      sessionId,
      'context.summary.stale',
      {
        'reason': reason,
        'coveredMessageCount': summary.coveredMessageCount,
        'summaryEstimatedTokens': summary.summaryEstimatedTokens,
      },
    );
  }

  int _countCompressedToolResults(
    List<Map<String, dynamic>> before,
    List<Map<String, dynamic>> after,
  ) {
    final length = math.min(before.length, after.length);
    var count = 0;
    for (var i = 0; i < length; i++) {
      final beforeContent = before[i]['content'];
      final afterContent = after[i]['content'];
      if (beforeContent is! List || afterContent is! List) continue;
      final blockLength = math.min(beforeContent.length, afterContent.length);
      for (var j = 0; j < blockLength; j++) {
        final beforeBlock = beforeContent[j];
        final afterBlock = afterContent[j];
        if (beforeBlock is! Map || afterBlock is! Map) continue;
        if (beforeBlock['type'] != 'tool_result' ||
            afterBlock['type'] != 'tool_result') {
          continue;
        }
        final beforeOutput = beforeBlock['content'] ?? beforeBlock['output'];
        final afterOutput = afterBlock['content'] ?? afterBlock['output'];
        if (beforeOutput != afterOutput &&
            afterOutput is String &&
            afterOutput.contains('Tool result truncated')) {
          count++;
        }
      }
    }
    return count;
  }

  String _shortHash(String value) {
    var hash = 0x811c9dc5;
    for (final codeUnit in value.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _nextAssemblyId() {
    final count = _assemblyCounter++;
    return '${DateTime.now().microsecondsSinceEpoch}-$count';
  }
}

class _SummaryContextResult {
  final String systemPrompt;
  final List<Map<String, dynamic>> messages;
  final ContextSummary? summary;
  final bool summaryChanged;
  final bool summaryGenerated;
  final bool summaryReused;
  final bool summaryFailed;
  final int coveredMessageCount;

  const _SummaryContextResult({
    required this.systemPrompt,
    required this.messages,
    this.summary,
    this.summaryChanged = false,
    this.summaryGenerated = false,
    this.summaryReused = false,
    this.summaryFailed = false,
    this.coveredMessageCount = 0,
  });
}

class _ToolCompressionResult {
  final List<Map<String, dynamic>> messages;
  final int compressedCount;

  const _ToolCompressionResult({
    required this.messages,
    this.compressedCount = 0,
  });
}

class _PendingTokenCalibration {
  final String sessionId;
  final String key;
  final int estimatedInputTokens;
  final int rawEstimatedInputTokens;
  final int estimatedImageTokens;
  final int rawEstimatedImageTokens;
  final int estimatedToolTokens;
  final int rawEstimatedToolTokens;
  final int largestBlockTokens;
  final int rawLargestBlockTokens;
  final String? skipReasonOverride;

  const _PendingTokenCalibration({
    required this.sessionId,
    required this.key,
    required this.estimatedInputTokens,
    required this.rawEstimatedInputTokens,
    required this.estimatedImageTokens,
    required this.rawEstimatedImageTokens,
    required this.estimatedToolTokens,
    required this.rawEstimatedToolTokens,
    required this.largestBlockTokens,
    required this.rawLargestBlockTokens,
    this.skipReasonOverride,
  });

  TokenCalibrationSample toSample(LlmUsage? usage) {
    return TokenCalibrationSample(
      key: key,
      estimatedInputTokens: estimatedInputTokens,
      rawEstimatedInputTokens: rawEstimatedInputTokens,
      actualInputTokens: usage?.inputTokens,
      estimatedImageTokens: estimatedImageTokens,
      rawEstimatedImageTokens: rawEstimatedImageTokens,
      estimatedToolTokens: estimatedToolTokens,
      rawEstimatedToolTokens: rawEstimatedToolTokens,
      largestBlockTokens: largestBlockTokens,
      rawLargestBlockTokens: rawLargestBlockTokens,
      cacheReadTokens: usage?.cacheReadInputTokens,
      cacheCreationTokens: usage?.cacheCreationInputTokens,
      skipReasonOverride: skipReasonOverride,
    );
  }
}
