import 'dart:async';

import 'package:clawchat/app.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/screens/chat_sessions_screen.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('search error settles, retries, and ignores stale completion',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = ChatProvider(storage: _NoopSessionStorage());
    addTearDown(provider.dispose);
    final calls = <String, Completer<List<SessionSearchResult>>>{};
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          home: ChatSessionsScreen(
            sessionSearcher: (query) =>
                (calls[query] = Completer<List<SessionSearchResult>>()).future,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    provider.sessions = [_summary('local')];
    provider.notifyListeners();
    await tester.pump();

    final field = find.byType(TextField);
    await tester.enterText(field, 'first');
    await tester.pump(const Duration(milliseconds: 250));
    calls['first']!.completeError(StateError('sanitized'));
    await tester.pump();
    expect(find.text(AppStrings.sessionSearchFailed), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.text(AppStrings.retry));
    await tester.pump(const Duration(milliseconds: 250));
    final retry = calls['first']!;
    await tester.enterText(field, 'newer');
    await tester.pump(const Duration(milliseconds: 250));
    calls['newer']!.complete([_result('newer')]);
    await tester.pump();
    retry.completeError(StateError('stale failure'));
    await tester.pump();

    expect(find.text(AppStrings.sessionSearchFailed), findsNothing);
    expect(find.text('Newer result'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
        'selected session row uses readable semantic foregrounds in ${brightness.name} theme',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final provider = ChatProvider(storage: _NoopSessionStorage());
      addTearDown(provider.dispose);
      final selectedSummary = _summary(
        'selected',
        title: 'Selected session',
      );
      provider.sessions = [selectedSummary];
      provider.currentSession = ChatSession(
        id: selectedSummary.id,
        title: selectedSummary.title,
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: _productionThemeFor(brightness),
            home: ChatSessionsScreen(
              sessionSearcher: (_) async => [
                SessionSearchResult(
                  summary: selectedSummary,
                  matchPreview: 'Matched preview text',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'matched');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();

      final tile = find
          .ancestor(
            of: find.text('Selected session'),
            matching: find.byType(ListTile),
          )
          .first;
      final theme = Theme.of(tester.element(tile));
      final selectedForeground = theme.colorScheme.onSurface;
      final selectedBackground = Color.alphaBlend(
        theme.colorScheme.primaryContainer.withAlpha(170),
        theme.scaffoldBackgroundColor,
      );

      expect(
        _contrastRatio(selectedForeground, selectedBackground),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: tile,
                matching: find.text('Selected session'),
              ),
            )
            .style
            ?.color,
        selectedForeground,
      );
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: tile,
                matching: find.byIcon(Icons.chat_bubble_outline),
              ),
            )
            .color,
        selectedForeground,
      );
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: tile,
                matching: find.byIcon(Icons.more_vert),
              ),
            )
            .color,
        selectedForeground,
      );
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: tile,
                matching: find.byIcon(Icons.manage_search),
              ),
            )
            .color,
        selectedForeground,
      );
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: tile,
                matching: find.text('Matched preview text'),
              ),
            )
            .style
            ?.color,
        selectedForeground,
      );
    });
  }
}

ThemeData _productionThemeFor(Brightness brightness) {
  if (brightness == Brightness.dark) {
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
    );
  }

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
  );
}

double _contrastRatio(Color foreground, Color background) {
  final foregroundLuminance = foreground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  final lighter = foregroundLuminance > backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  final darker = foregroundLuminance > backgroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}

SessionSummary _summary(String id, {String? title}) => SessionSummary(
      id: id,
      title: title ?? (id == 'newer' ? 'Newer result' : 'Local session'),
      createdAt: DateTime.utc(2026, 7, 12),
      updatedAt: DateTime.utc(2026, 7, 12),
    );

SessionSearchResult _result(String id) =>
    SessionSearchResult(summary: _summary(id));

final class _NoopSessionStorage extends SessionStorage {
  @override
  Future<void> init() async {}

  @override
  Future<List<SessionSummary>> getSessionsSummary() async => const [];
}
