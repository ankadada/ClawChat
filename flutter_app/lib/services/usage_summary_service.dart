import '../models/chat_models.dart';

class UsageSummary {
  final int messageCount;
  final int messagesWithUsage;
  final int inputTokens;
  final int outputTokens;
  final int totalTokens;
  final int? cacheReadInputTokens;
  final int? cacheCreationInputTokens;

  const UsageSummary({
    required this.messageCount,
    required this.messagesWithUsage,
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
    this.cacheReadInputTokens,
    this.cacheCreationInputTokens,
  });

  bool get hasUsage => messagesWithUsage > 0;
  bool get hasCacheUsage =>
      cacheReadInputTokens != null || cacheCreationInputTokens != null;

  Map<String, dynamic> toJson() => {
        'messageCount': messageCount,
        'messagesWithUsage': messagesWithUsage,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'totalTokens': totalTokens,
        if (cacheReadInputTokens != null)
          'cacheReadInputTokens': cacheReadInputTokens,
        if (cacheCreationInputTokens != null)
          'cacheCreationInputTokens': cacheCreationInputTokens,
      };

  factory UsageSummary.fromJson(Map<String, dynamic> json) {
    return UsageSummary(
      messageCount: json['messageCount'] as int? ?? 0,
      messagesWithUsage: json['messagesWithUsage'] as int? ?? 0,
      inputTokens: json['inputTokens'] as int? ?? 0,
      outputTokens: json['outputTokens'] as int? ?? 0,
      totalTokens: json['totalTokens'] as int? ?? 0,
      cacheReadInputTokens: json['cacheReadInputTokens'] as int?,
      cacheCreationInputTokens: json['cacheCreationInputTokens'] as int?,
    );
  }
}

class UsageSummaryService {
  const UsageSummaryService();

  UsageSummary forSession(ChatSession? session) {
    if (session == null) {
      return const UsageSummary(
        messageCount: 0,
        messagesWithUsage: 0,
        inputTokens: 0,
        outputTokens: 0,
        totalTokens: 0,
      );
    }
    return forMessages(session.messages);
  }

  UsageSummary forSessions(Iterable<ChatSession> sessions) {
    final messages = sessions.expand((session) => session.messages);
    return forMessages(messages);
  }

  UsageSummary combine(Iterable<UsageSummary> summaries) {
    var messageCount = 0;
    var messagesWithUsage = 0;
    var inputTokens = 0;
    var outputTokens = 0;
    var totalTokens = 0;
    var cacheReadTokens = 0;
    var cacheCreationTokens = 0;
    var hasCacheRead = false;
    var hasCacheCreation = false;

    for (final summary in summaries) {
      messageCount += summary.messageCount;
      messagesWithUsage += summary.messagesWithUsage;
      inputTokens += summary.inputTokens;
      outputTokens += summary.outputTokens;
      totalTokens += summary.totalTokens;
      final cacheRead = summary.cacheReadInputTokens;
      if (cacheRead != null) {
        hasCacheRead = true;
        cacheReadTokens += cacheRead;
      }
      final cacheCreation = summary.cacheCreationInputTokens;
      if (cacheCreation != null) {
        hasCacheCreation = true;
        cacheCreationTokens += cacheCreation;
      }
    }

    return UsageSummary(
      messageCount: messageCount,
      messagesWithUsage: messagesWithUsage,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      totalTokens: totalTokens,
      cacheReadInputTokens: hasCacheRead ? cacheReadTokens : null,
      cacheCreationInputTokens: hasCacheCreation ? cacheCreationTokens : null,
    );
  }

  UsageSummary forMessages(Iterable<ChatMessage> messages) {
    var messageCount = 0;
    var messagesWithUsage = 0;
    var inputTokens = 0;
    var outputTokens = 0;
    var totalTokens = 0;
    var cacheReadTokens = 0;
    var cacheCreationTokens = 0;
    var hasCacheRead = false;
    var hasCacheCreation = false;

    for (final message in messages) {
      if (message.isSystemNotice) continue;
      messageCount++;
      final hasUsage = message.inputTokens != null ||
          message.outputTokens != null ||
          message.cacheReadInputTokens != null ||
          message.cacheCreationInputTokens != null;
      if (!hasUsage) continue;
      messagesWithUsage++;
      inputTokens += message.inputTokens ?? 0;
      outputTokens += message.outputTokens ?? 0;
      final cacheRead = message.cacheReadInputTokens;
      if (cacheRead != null) {
        hasCacheRead = true;
        cacheReadTokens += cacheRead;
      }
      final cacheCreation = message.cacheCreationInputTokens;
      if (cacheCreation != null) {
        hasCacheCreation = true;
        cacheCreationTokens += cacheCreation;
      }
      totalTokens += (message.inputTokens ?? 0) + (message.outputTokens ?? 0);
      if (!message.inputTokensIncludeCache) {
        totalTokens += (cacheRead ?? 0) + (cacheCreation ?? 0);
      }
    }

    return UsageSummary(
      messageCount: messageCount,
      messagesWithUsage: messagesWithUsage,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      totalTokens: totalTokens,
      cacheReadInputTokens: hasCacheRead ? cacheReadTokens : null,
      cacheCreationInputTokens: hasCacheCreation ? cacheCreationTokens : null,
    );
  }
}

class UsageSummaryAggregate {
  final int sessionCount;
  final UsageSummary summary;

  const UsageSummaryAggregate({
    required this.sessionCount,
    required this.summary,
  });

  Map<String, dynamic> toJson() => {
        'sessionCount': sessionCount,
        'summary': summary.toJson(),
      };

  factory UsageSummaryAggregate.fromJson(Map<String, dynamic> json) {
    final rawSummary = json['summary'];
    return UsageSummaryAggregate(
      sessionCount: json['sessionCount'] as int? ?? 0,
      summary: rawSummary is Map
          ? UsageSummary.fromJson(Map<String, dynamic>.from(rawSummary))
          : const UsageSummary(
              messageCount: 0,
              messagesWithUsage: 0,
              inputTokens: 0,
              outputTokens: 0,
              totalTokens: 0,
            ),
    );
  }
}
