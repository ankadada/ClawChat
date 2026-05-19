import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'providers/chat_provider.dart';
import 'screens/splash_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/chat_sessions_screen.dart';
import 'services/preferences_service.dart';

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

class ClawChatApp extends StatelessWidget {
  const ClawChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ChatProvider()),
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
                  textScaler: TextScaler.linear(scale),
                ),
                child: child!,
              );
            },
            home: const SplashScreen(),
          ),
        ),
      ),
    );
  }

  ThemeData _buildDarkTheme() {
    final base = ThemeData.dark(useMaterial3: true);
    final textTheme = GoogleFonts.interTextTheme(base.textTheme);

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
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: AppColors.darkBg,
        foregroundColor: Colors.white,
        titleTextStyle: GoogleFonts.inter(
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
      dividerTheme: const DividerThemeData(color: AppColors.darkBorder, space: 1),
      dialogTheme: DialogTheme(
        backgroundColor: AppColors.darkSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.l),
          side: const BorderSide(color: AppColors.darkBorder),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.darkSurfaceAlt,
        contentTextStyle: GoogleFonts.inter(color: Colors.white),
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
    final textTheme = GoogleFonts.interTextTheme(base.textTheme);

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
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: AppColors.lightBg,
        foregroundColor: const Color(0xFF0A0A0A),
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: const Color(0xFF0A0A0A),
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.s)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF0A0A0A),
          side: const BorderSide(color: AppColors.lightBorder),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.s)),
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
      dividerTheme: const DividerThemeData(color: AppColors.lightBorder, space: 1),
      dialogTheme: DialogTheme(
        backgroundColor: AppColors.lightBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.l),
          side: const BorderSide(color: AppColors.lightBorder),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF0A0A0A),
        contentTextStyle: GoogleFonts.inter(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.s)),
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

class ResponsiveShell extends StatefulWidget {
  const ResponsiveShell({super.key});

  @override
  State<ResponsiveShell> createState() => _ResponsiveShellState();
}

class _ResponsiveShellState extends State<ResponsiveShell> {
  bool _isDualPane = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final shouldBeDual = _isDualPane
            ? constraints.maxWidth >= 680  // stay dual until drops below 680
            : constraints.maxWidth >= 700; // switch to dual at 700
        if (shouldBeDual != _isDualPane) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            setState(() => _isDualPane = shouldBeDual);
          });
        }
        if (_isDualPane) {
          return const DualPaneLayout();
        }
        return const ChatScreen();
      },
    );
  }
}

class DualPaneLayout extends StatelessWidget {
  const DualPaneLayout({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 280,
            child: ChatSessionsScreen(embedded: true),
          ),
          const VerticalDivider(width: 1),
          const Expanded(child: ChatScreen()),
        ],
      ),
    );
  }
}
