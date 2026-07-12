import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:clawchat/layout/foldable_layout.dart';
import 'package:clawchat/l10n/app_strings.dart';
import 'package:clawchat/models/setup_state.dart';
import 'package:clawchat/screens/onboarding_screen.dart';
import 'package:clawchat/screens/setup_wizard_screen.dart';
import 'package:clawchat/services/bootstrap_service.dart';
import 'package:clawchat/widgets/setup_adaptive_region.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ready = BootstrapPreflight(
    bootstrapComplete: false,
    rootfsPresent: false,
    availableBytes: 512 * 1024 * 1024,
    cachedArchiveBytes: 0,
    networkConnected: true,
    networkValidated: true,
  );

  test('setup region is a thin projection of the shared foldable model', () {
    const size = Size(900, 600);
    const features = [
      DisplayFeature(
        bounds: Rect.fromLTWH(440, 0, 20, 600),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      ),
    ];
    final shared = FoldableLayout.resolve(size, features);
    expect(setupRegionForLayout(shared), shared.primary);
    expect(setupRegionForLayout(shared).left, 460);
  });

  test('zero-thickness and multiple features preserve shared-model parity', () {
    const size = Size(900, 600);
    const cases = [
      [
        DisplayFeature(
          bounds: Rect.fromLTWH(440, 0, 0, 600),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ],
      [
        DisplayFeature(
          bounds: Rect.fromLTWH(0, 300, 900, 0),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ],
      [
        DisplayFeature(
          bounds: Rect.fromLTWH(0, 0, 32, 32),
          type: DisplayFeatureType.cutout,
          state: DisplayFeatureState.unknown,
        ),
        DisplayFeature(
          bounds: Rect.fromLTWH(440, 0, 20, 600),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureFlat,
        ),
      ],
    ];
    for (final features in cases) {
      final shared = FoldableLayout.resolve(size, features);
      expect(setupRegionForLayout(shared), shared.primary);
      expect(setupRegionForLayout(shared).overlaps(shared.occlusion!), isFalse);
    }
  });

  test('setup helper contains no independent display-feature parser', () {
    final source =
        File('lib/widgets/setup_adaptive_region.dart').readAsStringSync();
    expect(source, contains('FoldableLayout.resolve'));
    expect(source, isNot(contains('feature.bounds')));
    expect(source, isNot(contains('DisplayFeatureType')));
    expect(source, isNot(contains('postureHalfOpened')));
  });

  testWidgets(
      'setup prelude keeps CTA visible with 320dp, large text, IME and resize',
      (tester) async {
    var preflightCalls = 0;
    final screen = SetupWizardScreen(
      preflightLoader: () async {
        preflightCalls += 1;
        return ready;
      },
      setupRunner: (_) async {},
    );
    await _pumpMedia(
      tester,
      screen,
      size: const Size(320, 600),
      textScale: 2,
      viewInsets: const EdgeInsets.only(bottom: 220),
    );
    await tester.pumpAndSettle();
    final action = find.byKey(const Key('setup-primary-action'));
    expect(action, findsOneWidget);
    expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    expect(tester.getBottomLeft(action).dy, lessThanOrEqualTo(380));

    await _pumpMedia(
      tester,
      screen,
      size: const Size(600, 320),
      textScale: 2,
    );
    await tester.pump();
    expect(preflightCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hinge and tabletop never cover setup primary action',
      (tester) async {
    const screen = SetupWizardScreen(
      preflightLoader: _readyPreflight,
      setupRunner: _completeSetup,
    );
    await _pumpMedia(
      tester,
      screen,
      size: const Size(900, 600),
      features: const [
        DisplayFeature(
          bounds: Rect.fromLTWH(440, 0, 20, 600),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureFlat,
        ),
      ],
    );
    await tester.pumpAndSettle();
    final bookAction = tester.getRect(
      find.byKey(const Key('setup-primary-action')),
    );
    expect(bookAction.left, greaterThanOrEqualTo(460));
    expect(bookAction.overlaps(const Rect.fromLTWH(440, 0, 20, 600)), isFalse);

    await _pumpMedia(
      tester,
      screen,
      size: const Size(700, 600),
      features: const [
        DisplayFeature(
          bounds: Rect.fromLTWH(0, 300, 700, 20),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ],
    );
    await tester.pump();
    final tabletopAction = tester.getRect(
      find.byKey(const Key('setup-primary-action')),
    );
    expect(tabletopAction.top, greaterThanOrEqualTo(320));
    expect(
      tabletopAction.overlaps(const Rect.fromLTWH(0, 300, 700, 20)),
      isFalse,
    );
  });

  testWidgets('zero-thickness folds keep form and CTA in one shared pane',
      (tester) async {
    var preflightCalls = 0;
    final screen = SetupWizardScreen(
      preflightLoader: () async {
        preflightCalls += 1;
        return ready;
      },
      setupRunner: _completeSetup,
    );
    await _pumpMedia(
      tester,
      screen,
      size: const Size(900, 600),
      features: const [
        DisplayFeature(
          bounds: Rect.fromLTWH(440, 0, 0, 600),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ],
    );
    await tester.pumpAndSettle();
    final verticalAction = tester.getRect(
      find.byKey(const Key('setup-primary-action')),
    );
    final verticalForm = tester.getRect(find.byKey(const Key('setup-scroll')));
    expect(verticalAction.left, greaterThanOrEqualTo(440));
    expect(verticalForm.left, greaterThanOrEqualTo(440));

    await _pumpMedia(
      tester,
      screen,
      size: const Size(700, 600),
      textScale: 2,
      viewInsets: const EdgeInsets.only(bottom: 220),
      features: const [
        DisplayFeature(
          bounds: Rect.fromLTWH(0, 300, 700, 0),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ],
    );
    await tester.pump();
    final horizontalAction = tester.getRect(
      find.byKey(const Key('setup-primary-action')),
    );
    final horizontalForm =
        tester.getRect(find.byKey(const Key('setup-scroll')));
    expect(horizontalAction.bottom, lessThanOrEqualTo(300));
    expect(horizontalForm.bottom, lessThanOrEqualTo(300));
    expect(preflightCalls, 1);

    await _pumpMedia(tester, screen, size: const Size(700, 600));
    await tester.pump();
    expect(preflightCalls, 1);
  });

  testWidgets('setup start is single-flight across repeated taps and resize',
      (tester) async {
    var runs = 0;
    final finish = Completer<void>();
    final screen = SetupWizardScreen(
      preflightLoader: _readyPreflight,
      setupRunner: (progress) {
        runs += 1;
        progress(const SetupState(
          step: SetupStep.downloadingRootfs,
          message: 'progress',
        ));
        return finish.future;
      },
    );
    await _pumpMedia(tester, screen, size: const Size(400, 700));
    await tester.pumpAndSettle();
    final action = find.byKey(const Key('setup-primary-action'));
    await tester.tap(action);
    await tester.tap(action);
    await tester.pump();
    await _pumpMedia(tester, screen, size: const Size(700, 400));
    await tester.pump();
    expect(runs, 1);
    finish.complete();
    await tester.pump();
  });

  testWidgets('provider errors are sanitized and manual model is required',
      (tester) async {
    var saved = 0;
    await _pumpMedia(
      tester,
      OnboardingScreen(
        isFirstRun: true,
        initialValuesLoader: () async => const OnboardingInitialValues(
          apiKey: 'test-key',
          baseUrl: 'https://provider.invalid',
        ),
        modelFetcher: ({required apiFormat, required apiKey, baseUrl}) async {
          throw Exception('endpoint secret-host.test private-body');
        },
        configSaver: (_) async => saved += 1,
      ),
      size: const Size(320, 700),
      textScale: 2,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding-primary-action')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('onboarding-primary-action')));
    await tester.pump();
    await tester.ensureVisible(find.text(AppStrings.testConnection));
    await tester.tap(find.text(AppStrings.testConnection));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.providerEndpointFailure), findsOneWidget);
    expect(find.textContaining('secret-host'), findsNothing);

    await tester.tap(find.byKey(const Key('onboarding-primary-action')));
    await tester.pump();
    expect(find.text(AppStrings.pleaseSelectModel), findsOneWidget);
    expect(saved, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('onboarding preserves fields with IME, large text and posture',
      (tester) async {
    var loads = 0;
    final screen = OnboardingScreen(
      isFirstRun: true,
      initialValuesLoader: () async {
        loads += 1;
        return const OnboardingInitialValues();
      },
      modelFetcher: ({required apiFormat, required apiKey, baseUrl}) async =>
          const ['model-a'],
      configSaver: (_) async {},
    );
    await _pumpMedia(tester, screen, size: const Size(320, 600));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding-primary-action')));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'preserved-key');
    await tester.enterText(find.byType(TextField).last, 'not a url');

    await _pumpMedia(
      tester,
      screen,
      size: const Size(320, 600),
      textScale: 2,
      viewInsets: const EdgeInsets.only(bottom: 220),
    );
    await tester.pump();
    final action = find.byKey(const Key('onboarding-primary-action'));
    expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    expect(tester.getBottomLeft(action).dy, lessThanOrEqualTo(380));
    expect(find.text('preserved-key'), findsOneWidget);
    expect(loads, 1);

    await tester.tap(action);
    await tester.pump();
    expect(find.text(AppStrings.invalidBaseUrl), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _pumpMedia(
      tester,
      screen,
      size: const Size(900, 600),
      features: const [
        DisplayFeature(
          bounds: Rect.fromLTWH(440, 0, 20, 600),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureFlat,
        ),
      ],
    );
    await tester.pump();
    expect(tester.getTopLeft(action).dx, greaterThanOrEqualTo(460));
    expect(loads, 1);
  });

  testWidgets('cancelled model lookup cannot overwrite preserved form state',
      (tester) async {
    final models = Completer<List<String>>();
    final screen = OnboardingScreen(
      isFirstRun: true,
      initialValuesLoader: () async => const OnboardingInitialValues(
        apiKey: 'test-key',
        baseUrl: 'https://provider.invalid',
      ),
      modelFetcher: ({required apiFormat, required apiKey, baseUrl}) =>
          models.future,
      configSaver: (_) async {},
    );
    await _pumpMedia(tester, screen, size: const Size(400, 700));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding-primary-action')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('onboarding-primary-action')));
    await tester.pump();
    await tester.tap(find.text(AppStrings.testConnection));
    await tester.pump();
    await tester.tap(find.text(AppStrings.cancel));
    await tester.pump();
    models.complete(const ['late-model']);
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.providerFetchCancelled), findsOneWidget);
    expect(find.text('late-model'), findsNothing);

    await _pumpMedia(tester, screen, size: const Size(700, 400));
    await tester.pump();
    expect(find.text(AppStrings.providerFetchCancelled), findsOneWidget);
  });
}

Future<BootstrapPreflight> _readyPreflight() async => const BootstrapPreflight(
      bootstrapComplete: false,
      rootfsPresent: false,
      availableBytes: 512 * 1024 * 1024,
      cachedArchiveBytes: 0,
      networkConnected: true,
      networkValidated: true,
    );

Future<void> _completeSetup(void Function(SetupState) progress) async {
  progress(const SetupState(step: SetupStep.complete, progress: 1));
}

Future<void> _pumpMedia(
  WidgetTester tester,
  Widget child, {
  required Size size,
  double textScale = 1,
  EdgeInsets viewInsets = EdgeInsets.zero,
  List<DisplayFeature> features = const [],
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  return tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
          viewInsets: viewInsets,
          displayFeatures: features,
        ),
        child: child,
      ),
    ),
  );
}
