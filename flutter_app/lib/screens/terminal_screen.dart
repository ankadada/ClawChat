import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/preferences_service.dart';
import '../services/terminal_runtime_session.dart';
import '../l10n/app_strings.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  static _TerminalScreenState? _inputOwner;
  final TerminalRuntimeSession _runtime = TerminalRuntimeSession.shared;
  late final Terminal _terminal;
  late final TerminalController _controller;
  StreamSubscription<void>? _runtimeSubscription;
  bool _loading = true;
  String? _error;
  final _ctrlNotifier = ValueNotifier<bool>(false);
  final _altNotifier = ValueNotifier<bool>(false);
  final _screenshotKey = GlobalKey();
  final _prefs = PreferencesService();
  double? _terminalFontSizeOverride;
  static final _anyUrlRegex = RegExp(r'https?://[^\s<>\[\]"' "'" r'\)]+');

  /// Box-drawing and other TUI characters that break URLs when copied
  static final _boxDrawing = RegExp(r'[│┤├┬┴┼╮╯╰╭─╌╴╶┌┐└┘◇◆]+');

  static const _fontFallback = [
    'monospace',
    'Noto Sans Mono',
    'Noto Sans Mono CJK SC',
    'Noto Sans Mono CJK TC',
    'Noto Sans Mono CJK JP',
    'Noto Color Emoji',
    'Noto Sans Symbols',
    'Noto Sans Symbols 2',
    'sans-serif',
  ];

  @override
  void initState() {
    super.initState();
    _terminal = _runtime.terminal;
    _controller = TerminalController();
    _loading = _runtime.loading || !_runtime.hasActiveProcess;
    _error = _runtime.error;
    _loadTerminalPreferences();
    _runtimeSubscription = _runtime.changes.listen((_) {
      if (!mounted) return;
      setState(() {
        _loading = _runtime.loading;
        _error = _runtime.error;
      });
    });
    _attachTerminalInput();
    // Defer PTY start until after the first frame so TerminalView has been
    // laid out and _terminal.viewWidth/viewHeight reflect real screen
    // dimensions instead of the 80×24 default.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startPty();
    });
  }

  void _attachTerminalInput() {
    _inputOwner = this;
    _terminal.onOutput = (data) {
      // Intercept keyboard input when CTRL/ALT toolbar modifiers are active.
      if (_ctrlNotifier.value && data.length == 1) {
        final code = data.toLowerCase().codeUnitAt(0);
        if (code >= 97 && code <= 122) {
          _runtime.write([code - 96]);
          _ctrlNotifier.value = false;
          return;
        }
      }
      if (_altNotifier.value && data.isNotEmpty) {
        _runtime.write(utf8.encode('\x1b$data'));
        _altNotifier.value = false;
        return;
      }
      _runtime.write(utf8.encode(data));
    };
    _terminal.onResize = (w, h, pw, ph) {
      _runtime.resize(h, w);
    };
  }

  Future<void> _loadTerminalPreferences() async {
    await _prefs.init();
    if (!mounted) return;
    setState(() => _terminalFontSizeOverride = _prefs.terminalFontSize);
  }

  double _adaptiveTerminalFontSize(double width) {
    if (width >= 920) return 16;
    if (width >= 700) return 14.5;
    return 13;
  }

  double _effectiveTerminalFontSize(double width) {
    return _terminalFontSizeOverride ?? _adaptiveTerminalFontSize(width);
  }

  Future<void> _startPty({bool restart = false}) async {
    if (restart) {
      await _runtime.restart(
        columns: _terminal.viewWidth,
        rows: _terminal.viewHeight,
      );
    } else {
      await _runtime.ensureStarted(
        columns: _terminal.viewWidth,
        rows: _terminal.viewHeight,
      );
    }
  }

  @override
  void dispose() {
    _runtimeSubscription?.cancel();
    if (identical(_inputOwner, this)) {
      _inputOwner = null;
      _terminal.onOutput = null;
      _terminal.onResize = null;
    }
    _ctrlNotifier.dispose();
    _altNotifier.dispose();
    _controller.dispose();
    super.dispose();
  }

  String? _getSelectedText() {
    final selection = _controller.selection;
    if (selection == null || selection.isCollapsed) return null;

    final range = selection.normalized;
    final sb = StringBuffer();
    for (int y = range.begin.y; y <= range.end.y; y++) {
      if (y >= _terminal.buffer.lines.length) break;
      final line = _terminal.buffer.lines[y];
      final from = (y == range.begin.y) ? range.begin.x : 0;
      final to = (y == range.end.y) ? range.end.x : null;
      sb.write(line.getText(from, to));
      if (y < range.end.y) sb.writeln();
    }
    final text = sb.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// Extract a clean URL from selected text by stripping box-drawing
  /// chars and rejoining lines, but splitting on `http` boundaries
  /// so concatenated URLs don't merge into one.
  String? _extractUrl(String text) {
    final clean =
        text.replaceAll(_boxDrawing, '').replaceAll(RegExp(r'\s+'), '');
    // Split before each http(s):// so concatenated URLs become separate
    final parts = clean.split(RegExp(r'(?=https?://)'));
    // Return the longest URL match (token URLs are longest)
    String? best;
    for (final part in parts) {
      final match = _anyUrlRegex.firstMatch(part);
      if (match != null) {
        final url = match.group(0)!;
        if (best == null || url.length > best.length) {
          best = url;
        }
      }
    }
    return best;
  }

  void _copySelection() {
    final text = _getSelectedText();
    if (text == null) return;

    Clipboard.setData(ClipboardData(text: text));

    // If the copied text contains a URL, offer "Open" action
    final url = _extractUrl(text);
    if (url != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(AppStrings.copiedToClipboard),
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: AppStrings.open,
            onPressed: () {
              final uri = Uri.tryParse(url);
              if (uri != null) {
                launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(AppStrings.copiedToClipboard),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  void _openSelection() {
    final text = _getSelectedText();
    if (text == null) return;

    final url = _extractUrl(text);
    if (url != null) {
      final uri = Uri.tryParse(url);
      if (uri != null) {
        launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(AppStrings.noUrlFound),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      _runtime.write(utf8.encode(data.text!));
    }
  }

  Future<void> _takeScreenshot() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text(AppStrings.screenshotUnavailable)),
    );
  }

  /// Detect URLs in terminal at tap position. Joins adjacent lines
  /// and strips box-drawing chars to handle wrapped URLs.
  void _handleTap(TapUpDetails details, CellOffset offset) {
    final totalLines = _terminal.buffer.lines.length;
    final scrollbackOffset =
        _terminal.buffer.cursorY - _terminal.viewHeight + 1;
    final absoluteY = offset.y + scrollbackOffset;
    final startRow = (absoluteY - 2).clamp(0, totalLines - 1);
    final endRow = (absoluteY + 2).clamp(0, totalLines - 1);

    final sb = StringBuffer();
    for (int row = startRow; row <= endRow; row++) {
      sb.write(_getLineText(row).trimRight());
    }
    final url = _extractUrl(sb.toString());
    if (url != null) {
      _openUrl(url);
    }
  }

  String _getLineText(int row) {
    try {
      final line = _terminal.buffer.lines[row];
      final sb = StringBuffer();
      for (int i = 0; i < line.length; i++) {
        final char = line.getCodePoint(i);
        if (char != 0) {
          sb.writeCharCode(char);
        }
      }
      return sb.toString();
    } catch (_) {
      return '';
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    final shouldOpen = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(AppStrings.openLink),
        content: Text(url),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(AppStrings.cancel),
          ),
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: url));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(AppStrings.linkCopied),
                  duration: Duration(seconds: 1),
                ),
              );
              Navigator.pop(ctx, false);
            },
            child: const Text(AppStrings.copy),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(AppStrings.open),
          ),
        ],
      ),
    );

    if (shouldOpen == true) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.terminalTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.camera_alt_outlined),
            tooltip: AppStrings.screenshot,
            onPressed: _takeScreenshot,
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: AppStrings.copy,
            onPressed: _copySelection,
          ),
          IconButton(
            icon: const Icon(Icons.open_in_browser),
            tooltip: AppStrings.openUrl,
            onPressed: _openSelection,
          ),
          IconButton(
            icon: const Icon(Icons.paste),
            tooltip: AppStrings.paste,
            onPressed: _paste,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: AppStrings.restart,
            onPressed: () {
              setState(() {
                _loading = true;
                _error = null;
              });
              _startPty(restart: true);
            },
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text(AppStrings.startingTerminal),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  setState(() {
                    _loading = true;
                    _error = null;
                  });
                  _startPty();
                },
                icon: const Icon(Icons.refresh),
                label: const Text(AppStrings.retry),
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final terminalFontSize =
            _effectiveTerminalFontSize(constraints.maxWidth);
        return Column(
          children: [
            Expanded(
              child: RepaintBoundary(
                key: _screenshotKey,
                child: TerminalView(
                  _terminal,
                  controller: _controller,
                  textStyle: TerminalStyle(
                    fontSize: terminalFontSize,
                    height: 1.15,
                    fontFamily: 'DejaVuSansMono',
                    fontFamilyFallback: _fontFallback,
                  ),
                  onTapUp: _handleTap,
                ),
              ),
            ),
            _buildSimpleToolbar(),
          ],
        );
      },
    );
  }

  Future<void> _showFontSizeSheet() async {
    await _prefs.init();
    if (!mounted) return;
    final width = MediaQuery.sizeOf(context).width;
    var selectedSize = _effectiveTerminalFontSize(width);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setSheetState) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppStrings.terminalFontSize,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(Icons.format_size),
                        Expanded(
                          child: Slider(
                            min: 12,
                            max: 18,
                            divisions: 12,
                            value: selectedSize,
                            label: selectedSize.toStringAsFixed(1),
                            onChanged: (value) {
                              setSheetState(() => selectedSize = value);
                              setState(() => _terminalFontSizeOverride = value);
                              _prefs.terminalFontSize = value;
                            },
                          ),
                        ),
                        SizedBox(
                          width: 44,
                          child: Text(
                            selectedSize.toStringAsFixed(1),
                            textAlign: TextAlign.end,
                          ),
                        ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () {
                          final autoSize = _adaptiveTerminalFontSize(width);
                          setSheetState(() => selectedSize = autoSize);
                          setState(() => _terminalFontSizeOverride = null);
                          _prefs.terminalFontSize = null;
                        },
                        child: const Text(AppStrings.terminalFontAuto),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildSimpleToolbar() {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top: BorderSide(
                color: Theme.of(context).colorScheme.outline.withAlpha(50)),
          ),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _toolbarIconButton(
                icon: Icons.keyboard_tab,
                tooltip: 'Tab',
                onTap: () => _runtime.write(utf8.encode('\t')),
              ),
              _toolbarIconButton(
                icon: Icons.keyboard,
                tooltip: 'Esc',
                onTap: () => _runtime.write(utf8.encode('\x1b')),
              ),
              _toolbarDivider(),
              _toolbarToggleButton(
                label: 'Ctrl',
                notifier: _ctrlNotifier,
              ),
              _toolbarToggleButton(
                label: 'Alt',
                notifier: _altNotifier,
              ),
              _toolbarIconButton(
                icon: Icons.format_size,
                tooltip: AppStrings.terminalFontSize,
                onTap: _showFontSizeSheet,
              ),
              _toolbarDivider(),
              _toolbarIconButton(
                icon: Icons.keyboard_arrow_up,
                tooltip: 'Up',
                onTap: () => _runtime.write(utf8.encode('\x1b[A')),
              ),
              _toolbarIconButton(
                icon: Icons.keyboard_arrow_down,
                tooltip: 'Down',
                onTap: () => _runtime.write(utf8.encode('\x1b[B')),
              ),
              _toolbarIconButton(
                icon: Icons.keyboard_arrow_left,
                tooltip: 'Left',
                onTap: () => _runtime.write(utf8.encode('\x1b[D')),
              ),
              _toolbarIconButton(
                icon: Icons.keyboard_arrow_right,
                tooltip: 'Right',
                onTap: () => _runtime.write(utf8.encode('\x1b[C')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbarIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: IconButton(
        icon: Icon(icon, size: 20),
        tooltip: tooltip,
        onPressed: onTap,
        style: IconButton.styleFrom(
          minimumSize: const Size(44, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  Widget _toolbarToggleButton({
    required String label,
    required ValueNotifier<bool> notifier,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: ValueListenableBuilder<bool>(
        valueListenable: notifier,
        builder: (context, active, _) {
          return Tooltip(
            message: label,
            child: SizedBox(
              height: 44,
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  backgroundColor: active
                      ? Theme.of(context).colorScheme.primaryContainer
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  foregroundColor: active
                      ? Theme.of(context).colorScheme.onPrimaryContainer
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: () => notifier.value = !notifier.value,
                child: Text(label, style: const TextStyle(fontSize: 13)),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _toolbarDivider() {
    return Container(
      width: 1,
      height: 28,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: Theme.of(context).colorScheme.outline.withAlpha(80),
    );
  }
}
