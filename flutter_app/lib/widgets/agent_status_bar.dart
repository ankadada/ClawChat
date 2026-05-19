import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../app.dart';
import '../models/chat_models.dart';
import '../providers/chat_provider.dart';
import '../l10n/app_strings.dart';

class AgentStatusBar extends StatelessWidget {
  const AgentStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Consumer<ChatProvider>(
      builder: (_, provider, __) {
        if (provider.agentStatus == AgentStatus.idle) {
          return _animatedStatusBar(const SizedBox.shrink(key: ValueKey('idle')));
        }

        final activeToolName = _activeToolName(provider);
        final (icon, label, color) = switch (provider.agentStatus) {
          AgentStatus.thinking => (Icons.psychology, AppStrings.statusThinking, theme.colorScheme.primary),
          AgentStatus.streaming => (Icons.edit, AppStrings.statusStreaming, theme.colorScheme.primary),
          AgentStatus.tooling => (
              Icons.build,
              activeToolName == null
                  ? AppStrings.statusTooling
                  : AppStrings.toolExecuting(activeToolName),
              AppColors.statusAmber,
            ),
          AgentStatus.error => (Icons.error_outline, provider.errorMessage ?? AppStrings.statusError, theme.colorScheme.error),
          _ => (Icons.hourglass_empty, AppStrings.statusProcessing, theme.colorScheme.primary),
        };

        final isError = provider.agentStatus == AgentStatus.error;
        void copyError() {
          Clipboard.setData(ClipboardData(text: label));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已复制错误信息')),
          );
        }

        return _animatedStatusBar(Container(
          key: ValueKey('status-${provider.agentStatus}-$label'),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Color.alphaBlend(color.withAlpha(18), theme.colorScheme.surface),
            border: Border(
              bottom: BorderSide(color: color.withAlpha(65)),
            ),
            boxShadow: [
              BoxShadow(
                color: color.withAlpha(12),
                blurRadius: 12,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: isError ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              if (!isError)
                provider.agentStatus == AgentStatus.thinking
                    ? _PulsingStatusDot(color: color)
                    : SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: color,
                        ),
                      )
              else
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(icon, size: 14, color: color),
                ),
              const SizedBox(width: 8),
              Expanded(
                child: isError
                    ? InkWell(
                        onLongPress: copyError,
                        borderRadius: BorderRadius.circular(AppRadii.s),
                        child: Text(
                          label,
                          style: theme.textTheme.bodySmall?.copyWith(color: color),
                          maxLines: 10,
                        ),
                      )
                    : Text(
                        label,
                        style: theme.textTheme.bodySmall?.copyWith(color: color),
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
              if (isError)
                IconButton(
                  tooltip: AppStrings.copy,
                  icon: Icon(Icons.copy, size: 16, color: color),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  onPressed: copyError,
                )
              else
                TextButton(
                  onPressed: provider.cancelAgent,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(48, 48),
                  ),
                  child: Text(AppStrings.cancel, style: TextStyle(color: color, fontSize: 12)),
                ),
            ],
          ),
        ));
      },
    );
  }

  Widget _animatedStatusBar(Widget child) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final slide = Tween<Offset>(
          begin: const Offset(0, -0.18),
          end: Offset.zero,
        ).animate(animation);
        return ClipRect(
          child: SizeTransition(
            sizeFactor: animation,
            axisAlignment: -1,
            child: FadeTransition(
              opacity: animation,
              child: SlideTransition(position: slide, child: child),
            ),
          ),
        );
      },
      child: child,
    );
  }

  String? _activeToolName(ChatProvider provider) {
    final pendingTool = provider.pendingApproval?.toolName;
    if (pendingTool != null && pendingTool.isNotEmpty) return pendingTool;

    final messages = provider.currentSession?.messages;
    if (messages == null) return null;
    for (final message in messages.reversed) {
      for (final content in message.content.reversed) {
        if (content is ToolUseContent && content.isExecuting) {
          return content.name;
        }
      }
    }
    return null;
  }
}

class _PulsingStatusDot extends StatefulWidget {
  final Color color;

  const _PulsingStatusDot({required this.color});

  @override
  State<_PulsingStatusDot> createState() => _PulsingStatusDotState();
}

class _PulsingStatusDotState extends State<_PulsingStatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: 14,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final size = 7.0 + (_controller.value * 4.0);
          return Center(
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: widget.color.withAlpha(145 + (_controller.value * 80).round()),
                shape: BoxShape.circle,
              ),
            ),
          );
        },
      ),
    );
  }
}
