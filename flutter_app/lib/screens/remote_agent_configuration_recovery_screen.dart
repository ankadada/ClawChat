import 'package:flutter/material.dart';

import '../layout/foldable_layout.dart';
import '../services/remote_agent_boot.dart';

class RemoteAgentBootProgressScreen extends StatelessWidget {
  const RemoteAgentBootProgressScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在验证本地远程 Agent 配置…'),
                ],
              ),
            ),
          ),
        ),
      );
}

class RemoteAgentConfigurationRecoveryScreen extends StatelessWidget {
  const RemoteAgentConfigurationRecoveryScreen({
    super.key,
    required this.controller,
  });

  final RemoteAgentBootController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(builder: (context, constraints) {
        final media = MediaQuery.of(context);
        final layout = FoldableLayout.resolve(
          constraints.biggest,
          media.displayFeatures,
          bottomInset: media.viewInsets.bottom,
        );
        final primary = _RecoveryContent(
          controller: controller,
          onAdvancedReset: () => _confirmReset(context),
        );
        if (!layout.hasSeparatedRegions) return primary;
        return Stack(children: [
          Positioned.fromRect(
            rect: layout.auxiliary!,
            child: const _RecoveryAuxiliary(),
          ),
          Positioned.fromRect(rect: layout.primary, child: primary),
        ]);
      }),
    );
  }

  Future<void> _confirmReset(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ResetConfirmationDialog(),
    );
    if (confirmed == true) await controller.resetEvidenceAndRetry();
  }
}

class _ResetConfirmationDialog extends StatefulWidget {
  const _ResetConfirmationDialog();

  @override
  State<_ResetConfirmationDialog> createState() =>
      _ResetConfirmationDialogState();
}

class _ResetConfirmationDialogState extends State<_ResetConfirmationDialog> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('高级恢复：重置远程配置证据'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '此操作仅重置远程 Agent 的本地元数据。执行前会尝试保留一份有界的本地恢复备份；不会导出凭据或删除 Keystore 密钥。',
              ),
              const SizedBox(height: 12),
              const Text('输入 RESET 确认。'),
              const SizedBox(height: 8),
              TextField(
                controller: _input,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '确认文字',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _input.text == 'RESET'
                ? () => Navigator.pop(context, true)
                : null,
            child: const Text('重置并重试'),
          ),
        ],
      );
}

class _RecoveryContent extends StatelessWidget {
  const _RecoveryContent({
    required this.controller,
    required this.onAdvancedReset,
  });

  final RemoteAgentBootController controller;
  final VoidCallback onAdvancedReset;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        key: const ValueKey('remote-configuration-recovery-scroll'),
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.settings_backup_restore,
                  size: 48,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  '需要恢复本地配置',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                const Text(
                  '远程 Agent 的本地变更证据无法安全验证。为避免删除或误用凭据，远程配置已关闭，现有证据保持原样。',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  '普通重试和本地安全模式都不会删除证据，也不会解析凭据或发起网络请求。',
                  textAlign: TextAlign.center,
                ),
                if (controller.failureCode ==
                    'remote_configuration_reset_failed') ...[
                  const SizedBox(height: 12),
                  Text(
                    '高级重置未完成；已保留的本地备份不会被覆盖。可再次确认高级恢复，以继续清理尚未移除的元数据。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: const ValueKey('remote-configuration-retry'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: controller.isAttempting ? null : controller.retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试验证'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey('remote-configuration-local-only'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed:
                      controller.isAttempting ? null : controller.useLocalOnly,
                  icon: const Icon(Icons.phone_android),
                  label: const Text('使用本地安全模式'),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed:
                      controller.canResetEvidence && !controller.isAttempting
                          ? onAdvancedReset
                          : null,
                  icon: const Icon(Icons.warning_amber_outlined),
                  label: const Text('高级恢复…'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecoveryAuxiliary extends StatelessWidget {
  const _RecoveryAuxiliary();

  @override
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: const SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.shield_outlined, size: 44),
                  SizedBox(height: 12),
                  Text('本地优先 · 证据保留'),
                ],
              ),
            ),
          ),
        ),
      );
}
