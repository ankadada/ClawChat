import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../app.dart';
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
          return const SizedBox.shrink();
        }

        final (icon, label, color) = switch (provider.agentStatus) {
          AgentStatus.thinking => (Icons.psychology, AppStrings.statusThinking, theme.colorScheme.primary),
          AgentStatus.streaming => (Icons.edit, AppStrings.statusStreaming, theme.colorScheme.primary),
          AgentStatus.tooling => (Icons.build, AppStrings.statusTooling, AppColors.statusAmber),
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

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: color.withAlpha(15),
            border: Border(
              bottom: BorderSide(color: color.withAlpha(50)),
            ),
          ),
          child: Row(
            crossAxisAlignment: isError ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              if (!isError)
                SizedBox(
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
        );
      },
    );
  }
}
