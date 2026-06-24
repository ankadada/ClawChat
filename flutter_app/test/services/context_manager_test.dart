import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/model_capabilities.dart';
import 'package:clawchat/services/chat_context_utils.dart';
import 'package:clawchat/services/context_manager.dart';
import 'package:clawchat/services/context_summary_service.dart';
import 'package:clawchat/services/llm_service.dart';
import 'package:clawchat/services/runtime_debug_events.dart';
import 'package:clawchat/services/token_calibration_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const llmConfig = LlmConfig(
    format: ApiFormat.anthropic,
    apiKey: 'sk-test',
    model: 'claude-sonnet-4-20250514',
    baseUrl: 'http://127.0.0.1',
    maxTokens: 8192,
  );

  Future<ContextManager> createManager({
    RuntimeDebugEventService? events,
    ContextSummaryService Function()? summaryFactory,
    ProviderTransformPreflight? providerTransformPreflight,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final manager = ContextManager(
      contextSummaryServiceFactory:
          summaryFactory ?? () => _ScriptedContextSummaryService(),
      providerTransformPreflight: providerTransformPreflight,
      runtimeDebugEvents: events,
      tokenCalibration: TokenCalibrationService(prefs: prefs),
    );
    await manager.init();
    return manager;
  }

  ContextSendRequest sendRequest({
    required List<Map<String, dynamic>> messages,
    ContextSummary? existingSummary,
    String systemPrompt = 'system',
    int contextTokenBudget = 32768,
    bool autoCompact = true,
    ModelCapabilities capabilities = const ModelCapabilities(),
    List<Map<String, dynamic>> toolDefinitions = const [],
    Future<void> Function()? onSummaryGenerationStarted,
  }) {
    return ContextSendRequest(
      sessionId: 'session',
      fullApiMessages: messages,
      existingSummary: existingSummary,
      llmConfig: llmConfig,
      systemPrompt: systemPrompt,
      capabilities: capabilities,
      toolDefinitions: toolDefinitions,
      contextTokenBudget: contextTokenBudget,
      autoCompact: autoCompact,
      activeProfileId: 'profile',
      onSummaryGenerationStarted: onSummaryGenerationStarted,
    );
  }

  group('ContextManager assembleForSend', () {
    test('under budget returns original prompt/messages without patch',
        () async {
      var summaryCalls = 0;
      final manager = await createManager(
        summaryFactory: () => _ScriptedContextSummaryService(
          onGenerate: (_) {
            summaryCalls++;
            throw StateError('should not summarize');
          },
        ),
      );
      final messages = [
        {'role': 'user', 'content': 'hello'},
      ];

      final result = await manager.assembleForSend(
        sendRequest(messages: messages, contextTokenBudget: 32768),
      );

      expect(result.systemPrompt, 'system');
      expect(result.messages, messages);
      expect(result.initialApiMsgCount, 1);
      expect(result.patch.isEmpty, isTrue);
      expect(result.summaryOutcome.generated, isFalse);
      expect(summaryCalls, 0);
    });

    test('summary generated returns patch/notices and summary prompt',
        () async {
      var started = false;
      final events = RuntimeDebugEventService();
      final manager = await createManager(
        events: events,
        summaryFactory: () => _ScriptedContextSummaryService(
          onGenerate: _summaryForRequest,
        ),
      );

      final result = await manager.assembleForSend(
        sendRequest(
          messages: _largeHistory(prefix: 'old-summary'),
          onSummaryGenerationStarted: () async {
            started = true;
          },
        ),
      );

      expect(started, isTrue);
      expect(result.systemPrompt, contains('conversation_context_summary'));
      expect(result.systemPrompt, contains('Test summary'));
      expect(result.messages.toString(), isNot(contains('old-summary')));
      expect(result.patch.hasSummaryUpdate, isTrue);
      expect(result.patch.nextSummary, isNotNull);
      expect(
          result.patch.notices.single.type, ContextNoticeType.summaryCompacted);
      expect(result.summaryOutcome.generated, isTrue);
      expect(
        events
            .recent(sessionId: 'session')
            .where((event) => event.type == 'context.summary.generated'),
        hasLength(1),
      );
    });

    test('summary reused does not call LLM and returns no patch', () async {
      var summaryCalls = 0;
      final events = RuntimeDebugEventService();
      final manager = await createManager(
        events: events,
        summaryFactory: () => _ScriptedContextSummaryService(
          onGenerate: (_) {
            summaryCalls++;
            throw StateError('should reuse');
          },
        ),
      );
      final messages = _largeHistory(prefix: 'old-reuse');
      final budget = _messageBudgetFor(messages);
      final plan = ChatContextUtils.planCompaction(
        messages,
        maxTokens: budget,
        estimator: const TokenEstimator(),
      );
      final summary = ContextSummary(
        version: ContextSummaryService.version,
        text: '## Goal\nReusable summary',
        coveredMessageCount: plan.headForSummary.length,
        coveredDigest: plan.headDigest,
        sourceEstimatedTokens: plan.headEstimatedTokens,
        summaryEstimatedTokens: 20,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

      final result = await manager.assembleForSend(
        sendRequest(messages: messages, existingSummary: summary),
      );

      expect(summaryCalls, 0);
      expect(result.systemPrompt, contains('Reusable summary'));
      expect(result.patch.hasSummaryUpdate, isFalse);
      expect(result.summaryOutcome.reused, isTrue);
      expect(
        events
            .recent(sessionId: 'session')
            .where((event) => event.type == 'context.summary.reused'),
        hasLength(1),
      );
    });

    test('summary failed falls back with notice', () async {
      final events = RuntimeDebugEventService();
      final manager = await createManager(
        events: events,
        summaryFactory: () => _ScriptedContextSummaryService(
          onGenerate: (_) => throw StateError('summary unavailable'),
        ),
      );

      final result = await manager.assembleForSend(
        sendRequest(messages: _largeHistory(prefix: 'old-fallback')),
      );

      expect(result.systemPrompt, contains('conversation_context_summary'));
      expect(result.patch.hasSummaryUpdate, isTrue);
      expect(result.patch.notices.single.type, ContextNoticeType.summaryFailed);
      expect(result.summaryOutcome.failed, isTrue);
      expect(
        events
            .recent(sessionId: 'session')
            .where((event) => event.type == 'context.summary.failed')
            .single
            .data['stage'],
        'llm',
      );
    });

    test('summary double failure falls through to pure truncate', () async {
      final events = RuntimeDebugEventService();
      final manager = await createManager(
        events: events,
        summaryFactory: () => _ScriptedContextSummaryService(
          onGenerate: (_) => throw StateError('summary unavailable'),
          onExtractive: (_) => throw StateError('extractive unavailable'),
        ),
      );

      final result = await manager.assembleForSend(
        sendRequest(messages: _largeHistory(prefix: 'old-double-failure')),
      );

      expect(
          result.systemPrompt, isNot(contains('conversation_context_summary')));
      expect(result.patch.hasSummaryUpdate, isFalse);
      expect(
        result.patch.notices.map((notice) => notice.type),
        containsAll([
          ContextNoticeType.summaryFailed,
          ContextNoticeType.truncated,
        ]),
      );
      expect(result.messages.toString(), contains('new prompt'));
      expect(result.messages.toString(), isNot(contains('old-double-failure')));
      final failedStages = events
          .recent(sessionId: 'session')
          .where((event) => event.type == 'context.summary.failed')
          .map((event) => event.data['stage'])
          .toList();
      expect(failedStages, containsAll(['llm', 'extractive']));
      expect(
        events
            .recent(sessionId: 'session')
            .where((event) => event.type == 'context.truncated'),
        hasLength(1),
      );
    });

    test('tool compression outcome is reported', () async {
      final events = RuntimeDebugEventService();
      final manager = await createManager(events: events);
      final oldOutput = 'old-output-${'x' * 3000}';
      final messages = [
        {'role': 'user', 'content': 'old tool prompt'},
        _toolUseMessage('call_old', 'bash'),
        _toolResultMessage('call_old', oldOutput),
        {'role': 'assistant', 'content': 'old done'},
        {'role': 'user', 'content': 'middle tool prompt'},
        _toolUseMessage('call_middle', 'grep'),
        _toolResultMessage('call_middle', 'middle-output-${'y' * 3000}'),
        {'role': 'assistant', 'content': 'middle done'},
        {'role': 'user', 'content': 'latest tool prompt'},
        _toolUseMessage('call_latest', 'cat'),
        _toolResultMessage('call_latest', 'latest-output-${'z' * 3000}'),
        {'role': 'assistant', 'content': 'latest done'},
        {'role': 'user', 'content': 'new prompt'},
      ];

      final result = await manager.assembleForSend(
        sendRequest(messages: messages),
      );

      expect(result.compressedToolResultCount, 1);
      expect(result.truncation?.wasTruncated, isFalse);
      expect(result.messages.toString(), contains('Tool result truncated'));
      expect(result.messages.toString(), isNot(contains(oldOutput)));
      expect(
        events
            .recent(sessionId: 'session')
            .where((event) => event.type == 'tool_result.compressed'),
        hasLength(1),
      );
    });

    test('provider warnings and sensitive events are preflighted', () async {
      final events = RuntimeDebugEventService();
      final manager = await createManager(events: events);

      await manager.assembleForSend(
        sendRequest(
          messages: const [
            {
              'role': 'user',
              'content':
                  'Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456',
            },
            {
              'role': 'user',
              'content': [
                {
                  'type': 'image',
                  'source': {'type': 'base64', 'data': 'abc123'},
                },
              ],
            },
          ],
          capabilities: const ModelCapabilities(supportsImages: false),
        ),
      );

      final recorded = events.recent(sessionId: 'session');
      expect(
        recorded.where((event) => event.type == 'provider.transform.warning'),
        hasLength(1),
      );
      expect(
        recorded.where((event) => event.type == 'llm.sensitive_data_redacted'),
        hasLength(1),
      );
      expect(
          recorded.toString(), isNot(contains('abcdefghijklmnopqrstuvwxyz')));
      expect(recorded.toString(), isNot(contains('abc123')));
    });

    test('calibration update skip and discard are keyed by assembly id',
        () async {
      final events = RuntimeDebugEventService();
      final manager = await createManager(events: events);
      final result = await manager.assembleForSend(
        sendRequest(messages: _calibrationHistory()),
      );

      final record = manager.recordCompletion(
        assemblyId: result.assemblyId,
        usage: const LlmUsage(inputTokens: 22000, outputTokens: 50),
        hadToolCalls: false,
      );

      expect(record?.updated, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(TokenCalibrationService.storageKey), isNotNull);
      expect(
        events
            .recent(sessionId: 'session')
            .where((event) => event.type == 'token.calibration.updated'),
        hasLength(1),
      );
      expect(
        manager.recordCompletion(
          assemblyId: result.assemblyId,
          usage: const LlmUsage(inputTokens: 22000),
          hadToolCalls: false,
        ),
        isNull,
      );

      final skipResult = await manager.assembleForSend(
        sendRequest(messages: _calibrationHistory(suffix: 'skip')),
      );
      final skipped = manager.recordCompletion(
        assemblyId: skipResult.assemblyId,
        usage: null,
        hadToolCalls: false,
      );
      expect(skipped?.updated, isFalse);
      expect(skipped?.skipReason, 'missing_actual_tokens');
      expect(
        events
            .recent(sessionId: 'session')
            .where((event) => event.type == 'token.calibration.skipped'),
        hasLength(1),
      );

      final discardResult = await manager.assembleForSend(
        sendRequest(messages: _calibrationHistory(suffix: 'discard')),
      );
      manager.discardCompletion(discardResult.assemblyId);
      expect(
        manager.recordCompletion(
          assemblyId: discardResult.assemblyId,
          usage: const LlmUsage(inputTokens: 22000),
          hadToolCalls: false,
        ),
        isNull,
      );
    });
  });

  group('ContextManager assembleForCompare', () {
    test('uses temporary compare prompt without patch or calibration',
        () async {
      final manager = await createManager(
        summaryFactory: () => _ScriptedContextSummaryService(
          onGenerate: (_) => throw StateError('compare must not generate'),
        ),
      );

      final result = await manager.assembleForCompare(
        const ContextCompareRequest(
          sessionId: 'session',
          sessionApiMessages: [
            {'role': 'user', 'content': 'existing prompt'},
          ],
          comparePrompt: 'compare prompt',
          llmConfig: llmConfig,
          systemPrompt: 'system',
          compareModels: ['model-a', 'model-b'],
          contextTokenBudget: 32768,
          autoCompact: true,
        ),
      );

      expect(result.messages.toString(), contains('existing prompt'));
      expect(result.messages.toString(), contains('compare prompt'));
      expect(result.patch.isEmpty, isTrue);
      expect(
        manager.recordCompletion(
          assemblyId: result.assemblyId,
          usage: const LlmUsage(inputTokens: 1000),
          hadToolCalls: false,
        ),
        isNull,
      );
    });

    test('reuses valid summary and ignores stale summary for compare',
        () async {
      final events = RuntimeDebugEventService();
      final manager = await createManager(
        events: events,
        summaryFactory: () => _ScriptedContextSummaryService(
          onGenerate: (_) => throw StateError('compare must not generate'),
        ),
      );
      final sessionMessages = _largeHistory(prefix: 'compare-covered')
        ..removeLast();
      final compareMessages = [
        ...sessionMessages,
        {'role': 'user', 'content': 'compare prompt'},
      ];
      final plan = ChatContextUtils.planCompaction(
        compareMessages,
        maxTokens: _messageBudgetFor(compareMessages),
        estimator: const TokenEstimator(),
      );
      final validSummary = ContextSummary(
        version: ContextSummaryService.version,
        text: '## Goal\nValid compare summary',
        coveredMessageCount: plan.headForSummary.length,
        coveredDigest: plan.headDigest,
        sourceEstimatedTokens: plan.headEstimatedTokens,
        summaryEstimatedTokens: 20,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

      final validResult = await manager.assembleForCompare(
        ContextCompareRequest(
          sessionId: 'session',
          sessionApiMessages: sessionMessages,
          comparePrompt: 'compare prompt',
          existingSummary: validSummary,
          llmConfig: llmConfig,
          systemPrompt: 'system',
          compareModels: const ['model-a', 'model-b'],
          contextTokenBudget: 32768,
          autoCompact: true,
        ),
      );

      expect(validResult.systemPrompt, contains('Valid compare summary'));
      expect(validResult.summaryOutcome.reused, isTrue);

      final staleResult = await manager.assembleForCompare(
        ContextCompareRequest(
          sessionId: 'session',
          sessionApiMessages: sessionMessages,
          comparePrompt: 'compare prompt',
          existingSummary: ContextSummary(
            version: ContextSummaryService.version,
            text: '## Goal\nStale compare summary',
            coveredMessageCount: 1,
            coveredDigest: 'wrong-digest',
            sourceEstimatedTokens: 100,
            summaryEstimatedTokens: 20,
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
          llmConfig: llmConfig,
          systemPrompt: 'system',
          compareModels: const ['model-a', 'model-b'],
          contextTokenBudget: 32768,
          autoCompact: true,
        ),
      );

      expect(
          staleResult.systemPrompt, isNot(contains('Stale compare summary')));
      expect(staleResult.summaryOutcome.reused, isFalse);
      expect(
        events
            .recent(sessionId: 'session')
            .where((event) => event.type == 'context.summary.stale'),
        hasLength(1),
      );
    });
  });
}

List<Map<String, dynamic>> _largeHistory({required String prefix}) {
  return [
    {'role': 'user', 'content': '$prefix ${'中' * 24000}'},
    {'role': 'assistant', 'content': 'old reply ${'中' * 24000}'},
    {'role': 'user', 'content': 'recent prompt'},
    {'role': 'assistant', 'content': 'recent reply'},
    {'role': 'user', 'content': 'new prompt'},
  ];
}

List<Map<String, dynamic>> _calibrationHistory({String suffix = ''}) {
  return [
    for (var i = 0; i < 12; i++)
      {'role': 'user', 'content': 'history-$suffix-$i ${'x' * 4000}'},
    {'role': 'user', 'content': 'calibrate $suffix'},
  ];
}

Map<String, dynamic> _toolUseMessage(String id, String name) {
  return {
    'role': 'assistant',
    'content': [
      {
        'type': 'tool_use',
        'id': id,
        'name': name,
        'input': {'cmd': name},
      },
    ],
  };
}

Map<String, dynamic> _toolResultMessage(String id, String output) {
  return {
    'role': 'user',
    'content': [
      {
        'type': 'tool_result',
        'tool_use_id': id,
        'content': output,
      },
    ],
  };
}

int _messageBudgetFor(List<Map<String, dynamic>> messages) {
  return 32768 - const TokenEstimator().estimateText('system') - 8192 - 1024;
}

ContextSummary _summaryForRequest(ContextSummaryRequest request) {
  return ContextSummary(
    version: ContextSummaryService.version,
    text: '## Goal\nTest summary',
    coveredMessageCount: request.coveredMessageCount,
    coveredDigest: request.coveredDigest,
    sourceEstimatedTokens: request.sourceEstimatedTokens,
    summaryEstimatedTokens: 20,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    model: 'claude',
    apiFormat: 'anthropic',
  );
}

class _ScriptedContextSummaryService extends ContextSummaryService {
  final ContextSummary Function(ContextSummaryRequest request)? onGenerate;
  final ContextSummary Function(ContextSummaryRequest request)? onExtractive;

  _ScriptedContextSummaryService({
    this.onGenerate,
    this.onExtractive,
  });

  @override
  Future<ContextSummary> generateSummary(
    ContextSummaryRequest request,
  ) async {
    final handler = onGenerate;
    if (handler != null) return handler(request);
    return _summaryForRequest(request);
  }

  @override
  ContextSummary extractiveFallback(ContextSummaryRequest request) {
    final handler = onExtractive;
    if (handler != null) return handler(request);
    return super.extractiveFallback(request);
  }
}
