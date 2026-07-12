import 'dart:async';

import 'package:clawchat/constants.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/screens/settings_screen.dart';
import 'package:clawchat/services/skill_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AppConstants.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getArch':
          return 'arm64';
        case 'getBootstrapStatus':
          return <String, dynamic>{};
        case 'runInProot':
          return '';
        case 'readRootfsFile':
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('visible cancel aborts production preparation before consent',
      (tester) async {
    final operation = _PendingPreparation();
    await _pumpSettings(tester, operation.call);

    await tester.tap(find.byTooltip(AppStrings.importSkill));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'https://public.example/skill.zip',
    );
    await tester
        .tap(find.widgetWithText(FilledButton, AppStrings.importButton));
    await tester.pump();

    expect(find.text(AppStrings.preparingSkillArchive), findsOneWidget);
    expect(find.text(AppStrings.cancelSkillImport), findsOneWidget);
    await tester.tap(find.text(AppStrings.cancelSkillImport));
    await operation.cancelObserved.future;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(operation.requestedUrl, 'https://public.example/skill.zip');
    expect(find.text('Review skill capabilities'), findsNothing);
    expect(find.text(AppStrings.preparingSkillArchive), findsNothing);
  });

  testWidgets('disposing Settings cancels an in-flight remote preparation',
      (tester) async {
    final operation = _PendingPreparation();
    await _pumpSettings(tester, operation.call);

    await tester.tap(find.byTooltip(AppStrings.importSkill));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'https://public.example/skill.zip',
    );
    await tester
        .tap(find.widgetWithText(FilledButton, AppStrings.importButton));
    await tester.pump();
    expect(find.text(AppStrings.cancelSkillImport), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await operation.cancelObserved.future;
    await tester.pump();

    expect(operation.token?.isCancelled, isTrue);
    expect(find.text('Review skill capabilities'), findsNothing);
  });
}

Future<void> _pumpSettings(
  WidgetTester tester,
  Future<PreparedSkillImport> Function(
    String url,
    SkillImportCancellationToken cancellationToken,
  ) prepare,
) async {
  await tester.pumpWidget(MaterialApp(
    home: SettingsScreen(
      prepareSkillFromUrlForTesting: prepare,
      skipInitialLoadForTesting: true,
      importFlowOnlyForTesting: true,
    ),
  ));
  for (var index = 0; index < 5; index++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

final class _PendingPreparation {
  final Completer<PreparedSkillImport> _result =
      Completer<PreparedSkillImport>();
  final Completer<void> cancelObserved = Completer<void>();
  SkillImportCancellationToken? token;
  String? requestedUrl;

  Future<PreparedSkillImport> call(
    String url,
    SkillImportCancellationToken cancellationToken,
  ) {
    requestedUrl = url;
    token = cancellationToken;
    unawaited(cancellationToken.whenCancelled.then((_) {
      if (!cancelObserved.isCompleted) cancelObserved.complete();
      if (!_result.isCompleted) {
        _result.completeError(StateError('Skill import cancelled.'));
      }
    }));
    return _result.future;
  }
}
