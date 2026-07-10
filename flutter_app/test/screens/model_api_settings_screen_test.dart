import 'dart:async';

import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/models/provider_profile.dart';
import 'package:clawchat/screens/model_api_settings_screen.dart';
import 'package:clawchat/services/fallback_model_selection.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> secureStorage;
  late PreferencesService prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTesting();
    secureStorage = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      final key = args['key']?.toString();
      switch (call.method) {
        case 'read':
          return key == null ? null : secureStorage[key];
        case 'write':
          if (key != null) secureStorage[key] = args['value']?.toString() ?? '';
          return null;
        case 'delete':
          if (key != null) secureStorage.remove(key);
          return null;
        case 'deleteAll':
          secureStorage.clear();
          return null;
        case 'containsKey':
          return key != null && secureStorage.containsKey(key);
        case 'readAll':
          return Map<String, String>.from(secureStorage);
      }
      return null;
    });
    prefs = PreferencesService();
    await prefs.init();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    PreferencesService.resetForTesting();
  });

  testWidgets('Add/Edit uses selectable known model and target default',
      (tester) async {
    await _installProfiles(prefs);
    await _pumpSettings(
      tester,
      modelFetcher: ({
        required String apiFormat,
        required String apiKey,
        String? baseUrl,
      }) async {
        return baseUrl?.contains('fallback-b') == true
            ? ['known-b']
            : ['known-a', 'known-shared'];
      },
    );

    await _openAddDialog(tester);

    expect(
        find.byKey(const ValueKey('fallback_model_selector')), findsOneWidget);
    expect(find.text(AppStrings.fallbackModelOverride), findsNothing);
    expect(find.textContaining(AppStrings.fallbackUseTargetDefault),
        findsOneWidget);

    await _selectDropdownValue(
      tester,
      const ValueKey('fallback_model_selector'),
      'known-a',
    );
    await _saveDialog(tester);

    var primary = _profileById(prefs, 'primary');
    expect(primary.fallbackTargets, hasLength(1));
    expect(primary.fallbackTargets.single.targetProfileId, 'fallback-a');
    expect(primary.fallbackTargets.single.modelOverride, 'known-a');

    await tester.tap(find.textContaining('known-a').last);
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('fallback_model_selector')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('fallback_custom_model_input')),
      findsNothing,
    );
    await _selectDropdownValue(
      tester,
      const ValueKey('fallback_model_selector'),
      AppStrings.fallbackUseTargetDefault,
      containsText: true,
    );
    await _saveDialog(tester);

    primary = _profileById(prefs, 'primary');
    expect(primary.fallbackTargets.single.modelOverride, isEmpty);
  });

  testWidgets('Edit preserves manual custom model input', (tester) async {
    await _installProfiles(
      prefs,
      initialFallback: const ModelFallbackTarget(
        targetProfileId: 'fallback-a',
        modelOverride: 'custom/vendor-model',
      ),
    );
    await _pumpSettings(
      tester,
      modelFetcher: ({
        required String apiFormat,
        required String apiKey,
        String? baseUrl,
      }) async =>
          ['known-a'],
    );

    await tester.tap(find.textContaining('custom/vendor-model').last);
    await tester.pumpAndSettle();

    final customField = find.byKey(
      const ValueKey('fallback_custom_model_input'),
    );
    expect(customField, findsOneWidget);
    expect(
      tester.widget<TextField>(customField).controller?.text,
      'custom/vendor-model',
    );

    await tester.enterText(customField, 'custom/new-model');
    await _saveDialog(tester);

    final primary = _profileById(prefs, 'primary');
    expect(primary.fallbackTargets.single.modelOverride, 'custom/new-model');
  });

  testWidgets('empty model fetch keeps default and custom selections usable',
      (tester) async {
    await _installProfiles(prefs);
    await _pumpSettings(
      tester,
      modelFetcher: ({
        required String apiFormat,
        required String apiKey,
        String? baseUrl,
      }) async =>
          const [],
    );

    await _exerciseNoCatalogCustomSave(
      tester,
      prefs,
      customModel: 'empty-fetch/custom-model',
    );
  });

  testWidgets('throwing model fetch keeps default and custom selections usable',
      (tester) async {
    await _installProfiles(prefs);
    await _pumpSettings(
      tester,
      modelFetcher: ({
        required String apiFormat,
        required String apiKey,
        String? baseUrl,
      }) async {
        throw StateError('test model fetch failure');
      },
    );

    await _exerciseNoCatalogCustomSave(
      tester,
      prefs,
      customModel: 'throwing-fetch/custom-model',
    );
  });

  testWidgets('former sentinel strings persist as literal known model ids',
      (tester) async {
    const formerDefaultSentinel = '__target_profile_default__';
    const formerCustomSentinel = '__custom_model_override__';
    await _installProfiles(prefs);
    await _pumpSettings(
      tester,
      modelFetcher: ({
        required String apiFormat,
        required String apiKey,
        String? baseUrl,
      }) async =>
          const [formerDefaultSentinel, formerCustomSentinel],
    );

    await _openAddDialog(tester);
    await _selectDropdownValue(
      tester,
      const ValueKey('fallback_model_selector'),
      formerDefaultSentinel,
    );
    await _saveDialog(tester);

    var primary = _profileById(prefs, 'primary');
    expect(primary.fallbackTargets.single.modelOverride, formerDefaultSentinel);

    await tester.tap(find.textContaining(formerDefaultSentinel).last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('fallback_custom_model_input')),
      findsNothing,
    );
    await _selectDropdownValue(
      tester,
      const ValueKey('fallback_model_selector'),
      formerCustomSentinel,
    );
    await _saveDialog(tester);

    primary = _profileById(prefs, 'primary');
    expect(primary.fallbackTargets.single.modelOverride, formerCustomSentinel);
  });

  testWidgets('A-B-A target changes ignore every older fetch generation',
      (tester) async {
    await _installProfiles(prefs);
    final oldestA = Completer<List<String>>();
    final staleB = Completer<List<String>>();
    final newestA = Completer<List<String>>();
    final requestedTargets = <String>[];
    var aRequestCount = 0;

    await _pumpSettings(
      tester,
      modelFetcher: ({
        required String apiFormat,
        required String apiKey,
        String? baseUrl,
      }) {
        final target = baseUrl?.contains('fallback-b') == true ? 'b' : 'a';
        requestedTargets.add(target);
        if (target == 'b') return staleB.future;
        aRequestCount += 1;
        return aRequestCount == 1 ? oldestA.future : newestA.future;
      },
    );

    await tester.tap(find.text(AppStrings.addFallbackTarget));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(requestedTargets, ['a']);

    await _selectDropdownValue(
      tester,
      const ValueKey('fallback_target_profile_selector'),
      'Fallback B',
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(requestedTargets, ['a', 'b']);

    await _selectDropdownValue(
      tester,
      const ValueKey('fallback_target_profile_selector'),
      'Fallback A',
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(requestedTargets, ['a', 'b', 'a']);

    newestA.complete(['newest-a']);
    await tester.pump();
    await tester.pumpAndSettle();
    _expectModelRefreshEnabled(tester);

    await _expectModelOptions(
      tester,
      present: 'newest-a',
      absent: ['oldest-a', 'stale-b'],
    );

    oldestA.complete(['oldest-a']);
    await tester.pump();
    await tester.pumpAndSettle();
    _expectModelRefreshEnabled(tester);

    await _expectModelOptions(
      tester,
      present: 'newest-a',
      absent: ['oldest-a', 'stale-b'],
    );

    staleB.complete(['stale-b']);
    await tester.pump();
    await tester.pumpAndSettle();
    _expectModelRefreshEnabled(tester);

    await _selectDropdownValue(
      tester,
      const ValueKey('fallback_model_selector'),
      'newest-a',
    );
    await _saveDialog(tester);

    final primary = _profileById(prefs, 'primary');
    expect(primary.fallbackTargets.single.targetProfileId, 'fallback-a');
    expect(primary.fallbackTargets.single.modelOverride, 'newest-a');
  });

  testWidgets('stale A error cannot clear newest A fetching state',
      (tester) async {
    await _installProfiles(prefs);
    final oldestA = Completer<List<String>>();
    final staleB = Completer<List<String>>();
    final newestA = Completer<List<String>>();
    var aRequestCount = 0;

    await _pumpSettings(
      tester,
      modelFetcher: ({
        required String apiFormat,
        required String apiKey,
        String? baseUrl,
      }) {
        if (baseUrl?.contains('fallback-b') == true) return staleB.future;
        aRequestCount += 1;
        return aRequestCount == 1 ? oldestA.future : newestA.future;
      },
    );

    await tester.tap(find.text(AppStrings.addFallbackTarget));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _selectDropdownValue(
      tester,
      const ValueKey('fallback_target_profile_selector'),
      'Fallback B',
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 300));
    await _selectDropdownValue(
      tester,
      const ValueKey('fallback_target_profile_selector'),
      'Fallback A',
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 300));
    _expectModelRefreshEnabled(tester, enabled: false);

    oldestA.completeError(StateError('stale A fetch failure'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    _expectModelRefreshEnabled(tester, enabled: false);

    newestA.complete(['newest-a']);
    await tester.pump();
    await tester.pumpAndSettle();
    _expectModelRefreshEnabled(tester);

    staleB.complete(['stale-b']);
    await tester.pump();
    await tester.pumpAndSettle();
    await _expectModelOptions(
      tester,
      present: 'newest-a',
      absent: ['stale-b'],
    );
  });
}

Future<void> _exerciseNoCatalogCustomSave(
  WidgetTester tester,
  PreferencesService prefs, {
  required String customModel,
}) async {
  await _openAddDialog(tester);
  expect(find.text(AppStrings.fallbackNoModelCatalog), findsOneWidget);
  expect(
    find.textContaining(AppStrings.fallbackUseTargetDefault),
    findsOneWidget,
  );

  await _selectDropdownValue(
    tester,
    const ValueKey('fallback_model_selector'),
    AppStrings.fallbackCustomModel,
  );
  expect(
    find.byKey(const ValueKey('fallback_custom_model_input')),
    findsOneWidget,
  );
  await _selectDropdownValue(
    tester,
    const ValueKey('fallback_model_selector'),
    AppStrings.fallbackUseTargetDefault,
    containsText: true,
  );
  expect(
    find.byKey(const ValueKey('fallback_custom_model_input')),
    findsNothing,
  );
  await _selectDropdownValue(
    tester,
    const ValueKey('fallback_model_selector'),
    AppStrings.fallbackCustomModel,
  );
  await tester.enterText(
    find.byKey(const ValueKey('fallback_custom_model_input')),
    customModel,
  );
  await _saveDialog(tester);

  final primary = _profileById(prefs, 'primary');
  expect(primary.fallbackTargets.single.modelOverride, customModel);
}

Future<void> _expectModelOptions(
  WidgetTester tester, {
  required String present,
  required List<String> absent,
}) async {
  await tester.tap(find.byKey(const ValueKey('fallback_model_selector')));
  await tester.pumpAndSettle();
  expect(find.text(present), findsWidgets);
  for (final model in absent) {
    expect(find.text(model), findsNothing);
  }
  await tester.tap(find.text(present).last);
  await tester.pumpAndSettle();
}

void _expectModelRefreshEnabled(
  WidgetTester tester, {
  bool enabled = true,
}) {
  final refreshButton = tester.widget<IconButton>(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            widget.tooltip == AppStrings.fetchModelsButton,
      ),
    ),
  );
  expect(refreshButton.onPressed, enabled ? isNotNull : isNull);
}

Future<void> _installProfiles(
  PreferencesService prefs, {
  ModelFallbackTarget? initialFallback,
}) async {
  final primary = ProviderProfile.defaults(name: 'Primary').copyWith(
    id: 'primary',
    apiFormat: ProviderProfile.openaiFormat,
    apiKey: 'test-primary-key',
    baseUrl: 'https://primary.invalid',
    model: 'primary-default',
    fallbackTargets: initialFallback == null ? const [] : [initialFallback],
  );
  final fallbackA = ProviderProfile.defaults(name: 'Fallback A').copyWith(
    id: 'fallback-a',
    apiFormat: ProviderProfile.openaiFormat,
    apiKey: 'test-fallback-a-key',
    baseUrl: 'https://fallback-a.invalid',
    model: 'fallback-a-default',
  );
  final fallbackB = ProviderProfile.defaults(name: 'Fallback B').copyWith(
    id: 'fallback-b',
    apiFormat: ProviderProfile.openaiFormat,
    apiKey: 'test-fallback-b-key',
    baseUrl: 'https://fallback-b.invalid',
    model: 'fallback-b-default',
  );
  await prefs.setProfiles([primary, fallbackA, fallbackB]);
  await prefs.setActiveProfileId('primary');
}

Future<void> _pumpSettings(
  WidgetTester tester, {
  required ModelListFetcher modelFetcher,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 1800);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: ModelApiSettingsScreen(modelFetcher: modelFetcher),
    ),
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(AppStrings.addFallbackTarget));
  await tester.pumpAndSettle();
}

Future<void> _openAddDialog(WidgetTester tester) async {
  await tester.tap(find.text(AppStrings.addFallbackTarget));
  await tester.pumpAndSettle();
}

Future<void> _selectDropdownValue(
  WidgetTester tester,
  Key dropdownKey,
  String text, {
  bool containsText = false,
  bool settle = true,
}) async {
  await tester.tap(find.byKey(dropdownKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  final option = containsText ? find.textContaining(text) : find.text(text);
  await tester.tap(option.last);
  await tester.pump();
  if (settle) await tester.pumpAndSettle();
}

Future<void> _saveDialog(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('fallback_target_save')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pumpAndSettle();
}

ProviderProfile _profileById(PreferencesService prefs, String id) {
  return prefs.profiles.firstWhere((profile) => profile.id == id);
}
