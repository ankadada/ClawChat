import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/models/extension_manifest.dart';
import 'package:clawchat/models/update_models.dart';
import 'package:clawchat/services/skill_service.dart';
import 'package:clawchat/services/update_service.dart';
import 'package:clawchat/widgets/update_preview_dialog.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('extension preview shows verified identity and capability diff',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    late Directory temp;
    late UpdateService service;
    final plan = (await tester.runAsync<ExtensionUpdatePlan>(() async {
      temp = await Directory.systemTemp.createTemp('update_dialog_');
      final bytes = utf8.encode('extension archive');
      final archive = File('${temp.path}/update.zip')..writeAsBytesSync(bytes);
      final candidate = _candidate();
      service = UpdateService(
        signatureCheck: (_, __, ___, ____) async => true,
        tempDirectoryProvider: () async => temp,
        prepareLocalSkill: (_) async => candidate,
        discardPreparedSkill: (_) async {},
        installedSkillSnapshotReader: (_) async => InstalledSkillUpdateSnapshot(
          id: candidate.id,
          version: '1.0.0',
          trustDigest: 'b' * 64,
        ),
      );
      final check = await service.checkLocalMetadata(
        jsonEncode(_metadata(
          kind: 'extension',
          target: candidate.id,
          version: candidate.version,
          bytes: bytes,
          url: 'https://updates.example/extension.zip',
        )),
        expectedKind: UpdateArtifactKind.extension,
        expectedTargetId: candidate.id,
        currentVersion: '1.0.0',
        sourceIdentity: 'Local metadata: update.json',
      );
      return service.planExtensionUpdate(
        check,
        localArtifactPath: archive.path,
      );
    }))!;
    addTearDown(() => temp.delete(recursive: true));

    await tester.pumpWidget(MaterialApp(
      home: UpdatePreviewDialog.extension(plan: plan),
    ));
    await tester.pump();

    expect(find.text('Review extension update'), findsOneWidget);
    expect(find.text('Signature: SHA256withRSA verified'), findsOneWidget);
    expect(find.text('+ Command: curl'), findsOneWidget);
    expect(find.textContaining('local backup'), findsOneWidget);
    expect(find.text('Apply with backup'), findsOneWidget);
    unawaited(service.discardExtensionPlan(plan));
  });

  testWidgets('app preview requires explicit installer handoff confirmation',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    late Directory temp;
    late UpdateService service;
    final plan = (await tester.runAsync<AppUpdatePlan>(() async {
      temp = await Directory.systemTemp.createTemp('app_dialog_');
      final apk = utf8.encode('apk');
      service = UpdateService(
        httpClient: _OneResponseClient(
          http.StreamedResponse(Stream.value(apk), 200),
        ),
        signatureCheck: (_, __, ___, ____) async => true,
        tempDirectoryProvider: () async => temp,
      );
      final check = await service.checkLocalMetadata(
        jsonEncode(_metadata(
          kind: 'androidApp',
          target: AppConstants.packageName,
          version: '2.6.0',
          bytes: apk,
          url: 'https://updates.example/app.apk',
        )),
        expectedKind: UpdateArtifactKind.androidApp,
        expectedTargetId: AppConstants.packageName,
        currentVersion: AppConstants.version,
        sourceIdentity: 'Local metadata: app.json',
      );
      return service.planAppUpdate(check);
    }))!;
    addTearDown(() => temp.delete(recursive: true));
    bool? decision;

    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return TextButton(
          onPressed: () async {
            decision = await showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (_) => UpdatePreviewDialog.app(plan: plan),
            );
          },
          child: const Text('Open'),
        );
      }),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Verified Android app update'), findsOneWidget);
    expect(find.textContaining('cannot silently install'), findsOneWidget);
    expect(find.text('Open system installer'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(decision, isFalse);
    await tester.runAsync<void>(() => service.discardAppPlan(plan));
  });
}

PreparedSkillImport _candidate() {
  final oldManifest = ExtensionManifest.fromJson(_manifest('1.0.0', false));
  final grant = SkillTrustGrant(
    schemaVersion: 1,
    id: oldManifest.id,
    version: oldManifest.version,
    manifestDigest: 'b' * 64,
    contentDigest: 'c' * 64,
    snapshot: oldManifest.capabilities.snapshot,
    sourceIdentity: 'HTTPS: updates.example',
    legacy: false,
    grantedAt: DateTime.utc(2026).toIso8601String(),
  );
  return SkillService.inspectPackage(
    stagingPath: '/tmp/update-preview',
    sourceIdentity: 'HTTPS: updates.example',
    skillContent: 'updated',
    manifestContent: jsonEncode(_manifest('2.0.0', true)),
    previousGrant: grant,
  );
}

Map<String, dynamic> _manifest(String version, bool addCurl) => {
      'schemaVersion': 1,
      'id': 'com.example.demo',
      'name': 'Demo',
      'description': 'Demo update.',
      'model': {'name': 'demo', 'description': 'Demo.'},
      'version': version,
      'source': {'type': 'url', 'url': 'https://updates.example/update.json'},
      'integrity': <String, dynamic>{},
      'author': 'Example',
      'license': 'MIT',
      'capabilities': {
        'tools': <String>[],
        'commands': [if (addCurl) 'curl'],
        'networkDomains': <String>[],
        'filesystem': {'read': <String>[], 'write': <String>[]},
        'android': {'intents': <String>[], 'permissions': <String>[]},
        'secrets': <String>[],
        'subprocess': {'required': false, 'runtimes': <String>[]},
        'riskTier': addCurl ? 'moderate' : 'low',
        'updatePolicy': 'manual',
      },
    };

Map<String, dynamic> _metadata({
  required String kind,
  required String target,
  required String version,
  required List<int> bytes,
  required String url,
}) =>
    {
      'schemaVersion': 1,
      'kind': kind,
      'targetId': target,
      'version': version,
      'revision': 1,
      'artifactUrl': url,
      'artifactSha256': sha256.convert(bytes).toString(),
      'artifactSize': bytes.length,
      'signatureAlgorithm': 'SHA256withRSA',
      'keyId': 'a' * 64,
      'signature': base64Encode(const [1]),
    };

final class _OneResponseClient extends http.BaseClient {
  _OneResponseClient(this.response);
  final http.StreamedResponse response;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response;
}
