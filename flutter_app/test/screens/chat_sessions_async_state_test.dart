import 'dart:async';

import 'package:clawchat/l10n/app_strings.dart';
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
}

SessionSummary _summary(String id) => SessionSummary(
      id: id,
      title: id == 'newer' ? 'Newer result' : 'Local session',
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
