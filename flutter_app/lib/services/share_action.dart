import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/chat_models.dart';
import '../models/workspace.dart';
import 'shared_content.dart';

/// What the user chose to do with content that arrived through the share sheet.
enum ShareActionKind {
  /// Ask the agent to summarise the shared content.
  summarize,

  /// Ask the agent to extract actionable items.
  extractTodos,

  /// Write the shared content into the active workspace as a file.
  saveToWorkspace,

  /// Keep today's behaviour: stage the content as a draft and stop.
  draftOnly,
}

/// Which session/workspace the action applies to.
@immutable
class ShareActionTarget {
  final String workspaceId;
  final String? sessionId;

  const ShareActionTarget({required this.workspaceId, this.sessionId});
}

/// The concrete result of a share action: what to type, what to save, and what
/// the user has to be told.
@immutable
class ShareActionPlan {
  /// Text staged into the composer (and sent for the two agent actions).
  final String draftText;

  /// True when the staged text is meant to be sent without further editing.
  final bool sendImmediately;

  /// Candidate guest paths for a save, in order. The planner puts a millisecond
  /// stamp and a random suffix in the first one; the rest cover the (unlikely)
  /// case where that exact name is already taken, so a save can be retried
  /// without ever overwriting an existing file.
  final List<String> writeAttempts;
  final String? writeBody;

  /// The path the save is expected to use.
  String? get writePath => writeAttempts.isEmpty ? null : writeAttempts.first;

  /// Bounded, user-visible lines about what happened or was dropped.
  final List<String> notices;

  const ShareActionPlan({
    required this.draftText,
    this.sendImmediately = false,
    this.writeAttempts = const [],
    this.writeBody,
    this.notices = const [],
  });
}

/// Turns shared content into a plan. Pure: every side effect (session creation,
/// file write, send) is executed by the caller, so the decision can be tested
/// without widgets or native plumbing.
class ShareActionPlanner {
  /// Longest shared text folded into one prompt. The rest is replaced by a
  /// notice instead of silently shipping an unbounded payload to the model.
  static const int maxPromptContentChars = 8000;

  const ShareActionPlanner();

  static String label(ShareActionKind kind) {
    switch (kind) {
      case ShareActionKind.summarize:
        return '总结';
      case ShareActionKind.extractTodos:
        return '提取待办';
      case ShareActionKind.saveToWorkspace:
        return '保存到工作区';
      case ShareActionKind.draftOnly:
        return '仅新建草稿';
    }
  }

  ShareActionPlan plan({
    required ShareActionKind kind,
    required SharedContent content,
    required PreparedSharedContent prepared,
    required WorkspaceMetadata workspace,
    DateTime? now,
  }) {
    final notices = <String>[...prepared.warnings];
    final imageCount = prepared.attachments
        .where((item) => item.content is ImageContent)
        .length;
    if (imageCount > 0) {
      notices.add('已附带 $imageCount 张图片');
    }

    switch (kind) {
      case ShareActionKind.summarize:
        return ShareActionPlan(
          draftText: _prompt(
            '请总结我分享的内容：先给出一句话结论，再列出要点。',
            content.text,
            notices,
          ),
          sendImmediately: true,
          notices: notices,
        );
      case ShareActionKind.extractTodos:
        return ShareActionPlan(
          draftText: _prompt(
            '请从下面分享的内容中提取可执行的待办事项，按优先级列出，并标注时间或负责人（如果内容里有）。',
            content.text,
            notices,
          ),
          sendImmediately: true,
          notices: notices,
        );
      case ShareActionKind.saveToWorkspace:
        final attempts = <String>[
          savePathFor(workspace: workspace, content: content, now: now),
          savePathFor(
            workspace: workspace,
            content: content,
            now: now,
            attempt: 1,
          ),
          savePathFor(
            workspace: workspace,
            content: content,
            now: now,
            attempt: 2,
          ),
        ];
        final path = attempts.first;
        final hasText = content.text.trim().isNotEmpty;
        return ShareActionPlan(
          draftText:
              hasText ? '已保存到工作区：$path\n\n可以让我基于这个文件继续处理。' : '已保存到工作区：$path',
          writeAttempts: attempts,
          writeBody: buildSaveBody(content: content, now: now),
          notices: notices,
        );
      case ShareActionKind.draftOnly:
        return ShareActionPlan(
          draftText: content.text.trim(),
          notices: notices,
        );
    }
  }

  /// Destination for a saved share: the shared folder inside the workspace,
  /// with a timestamped, sanitized name so two shares never overwrite each
  /// other and the path can never leave the workspace root.
  String savePathFor({
    required WorkspaceMetadata workspace,
    required SharedContent content,
    DateTime? now,
    int attempt = 0,
    String? nonce,
  }) {
    final stamp = _timestamp(now ?? DateTime.now());
    final subjectSource = (content.subject?.trim().isNotEmpty ?? false)
        ? content.subject!.trim()
        : content.text.trim().split('\n').first;
    final subject = WorkspaceMetadata.sanitizeFileSegment(subjectSource);
    final suffix = nonce ?? _randomSuffix();
    final attemptSuffix = attempt == 0 ? '' : '-${attempt + 1}';
    return '${workspace.rootPath}/shared/'
        '$stamp-$suffix-$subject$attemptSuffix.md';
  }

  static final Random _random = Random.secure();

  static String _randomSuffix() {
    final value = _random.nextInt(0x10000);
    return value.toRadixString(16).padLeft(4, '0');
  }

  /// The markdown body written for a saved share. Images are listed by name:
  /// their native temp paths do not outlive the import.
  String buildSaveBody({required SharedContent content, DateTime? now}) {
    final subject = (content.subject?.trim().isNotEmpty ?? false)
        ? content.subject!.trim()
        : '分享内容';
    final buffer = StringBuffer()
      ..writeln('# $subject')
      ..writeln()
      ..writeln('- 保存时间：${(now ?? DateTime.now()).toIso8601String()}')
      ..writeln('- 来源：系统分享');
    final text = content.text.trim();
    if (text.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(text);
    }
    if (content.images.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## 图片');
      for (final image in content.images) {
        buffer.writeln('- ${image.name}');
      }
    }
    return buffer.toString();
  }

  String _prompt(String instruction, String text, List<String> notices) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return instruction;
    if (trimmed.length <= maxPromptContentChars) {
      return '$instruction\n\n---\n$trimmed';
    }
    notices.add(
      '分享内容较长，已截断到 $maxPromptContentChars 字符；可用“保存到工作区”保留完整内容。',
    );
    return '$instruction\n\n---\n${trimmed.substring(0, maxPromptContentChars)}';
  }

  static String _timestamp(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    String three(int number) => number.toString().padLeft(3, '0');
    return '${value.year}${two(value.month)}${two(value.day)}-'
        '${two(value.hour)}${two(value.minute)}${two(value.second)}'
        '${three(value.millisecond)}';
  }
}
