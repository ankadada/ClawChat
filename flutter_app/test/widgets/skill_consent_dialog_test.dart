import 'dart:convert';
import 'dart:ui';

import 'package:clawchat/services/skill_service.dart';
import 'package:clawchat/widgets/skill_consent_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String _manifest() => jsonEncode({
      'schemaVersion': 1,
      'id': 'com.example.safe-preview',
      'name': 'Safe Preview',
      'description': 'Preview test.',
      'model': {
        'name': 'safe_preview',
        'description': 'Use for preview tests.',
      },
      'version': '1.0.0',
      'source': {'type': 'local'},
      'integrity': <String, dynamic>{},
      'author': 'Example',
      'license': 'MIT',
      'capabilities': {
        'tools': ['bash'],
        'commands': ['git'],
        'networkDomains': ['example.com'],
        'filesystem': {
          'read': ['/root/workspace'],
          'write': <String>[],
        },
        'android': {
          'intents': <String>[],
          'permissions': <String>[],
        },
        'secrets': ['PRIVATE_TOKEN'],
        'subprocess': {
          'required': true,
          'runtimes': ['git'],
        },
        'riskTier': 'high',
        'updatePolicy': 'manual',
      },
    });

void main() {
  testWidgets('renders identity and secret names but never secret values',
      (tester) async {
    final candidate = SkillService.inspectPackage(
      stagingPath: '/tmp/safe-preview',
      sourceIdentity: 'Local: safe-preview',
      skillContent: '---\nname: safe-preview\n---',
      manifestContent: _manifest(),
    );
    bool? result;

    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return TextButton(
          onPressed: () async {
            result = await showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (_) => SkillConsentDialog(candidate: candidate),
            );
          },
          child: const Text('Open'),
        );
      }),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Review skill capabilities'), findsOneWidget);
    expect(find.text('Local inert import inspection'), findsOneWidget);
    expect(find.text('Verdict: needs_review'), findsOneWidget);
    expect(find.textContaining('capability_review_required'), findsOneWidget);
    expect(find.text('Manifest ID: com.example.safe-preview'), findsOneWidget);
    expect(find.text('Secret names: PRIVATE_TOKEN'), findsOneWidget);
    expect(find.text('Declared risk: high'), findsOneWidget);
    expect(find.text('Effective risk: critical'), findsOneWidget);
    expect(
      find.textContaining(
        'Filesystem access is unsupported on the current Android runtime',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Filesystem read unsupported/denied on Android: /root/workspace',
      ),
      findsOneWidget,
    );
    expect(find.text('Install with filesystem denied'), findsOneWidget);
    expect(find.textContaining('actual-secret-value'), findsNothing);
    expect(
      find.textContaining('does not approve individual tool calls'),
      findsOneWidget,
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('legacy preview is explicitly labeled unknown/critical risk',
      (tester) async {
    final legacy = SkillService.inspectPackage(
      stagingPath: '/tmp/legacy',
      sourceIdentity: 'Local: legacy',
      skillContent: '---\nname: legacy\n---',
      manifestContent: null,
    );

    await tester.pumpWidget(MaterialApp(
      home: SkillConsentDialog(candidate: legacy),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Legacy skill warning'), findsOneWidget);
    expect(find.textContaining('undeclared'), findsWidgets);
    expect(
      find.textContaining('unknown / conservative critical'),
      findsOneWidget,
    );
  });

  testWidgets('bounded inspection summary fits 320dp at 200 percent text',
      (tester) async {
    tester.view.physicalSize = const Size(640, 1280);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final candidate = SkillService.inspectPackage(
      stagingPath: '/tmp/safe-preview',
      sourceIdentity: 'Local: safe-preview',
      skillContent: '---\nname: safe-preview\n---',
      manifestContent: _manifest(),
    );

    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: const TextScaler.linear(2),
        ),
        child: child!,
      ),
      home: SkillConsentDialog(candidate: candidate),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Local inert import inspection'), findsOneWidget);
    expect(find.text('Verdict: needs_review'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('book posture keeps inspection consent outside the hinge',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const hinge = Rect.fromLTWH(390, 0, 20, 700);
    final candidate = SkillService.inspectPackage(
      stagingPath: '/tmp/safe-preview',
      sourceIdentity: 'Local: safe-preview',
      skillContent: '---\nname: safe-preview\n---',
      manifestContent: _manifest(),
    );

    await _pumpDialogRoute(
      tester,
      candidate,
      const MediaQueryData(
        size: Size(800, 700),
        textScaler: TextScaler.linear(2),
        displayFeatures: [
          DisplayFeature(
            bounds: hinge,
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.postureFlat,
          ),
        ],
      ),
    );

    expect(tester.getRect(find.byType(AlertDialog)).overlaps(hinge), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tabletop and IME keep inspection consent in the top region',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 760);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const fold = Rect.fromLTWH(0, 350, 400, 20);
    final candidate = SkillService.inspectPackage(
      stagingPath: '/tmp/safe-preview',
      sourceIdentity: 'Local: safe-preview',
      skillContent: '---\nname: safe-preview\n---',
      manifestContent: _manifest(),
    );

    await _pumpDialogRoute(
      tester,
      candidate,
      const MediaQueryData(
        size: Size(400, 760),
        textScaler: TextScaler.linear(2),
        viewInsets: EdgeInsets.only(bottom: 240),
        displayFeatures: [
          DisplayFeature(
            bounds: fold,
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ],
      ),
    );

    expect(tester.getRect(find.byType(AlertDialog)).bottom,
        lessThanOrEqualTo(fold.top));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpDialogRoute(
  WidgetTester tester,
  PreparedSkillImport candidate,
  MediaQueryData media,
) async {
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(data: media, child: child!),
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () => showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => SkillConsentDialog(candidate: candidate),
        ),
        child: const Text('Open'),
      ),
    ),
  ));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}
