import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'app.dart' show ClawChatApp, initThemeFromPreferences;

// TODO: i18n - The app mixes Chinese and English strings throughout.
// Consider using flutter_localizations + intl for proper internationalization.

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
            '渲染错误',
            style: TextStyle(color: Colors.red.shade700),
          ),
        ),
      ),
    );
  };

  runZonedGuarded(() async {
    await initThemeFromPreferences();
    runApp(const ClawChatApp());
  }, (error, stackTrace) {
    if (kDebugMode) {
      debugPrint('Uncaught error: $error');
      debugPrint('$stackTrace');
    } else {
      // TODO: Add crash reporting (e.g., Firebase Crashlytics)
      debugPrint('Error: $error');
    }
  });
}
