import 'package:flutter/services.dart';
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

  /// Scans the skills directory for SKILL.md files and returns their metadata.
  static Future<List<SkillInfo>> scanSkills() async {
    try {
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
          skills.add(SkillInfo(name: name, description: description, path: path));
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
    final safeUrl = url.replaceAll(RegExp(r'[;&|`$"\\]'), '');
    final skillName = safeUrl.split('/').last.replaceAll('.git', '').replaceAll('.tar.gz', '');
    final targetDir = '$_skillsDir/$skillName';

    if (safeUrl.endsWith('.git') || safeUrl.contains('github.com')) {
      final output = await NativeBridge.runInProot(
        'git clone "$safeUrl" "$targetDir" 2>&1 || echo "CLONE_FAILED"',
      );
      if (output.contains('CLONE_FAILED')) {
        throw Exception('Git clone failed: $output');
      }
      return skillName;
    } else {
      // Download and extract tar.gz
      await NativeBridge.runInProot(
        'mkdir -p "$targetDir" && curl -fsSL "$safeUrl" | tar xz -C "$targetDir" 2>&1',
      );
      return skillName;
    }
  }

  /// Imports a skill from a local directory or zip/tar.gz file on the device.
  static Future<String> importSkillFromLocalPath(String sourcePath) async {
    final name = sourcePath.split('/').last
        .replaceAll('.tar.gz', '')
        .replaceAll('.tgz', '')
        .replaceAll('.zip', '');
    final targetDir = '$_skillsDir/$name';

    if (sourcePath.endsWith('.tar.gz') || sourcePath.endsWith('.tgz')) {
      await NativeBridge.runInProot(
        'mkdir -p "$targetDir" && tar xzf "$sourcePath" -C "$targetDir"',
      );
    } else if (sourcePath.endsWith('.zip')) {
      await NativeBridge.runInProot(
        'mkdir -p "$targetDir" && unzip -o "$sourcePath" -d "$targetDir"',
      );
    } else {
      // Assume it's a directory, copy it
      await NativeBridge.runInProot(
        'cp -r "$sourcePath" "$targetDir"',
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
}
