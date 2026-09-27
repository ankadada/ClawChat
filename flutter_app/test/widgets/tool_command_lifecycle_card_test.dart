import 'package:clawchat/constants.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:clawchat/widgets/tool_call_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The card looks up `ChatProvider?`, so the stub must be provided as the
/// `ChatProvider` type, not as the subclass.
class _StubChatProvider extends ChatProvider {
  _StubChatProvider({
    required super.storage,
    required AgentStatus status,
    AgentRunRecoveryMarker? interruptedRun,
  })  : _status = status,
        _interruptedRun = interruptedRun;

  final AgentStatus _status;
  final AgentRunRecoveryMarker? _interruptedRun;

  @override
  AgentStatus get agentStatus => _status;

  @override
  AgentRunRecoveryMarker? get currentInterruptedAgentRun => _interruptedRun;
}

class _MemoryStorage extends SessionStorage {
  @override
  Future<void> init() async {}

  @override
  Future<List<SessionSummary>> getSessionsSummary() async => const [];

  @override
  Future<ChatSession?> getSession(String id) async => null;
}

ToolUseContent _bashTool(String id) => ToolUseContent(
      id: id,
      name: 'bash',
      input: const {'command': 'echo ok'},
    );

AgentRunRecoveryMarker _interruptedBashMarker() {
  final at = DateTime.utc(2026, 9, 23, 7);
  return AgentRunRecoveryMarker(
    runAttemptId: 'run-1',
    startedAt: at,
    updatedAt: at,
    toolAttempts: [
      ToolAttemptRecoveryMetadata(
        operationId: 'op-1',
        toolName: 'bash',
        risk: RecoveryToolRisk.safe,
        lifecycle: ToolAttemptLifecycle.interruptedUnknown,
        proposedAt: at,
        updatedAt: at,
        executionStartedAt: at,
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ChatProvider? provider;
  const native = MethodChannel(AppConstants.channelName);
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(native, (call) async {
      if (call.method == 'consumePendingNavigateToSession') return null;
      return true;
    });
    messenger.setMockMethodCallHandler(secure, (call) async {
      if (call.method == 'readAll') return <String, String>{};
      if (call.method == 'containsKey') return false;
      return null;
    });
    ToolCallCard.clearExpansionState();
  });

  tearDown(() async {
    provider?.dispose();
    provider = null;
    PreferencesService.resetForTesting();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(secure, null);
  });

  Future<void> pumpCard(
    WidgetTester tester, {
    required ToolUseContent toolUse,
    String? output,
    AgentStatus status = AgentStatus.idle,
    AgentRunRecoveryMarker? interruptedRun,
  }) async {
    provider = _StubChatProvider(
      storage: _MemoryStorage(),
      status: status,
      interruptedRun: interruptedRun,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider!,
        child: MaterialApp(
          home: Scaffold(
            body: ToolCallCard(toolUse: toolUse, toolOutput: output),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a bash attempt with no result shows started', (tester) async {
    await pumpCard(tester, toolUse: _bashTool('t-started'));
    expect(find.text('已发起'), findsOneWidget);
  });

  testWidgets('a bash attempt with a result shows completed', (tester) async {
    await pumpCard(tester, toolUse: _bashTool('t-done'), output: 'ok\n');
    expect(find.text('已完成'), findsOneWidget);
  });

  testWidgets('a cancelled bash result shows cancelled', (tester) async {
    await pumpCard(
      tester,
      toolUse: _bashTool('t-cancelled'),
      output: 'Tool execution cancelled',
    );
    expect(find.text('已取消'), findsOneWidget);
    expect(find.text('已完成'), findsNothing);
  });

  testWidgets('a live tool run shows running', (tester) async {
    await pumpCard(
      tester,
      toolUse: _bashTool('t-running'),
      status: AgentStatus.tooling,
    );
    expect(find.text('运行中'), findsOneWidget);
  });

  testWidgets(
      'an interrupted run shows interrupted-unknown and no silent retry',
      (tester) async {
    await pumpCard(
      tester,
      toolUse: _bashTool('t-interrupted'),
      interruptedRun: _interruptedBashMarker(),
    );
    expect(find.text('结果未知'), findsOneWidget);

    await tester.tap(find.text('echo ok'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('没有完成'), findsOneWidget);
    expect(find.textContaining('不会静默重试'), findsOneWidget);
  });

  testWidgets('a non-bash card never shows a command lifecycle label',
      (tester) async {
    await pumpCard(
      tester,
      toolUse: ToolUseContent(
        id: 't-read',
        name: 'read_file',
        input: const {'path': '/root/workspace/a.txt'},
      ),
      output: 'hello',
    );
    expect(find.text('已完成'), findsNothing);
    expect(find.text('已发起'), findsNothing);
  });
}
