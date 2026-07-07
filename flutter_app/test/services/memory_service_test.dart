import 'dart:convert';

import 'package:clawchat/constants.dart';
import 'package:clawchat/services/memory_service.dart';
import 'package:clawchat/services/tools/memory_tools.dart';
import 'package:clawchat/services/tools/tool_registry.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConstants.channelName);
  late Map<String, String> files;

  setUp(() {
    files = {};
    MemoryService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'readRootfsFile':
          return files[args['path']?.toString()];
        case 'writeRootfsFile':
          files[args['path']?.toString() ?? ''] =
              args['content']?.toString() ?? '';
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    MemoryService.resetForTesting();
  });

  test('memory tools write, read, delete, and audit changes', () async {
    MemoryService.setCurrentSessionId('session-1');

    final write = jsonDecode(
      await MemoryWriteTool().execute({'fact': 'prefers concise answers'}),
    ) as Map<String, dynamic>;
    final read =
        jsonDecode(await MemoryGetTool().execute({})) as Map<String, dynamic>;
    final del = jsonDecode(await MemoryDeleteTool().execute({'index': 0}))
        as Map<String, dynamic>;

    expect(write['ok'], isTrue);
    expect(read['memories'], ['prefers concise answers']);
    expect(del['deleted'], isTrue);
    expect(
        files['root/.clawchat_memory_audit.jsonl'], contains('memory_write'));
    expect(
        files['root/.clawchat_memory_audit.jsonl'], contains('memory_delete'));
  });

  test('limits entries and truncates oversized facts', () async {
    MemoryService.setCurrentSessionId('session-1');
    final longFact = 'x' * (MemoryService.maxMemoryChars + 50);

    final first = await MemoryService.addMemory(longFact);
    for (var i = 0; i < MemoryService.maxMemoryEntries + 5; i++) {
      await MemoryService.addMemory('fact $i');
    }
    final memories = await MemoryService.getMemories();

    expect(first.truncated, isTrue);
    expect(memories.length, MemoryService.maxMemoryEntries);
    expect(memories.last, 'fact ${MemoryService.maxMemoryEntries + 4}');
  });

  test('session disable hides memory tools and disables execution', () async {
    MemoryService.setCurrentSessionId('session-1');
    await MemoryService.setSessionMemoryMode(
      'session-1',
      SessionMemoryMode.disabled,
    );
    final registry = ToolRegistry.withDefaults();

    expect(registry.availableTools, isNot(contains('memory_get')));
    final result =
        jsonDecode(await MemoryGetTool().execute({})) as Map<String, dynamic>;
    expect(result['ok'], isFalse);
    expect(result['error'], 'memory_disabled');
  });
}
