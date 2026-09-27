import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/workspace.dart';
import 'package:clawchat/services/file_attachment_service.dart';
import 'package:clawchat/services/share_action.dart';
import 'package:clawchat/services/shared_content.dart';
import 'package:clawchat/widgets/share_action_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final workspaces = [
    WorkspaceMetadata.defaultWorkspace(),
    WorkspaceMetadata(
      id: 'ws-docs',
      name: 'Docs',
      rootPath: '/root/workspace/docs',
    ),
  ];

  Future<ShareActionSelection?> openSheet(
    WidgetTester tester, {
    SharedContent content = const SharedContent(text: '会议纪要：下周一交付。'),
    PreparedSharedContent? prepared,
    void Function(ShareActionSelection?)? onResult,
    Size? size,
    double textScale = 1,
  }) async {
    ShareActionSelection? selection;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: size ?? const Size(800, 600),
            textScaler: TextScaler.linear(textScale),
          ),
          child: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    selection = await showShareActionSheet(
                      context,
                      content: content,
                      prepared: prepared ??
                          PreparedSharedContent(draftText: content.text.trim()),
                      workspaces: workspaces,
                      activeWorkspaceId: workspaces.first.id,
                    );
                    onResult?.call(selection);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return selection;
  }

  testWidgets('shows the preview and offers every action', (tester) async {
    await openSheet(
      tester,
      content: const SharedContent(
        text: '会议纪要：下周一交付。',
        subject: 'Weekly Sync',
      ),
    );

    expect(find.text('分享内容'), findsOneWidget);
    expect(find.text('Weekly Sync'), findsOneWidget);
    expect(find.textContaining('会议纪要'), findsWidgets);
    for (final kind in ShareActionKind.values) {
      expect(
        find.byKey(ValueKey('share-action-${kind.name}')),
        findsOneWidget,
        reason: kind.name,
      );
    }
    // The consent line states what leaves the device.
    expect(find.textContaining('发送到你配置的模型'), findsOneWidget);
  });

  testWidgets('choosing an action returns it with the selected workspace',
      (tester) async {
    ShareActionSelection? selection;
    await openSheet(tester, onResult: (value) => selection = value);

    await tester.tap(find.byKey(const ValueKey('share-action-summarize')));
    await tester.pumpAndSettle();

    expect(selection, isNotNull);
    expect(selection!.kind, ShareActionKind.summarize);
    expect(selection!.workspaceId, WorkspaceMetadata.defaultWorkspaceId);
  });

  testWidgets('dismissing the sheet returns null so nothing is sent',
      (tester) async {
    ShareActionSelection? selection;
    var completed = false;
    await openSheet(tester, onResult: (value) {
      selection = value;
      completed = true;
    });

    // The sheet scrolls: the cancel row sits below the fold on a phone-sized
    // viewport, so the user has to reach it deliberately (it is not even built
    // until the list scrolls).
    await tester.scrollUntilVisible(find.text('取消'), 120);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    // The awaited result resolves one microtask after the route is gone.
    await tester.pump();

    expect(completed, isTrue);
    expect(selection, isNull);
  });

  testWidgets('names the target workspace and what leaves the device',
      (tester) async {
    await openSheet(tester);

    // The target line states where the content lands before any action.
    expect(find.textContaining('保存到工作区「工作区」'), findsOneWidget);
    expect(find.textContaining('新建一个会话'), findsOneWidget);
    // Send vs local is a status word, not a color-only signal.
    expect(find.text('会发送到模型'), findsNWidgets(2));
    expect(find.text('仅本地'), findsNWidgets(2));

    // Switching the workspace rewrites the same line.
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Docs').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('保存到工作区「Docs」'), findsOneWidget);
  });

  testWidgets('stays usable at 320dp and 200 percent text', (tester) async {
    await openSheet(tester, size: const Size(320, 720), textScale: 2);

    expect(find.textContaining('保存到工作区「工作区」'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('share-action-summarize')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('warnings and image counts are surfaced before acting',
      (tester) async {
    await openSheet(
      tester,
      prepared: PreparedSharedContent(
        draftText: 'hello',
        warnings: const ['a.png: 导入失败'],
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

    expect(find.text('1 张图片'), findsOneWidget);
    expect(find.textContaining('导入失败'), findsOneWidget);
  });
}
