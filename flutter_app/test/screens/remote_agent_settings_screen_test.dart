import 'package:clawchat/screens/remote_agent_settings_screen.dart';
import 'package:clawchat/models/remote_agent_connector.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/services/remote_agent_configuration_service.dart';
import 'package:clawchat/services/remote_agent_connector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
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

    expect(find.text('外部处理披露'), findsOneWidget);
    expect(find.textContaining('某个对话中明确选择'), findsOneWidget);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'https://agent.example/v3/chat');
    await tester.enterText(fields.at(1), 'agent_1');
    await tester.enterText(fields.at(2), 'secure-widget-value');
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();

    expect(service.isReady, isFalse);
    expect(metadata.values.toString(), isNot(contains('secure-widget-value')));
    expect(secrets.values.values, contains('secure-widget-value'));

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
      kind: RemoteAgentConnectorKind.cozeOpenApi,
      connectorId: 'primary_remote',
      displayName: 'Remote Agent',
      baseUrl: 'https://agent.example/v3/chat',
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
