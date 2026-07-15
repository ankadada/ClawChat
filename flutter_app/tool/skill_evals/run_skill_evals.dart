import 'dart:io';

import 'lib/skill_eval_host_gate.dart';

/// Thin CLI wrapper for the importable host-owned skill eval runner.
void main(List<String> arguments) {
  if (arguments.isNotEmpty) {
    stderr.writeln('usage: dart run tool/skill_evals/run_skill_evals.dart');
    exitCode = 64;
    return;
  }

  final projectRoot = Directory.current;
  final result = const HostSkillEvalRunner().run(
    skillAssetsDirectory: Directory('${projectRoot.path}/assets/skills'),
    inventoryFile: File(
      '${projectRoot.path}/tool/skill_evals/bundled-skill-inventory.json',
    ),
    corpusDirectory: Directory('${projectRoot.path}/tool/skill_evals'),
    runtimeProjectDirectory: projectRoot,
  );
  stdout.writeln(result.toCliOutput());
  exitCode = result.exitCode;
}
