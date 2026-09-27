import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pasted_text_blocks.dart';

/// Hardware shortcut intents handled at the app shell.
class NewChatIntent extends Intent {
  const NewChatIntent();
}

class FocusSessionSearchIntent extends Intent {
  const FocusSessionSearchIntent();
}

/// Targets the app shell cannot reach directly because they live inside a
/// screen (for example the session search sheet).
class AppShortcutTargets {
  AppShortcutTargets._();

  static VoidCallback? openSessionSearch;

  /// Clears the screen-owned target when that screen goes away.
  static void clearSessionSearch(VoidCallback target) {
    if (identical(openSessionSearch, target)) openSessionSearch = null;
  }

  static void resetForTesting() {
    openSessionSearch = null;
  }
}

/// App-shell wiring for the hardware shortcuts.
///
/// Wrapped around the whole app (in `MaterialApp.builder`) so the keys work on
/// every route, not only inside one screen. The shortcut is not consumed while
/// another editable text field has focus; the composer is the one exception and
/// may keep Ctrl/Cmd+N.
class AppHardwareShortcuts extends StatelessWidget {
  const AppHardwareShortcuts({
    super.key,
    required this.child,
    this.onNewChat,
    this.onFocusSessionSearch,
  });

  final Widget child;
  final VoidCallback? onNewChat;
  final VoidCallback? onFocusSessionSearch;

  /// True when the focused editable field is not the chat composer, so the
  /// shell must not steal Ctrl/Cmd+N or Ctrl/Cmd+F from it.
  static bool isBlockedByEditableFocus() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    if (focusContext.findAncestorWidgetOfExactType<EditableText>() == null) {
      return false;
    }
    return !ComposerFieldMarker.contains(focusContext);
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyN, control: true):
            NewChatIntent(),
        SingleActivator(LogicalKeyboardKey.keyN, meta: true): NewChatIntent(),
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            FocusSessionSearchIntent(),
        SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            FocusSessionSearchIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          NewChatIntent: _ShellShortcutAction<NewChatIntent>(
            isAvailable: () => onNewChat != null,
            onInvoke: () => onNewChat?.call(),
          ),
          FocusSessionSearchIntent:
              _ShellShortcutAction<FocusSessionSearchIntent>(
            isAvailable: () => onFocusSessionSearch != null,
            onInvoke: () => onFocusSessionSearch?.call(),
          ),
        },
        child: child,
      ),
    );
  }
}

class _ShellShortcutAction<T extends Intent> extends Action<T> {
  _ShellShortcutAction({required this.isAvailable, required this.onInvoke});

  final bool Function() isAvailable;
  final VoidCallback onInvoke;

  @override
  bool isEnabled(T intent) =>
      isAvailable() && !AppHardwareShortcuts.isBlockedByEditableFocus();

  @override
  void invoke(T intent, [BuildContext? context]) => onInvoke();
}
