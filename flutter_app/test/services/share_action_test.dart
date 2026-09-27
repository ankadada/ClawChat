import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/workspace.dart';
import 'package:clawchat/services/file_attachment_service.dart';
import 'package:clawchat/services/share_action.dart';
import 'package:clawchat/services/shared_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const planner = ShareActionPlanner();
  final now = DateTime(2026, 9, 26, 10, 30, 15);
  final workspace = WorkspaceMetadata(
    id: 'ws-1',
    name: '工作区',
    rootPath: '/root/workspace',
  );

  ShareActionPlan planFor(
    ShareActionKind kind, {
    String text = '',
    String? subject,
    List<SharedImage> images = const [],
    PreparedSharedContent? prepared,
    WorkspaceMetadata? target,
  }) {
    final content = SharedContent(
      text: text,
      subject: subject,
      images: images,
    );
    return planner.plan(
      kind: kind,
      content: content,
      prepared: prepared ?? PreparedSharedContent(draftText: text.trim()),
      workspace: target ?? workspace,
      now: now,
    );
  }

  group('ShareActionPlanner', () {
    test('summarize and extract-todos build real prompts with the content', () {
      final summarize = planFor(
        ShareActionKind.summarize,
        text: '会议纪要：下周一交付。',
      );
      expect(summarize.sendImmediately, isTrue);
      expect(summarize.draftText, contains('请总结我分享的内容'));
      expect(summarize.draftText, contains('会议纪要：下周一交付。'));
      expect(summarize.writePath, isNull);

      final todos = planFor(
        ShareActionKind.extractTodos,
        text: '会议纪要',
      );
      expect(todos.draftText, contains('提取可执行的待办事项'));
      expect(todos.draftText, contains('会议纪要'));
      expect(todos.sendImmediately, isTrue);
    });

    test('an empty payload still produces the instruction, never an empty send',
        () {
      final summarize = planFor(ShareActionKind.summarize);
      expect(summarize.draftText, '请总结我分享的内容：先给出一句话结论，再列出要点。');
      expect(summarize.draftText.trim(), isNotEmpty);
    });

    test('long content is truncated with a visible notice', () {
      final plan = planFor(
        ShareActionKind.summarize,
        text: 'x' * (ShareActionPlanner.maxPromptContentChars + 500),
      );

      expect(
        plan.draftText.length,
        lessThan(ShareActionPlanner.maxPromptContentChars + 200),
      );
      expect(plan.notices.join(), contains('已截断'));
    });

    test('save-to-workspace targets the shared folder inside the workspace',
        () {
      final plan = planFor(
        ShareActionKind.saveToWorkspace,
        text: '正文',
        subject: 'Weekly Sync',
      );

      expect(
        plan.writePath,
        startsWith('/root/workspace/shared/20260926-103015'),
      );
      expect(plan.writePath, endsWith('-Weekly_Sync.md'));
      expect(workspace.containsPath(plan.writePath!), isTrue);
      expect(plan.writeBody, contains('# Weekly Sync'));
      expect(plan.writeBody, contains('正文'));
      expect(plan.writeBody, contains('2026-09-26T10:30:15.000'));
      expect(plan.draftText, contains(plan.writePath!));
      expect(plan.sendImmediately, isFalse);
    });

    test('two shares in the same millisecond never share a name', () {
      final first = planner.plan(
        kind: ShareActionKind.saveToWorkspace,
        content: const SharedContent(text: 'a', subject: 'same'),
        prepared: const PreparedSharedContent(draftText: 'a'),
        workspace: workspace,
        now: now,
      );
      final second = planner.plan(
        kind: ShareActionKind.saveToWorkspace,
        content: const SharedContent(text: 'a', subject: 'same'),
        prepared: const PreparedSharedContent(draftText: 'a'),
        workspace: workspace,
        now: now,
      );

      // Same second and same subject: the millisecond stamp plus the random
      // suffix still keep the two saves apart.
      expect(first.writePath, isNot(second.writePath));
      expect(first.writePath, startsWith('/root/workspace/shared/'));
      expect(first.writePath, endsWith('-same.md'));
      expect(first.writeAttempts, hasLength(3));
      expect(first.writeAttempts.toSet(), hasLength(3));
      for (final candidate in first.writeAttempts) {
        expect(workspace.containsPath(candidate), isTrue);
      }
    });

    test('save path never escapes the workspace and never overwrites', () {
      final hostile = planFor(
        ShareActionKind.saveToWorkspace,
        text: 'x',
        subject: '../../etc/passwd',
      );
      expect(hostile.writePath, startsWith('/root/workspace/shared/'));
      expect(hostile.writePath, isNot(contains('..')));

      final first = planFor(
        ShareActionKind.saveToWorkspace,
        text: 'a',
        subject: 'same',
      );
      final second = planner.plan(
        kind: ShareActionKind.saveToWorkspace,
        content: const SharedContent(text: 'a', subject: 'same'),
        prepared: const PreparedSharedContent(draftText: 'a'),
        workspace: workspace,
        now: now.add(const Duration(seconds: 1)),
      );
      expect(first.writePath, isNot(second.writePath));
    });

    test('a nested workspace keeps saves inside its own subtree', () {
      final nested = WorkspaceMetadata(
        id: 'ws-2',
        name: 'Docs',
        rootPath: '/root/workspace/docs',
      );
      final plan = planFor(
        ShareActionKind.saveToWorkspace,
        text: 'x',
        subject: 'note',
        target: nested,
      );

      expect(plan.writePath, startsWith('/root/workspace/docs/shared/'));
      expect(nested.containsPath(plan.writePath!), isTrue);
    });

    test('images are reported by count, not embedded as temp paths', () {
      final plan = planFor(
        ShareActionKind.saveToWorkspace,
        text: 'text',
        images: const [
          SharedImage(path: '/tmp/a.png', name: 'a.png', size: 10),
        ],
        prepared: PreparedSharedContent(
          draftText: 'text',
          attachments: [
            PreparedAttachment(
              content: ImageContent(
                data: 'AAAA',
                mediaType: 'image/png',
                filename: 'a.png',
              ),
              inputText: '',
              includeAsContentBlock: true,
            ),
          ],
        ),
      );

      expect(plan.notices.join(), contains('已附带 1 张图片'));
      expect(plan.writeBody, contains('- a.png'));
      expect(plan.writeBody, isNot(contains('/tmp/a.png')));
    });

    test('draftOnly keeps the legacy behaviour and warnings', () {
      final plan = planFor(
        ShareActionKind.draftOnly,
        text: 'hello',
        prepared: const PreparedSharedContent(
          draftText: 'hello',
          warnings: ['a.png: 导入失败'],
        ),
      );

      expect(plan.draftText, 'hello');
      expect(plan.sendImmediately, isFalse);
      expect(plan.writePath, isNull);
      expect(plan.notices, contains('a.png: 导入失败'));
    });

    test('labels cover every action', () {
      for (final kind in ShareActionKind.values) {
        expect(ShareActionPlanner.label(kind).trim(), isNotEmpty);
      }
    });
  });
}
