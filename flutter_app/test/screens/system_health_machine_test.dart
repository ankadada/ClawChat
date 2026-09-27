import 'dart:io';

import 'package:clawchat/constants.dart';
import 'package:clawchat/models/chat_models.dart';
import 'package:clawchat/models/tool_command_lifecycle.dart';
import 'package:clawchat/providers/chat_provider.dart';
import 'package:clawchat/screens/dashboard_screen.dart';
import 'package:clawchat/services/machine_health_probe.dart';
import 'package:clawchat/services/preferences_service.dart';
import 'package:clawchat/services/session_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryStorage extends SessionStorage {
  @override
  Future<void> init() async {}

  @override
  Future<List<SessionSummary>> getSessionsSummary() async => const [];

  @override
  Future<ChatSession?> getSession(String id) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MachineHealthProbe', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('machine-health-');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    MachineHealthProbe probeFor(String rootfsPath, {int? freeBytes}) =>
        MachineHealthProbe(
          filesDir: () async => root.path,
          bootstrapStatus: () async => <String, dynamic>{
            'rootfsPath': rootfsPath,
            if (freeBytes != null) 'availableBytes': freeBytes,
          },
        );

    test('disk usage covers the rootfs and reports the workspace separately',
        () async {
      final rootfs = Directory('${root.path}/rootfs/alpine')
        ..createSync(recursive: true);
      File('${rootfs.path}/bin-busybox').writeAsBytesSync(List.filled(1024, 0));
      final workspace = Directory('${rootfs.path}/root/workspace')
        ..createSync(recursive: true);
      File('${workspace.path}/notes.txt').writeAsBytesSync(List.filled(512, 0));

      final disk = await probeFor(rootfs.path, freeBytes: 123456).diskUsage();

      expect(disk.known, isTrue);
      expect(disk.rootfsBytes, 1024 + 512);
      expect(disk.workspaceBytes, 512);
      expect(disk.freeBytes, 123456);
      expect(disk.usedBytes, disk.rootfsBytes);
    });

    test('a missing rootfs reports zero bytes rather than a fabricated value',
        () async {
      final disk = await probeFor('${root.path}/rootfs/alpine').diskUsage();
      // The rootfs directory is absent, so both sizes are zero but the walk
      // legitimately succeeded; the tile still reports a real 0 rather than a
      // fabricated value. Free space is simply unknown here.
      expect(disk.known, isTrue);
      expect(disk.freeBytes, isNull);
    });

    test('disk usage is unknown when no local path can be resolved', () async {
      final probe = MachineHealthProbe(
        filesDir: () async => throw StateError('no files dir'),
        bootstrapStatus: () async => throw StateError('no native status'),
      );
      final disk = await probe.diskUsage();
      expect(disk.known, isFalse);
      expect(disk.usedBytes, isNull);
    });

    test('dns is ready when resolv.conf has a usable nameserver', () async {
      Directory('${root.path}/config').createSync(recursive: true);
      File('${root.path}/config/resolv.conf')
          .writeAsStringSync('# managed\nnameserver 8.8.8.8\n');
      expect(
        await probeFor('${root.path}/rootfs/alpine').dnsStatus(),
        MachineDnsStatus.ready,
      );
    });

    test('dns falls back to the rootfs copy', () async {
      final resolv = File('${root.path}/rootfs/alpine/etc/resolv.conf');
      resolv.parent.createSync(recursive: true);
      resolv.writeAsStringSync('nameserver fd00::1\n');
      expect(
        await probeFor('${root.path}/rootfs/alpine').dnsStatus(),
        MachineDnsStatus.ready,
      );
    });

    test('comments and placeholder servers are not ready DNS', () async {
      Directory('${root.path}/config').createSync(recursive: true);
      File('${root.path}/config/resolv.conf')
          .writeAsStringSync('# nameserver 8.8.8.8\nnameserver 0.0.0.0\n');
      expect(
        await probeFor('${root.path}/rootfs/alpine').dnsStatus(),
        MachineDnsStatus.missing,
      );
    });

    test('dns is unknown when the base dir cannot be resolved', () async {
      final probe = MachineHealthProbe(
        filesDir: () async => throw StateError('no files dir'),
        bootstrapStatus: () async => throw StateError('no native status'),
      );
      expect(await probe.dnsStatus(), MachineDnsStatus.unknown);
    });

    test('formatHealthBytes never invents precision', () {
      expect(formatHealthBytes(0), '0 B');
      expect(formatHealthBytes(2048), '2 KB');
      expect(formatHealthBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatHealthBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });
  });

  group('System Health machine tiles', () {
    late ChatProvider provider;
    const native = MethodChannel(AppConstants.channelName);
    const secure =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      PreferencesService.resetForTesting();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(native, (call) async {
        if (call.method == 'consumePendingNavigateToSession') return null;
        return true;
      });
      messenger.setMockMethodCallHandler(secure, (call) async {
        if (call.method == 'readAll') return <String, String>{};
        if (call.method == 'containsKey') return false;
        return null;
      });
      provider = ChatProvider(storage: _MemoryStorage());
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });

    tearDown(() async {
      provider.dispose();
      PreferencesService.resetForTesting();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(native, null);
      messenger.setMockMethodCallHandler(secure, null);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    Future<void> pumpHealth(
      WidgetTester tester,
      SystemHealthSnapshot snapshot,
    ) async {
      // The machine tiles sit after the existing health tiles, so give the test
      // a tall viewport instead of scrolling in every assertion.
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 2400);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: MaterialApp(
            home: DashboardScreen(loadForTesting: () async => snapshot),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('healthy disk, DNS and an exited last command render ready',
        (tester) async {
      await pumpHealth(
        tester,
        const SystemHealthSnapshot(
          runtime: SystemHealthKind.ready,
          runtimeDetail: '运行时已就绪',
          updateState: null,
          updatesKnown: true,
          extensionCount: 1,
          extensionsKnown: true,
          diskUsage: MachineDiskUsage(
            rootfsBytes: 5 * 1024 * 1024,
            workspaceBytes: 1024 * 1024,
            freeBytes: 200 * 1024 * 1024,
          ),
          dnsStatus: MachineDnsStatus.ready,
          lastCommand: MachineLastCommand.exited,
        ),
      );

      expect(
        find.textContaining(
          '就绪 · rootfs 与工作区共 5.0 MB；工作区 1.0 MB；可用 200.0 MB',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('就绪 · resolv.conf 已配置可用的名称服务器'),
        findsOneWidget,
      );
      expect(find.textContaining('就绪 · 上一条命令已经结束'), findsOneWidget);
    });

    testWidgets('low free space asks the user to act', (tester) async {
      await pumpHealth(
        tester,
        const SystemHealthSnapshot(
          runtime: SystemHealthKind.ready,
          runtimeDetail: '运行时已就绪',
          updateState: null,
          updatesKnown: true,
          extensionCount: 1,
          extensionsKnown: true,
          diskUsage: MachineDiskUsage(
            rootfsBytes: 5 * 1024 * 1024,
            freeBytes: 10 * 1024 * 1024,
          ),
        ),
      );

      expect(
        find.textContaining('需要处理 · rootfs 与工作区共 5.0 MB'),
        findsOneWidget,
      );
    });

    testWidgets('unknown disk and DNS never render as ready', (tester) async {
      await pumpHealth(
        tester,
        const SystemHealthSnapshot(
          runtime: SystemHealthKind.ready,
          runtimeDetail: '运行时已就绪',
          updateState: null,
          updatesKnown: true,
          extensionCount: 1,
          extensionsKnown: true,
        ),
      );

      expect(
        find.textContaining('未知 · 无法读取 rootfs 与工作区占用'),
        findsOneWidget,
      );
      expect(find.textContaining('未知 · 无法读取 DNS 配置状态'), findsOneWidget);
    });

    testWidgets(
        'a missing resolv.conf and an unknown last command ask for action',
        (tester) async {
      await pumpHealth(
        tester,
        const SystemHealthSnapshot(
          runtime: SystemHealthKind.ready,
          runtimeDetail: '运行时已就绪',
          updateState: null,
          updatesKnown: true,
          extensionCount: 1,
          extensionsKnown: true,
          diskUsage: MachineDiskUsage(rootfsBytes: 4096),
          dnsStatus: MachineDnsStatus.missing,
          lastCommand: MachineLastCommand.unknown,
        ),
      );

      expect(
        find.textContaining('需要处理 · 缺少可用的 resolv.conf'),
        findsOneWidget,
      );
      expect(
        find.textContaining('需要处理 · 上一条命令可能没有完成，结果未知；不会静默重试'),
        findsOneWidget,
      );
    });

    testWidgets('a fresh machine reports no command without a score',
        (tester) async {
      await pumpHealth(
        tester,
        const SystemHealthSnapshot(
          runtime: SystemHealthKind.ready,
          runtimeDetail: '运行时已就绪',
          updateState: null,
          updatesKnown: true,
          extensionCount: 0,
          extensionsKnown: true,
          diskUsage: MachineDiskUsage(rootfsBytes: 4096),
          dnsStatus: MachineDnsStatus.ready,
          lastCommand: MachineLastCommand.none,
        ),
      );

      expect(find.textContaining('就绪 · 本次运行还没有执行过命令'), findsOneWidget);
      expect(find.text('健康分数'), findsNothing);
    });
  });
}
