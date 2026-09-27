import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app.dart';
import '../models/chat_models.dart';
import '../models/tool_command_lifecycle.dart';
import '../providers/chat_provider.dart';
import '../services/native_bridge.dart';
import '../services/tool_call_expansion_state.dart';
import '../services/tool_result_images.dart';
import 'code_block.dart';
import '../l10n/app_strings.dart';

export '../services/tool_result_images.dart'
    show ToolResultImage, ToolResultImageKind, extractToolResultImages;

class ToolCallCard extends StatefulWidget {
  final ToolUseContent toolUse;
  final String? toolOutput;

  const ToolCallCard({
    super.key,
    required this.toolUse,
    this.toolOutput,
  });

  static void clearExpansionState() => ToolCallExpansionState.clear();

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool get _expanded => ToolCallExpansionState.isExpanded(widget.toolUse.id);

  static const _permissionErrors = {
    'permission_required',
    'permission_permanently_denied',
  };

  /// True when this result is a denied runtime permission (including a
  /// permanent denial), so the card can offer a one-tap path to the OS App
  /// details screen.
  bool get _needsPermissionFix {
    final output = widget.toolOutput;
    if (output == null || output.isEmpty) return false;
    try {
      final decoded = jsonDecode(output);
      return decoded is Map && _permissionErrors.contains(decoded['error']);
    } catch (_) {
      return output.contains('"error":"permission_required"') ||
          output.contains('"error": "permission_required"') ||
          output.contains('"error":"permission_permanently_denied"') ||
          output.contains('"error": "permission_permanently_denied"');
    }
  }

  Future<void> _openAppPermissionSettings() async {
    // Never throws: a missing handler leaves the text path in place.
    await NativeBridge.openAppDetailsSettings();
  }

  void _toggleExpanded() {
    setState(() {
      ToolCallExpansionState.setExpanded(widget.toolUse.id, !_expanded);
    });
  }

  IconData _getToolIcon() {
    switch (widget.toolUse.name) {
      case 'bash':
        return Icons.terminal;
      case 'read_file':
        return Icons.description;
      case 'write_file':
        return Icons.edit_document;
      case 'web_fetch':
        return Icons.language;
      case 'web_search':
        return Icons.travel_explore;
      default:
        return Icons.build;
    }
  }

  String _getToolLabel() {
    switch (widget.toolUse.name) {
      case 'bash':
        return widget.toolUse.input['command'] as String? ?? 'Shell';
      case 'read_file':
        return widget.toolUse.input['path'] as String? ?? AppStrings.readFile;
      case 'write_file':
        return widget.toolUse.input['path'] as String? ?? AppStrings.writeFile;
      case 'web_fetch':
        return widget.toolUse.input['url'] as String? ?? AppStrings.webRequest;
      case 'web_search':
        return widget.toolUse.input['query'] as String? ?? widget.toolUse.name;
      default:
        return widget.toolUse.name;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isExecuting = widget.toolUse.isExecuting;
    final isError = widget.toolUse.isError;
    final hasOutput = widget.toolOutput != null;
    final isPending = isExecuting || (!isError && !hasOutput);
    final statusColor = isError
        ? theme.colorScheme.error
        : isPending
            ? AppColors.statusAmber
            : AppColors.statusGreen;
    final commandLifecycle =
        widget.toolUse.name == bashToolName ? _commandLifecycle(context) : null;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.s),
        border: isError
            ? Border.all(color: theme.colorScheme.error.withAlpha(110))
            : null,
        color: isError
            ? theme.colorScheme.errorContainer.withAlpha(60)
            : theme.colorScheme.surfaceContainerHighest.withAlpha(80),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.s),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: _PulsingToolBorder(
                color: statusColor,
                pulsing: isPending,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: _toggleExpanded,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(AppRadii.s),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Icon(
                              _getToolIcon(),
                              size: 16,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _getToolLabel(),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontFamily: 'monospace',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (commandLifecycle != null) ...[
                              const SizedBox(width: 6),
                              _CommandLifecycleChip(
                                lifecycle: commandLifecycle,
                                toolUseId: widget.toolUse.id,
                                color: _commandLifecycleColor(
                                  commandLifecycle,
                                  theme,
                                ),
                              ),
                            ],
                            if (isExecuting)
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            else if (isError)
                              Icon(
                                Icons.error_outline,
                                size: 16,
                                color: theme.colorScheme.error,
                              )
                            else if (isPending)
                              const Icon(
                                Icons.hourglass_empty,
                                size: 16,
                                color: AppColors.statusAmber,
                              )
                            else
                              const Icon(
                                Icons.check_circle_outline,
                                size: 16,
                                color: AppColors.statusGreen,
                              ),
                            const SizedBox(width: 4),
                            Icon(
                              _expanded ? Icons.expand_less : Icons.expand_more,
                              size: 18,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_needsPermissionFix)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.tonalIcon(
                          onPressed: _openAppPermissionSettings,
                          icon: const Icon(Icons.settings_outlined, size: 18),
                          label: const Text(AppStrings.openPermissionSettings),
                        ),
                      ),
                    ),
                  AnimatedCrossFade(
                    duration: const Duration(milliseconds: 260),
                    firstCurve: Curves.easeOutCubic,
                    secondCurve: Curves.easeOutCubic,
                    sizeCurve: Curves.easeOutCubic,
                    crossFadeState: _expanded
                        ? CrossFadeState.showSecond
                        : CrossFadeState.showFirst,
                    firstChild: const SizedBox(
                      width: double.infinity,
                      height: 0,
                    ),
                    secondChild: _buildExpandedContent(theme, commandLifecycle),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Classify this bash attempt from the transcript and the live run state.
  ///
  /// The provider is optional: outside a chat shell the card falls back to
  /// `started`/`completed`/`cancelled` without a live run signal.
  ToolCommandLifecycle _commandLifecycle(BuildContext context) {
    final signals =
        context.select<ChatProvider?, ({bool running, bool interrupted})>(
      (provider) {
        if (provider == null) {
          return (running: false, interrupted: false);
        }
        final marker = provider.currentInterruptedAgentRun;
        final interrupted = marker != null &&
            marker.toolAttempts.any(
              (attempt) =>
                  attempt.toolName == bashToolName &&
                  attempt.lifecycle == ToolAttemptLifecycle.interruptedUnknown,
            );
        return (
          running: provider.agentStatus == AgentStatus.tooling,
          interrupted: interrupted,
        );
      },
    );
    return classifyBashToolAttempt(
      hasResult: widget.toolOutput != null,
      runningNow: signals.running,
      interruptedUnknown: signals.interrupted,
      resultOutput: widget.toolOutput,
    );
  }

  Color _commandLifecycleColor(
    ToolCommandLifecycle lifecycle,
    ThemeData theme,
  ) =>
      switch (lifecycle) {
        ToolCommandLifecycle.running ||
        ToolCommandLifecycle.started =>
          AppColors.statusAmber,
        ToolCommandLifecycle.completed => AppColors.statusGreen,
        ToolCommandLifecycle.cancelled => theme.colorScheme.onSurfaceVariant,
        ToolCommandLifecycle.interruptedUnknown => theme.colorScheme.error,
      };

  Widget _buildExpandedContent(
    ThemeData theme,
    ToolCommandLifecycle? commandLifecycle,
  ) {
    final output = widget.toolOutput;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1),
        if (commandLifecycle != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              commandLifecycle.detail,
              key: ValueKey('tool-lifecycle-detail-${widget.toolUse.id}'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(AppStrings.inputLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  )),
              const SizedBox(height: 4),
              CodeBlock(
                code: const JsonEncoder.withIndent('  ')
                    .convert(widget.toolUse.input),
                language: 'json',
              ),
              if (output != null) ...[
                const SizedBox(height: 12),
                Text(AppStrings.outputLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    )),
                const SizedBox(height: 4),
                CodeBlock(
                  code: output,
                  language: 'text',
                  maxLines: 20,
                ),
                ..._buildResultImages(theme, output),
                if (widget.toolUse.name == 'web_search' &&
                    output.trim().isNotEmpty) ...[
                  _buildSearchSources(theme, output),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Tool result images: a data URL or an image path in the result is rendered
  /// in the card instead of staying a raw string.
  List<Widget> _buildResultImages(ThemeData theme, String output) {
    final images = extractToolResultImages(output);
    if (images.isEmpty) return const [];
    return [
      const SizedBox(height: 12),
      Text(
        AppStrings.resultImages,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 6),
      for (final image in images)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _ToolResultImage(theme: theme, image: image),
        ),
    ];
  }

  Widget _buildSearchSources(ThemeData theme, String output) {
    final sources = parseSearchSources(output);
    if (sources.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppStrings.searchSources,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final source in sources)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      avatar: Icon(
                        Icons.public,
                        size: 14,
                        color: theme.colorScheme.primary,
                      ),
                      label: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: Text(
                          source.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      onPressed: () => _openSource(source.uri),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openSource(Uri uri) async {
    if (!isLaunchableSearchSource(uri)) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

@visibleForTesting
List<SearchSource> parseSearchSources(String output) {
  final sources = <SearchSource>[];
  final seen = <String>{};
  final blocks = output.split(RegExp(r'\n\s*---\s*\n'));
  final urlPattern = RegExp(r'https?://[^\s<>)\]]+');

  for (final block in blocks) {
    final match = urlPattern.firstMatch(block);
    if (match == null) continue;

    final url = _cleanSearchSourceUrl(match.group(0)!);
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !isLaunchableSearchSource(uri) ||
        !seen.add(uri.toString())) {
      continue;
    }

    final title = block.split('\n').map((line) => line.trim()).firstWhere(
          (line) => line.isNotEmpty && !urlPattern.hasMatch(line),
          orElse: () => uri.host,
        );
    sources.add(SearchSource(
      uri: uri,
      label: title.isEmpty ? uri.host : title,
    ));
    if (sources.length >= 8) break;
  }

  return sources;
}

String _cleanSearchSourceUrl(String url) {
  return url.replaceFirst(RegExp(r'[.,;:!?]+$'), '');
}

@visibleForTesting
bool isLaunchableSearchSource(Uri uri) {
  return (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
}

@visibleForTesting
class SearchSource {
  final Uri uri;
  final String label;

  const SearchSource({
    required this.uri,
    required this.label,
  });
}

class _ToolResultImage extends StatelessWidget {
  final ThemeData theme;
  final ToolResultImage image;

  const _ToolResultImage({required this.theme, required this.image});

  @override
  Widget build(BuildContext context) {
    switch (image.kind) {
      case ToolResultImageKind.data:
        final bytes = _decodeDataUrl(image.value);
        if (bytes == null) return const SizedBox.shrink();
        return _frame(
          Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _unavailable(),
          ),
        );
      case ToolResultImageKind.network:
        return _frame(
          Image.network(
            image.value,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => _unavailable(),
          ),
        );
      case ToolResultImageKind.path:
        return FutureBuilder<Uint8List?>(
          future: ToolResultImageResolver.readWorkspaceBytes(image.value),
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            final mediaType = bytes == null
                ? null
                : ToolResultImageResolver.detectMediaType(bytes);
            if (bytes != null && mediaType != null) {
              return _frame(
                Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => _unavailable(),
                ),
              );
            }
            return _label(image.value);
          },
        );
    }
  }

  Widget _label(String value) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.image_outlined,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      );

  Widget _frame(Widget child) => ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.s),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240, maxWidth: 320),
          child: child,
        ),
      );

  Widget _unavailable() => Text(
        AppStrings.resultImageUnavailable,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );

  Uint8List? _decodeDataUrl(String dataUrl) {
    final comma = dataUrl.indexOf(',');
    if (comma < 0 || comma == dataUrl.length - 1) return null;
    try {
      return base64Decode(dataUrl.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }
}

class _CommandLifecycleChip extends StatelessWidget {
  const _CommandLifecycleChip({
    required this.lifecycle,
    required this.toolUseId,
    required this.color,
  });

  final ToolCommandLifecycle lifecycle;
  final String toolUseId;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      lifecycle.label,
      key: ValueKey('tool-lifecycle-$toolUseId'),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
    );
  }
}

class _PulsingToolBorder extends StatefulWidget {
  final Color color;
  final bool pulsing;

  const _PulsingToolBorder({
    required this.color,
    required this.pulsing,
  });

  @override
  State<_PulsingToolBorder> createState() => _PulsingToolBorderState();
}

class _PulsingToolBorderState extends State<_PulsingToolBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
  }

  @override
  void didUpdateWidget(covariant _PulsingToolBorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pulsing != widget.pulsing) {
      _syncAnimation();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.pulsing && !MediaQuery.disableAnimationsOf(context)) {
      _controller.repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final opacity =
            widget.pulsing ? 0.58 + (_controller.value * 0.22) : 0.9;
        return Container(
          width: 4,
          color: widget.color.withAlpha((255 * opacity).round()),
        );
      },
    );
  }
}
