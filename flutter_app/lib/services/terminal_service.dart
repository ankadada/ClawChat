import 'dart:io';
import 'package:flutter/services.dart';
import '../constants.dart';
import 'native_bridge.dart';

class TerminalService {
  static const _channel = MethodChannel(AppConstants.channelName);

  static const _fakeKernelRelease = '6.17.0-PRoot-Distro';
  static const _fakeKernelVersion =
      '#1 SMP PREEMPT_DYNAMIC Fri, 10 Oct 2025 00:00:00 +0000';

  static Future<Map<String, String>> getProotShellConfig({
    bool mountStorage = true,
  }) async {
    try { await NativeBridge.setupDirs(); } catch (_) {
      // Best-effort: dirs may already exist
    }
    try { await NativeBridge.writeResolv(); } catch (_) {
      // Best-effort: resolv.conf may already be configured
    }

    final filesDir = await _channel.invokeMethod<String>('getFilesDir') ?? '';
    final nativeLibDir = await _channel.invokeMethod<String>('getNativeLibDir') ?? '';

    final rootfsDir = '$filesDir/rootfs/alpine';
    final tmpDir = '$filesDir/tmp';
    final configDir = '$filesDir/config';
    final homeDir = '$filesDir/home';
    final prootPath = '$nativeLibDir/libproot.so';
    final libDir = '$filesDir/lib';
    final machine = await _getMachineString();

    const resolvContent = 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n';
    try {
      final resolvFile = File('$configDir/resolv.conf');
      if (!resolvFile.existsSync()) {
        Directory(configDir).createSync(recursive: true);
        resolvFile.writeAsStringSync(resolvContent);
      }
    } catch (_) {
      // Best-effort: config dir may not be writable
    }
    try {
      final rootfsResolv = File('$rootfsDir/etc/resolv.conf');
      if (!rootfsResolv.existsSync()) {
        rootfsResolv.parent.createSync(recursive: true);
        rootfsResolv.writeAsStringSync(resolvContent);
      }
    } catch (_) {
      // Best-effort: rootfs etc/ may not be writable
    }

    final storageGranted =
        mountStorage ? await NativeBridge.hasStoragePermission() : false;

    return {
      'executable': prootPath,
      'rootfsDir': rootfsDir,
      'tmpDir': tmpDir,
      'configDir': configDir,
      'homeDir': homeDir,
      'libDir': libDir,
      'nativeLibDir': nativeLibDir,
      'storageGranted': storageGranted.toString(),
      'PROOT_TMP_DIR': tmpDir,
      'PROOT_LOADER': '$nativeLibDir/libprootloader.so',
      'PROOT_LOADER_32': '$nativeLibDir/libprootloader32.so',
      'LD_LIBRARY_PATH': '$libDir:$nativeLibDir',
      'machine': machine,
    };
  }

  static List<String> buildProotArgs(Map<String, String> config,
      {int columns = 80, int rows = 24, bool mountStorage = true}) {
    final procFakes = '${config['configDir']}/proc_fakes';
    final sysFakes = '${config['configDir']}/sys_fakes';
    final rootfsDir = config['rootfsDir']!;

    final machine = config['machine'] ?? 'aarch64';

    final kernelRelease = '\\Linux\\localhost\\$_fakeKernelRelease'
        '\\$_fakeKernelVersion\\$machine\\localdomain\\-1\\';

    final args = <String>[
      '--change-id=0:0',
      '--sysvipc',
      '--kernel-release=$kernelRelease',
      '--link2symlink',
      '-L',
      '--kill-on-exit',
      '--rootfs=$rootfsDir',
      '--cwd=/root',
      '--bind=/dev',
      '--bind=/dev/urandom:/dev/random',
      '--bind=/proc',
      '--bind=/proc/self/fd:/dev/fd',
      '--bind=/proc/self/fd/0:/dev/stdin',
      '--bind=/proc/self/fd/1:/dev/stdout',
      '--bind=/proc/self/fd/2:/dev/stderr',
      '--bind=/sys',
      '--bind=$procFakes/loadavg:/proc/loadavg',
      '--bind=$procFakes/stat:/proc/stat',
      '--bind=$procFakes/uptime:/proc/uptime',
      '--bind=$procFakes/version:/proc/version',
      '--bind=$procFakes/vmstat:/proc/vmstat',
      '--bind=$procFakes/cap_last_cap:/proc/sys/kernel/cap_last_cap',
      '--bind=$procFakes/max_user_watches:/proc/sys/fs/inotify/max_user_watches',
      '--bind=$procFakes/fips_enabled:/proc/sys/crypto/fips_enabled',
      '--bind=$rootfsDir/tmp:/dev/shm',
      '--bind=$sysFakes/empty:/sys/fs/selinux',
      '--bind=${config['configDir']}/resolv.conf:/etc/resolv.conf',
      '--bind=${config['homeDir']}:/root/home',
    ];

    if (mountStorage && config['storageGranted'] == 'true') {
      args.addAll([
        '--bind=/storage:/storage',
        '--bind=/storage/emulated/0:/sdcard',
      ]);
    }

    args.addAll([
      '/usr/bin/env', '-i',
      'HOME=/root',
      'USER=root',
      'LANG=C.UTF-8',
      'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      'TERM=xterm-256color',
      'TMPDIR=/tmp',
      'COLUMNS=$columns',
      'LINES=$rows',
      '/bin/bash',
      '-l',
    ]);

    return args;
  }

  static Map<String, String> buildHostEnv(Map<String, String> config) {
    return {
      'PROOT_TMP_DIR': config['PROOT_TMP_DIR']!,
      'PROOT_LOADER': config['PROOT_LOADER']!,
      'PROOT_LOADER_32': config['PROOT_LOADER_32']!,
      'LD_LIBRARY_PATH': config['LD_LIBRARY_PATH']!,
    };
  }

  static Future<String> _getMachineString() async {
    try {
      return _machineForArch(await NativeBridge.getArch());
    } catch (_) {
      return 'aarch64';
    }
  }

  static String _machineForArch(String arch) {
    return switch (arch) {
      'arm64-v8a' => 'aarch64',
      'armeabi-v7a' => 'armv7l',
      'x86_64' => 'x86_64',
      'x86' => 'i686',
      _ => arch.isEmpty ? 'aarch64' : arch,
    };
  }
}
