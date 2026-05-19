import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../constants.dart';
import '../app.dart';
import '../services/preferences_service.dart';
import 'terminal_screen.dart';
import 'settings_screen.dart';
import 'onboarding_screen.dart';
import '../l10n/app_strings.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final Future<_DashboardStatus> _statusFuture;

  @override
  void initState() {
    super.initState();
    _statusFuture = _loadStatus();
  }

  Future<_DashboardStatus> _loadStatus() async {
    final prefs = PreferencesService();
    await prefs.init();
    return _DashboardStatus(
      model: prefs.model ?? AppConstants.defaultModel,
      apiFormat: prefs.apiFormat ?? 'anthropic',
      hasApiKey: prefs.apiKey?.isNotEmpty == true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.appName),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              CupertinoPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildStatusHeader(context),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 720 ? 4 : 2;
                return GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: columns,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: columns == 4 ? 1.05 : 0.98,
                  children: [
                    _buildQuickAction(
                      context,
                      icon: Icons.chat_bubble,
                      color: theme.colorScheme.primary,
                      title: AppStrings.chat,
                      subtitle: AppStrings.chatSubtitle,
                      onTap: () => Navigator.of(context).push(
                        CupertinoPageRoute(builder: (_) => const ResponsiveShell()),
                      ),
                    ),
                    _buildQuickAction(
                      context,
                      icon: Icons.terminal,
                      color: AppColors.statusGreen,
                      title: AppStrings.terminal,
                      subtitle: AppStrings.terminalSubtitle,
                      onTap: () => Navigator.of(context).push(
                        CupertinoPageRoute(builder: (_) => const TerminalScreen()),
                      ),
                    ),
                    _buildQuickAction(
                      context,
                      icon: Icons.vpn_key,
                      color: AppColors.statusAmber,
                      title: AppStrings.configureApiKey,
                      subtitle: AppStrings.configureApiKeySubtitle,
                      onTap: () => Navigator.of(context).push(
                        CupertinoPageRoute(builder: (_) => const OnboardingScreen()),
                      ),
                    ),
                    _buildQuickAction(
                      context,
                      icon: Icons.tune,
                      color: theme.colorScheme.secondary,
                      title: AppStrings.settings,
                      subtitle: AppStrings.settingsSubtitle,
                      onTap: () => Navigator.of(context).push(
                        CupertinoPageRoute(builder: (_) => const SettingsScreen()),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 24),
            Center(
              child: Column(
                children: [
                  Text(
                    'ClawChat v${AppConstants.version}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusHeader(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<_DashboardStatus>(
      future: _statusFuture,
      builder: (context, snapshot) {
        final status = snapshot.data;
        final connected = status?.hasApiKey ?? false;
        final model = status?.model ?? AppConstants.defaultModel;
        final format = status?.apiFormat == 'openai'
            ? AppStrings.openaiCompatible
            : 'Anthropic';

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withAlpha(120),
            borderRadius: BorderRadius.circular(AppRadii.l),
            border: Border.all(color: theme.colorScheme.outline.withAlpha(45)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: connected
                      ? AppColors.statusGreen.withAlpha(28)
                      : AppColors.statusAmber.withAlpha(35),
                  borderRadius: BorderRadius.circular(AppRadii.m),
                ),
                child: Icon(
                  connected ? Icons.cloud_done : Icons.cloud_off,
                  color: connected ? AppColors.statusGreen : AppColors.statusAmber,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      connected
                          ? AppStrings.dashboardConnected
                          : AppStrings.dashboardWaitingApi,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$format · $model',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildQuickAction(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(AppRadii.m),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.m),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.m),
            border: Border.all(color: theme.colorScheme.outline.withAlpha(45)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: color.withAlpha(28),
                  borderRadius: BorderRadius.circular(AppRadii.m),
                ),
                child: Icon(icon, color: color),
              ),
              const Spacer(),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashboardStatus {
  final String model;
  final String apiFormat;
  final bool hasApiKey;

  const _DashboardStatus({
    required this.model,
    required this.apiFormat,
    required this.hasApiKey,
  });
}
