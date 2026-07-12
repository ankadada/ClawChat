import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'app.dart' show ClawChatApp, initThemeFromPreferences;
import 'l10n/app_strings.dart';
import 'services/app_http.dart';
import 'services/update_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    if (kDebugMode) {
      debugPrint('FlutterError: ${details.exception}');
      debugPrint(details.stack.toString());
    }
  };

  ErrorWidget.builder = (FlutterErrorDetails details) {
    if (kDebugMode) {
      return ErrorWidget(details.exception);
    }
    return Material(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            AppStrings.renderError,
            style: TextStyle(color: Colors.red.shade700),
          ),
        ),
      ),
    );
  };

  runZonedGuarded(() async {
    final runtimeInfo = await AppRuntimeInfo.load();
    AppHttpOverrides.install(runtimeInfo);
    final httpRegistry = AppHttpClientRegistry(runtimeInfo: runtimeInfo);
    AppHttpClientRegistry.installForApp(httpRegistry);
    try {
      await UpdateService().reconcileAtStartup();
    } catch (_) {
      // Durable evidence is retained for the next idempotent reconciliation.
    }
    await initThemeFromPreferences();
    runApp(ClawChatApp(
      runtimeInfo: runtimeInfo,
      httpRegistry: httpRegistry,
    ));
  }, (error, stackTrace) {
    if (kDebugMode) {
      debugPrint('Uncaught error: $error');
      debugPrint('$stackTrace');
    } else {
      // Crash reporting is deferred until post-launch provider selection.
      debugPrint('Error: $error');
    }
  });
}
