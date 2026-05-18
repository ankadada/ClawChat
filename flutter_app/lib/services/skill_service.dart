import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'native_bridge.dart';

class SkillInfo {
  final String name;
  final String description;
  final String path;
  bool enabled;

  SkillInfo({
    required this.name,
    required this.description,
    required this.path,
    this.enabled = true,
  });
}

class SkillService {
  static const _skillsDir = '/root/workspace/skills';
  static const _kDisabledKey = 'disabled_skills';
  static final _safeSkillNamePattern = RegExp(r'^[A-Za-z0-9._-]+$');

  /// Loads the persisted set of disabled skill names from SharedPreferences.
  static Future<Set<String>> _loadDisabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kDisabledKey);
      if (raw == null || raw.isEmpty) return {};
      return Set<String>.from(jsonDecode(raw) as List);
    } catch (_) {
      return {};
    }
  }

  /// Persist the enabled state of a skill.
  static Future<void> setSkillEnabled(String name, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    final disabled = await _loadDisabled();
    if (enabled) {
      disabled.remove(name);
    } else {
      disabled.add(name);
    }
    await prefs.setString(_kDisabledKey, jsonEncode(disabled.toList()));
  }

  /// Scans the skills directory for SKILL.md files and returns their metadata.
  static Future<List<SkillInfo>> scanSkills() async {
    try {
      final disabled = await _loadDisabled();
      final output = await NativeBridge.runInProot(
        'find $_skillsDir -name "SKILL.md" -type f 2>/dev/null',
      );
      final paths = output.trim().split('\n').where((p) => p.isNotEmpty).toList();

      final skills = <SkillInfo>[];
      for (final path in paths) {
        try {
          final content = await NativeBridge.runInProot('head -10 "$path"');
          final name = _extractYamlField(content, 'name') ??
              path.split('/').reversed.skip(1).first;
          final description = _extractYamlField(content, 'description') ?? '';
          skills.add(SkillInfo(
            name: name,
            description: description,
            path: path,
            enabled: !disabled.contains(name),
          ));
        } catch (_) {}
      }
      return skills;
    } catch (_) {
      return [];
    }
  }

  /// Builds a skill index section for the system prompt.
  static String buildSkillIndex(List<SkillInfo> skills) {
    final enabled = skills.where((s) => s.enabled).toList();
    if (enabled.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln('\n<available-skills>');
    buffer.writeln('The following skills are available. To use a skill, read its full SKILL.md file using the read_file tool for detailed instructions.');
    buffer.writeln('');
    for (final skill in enabled) {
      buffer.writeln('- ${skill.name}: ${skill.description} (${skill.path})');
    }
    buffer.writeln('</available-skills>');
    return buffer.toString();
  }

  /// Downloads a skill from a URL (git repo or tar.gz) into the skills directory.
  static Future<String> importSkillFromUrl(String url) async {
    final safeUrl = url.trim();
    final skillName = _extractSkillNameFromUrl(safeUrl);
    final targetDir = _targetDirForSkillName(skillName);
    final quotedUrl = _shellQuote(safeUrl);
    final quotedTarget = _shellQuote(targetDir);

    if (safeUrl.endsWith('.git') || safeUrl.contains('github.com')) {
      final output = await NativeBridge.runInProot(
        'git clone $quotedUrl $quotedTarget 2>&1 || echo "CLONE_FAILED"',
      );
      if (output.contains('CLONE_FAILED')) {
        throw Exception('Git clone failed: $output');
      }
      return skillName;
    } else {
      // Download and extract tar.gz
      await NativeBridge.runInProot(
        'mkdir -p $quotedTarget && curl -fsSL $quotedUrl | tar xz -C $quotedTarget 2>&1',
      );
      return skillName;
    }
  }

  /// Imports a skill from a local directory or zip/tar.gz file on the device.
  static Future<String> importSkillFromLocalPath(String sourcePath) async {
    final safePath = sourcePath.trim();
    final name = _normalizeSkillName(safePath.split('/').last);
    final targetDir = _targetDirForSkillName(name);
    final quotedPath = _shellQuote(safePath);
    final quotedTarget = _shellQuote(targetDir);

    if (sourcePath.endsWith('.tar.gz') || sourcePath.endsWith('.tgz')) {
      await NativeBridge.runInProot(
        'mkdir -p $quotedTarget && tar xzf $quotedPath -C $quotedTarget',
      );
    } else if (sourcePath.endsWith('.zip')) {
      await NativeBridge.runInProot(
        'mkdir -p $quotedTarget && unzip -o $quotedPath -d $quotedTarget',
      );
    } else {
      // Assume it's a directory, copy it
      await NativeBridge.runInProot(
        'cp -r $quotedPath $quotedTarget',
      );
    }
    return name;
  }

  /// Install preset skills bundled with the app into the proot workspace.
  /// Only installs skills that don't already exist (won't overwrite user customizations).
  static Future<int> installPresetSkills() async {
    const presets = ['github', 'web-search', 'code-review', 'translator', 'file-manager', 'system-info', 'gws-calendar', 'gws-gmail', 'gws-drive'];
    int installed = 0;

    for (final name in presets) {
      final targetDir = '$_skillsDir/$name';
      try {
        // Check if already installed
        final checkOutput = await NativeBridge.runInProot('test -f "$targetDir/SKILL.md" && echo EXISTS || echo MISSING');
        if (checkOutput.trim() == 'EXISTS') continue;

        // Read from assets and write to proot
        final content = await rootBundle.loadString('assets/skills/$name/SKILL.md');
        await NativeBridge.runInProot('mkdir -p "$targetDir"');
        await NativeBridge.writeRootfsFile('root/workspace/skills/$name/SKILL.md', content);
        installed++;
      } catch (e) {
        // Skip failed preset installations silently
      }
    }
    return installed;
  }

  static String? _extractYamlField(String content, String field) {
    final regex = RegExp('^$field:\\s*(.+)\$', multiLine: true);
    final match = regex.firstMatch(content);
    return match?.group(1)?.trim();
  }

  static String _extractSkillNameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    final segments = uri?.pathSegments.where((s) => s.isNotEmpty).toList();
    final rawName = segments != null && segments.isNotEmpty
        ? segments.last
        : url.split('/').last;
    return _normalizeSkillName(rawName);
  }

  static String _normalizeSkillName(String rawName) {
    var name = rawName.trim();
    for (final suffix in ['.tar.gz', '.tgz', '.zip', '.git']) {
      if (name.endsWith(suffix)) {
        name = name.substring(0, name.length - suffix.length);
        break;
      }
    }

    if (name.isEmpty ||
        name.startsWith('.') ||
        name.contains('..') ||
        !_safeSkillNamePattern.hasMatch(name)) {
      throw Exception('Invalid skill name');
    }
    return name;
  }

  static String _targetDirForSkillName(String skillName) {
    final name = _normalizeSkillName(skillName);
    final baseUri = Uri.parse('file://$_skillsDir/');
    final targetUri = baseUri.resolve('$name/');
    final basePath = baseUri.toFilePath();
    final targetPath = targetUri.toFilePath();

    if (!targetPath.startsWith(basePath) || targetPath == basePath) {
      throw Exception('Invalid skill target path');
    }

    return targetPath.endsWith('/')
        ? targetPath.substring(0, targetPath.length - 1)
        : targetPath;
  }

  static String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\\''")}'";
  }
}
