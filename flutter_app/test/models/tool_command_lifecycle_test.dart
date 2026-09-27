import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/tool_command_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _assistantWithBash(String id) => ChatMessage(
      role: 'assistant',
      content: [
        ToolUseContent(
            id: id, name: 'bash', input: const {'command': 'echo ok'}),
      ],
    );

ChatMessage _resultFor(String id, String output, {bool isError = false}) =>
    ChatMessage.toolResults([
      {
        'tool_use_id': id,
        'output': output,
        'is_error': isError,
      },
    ]);

void main() {
  group('classifyBashToolAttempt', () {
    test('no result and no live signal is started', () {
      expect(
        classifyBashToolAttempt(
          hasResult: false,
          runningNow: false,
          interruptedUnknown: false,
        ),
        ToolCommandLifecycle.started,
      );
    });

    test('no result while the agent is running a tool is running', () {
      expect(
        classifyBashToolAttempt(
          hasResult: false,
          runningNow: true,
          interruptedUnknown: false,
        ),
        ToolCommandLifecycle.running,
      );
    });

    test('a result is completed even when the command failed', () {
      expect(
        classifyBashToolAttempt(
          hasResult: true,
          runningNow: false,
          interruptedUnknown: false,
          resultOutput: 'Error: Command failed (exit code 1)',
        ),
        ToolCommandLifecycle.completed,
      );
    });

    test('the known cancellation result is cancelled, not completed', () {
      expect(
        classifyBashToolAttempt(
          hasResult: true,
          runningNow: false,
          interruptedUnknown: false,
          resultOutput: cancelledCommandOutput,
        ),
        ToolCommandLifecycle.cancelled,
      );
    });

    test('a structured cancelled status is cancelled', () {
      expect(
        classifyBashToolAttempt(
          hasResult: true,
          runningNow: false,
          interruptedUnknown: false,
          resultOutput: '{"status":"cancelled"}',
        ),
        ToolCommandLifecycle.cancelled,
      );
    });

    test('an interrupted run without a result is interrupted-unknown', () {
      expect(
        classifyBashToolAttempt(
          hasResult: false,
          runningNow: false,
          interruptedUnknown: true,
        ),
        ToolCommandLifecycle.interruptedUnknown,
      );
    });

    test('a cancelled result wins over an interrupted run flag', () {
      expect(
        classifyBashToolAttempt(
          hasResult: true,
          runningNow: false,
          interruptedUnknown: true,
          resultOutput: cancelledCommandOutput,
        ),
        ToolCommandLifecycle.cancelled,
      );
    });
  });

  group('lifecycle copy', () {
    test('interrupted copy says the command did not finish and is not retried',
        () {
      expect(
        ToolCommandLifecycle.interruptedUnknown.detail,
        contains('没有完成'),
      );
      expect(
        ToolCommandLifecycle.interruptedUnknown.detail,
        contains('不会静默重试'),
      );
      expect(ToolCommandLifecycle.interruptedUnknown.label, '结果未知');
    });

    test('terminal states never return to a live state', () {
      expect(ToolCommandLifecycle.started.isTerminal, isFalse);
      expect(ToolCommandLifecycle.running.isTerminal, isFalse);
      expect(ToolCommandLifecycle.completed.isTerminal, isTrue);
      expect(ToolCommandLifecycle.cancelled.isTerminal, isTrue);
      expect(ToolCommandLifecycle.interruptedUnknown.isTerminal, isTrue);
    });
  });

  group('classifyLastCommand', () {
    test('no messages is none', () {
      expect(
        classifyLastCommand(
          messages: const [],
          runningNow: false,
          interruptedUnknown: false,
        ),
        MachineLastCommand.none,
      );
    });

    test('a finished command is exited', () {
      final messages = <ChatMessage>[
        _assistantWithBash('t1'),
        _resultFor('t1', 'ok\n'),
      ];
      expect(
        classifyLastCommand(
          messages: messages,
          runningNow: false,
          interruptedUnknown: false,
        ),
        MachineLastCommand.exited,
      );
    });

    test('a pending command while tooling is running', () {
      final messages = <ChatMessage>[_assistantWithBash('t1')];
      expect(
        classifyLastCommand(
          messages: messages,
          runningNow: true,
          interruptedUnknown: false,
        ),
        MachineLastCommand.running,
      );
    });

    test('a cancelled last command is unknown', () {
      final messages = <ChatMessage>[
        _assistantWithBash('t1'),
        _resultFor('t1', cancelledCommandOutput, isError: true),
      ];
      expect(
        classifyLastCommand(
          messages: messages,
          runningNow: false,
          interruptedUnknown: false,
        ),
        MachineLastCommand.unknown,
      );
    });

    test('an interrupted last command is unknown', () {
      final messages = <ChatMessage>[_assistantWithBash('t1')];
      expect(
        classifyLastCommand(
          messages: messages,
          runningNow: false,
          interruptedUnknown: true,
        ),
        MachineLastCommand.unknown,
      );
    });

    test('the newest bash attempt wins over an older finished one', () {
      final messages = <ChatMessage>[
        _assistantWithBash('t1'),
        _resultFor('t1', 'ok\n'),
        _assistantWithBash('t2'),
      ];
      expect(
        classifyLastCommand(
          messages: messages,
          runningNow: true,
          interruptedUnknown: false,
        ),
        MachineLastCommand.running,
      );
    });
  });
}
