import 'package:clawchat/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('share failure never copies until explicit Copy', (tester) async {
    var clipboardWrites = 0;
    var shareAttempts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboardWrites += 1;
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsDetailScreen(
          destination: SettingsDestination.privacy,
          skipInitialLoadForTesting: true,
          diagnosticsReportBuilderForTesting: () async =>
              'ClawChat diagnostics\nversion: 2.5.0\nsafeMode: false',
          diagnosticsShareForTesting: (_) async {
            shareAttempts += 1;
            return false;
          },
        ),
      ),
    );

    await tester.tap(find.text('导出脱敏诊断'));
    await tester.pumpAndSettle();
    expect(find.text('预览脱敏诊断'), findsOneWidget);
    expect(find.textContaining('不包含：消息、提示词、工具载荷、端点'), findsOneWidget);
    expect(find.textContaining('ClawChat diagnostics'), findsOneWidget);

    await tester.tap(find.text('分享'));
    await tester.pumpAndSettle();
    expect(shareAttempts, 1);
    expect(clipboardWrites, 0);
    expect(find.textContaining('分享未打开，内容未复制'), findsOneWidget);
    expect(find.text('重试分享'), findsOneWidget);
    expect(find.text('保存文件'), findsOneWidget);

    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(clipboardWrites, 1);
    expect(find.text('已复制'), findsOneWidget);
  });

  testWidgets('explicit Save uses safe destination without clipboard',
      (tester) async {
    var clipboardWrites = 0;
    var saves = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboardWrites += 1;
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsDetailScreen(
          destination: SettingsDestination.privacy,
          skipInitialLoadForTesting: true,
          diagnosticsReportBuilderForTesting: () async =>
              'ClawChat diagnostics\nversion: 2.5.0',
          diagnosticsSaveForTesting: (_) async {
            saves += 1;
            return true;
          },
        ),
      ),
    );

    await tester.tap(find.text('导出脱敏诊断'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存文件'));
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(clipboardWrites, 0);
    expect(find.text('已保存'), findsOneWidget);
  });
}
