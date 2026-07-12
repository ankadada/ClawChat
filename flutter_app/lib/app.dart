import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'layout/foldable_layout.dart';
import 'providers/chat_provider.dart';
import 'screens/splash_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/chat_sessions_screen.dart';
import 'screens/remote_agent_configuration_recovery_screen.dart';
import 'services/app_http.dart';
import 'services/preferences_service.dart';
import 'services/remote_agent_boot.dart';
import 'services/remote_agent_configuration_service.dart';
import 'services/remote_agent_connector.dart';

/// Global notifier so any widget (e.g. SettingsScreen) can change the theme
/// and have the MaterialApp rebuild immediately.
final themeNotifier = ValueNotifier<ThemeMode>(ThemeMode.system);

/// Global notifier for font scaling (0.8 – 1.4).
final fontScaleNotifier = ValueNotifier<double>(1.0);

/// Call once before runApp (or in initState) to seed the notifier from prefs.
Future<void> initThemeFromPreferences() async {
  final prefs = PreferencesService();
  await prefs.init();
  themeNotifier.value = switch (prefs.themeMode) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
  fontScaleNotifier.value = prefs.fontScale;
}

class AppColors {
  AppColors._();

  static const Color accent = Color(0xFF2563EB);
  static const Color darkBg = Color(0xFF141418);
  static const Color darkSurface = Color(0xFF1E1E26);
  static const Color darkSurfaceAlt = Color(0xFF252530);
  static const Color darkBorder = Color(0xFF343442);
  static const Color darkMutedText = Color(0xFF9CA3AF);
  static const Color lightBg = Color(0xFFFFFFFF);
  static const Color lightSurface = Color(0xFFF9F9F9);
  static const Color lightBorder = Color(0xFFE5E5E5);
  static const Color statusGreen = Color(0xFF22C55E);
  static const Color statusAmber = Color(0xFFF59E0B);
  static const Color statusRed = Color(0xFFEF4444);
  static const Color statusGrey = Color(0xFF6B7280);
  static const Color mutedText = Color(0xFF6B7280);
}

class AppRadii {
  AppRadii._();

  static const double s = 8.0;
  static const double m = 12.0;
  static const double l = 16.0;
  static const double xl = 24.0;
}

class ClawChatApp extends StatefulWidget {
  const ClawChatApp({
    super.key,
    required this.runtimeInfo,
    required this.httpRegistry,
    this.remoteAgentConfigurationLoader,
    this.remoteAgentEvidenceResetter,
    this.bootControllerForTesting,
    this.operationalHomeBuilderForTesting,
    this.chatProviderFactoryForTesting,
  });

  final AppRuntimeInfo runtimeInfo;
  final AppHttpClientRegistry httpRegistry;
  final RemoteAgentConfigurationLoader? remoteAgentConfigurationLoader;
  final RemoteAgentEvidenceResetter? remoteAgentEvidenceResetter;
  final RemoteAgentBootController? bootControllerForTesting;
  final Widget Function(BuildContext context, bool localOnly)?
      operationalHomeBuilderForTesting;
  final ChatProvider Function(RemoteAgentRuntimeBinding binding)?
      chatProviderFactoryForTesting;

  @override
  State<ClawChatApp> createState() => _ClawChatAppState();
}

class _ClawChatAppState extends State<ClawChatApp> {
  late final RemoteAgentBootController _remoteAgentBoot;
  late final RemoteAgentRuntimeBinding _remoteAgentRuntime;
  late final ChatProvider _chatProvider;
  RemoteAgentConfigurationService? _attachedRemoteConfiguration;
  late final bool _ownsRemoteAgentBoot;

  @override
  void initState() {
    super.initState();
    final injected = widget.bootControllerForTesting;
    _ownsRemoteAgentBoot = injected == null;
    _remoteAgentRuntime = RemoteAgentRuntimeBinding();
    _chatProvider =
        widget.chatProviderFactoryForTesting?.call(_remoteAgentRuntime) ??
            ChatProvider(remoteAgentRuntimeBinding: _remoteAgentRuntime);
    _remoteAgentBoot = injected ??
        RemoteAgentBootController(
          loader: widget.remoteAgentConfigurationLoader ??
              RemoteAgentConfigurationService.createForApp,
          resetter: widget.remoteAgentEvidenceResetter ??
              RemoteAgentConfigurationService.resetCorruptEvidenceForApp,
        );
    _remoteAgentBoot.bindRuntimeTransition(_syncRemoteRuntime);
    _remoteAgentBoot.start();
  }

  Future<void> _syncRemoteRuntime(
    RemoteAgentBootStatus status,
    RemoteAgentConfigurationService? configuration,
  ) async {
    if (status == RemoteAgentBootStatus.ready && configuration != null) {
      if (identical(_attachedRemoteConfiguration, configuration) &&
          _remoteAgentRuntime.isAttached) {
        return;
      }
      _attachedRemoteConfiguration = configuration;
      await _remoteAgentRuntime.attach(
        configuration,
        CozeOpenApiRemoteAgentConnector(
          client: widget.httpRegistry.webFetchClient,
          credentialResolver: configuration,
        ),
      );
      return;
    }
    _attachedRemoteConfiguration = null;
    await _remoteAgentRuntime.detach(
      reason: status == RemoteAgentBootStatus.localOnly
          ? '本地安全模式已启用；远程配置证据尚未恢复。'
          : '远程配置正在恢复，当前不可用。',
    );
  }

  @override
  void dispose() {
    _chatProvider.dispose();
    _remoteAgentRuntime.dispose();
    if (_ownsRemoteAgentBoot) _remoteAgentBoot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppRuntimeInfo>.value(value: widget.runtimeInfo),
        Provider<AppHttpClientRegistry>(
          create: (_) => widget.httpRegistry,
          dispose: (_, registry) => registry.dispose(),
          lazy: false,
        ),
        Provider<AppHttpClient>.value(value: widget.httpRegistry.client),
        ChangeNotifierProvider<RemoteAgentBootController>.value(
          value: _remoteAgentBoot,
        ),
        Provider<RemoteAgentRuntimeBinding>.value(
          value: _remoteAgentRuntime,
        ),
        ChangeNotifierProvider<ChatProvider>.value(value: _chatProvider),
      ],
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: themeNotifier,
        builder: (_, mode, __) => ValueListenableBuilder<double>(
          valueListenable: fontScaleNotifier,
          builder: (_, scale, __) => MaterialApp(
            // ClawChat currently uses AppStrings, a static Chinese-first string
            // table with English technical labels. Flutter generated i18n is
            // intentionally deferred until the app targets multiple locales.
            title: 'ClawChat',
            debugShowCheckedModeBanner: false,
            theme: _buildLightTheme(),
            darkTheme: _buildDarkTheme(),
            themeMode: mode,
            builder: (context, child) {
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: composeAppTextScaler(
                    MediaQuery.textScalerOf(context),
                    scale,
                  ),
                ),
                child: child!,
              );
            },
            home: AnimatedBuilder(
              animation: _remoteAgentBoot,
              builder: (context, _) => _bootHome(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bootHome(BuildContext context) {
    switch (_remoteAgentBoot.status) {
      case RemoteAgentBootStatus.initializing:
        return const RemoteAgentBootProgressScreen();
      case RemoteAgentBootStatus.recovery:
        return RemoteAgentConfigurationRecoveryScreen(
          controller: _remoteAgentBoot,
        );
      case RemoteAgentBootStatus.ready:
      case RemoteAgentBootStatus.localOnly:
        final localOnly = _remoteAgentBoot.isLocalOnly;
        final testingBuilder = widget.operationalHomeBuilderForTesting;
        if (testingBuilder != null) return testingBuilder(context, localOnly);
        return const _OperationalAppRoot();
    }
  }

  ThemeData _buildDarkTheme() {
    final base = ThemeData.dark(useMaterial3: true);
    final textTheme = base.textTheme;

    return base.copyWith(
      visualDensity: VisualDensity.adaptivePlatformDensity,
      scaffoldBackgroundColor: AppColors.darkBg,
      colorScheme: base.colorScheme.copyWith(
        primary: AppColors.accent,
        onPrimary: Colors.white,
        secondary: AppColors.accent,
        onSecondary: Colors.white,
        surface: AppColors.darkSurface,
        surfaceContainerHighest: AppColors.darkSurfaceAlt,
        surfaceContainerHigh: AppColors.darkSurfaceAlt,
        surfaceContainer: AppColors.darkSurface,
        surfaceContainerLow: AppColors.darkBg,
        surfaceContainerLowest: AppColors.darkBg,
        onSurface: Colors.white,
        onSurfaceVariant: AppColors.darkMutedText,
        error: AppColors.statusRed,
        onError: Colors.white,
        outline: AppColors.darkBorder,
      ),
      textTheme: textTheme.apply(
        bodyColor: Colors.white,
        displayColor: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: AppColors.darkBg,
        foregroundColor: Colors.white,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
      cardTheme: CardTheme(
        elevation: 0,
        color: AppColors.darkSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.m),
          side: const BorderSide(color: AppColors.darkBorder),
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.s),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white70,
          side: const BorderSide(color: AppColors.darkBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.s),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: AppColors.accent),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.s),
          borderSide: const BorderSide(color: AppColors.darkBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.s),
          borderSide: const BorderSide(color: AppColors.darkBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.s),
          borderSide: const BorderSide(color: AppColors.accent, width: 2),
        ),
        filled: true,
        fillColor: AppColors.darkSurfaceAlt,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return AppColors.accent;
          return AppColors.statusGrey;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppColors.accent.withAlpha(80);
          }
          return AppColors.darkBorder;
        }),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.accent,
        linearTrackColor: AppColors.darkBorder,
      ),
      dividerTheme:
          const DividerThemeData(color: AppColors.darkBorder, space: 1),
      dialogTheme: DialogTheme(
        backgroundColor: AppColors.darkSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.l),
          side: const BorderSide(color: AppColors.darkBorder),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.darkSurfaceAlt,
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.s),
          side: const BorderSide(color: AppColors.darkBorder),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      listTileTheme: const ListTileThemeData(iconColor: AppColors.mutedText),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return AppColors.accent;
          return AppColors.statusGrey;
        }),
      ),
    );
  }

  ThemeData _buildLightTheme() {
    final base = ThemeData.light(useMaterial3: true);
    final textTheme = base.textTheme;

    return base.copyWith(
      visualDensity: VisualDensity.adaptivePlatformDensity,
      scaffoldBackgroundColor: AppColors.lightBg,
      colorScheme: const ColorScheme.light(
        primary: AppColors.accent,
        onPrimary: Colors.white,
        secondary: AppColors.accent,
        onSecondary: Colors.white,
        surface: AppColors.lightBg,
        onSurface: Color(0xFF0A0A0A),
        onSurfaceVariant: AppColors.mutedText,
        error: AppColors.statusRed,
        onError: Colors.white,
        outline: AppColors.lightBorder,
      ),
      textTheme: textTheme.apply(
        bodyColor: const Color(0xFF0A0A0A),
        displayColor: const Color(0xFF0A0A0A),
      ),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: AppColors.lightBg,
        foregroundColor: Color(0xFF0A0A0A),
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: Color(0xFF0A0A0A),
        ),
      ),
      cardTheme: CardTheme(
        elevation: 0,
        color: AppColors.lightSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.m),
          side: const BorderSide(color: AppColors.lightBorder),
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.s)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF0A0A0A),
          side: const BorderSide(color: AppColors.lightBorder),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.s)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: AppColors.accent),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.s),
          borderSide: const BorderSide(color: AppColors.lightBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.s),
          borderSide: const BorderSide(color: AppColors.lightBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.s),
          borderSide: const BorderSide(color: AppColors.accent, width: 2),
        ),
        filled: true,
        fillColor: AppColors.lightSurface,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return AppColors.accent;
          return AppColors.statusGrey;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppColors.accent.withAlpha(80);
          }
          return AppColors.lightBorder;
        }),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.accent,
        linearTrackColor: AppColors.lightBorder,
      ),
      dividerTheme:
          const DividerThemeData(color: AppColors.lightBorder, space: 1),
      dialogTheme: DialogTheme(
        backgroundColor: AppColors.lightBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.l),
          side: const BorderSide(color: AppColors.lightBorder),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF0A0A0A),
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.s)),
        behavior: SnackBarBehavior.floating,
      ),
      listTileTheme: const ListTileThemeData(iconColor: AppColors.mutedText),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return AppColors.accent;
          return AppColors.statusGrey;
        }),
      ),
    );
  }
}

class _OperationalAppRoot extends StatelessWidget {
  const _OperationalAppRoot();

  @override
  Widget build(BuildContext context) => const SplashScreen();
}

class ResponsiveShell extends StatefulWidget {
  const ResponsiveShell({super.key});

  @override
  State<ResponsiveShell> createState() => _ResponsiveShellState();
}

class _ResponsiveShellState extends State<ResponsiveShell> {
  bool _isDualPane = false;
  final _chatScreenKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final media = MediaQuery.of(context);
        final foldable = FoldableLayout.resolve(
          constraints.biggest,
          media.displayFeatures,
          bottomInset: media.viewInsets.bottom,
        );
        if (foldable.hasSeparatedRegions) {
          return _SeparatedFoldableLayout(
            layout: foldable,
            chatScreenKey: _chatScreenKey,
          );
        }
        final shouldBeDual = _isDualPane
            ? constraints.maxWidth >= 680 // stay dual until drops below 680
            : constraints.maxWidth >= 700; // switch to dual at 700
        if (shouldBeDual != _isDualPane) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            setState(() => _isDualPane = shouldBeDual);
          });
        }
        if (_isDualPane) {
          return DualPaneLayout(chatScreenKey: _chatScreenKey);
        }
        return ChatScreen(key: _chatScreenKey);
      },
    );
  }
}

class DualPaneLayout extends StatefulWidget {
  final GlobalKey chatScreenKey;

  const DualPaneLayout({
    super.key,
    required this.chatScreenKey,
  });

  @override
  State<DualPaneLayout> createState() => _DualPaneLayoutState();
}

class _DualPaneLayoutState extends State<DualPaneLayout> {
  static const _minSidebarWidth = 200.0;
  final _prefs = PreferencesService();
  double _sidebarWidth = PreferencesService.defaultDualPaneSidebarWidth;
  bool _prefsReady = false;

  @override
  void initState() {
    super.initState();
    _prefs.init().then((_) {
      if (!mounted) return;
      setState(() {
        _sidebarWidth = _prefs.dualPaneSidebarWidth;
        _prefsReady = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxSidebarWidth = constraints.maxWidth * 0.5;
        final sidebarWidth =
            _sidebarWidth.clamp(_minSidebarWidth, maxSidebarWidth).toDouble();
        return Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: sidebarWidth,
                child: const ChatSessionsScreen(embedded: true),
              ),
              SidebarResizeDivider(
                semanticValue: '${sidebarWidth.round()} dp',
                onDragUpdate: (delta) {
                  final next = (sidebarWidth + delta)
                      .clamp(_minSidebarWidth, maxSidebarWidth)
                      .toDouble();
                  setState(() => _sidebarWidth = next);
                  if (_prefsReady) {
                    _prefs.dualPaneSidebarWidth = next;
                  }
                },
                onReset: () {
                  final next = PreferencesService.defaultDualPaneSidebarWidth
                      .clamp(_minSidebarWidth, maxSidebarWidth)
                      .toDouble();
                  setState(() => _sidebarWidth = next);
                  if (_prefsReady) _prefs.dualPaneSidebarWidth = next;
                },
              ),
              Expanded(child: ChatScreen(key: widget.chatScreenKey)),
            ],
          ),
        );
      },
    );
  }
}

class SidebarResizeDivider extends StatelessWidget {
  final String semanticValue;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onReset;

  const SidebarResizeDivider({
    super.key,
    required this.semanticValue,
    required this.onDragUpdate,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '调整会话列表宽度',
      value: '$semanticValue；可用方向键调整，Home 恢复默认',
      increasedValue: '更宽',
      decreasedValue: '更窄',
      onIncrease: () => onDragUpdate(24),
      onDecrease: () => onDragUpdate(-24),
      child: Focus(
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            onDragUpdate(-24);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            onDragUpdate(24);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.home) {
            onReset();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (details) => onDragUpdate(details.delta.dx),
            onDoubleTap: onReset,
            child: SizedBox(
              key: const ValueKey('sidebar-resize-target'),
              width: 48,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    key: const ValueKey('sidebar-resize-visual-line'),
                    width: 1,
                    color: theme.colorScheme.outline.withAlpha(80),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(AppRadii.s),
                      border: Border.all(
                        color: theme.colorScheme.outline.withAlpha(70),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Icon(
                        Icons.drag_indicator,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _PreferenceTextScaler extends TextScaler {
  const _PreferenceTextScaler(this.platform, this.preference);

  final TextScaler platform;
  final double preference;

  @override
  double scale(double fontSize) => platform.scale(fontSize) * preference;

  @override
  double get textScaleFactor => scale(1);

  @override
  bool operator ==(Object other) =>
      other is _PreferenceTextScaler &&
      other.platform == platform &&
      other.preference == preference;

  @override
  int get hashCode => Object.hash(platform, preference);
}

@visibleForTesting
TextScaler composeAppTextScaler(TextScaler platform, double preference) =>
    _PreferenceTextScaler(platform, preference);

class _SeparatedFoldableLayout extends StatelessWidget {
  const _SeparatedFoldableLayout({
    required this.layout,
    required this.chatScreenKey,
  });

  final FoldableLayout layout;
  final GlobalKey chatScreenKey;

  @override
  Widget build(BuildContext context) {
    final auxiliary = layout.auxiliary!;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fromRect(
            rect: auxiliary,
            child: ClipRect(
              child: layout.posture == FoldablePosture.tabletop
                  ? const _TabletopAuxiliary()
                  : const ChatSessionsScreen(embedded: true),
            ),
          ),
          Positioned.fromRect(
            rect: layout.primary,
            child: ClipRect(child: ChatScreen(key: chatScreenKey)),
          ),
        ],
      ),
    );
  }
}

class _TabletopAuxiliary extends StatelessWidget {
  const _TabletopAuxiliary();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ChatSessionsScreen()),
        ),
        child: Center(
          child: Semantics(
            button: true,
            label: '打开会话列表',
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.forum_outlined),
                  SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      '会话列表',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
