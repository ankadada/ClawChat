import 'dart:convert';

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
}
