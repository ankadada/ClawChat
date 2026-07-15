import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/screens/settings_screen.dart';
import 'package:clawchat/services/update_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('visible app update cancel never reaches installer preview',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final temp = (await tester.runAsync<Directory>(
      () => Directory.systemTemp.createTemp('settings_update_cancel_'),
    ))!;
    addTearDown(() => temp.delete(recursive: true));
    const artifact = [1, 2, 3];
    final metadata = utf8.encode(jsonEncode({
      'schemaVersion': 1,
      'kind': 'androidApp',
      'targetId': AppConstants.packageName,
      'version': '2.7.0',
      'revision': 1,
      'artifactUrl': 'https://updates.example/app.apk',
      'artifactSha256': sha256.convert(artifact).toString(),
      'artifactSize': artifact.length,
      'signatureAlgorithm': 'SHA256withRSA',
      'keyId': 'a' * 64,
      'signature': base64Encode(const [1]),
    }));
    final stalled = StreamController<List<int>>();
    final service = UpdateService(
      httpClient: _QueueClient([
        http.StreamedResponse(Stream.value(metadata), 200),
        http.StreamedResponse(stalled.stream, 200),
      ]),
      signatureCheck: (_, __, ___, ____) async => true,
      tempDirectoryProvider: () async => temp,
    );

    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(
        skipInitialLoadForTesting: true,
        importFlowOnlyForTesting: true,
        updateService: service,
      ),
    ));
    await tester.tap(find.byTooltip('Check signed app update'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://updates.example/app.json',
    );
    await tester.tap(find.text('Check'));
    await tester.pump();
    expect(find.text('Secure staged update'), findsOneWidget);
    await tester.tap(find.text('Cancel update'));
    expect(find.text('Verified Android app update'), findsNothing);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    unawaited(stalled.close());
    await tester.pump();
  });
}

final class _QueueClient extends http.BaseClient {
  _QueueClient(this.responses);
  final List<http.StreamedResponse> responses;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      responses.removeAt(0);
}
