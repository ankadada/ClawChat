import 'dart:async';
import 'dart:typed_data';

import 'package:clawchat/models/workspace.dart';
import 'package:clawchat/screens/workspace_browser_screen.dart';
import 'package:clawchat/services/workspace_file_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeNative {
  final Map<String, Map<String, dynamic>> listings = {};
  final Map<String, List<int>> texts = {};
  final Map<String, Uint8List> bytes = {};
  final deleted = <String>[];
  final written = <String, String>{};
  final writeCreateNew = <bool>[];
  bool deleteResult = true;
  Object? listError;
  Completer<void>? listGate;

  /// Per-path scripted list calls, consumed in order: a [Completer] holds that
  /// call until the test completes it, a map is returned as its result. Calls
  /// beyond the script fall back to the listings below.
  final Map<String, List<Object>> listScript = {};

  Future<Map<String, dynamic>> list({
    required String path,
    required List<String> allowedRoots,
    required int maxEntries,
  }) async {
    final script = listScript[path];
    if (script != null && script.isNotEmpty) {
      final step = script.removeAt(0);
      if (step is Completer<void>) {
        await step.future;
      } else if (step is Map<String, dynamic>) {
        return step;
      }
    }
    final gate = listGate;
    if (gate != null) await gate.future;
    final error = listError;
    if (error != null) throw error;
    return listings[path] ?? const {'entries': [], 'truncated': false};
  }

  Future<Uint8List?> readBytesFor(
    String path, {
    List<String>? allowedRoots,
    int maxBytes = 0,
  }) async =>
      texts[path] == null ? null : Uint8List.fromList(texts[path]!);

  Future<Uint8List?> readBytes(
    String path, {
    List<String>? allowedRoots,
    int maxBytes = 0,
  }) async =>
      bytes[path];

  Future<bool> delete(String path, {List<String>? allowedRoots}) async {
    deleted.add(path);
    return deleteResult;
  }

  Future<bool> write(
    String path,
    String content, {
    List<String>? allowedRoots,
    bool createNew = false,
  }) async {
    written[path] = content;
    writeCreateNew.add(createNew);
    return true;
  }
}

Map<String, dynamic> entry(
  String name, {
  bool isDirectory = false,
  bool isSymbolicLink = false,
  int sizeBytes = 0,
  String root = '/root/workspace',
}) =>
    {
      'name': name,
      'path': '$root/$name',
      'isDirectory': isDirectory,
      'isSymbolicLink': isSymbolicLink,
      'sizeBytes': sizeBytes,
      'modifiedEpochMs': 1700000000000,
    };

void main() {
  late _FakeNative native;
  late WorkspaceMetadata workspace;

  WorkspaceFileService serviceFor(WorkspaceMetadata target) =>
      WorkspaceFileService(
        workspace: target,
        list: native.list,
        readBytes: native.readBytesFor,
        delete: native.delete,
        write: native.write,
      );

  setUp(() {
    native = _FakeNative();
    workspace = WorkspaceMetadata(
      id: 'ws-1',
      name: 'Docs',
      rootPath: '/root/workspace',
    );
    native.listings['/root/workspace'] = {
      'entries': [
        entry('sub', isDirectory: true),
        entry('note.md', sizeBytes: 12),
        entry('link', isSymbolicLink: true),
      ],
      'truncated': false,
    };
    native.listings['/root/workspace/sub'] = {
      'entries': [
        entry('inner.txt', sizeBytes: 3, root: '/root/workspace/sub')
      ],
      'truncated': false,
    };
    native.texts['/root/workspace/note.md'] = 'hello workspace\n'.codeUnits;
  });

  Future<void> pumpBrowser(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WorkspaceBrowserScreen(
          workspace: workspace,
          service: serviceFor(workspace),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists directories first with folder, link and file rows',
      (tester) async {
    await pumpBrowser(tester);

    expect(find.text('sub'), findsOneWidget);
    expect(find.text('note.md'), findsOneWidget);
    expect(find.text('link'), findsOneWidget);
    expect(find.text('链接（不跟随）'), findsOneWidget);
    expect(find.text('文件夹'), findsOneWidget);
    // Directories come first, so the folder row sits above the first file row.
    final folderTop = tester.getTopLeft(find.text('sub')).dy;
    final fileTop = tester.getTopLeft(find.text('note.md')).dy;
    expect(folderTop, lessThan(fileTop));
  });

  testWidgets('descends into a folder and shows the nested file',
      (tester) async {
    await pumpBrowser(tester);

    await tester.tap(find.text('sub'));
    await tester.pumpAndSettle();

    expect(find.text('inner.txt'), findsOneWidget);
    // Breadcrumb offers a way back to the root.
    await tester
        .tap(find.byKey(const ValueKey('workspace-crumb-/root/workspace')));
    await tester.pumpAndSettle();
    expect(find.text('note.md'), findsOneWidget);
  });

  testWidgets('a symlinked entry is never opened', (tester) async {
    await pumpBrowser(tester);

    await tester.tap(find.text('link'));
    await tester.pumpAndSettle();

    expect(find.text('链接不会在这里打开'), findsOneWidget);
  });

  testWidgets('preview offers copy, send and delete, and send returns the path',
      (tester) async {
    String? reference;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  reference = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) => WorkspaceBrowserScreen(
                        workspace: workspace,
                        service: serviceFor(workspace),
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('note.md'));
    await tester.pumpAndSettle();

    expect(find.text('hello workspace\n'), findsOneWidget);
    expect(find.text('复制路径'), findsOneWidget);
    expect(find.textContaining('插入后仍需你确认发送'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    await tester.tap(find.text('插入输入框'));
    await tester.pumpAndSettle();

    expect(reference, '工作区文件：/root/workspace/note.md');
  });

  testWidgets('delete asks for scope-confirmed consent then offers undo',
      (tester) async {
    await pumpBrowser(tester);

    await tester.tap(find.text('note.md'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // The confirmation names the file, its location and the workspace.
    expect(find.textContaining('note.md'), findsWidgets);
    expect(find.textContaining('工作区：Docs'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(native.deleted, ['/root/workspace/note.md']);
    expect(find.text('已删除 note.md'), findsOneWidget);

    // Undo restores the text the preview held.
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(native.written['/root/workspace/note.md'], 'hello workspace\n');
  });

  testWidgets('cancelling the delete confirmation returns to the preview',
      (tester) async {
    await pumpBrowser(tester);

    await tester.tap(find.text('note.md'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // The preview stays open behind the confirmation dialog.
    expect(find.text('插入输入框'), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(TextButton, '取消'),
    ));
    await tester.pumpAndSettle();

    // Cancelling returns to the preview, not to the directory listing, and
    // nothing was deleted.
    expect(find.text('hello workspace\n'), findsOneWidget);
    expect(find.text('插入输入框'), findsOneWidget);
    expect(native.deleted, isEmpty);
  });

  testWidgets('refreshing a visible listing shows progress and keeps rows',
      (tester) async {
    await pumpBrowser(tester);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    final gate = Completer<void>();
    native.listGate = gate;
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    // The rows that are already on screen stay reachable during the refresh.
    expect(find.text('note.md'), findsOneWidget);

    native.listGate = null;
    gate.complete();
    await tester.pumpAndSettle();

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('note.md'), findsOneWidget);
  });

  testWidgets('a late result for a left directory never replaces the view',
      (tester) async {
    await pumpBrowser(tester);

    final subGate = Completer<void>();
    native.listScript['/root/workspace/sub'] = [subGate];

    await tester.tap(find.text('sub'));
    await tester.pump();
    // The sub directory read is still in flight.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Go back to the root before it resolves.
    await tester
        .tap(find.byKey(const ValueKey('workspace-crumb-/root/workspace')));
    await tester.pumpAndSettle();
    expect(find.text('note.md'), findsOneWidget);

    // The stale sub listing arrives late and must be discarded.
    subGate.complete();
    await tester.pumpAndSettle();

    expect(find.text('note.md'), findsOneWidget);
    expect(find.text('inner.txt'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stale refresh never overwrites a newer listing of the path',
      (tester) async {
    await pumpBrowser(tester);

    final slowRefresh = Completer<void>();
    native.listScript['/root/workspace'] = [
      slowRefresh,
      {
        'entries': [entry('fresh.md', sizeBytes: 4)],
        'truncated': false,
      },
    ];

    // Refresh #1 waits on the gate.
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();

    // Leave and come back: the return trip reads the same path again and gets
    // the fresh listing.
    await tester.tap(find.text('sub'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('workspace-crumb-/root/workspace')));
    await tester.pumpAndSettle();
    expect(find.text('fresh.md'), findsOneWidget);

    // The older refresh resolves last and must be dropped.
    slowRefresh.complete();
    await tester.pumpAndSettle();

    expect(find.text('fresh.md'), findsOneWidget);
    expect(find.text('note.md'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scope refusals surface as an error state with retry',
      (tester) async {
    native.listings.clear();

    await pumpBrowser(tester);

    expect(find.text('这个目录还是空的'), findsOneWidget);

    native.listError = const WorkspaceFileException('list_failed', '越界');
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(find.text('无法读取这个目录'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}
