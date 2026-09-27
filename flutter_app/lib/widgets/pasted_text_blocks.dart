import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_strings.dart';

/// Long pastes kept out of the composer text.
///
/// A paste longer than [maxCharacters] or [maxLines] becomes a short
/// `[Pasted#N]` token in the composer, while the full text is kept here in
/// insertion order. Sending expands every token back to its full text, so the
/// model receives the pasted content in order.
class PastedTextBlocks extends ChangeNotifier {
  static const int maxCharacters = 800;
  static const int maxLines = 20;

  final Map<int, String> _blocks = <int, String>{};
  int _nextId = 1;

  Map<int, String> get blocks => Map.unmodifiable(_blocks);

  List<int> get ids => _blocks.keys.toList(growable: false);

  bool get isEmpty => _blocks.isEmpty;

  int get length => _blocks.length;

  /// Whether [text] is long enough to become a chip instead of inline text.
  static bool isLongPaste(String text) {
    if (text.length > maxCharacters) return true;
    return '\n'.allMatches(text).length + 1 > maxLines;
  }

  /// The composer token for [id].
  static String tokenFor(int id) => '[Pasted#$id]';

  static final RegExp _tokenPattern = RegExp(r'\[Pasted#(\d+)\]');

  /// Ids referenced by a composer text, in order.
  static List<int> referencedIds(String text) => _tokenPattern
      .allMatches(text)
      .map((match) => int.parse(match.group(1)!))
      .toList(growable: false);

  int add(String text) {
    final id = _nextId++;
    _blocks[id] = text;
    notifyListeners();
    return id;
  }

  void remove(int id) {
    if (_blocks.remove(id) != null) notifyListeners();
  }

  /// Drop blocks whose token is no longer in the composer text.
  void retainReferenced(String text) {
    final referenced = referencedIds(text).toSet();
    final stale = _blocks.keys.where((id) => !referenced.contains(id)).toList();
    if (stale.isEmpty) return;
    for (final id in stale) {
      _blocks.remove(id);
    }
    notifyListeners();
  }

  void clear() {
    if (_blocks.isEmpty) return;
    _blocks.clear();
    notifyListeners();
  }

  /// Replace every token in [text] with its full pasted text, in order.
  String expand(String text) {
    if (_blocks.isEmpty) return text;
    return text.replaceAllMapped(_tokenPattern, (match) {
      final id = int.parse(match.group(1)!);
      return _blocks[id] ?? match.group(0)!;
    });
  }
}

/// The chip row above the composer. Tapping a chip shows the full pasted text
/// and offers removal.
class PastedTextChipRow extends StatelessWidget {
  const PastedTextChipRow({
    super.key,
    required this.blocks,
    required this.onRemove,
  });

  final PastedTextBlocks blocks;
  final void Function(int id) onRemove;

  Future<void> _showFullText(BuildContext context, int id) async {
    final text = blocks.blocks[id];
    if (text == null) return;
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${AppStrings.pastedTextChipTitle} ${PastedTextBlocks.tokenFor(id)}'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 380),
          child: SingleChildScrollView(
            child: SelectableText(text),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text(AppStrings.close),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(AppStrings.pastedTextRemove),
          ),
        ],
      ),
    );
    if (remove == true) onRemove(id);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: blocks,
      builder: (context, _) {
        if (blocks.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final id in blocks.ids)
                ActionChip(
                  key: ValueKey('pasted-chip-$id'),
                  avatar: const Icon(Icons.content_paste, size: 16),
                  label: Text(PastedTextBlocks.tokenFor(id)),
                  tooltip: AppStrings.pastedTextChipTitle,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  onPressed: () => _showFullText(context, id),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Routes Ctrl/Cmd+V in the composer through [onPaste] so a long paste can
/// become a chip instead of a wall of text. Short pastes are inserted by the
/// same handler, so normal paste still works.
class ComposerPasteShortcuts extends StatelessWidget {
  const ComposerPasteShortcuts({
    super.key,
    required this.onPaste,
    required this.child,
  });

  final VoidCallback onPaste;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyV, control: true):
            _ComposerPasteIntent(),
        SingleActivator(LogicalKeyboardKey.keyV, meta: true):
            _ComposerPasteIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _ComposerPasteIntent: CallbackAction<_ComposerPasteIntent>(
            onInvoke: (_) {
              onPaste();
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }
}

class _ComposerPasteIntent extends Intent {
  const _ComposerPasteIntent();
}

/// Marks the composer text field for the app-shell shortcuts: the composer may
/// keep Ctrl/Cmd+N, any other editable field blocks the shell shortcut.
class ComposerFieldMarker extends InheritedWidget {
  const ComposerFieldMarker({super.key, required super.child});

  static bool contains(BuildContext context) =>
      context.findAncestorWidgetOfExactType<ComposerFieldMarker>() != null;

  @override
  bool updateShouldNotify(ComposerFieldMarker oldWidget) => false;
}
