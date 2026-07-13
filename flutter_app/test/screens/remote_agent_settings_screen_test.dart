import 'dart:convert';

import 'package:clawchat/screens/remote_agent_settings_screen.dart';
import 'package:clawchat/models/remote_agent_connector.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/services/remote_agent_configuration_service.dart';
import 'package:clawchat/services/remote_agent_connector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('legacy Coze settings are stopped and require clean re-entry',
      (tester) async {
    final metadata = _MemoryStorage();
    final secrets = _MemoryStorage();
    final reference = RemoteAgentCredentialReference.parse(
      'cred_0123456789abcdefghijklmnopqrstuv',
    );
    final legacy = RemoteAgentConnectorConfig(
      kind: RemoteAgentConnectorKind.cozeOpenApi,
      id: 'primary_remote',
      displayName: 'Remote Agent',
      baseUrl: 'https://legacy.example/v3/chat',
      credentialReference: reference,
      remoteAgentId: 'legacy_agent',
      enabled: true,
    );
    metadata.values['remote_agent_connector_config_v1'] =
        jsonEncode(legacy.toJson());
    metadata.values['remote_agent_connector_consent_v1'] = jsonEncode(
      RemoteAgentConsent.grant(
        legacy,
        acceptedAt: DateTime.utc(2026, 7, 11),
      ).toJson(),
    );
    secrets.values['remote_agent_credential_${reference.value}'] =
        'legacy-secret';
    final service = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: secrets,
    );

    await tester.pumpWidget(
      Provider<RemoteAgentRuntimeBinding>.value(
        value: _runtime(service),
        child: const MaterialApp(home: RemoteAgentSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('OpenClaw Gateway'), findsOneWidget);
    expect(find.text('旧版连接器配置已停用'), findsOneWidget);
    expect(find.textContaining('2.5.0 中误加入的 Coze 配置'), findsOneWidget);
    expect(service.isReady, isFalse);
    final fields = tester.widgetList<TextFormField>(find.byType(TextFormField));
    expect(fields.elementAt(0).controller!.text, isEmpty);
    expect(fields.elementAt(1).controller!.text, 'default');
    expect(find.text('Gateway Token 或密码'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(find.text('移除凭据与配置'), findsOneWidget);
  });

  testWidgets('requires disclosure after secure configuration save',
      (tester) async {
    final metadata = _MemoryStorage();
    final secrets = _MemoryStorage();
    final service = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: secrets,
    );
    await tester.pumpWidget(
      Provider<RemoteAgentRuntimeBinding>.value(
        value: _runtime(service),
        child: const MaterialApp(home: RemoteAgentSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('OpenClaw Gateway'), findsOneWidget);
    expect(find.text('Coze OpenAPI'), findsNothing);
    expect(find.text('外部处理披露'), findsOneWidget);
    expect(find.textContaining('某个对话中明确选择'), findsOneWidget);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'https://agent.example');
    await tester.enterText(fields.at(1), 'agent_1');
    await tester.enterText(fields.at(2), 'secure-widget-value');
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();

    expect(service.isReady, isFalse);
    expect(metadata.values.toString(), isNot(contains('secure-widget-value')));
    expect(secrets.values.values, contains('secure-widget-value'));

    await tester.ensureVisible(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.ensureVisible(find.text('授权并启用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('授权并启用'));
    await tester.pumpAndSettle();

    expect(service.isReady, isTrue);
    expect(find.text('已授权并启用'), findsOneWidget);
  });

  testWidgets('load failure settles with retry and keeps errors sanitized',
      (tester) async {
    final metadata = _MemoryStorage()..readFailures = 1;
    final service = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: _MemoryStorage(),
    );
    await tester.pumpWidget(
      Provider<RemoteAgentRuntimeBinding>.value(
        value: _runtime(service),
        child: const MaterialApp(home: RemoteAgentSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('无法读取远程 Agent 设置'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.textContaining('无法读取远程 Agent 设置'), findsNothing);
    expect(find.text('保存配置'), findsOneWidget);
  });

  testWidgets('OpenClaw settings stay reachable at 320dp and 200% text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 620);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = RemoteAgentConfigurationService(
      metadataStorage: _MemoryStorage(),
      secretStorage: _MemoryStorage(),
    );

    await tester.pumpWidget(
      Provider<RemoteAgentRuntimeBinding>.value(
        value: _runtime(service),
        child: MaterialApp(
          builder: (context, child) {
            final data = MediaQuery.of(context);
            return MediaQuery(
              data: data.copyWith(
                textScaler: const TextScaler.linear(2),
                viewInsets: const EdgeInsets.only(bottom: 220),
              ),
              child: child!,
            );
          },
          home: const RemoteAgentSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('OpenClaw Gateway'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('保存配置'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('保存配置'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('外部处理披露'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('外部处理披露'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed disable settles and preserves enabled configuration',
      (tester) async {
    final metadata = _MemoryStorage();
    final secrets = _MemoryStorage();
    var failMutations = false;
    final service = RemoteAgentConfigurationService(
      metadataStorage: metadata,
      secretStorage: secrets,
      faultInjector: (step) {
        if (failMutations && step == RemoteAgentMutationStep.journalPrepared) {
          throw StateError('private mutation detail');
        }
      },
    );
    await service.saveConfiguration(
      kind: RemoteAgentConnectorKind.openClawGateway,
      connectorId: 'primary_remote',
      displayName: 'Remote Agent',
      baseUrl: 'https://agent.example/v1/chat/completions',
      remoteAgentId: 'agent_1',
      credential: 'secure-widget-value',
    );
    await service.grantConsentAndEnable(acceptedAt: DateTime.now());
    failMutations = true;
    await tester.pumpWidget(
      Provider<RemoteAgentRuntimeBinding>.value(
        value: _runtime(service),
        child: const MaterialApp(home: RemoteAgentSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('停用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('停用'));
    await tester.pumpAndSettle();
    expect(find.textContaining('当前配置未更改'), findsOneWidget);
    expect(service.isReady, isTrue);
    expect(find.text('停用'), findsOneWidget);
  });
}

RemoteAgentRuntimeBinding _runtime(
  RemoteAgentConfigurationService service,
) =>
    RemoteAgentRuntimeBinding(
      configuration: service,
      connector: _UnusedConnector(),
    );

final class _UnusedConnector implements RemoteAgentConnector {
  @override
  Stream<RemoteAgentEvent> send(
    RemoteAgentConnectorConfig config,
    RemoteAgentConsent? consent,
    RemoteAgentRequest request, {
    RemoteAgentCancellation? cancellation,
    bool Function()? authorizationGuard,
  }) =>
      const Stream.empty();
}

final class _MemoryStorage
    implements RemoteAgentMetadataStorage, RemoteAgentSecretStorage {
  final Map<String, String> values = {};
  int readFailures = 0;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async {
    if (readFailures > 0) {
      readFailures -= 1;
      throw StateError('private read detail');
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
