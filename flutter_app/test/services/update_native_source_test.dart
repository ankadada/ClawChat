import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('verified APK handoff is intent-only and rechecks bounded identity', () {
    final source = File(
      'android/app/src/main/kotlin/com/anka/clawbot/MainActivity.kt',
    ).readAsStringSync();
    final start = source.indexOf('"handoffVerifiedApk" ->');
    final end = source.indexOf('"playAudio" ->', start);
    final handoff = source.substring(start, end);

    expect(handoff, contains('verifiedUpdateApk'));
    expect(handoff, contains('VerifiedApkUpdate.intentPlan'));
    expect(handoff, contains('Intent(Intent.ACTION_VIEW)'));
    expect(handoff, contains('FLAG_GRANT_READ_URI_PERMISSION'));
    expect(handoff, contains('startActivity(installIntent)'));
    expect(handoff, isNot(contains('runInProot')));
    expect(handoff, isNot(contains('Runtime.getRuntime')));
    expect(handoff, isNot(contains('pm install')));

    final verifierStart = source.indexOf('private fun verifiedUpdateApk');
    final verifierEnd = source.indexOf('override fun onDestroy', verifierStart);
    final verifier = source.substring(verifierStart, verifierEnd);
    expect(verifier, contains('VerifiedApkUpdate.verify'));
    expect(verifier, contains('File(cacheDir, "updates")'));

    final helper = File(
      'android/app/src/main/kotlin/com/anka/clawbot/VerifiedApkUpdate.kt',
    ).readAsStringSync();
    expect(helper, contains('application/vnd.android.package-archive'));
    expect(helper, contains('Files.isRegularFile'));
    expect(helper, contains('Files.isSymbolicLink'));
    expect(helper, contains('resolved.startsWith(root)'));
    expect(helper, contains('Files.size(resolved) == expectedSize'));
    expect(helper, contains('actual == expectedSha256'));

    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android.permission.REQUEST_INSTALL_PACKAGES'));
    expect(manifest, contains(r'${applicationId}.updates'));
    final updatePaths = File('android/app/src/main/res/xml/update_paths.xml')
        .readAsStringSync();
    expect(updatePaths, contains('path="updates/"'));
    expect(updatePaths, isNot(contains('<files-path')));
    expect(updatePaths, isNot(contains('path="."')));
  });

  test('metadata signature is anchored to the installed app signer', () {
    final source = File(
      'android/app/src/main/kotlin/com/anka/clawbot/MainActivity.kt',
    ).readAsStringSync();
    final start = source.indexOf('private fun verifyUpdateSignature');
    final end = source.indexOf('private fun verifiedUpdateApk', start);
    final verifier = source.substring(start, end);

    expect(verifier, contains('currentSigningCertificateBytes'));
    expect(verifier, contains('MessageDigest.getInstance("SHA-256")'));
    expect(verifier, contains('if (actualKeyId != keyId) return false'));
    expect(verifier, contains('CryptoSignature.getInstance(algorithm)'));
    expect(verifier, contains('verifier.verify(signatureBytes)'));
  });

  test('extension activation preserves backup and has fail-closed rollback',
      () {
    final source = File('lib/services/skill_service.dart').readAsStringSync();
    final installStart = source.indexOf('static Future<SkillInstallResult>');
    final rollbackStart = source
        .indexOf('static Future<SkillRollbackResult> rollbackInstalledSkill');
    final discardStart =
        source.indexOf('static Future<void> discardPreparedImport');
    final install = source.substring(installStart, rollbackStart);
    final rollback = source.substring(rollbackStart, discardStart);

    expect(install, contains('preservedBackupPath'));
    expect(install, contains('updateBackupPath(candidate.id)'));
    expect(install, contains('preserveBackup'));
    expect(install, contains(r'mv ${_shellQuote(target)}'));
    expect(install, contains('await afterBackupMove?.call();'));
    expect(install, contains('await afterNewMove?.call();'));
    expect(
      install.indexOf('await afterBackupMove?.call();'),
      lessThan(install.indexOf(r'mv ${_shellQuote(candidate.stagingPath)}')),
    );
    expect(
      install.indexOf('await afterNewMove?.call();'),
      lessThan(install.indexOf('final installed = await')),
    );
    expect(
        install, contains('Installed skill differs from validated staging.'));
    expect(rollback, contains('expectedCurrentTrustDigest'));
    expect(rollback, contains('SKILL_ROLLBACK_OK'));
    expect(rollback, contains('Rolled back extension failed verification.'));
    expect(rollback,
        contains(r'mv ${_shellQuote(target)} ${_shellQuote(failed)}'));
    expect(
      rollback,
      contains(r'mv ${_shellQuote(backupPath)} ${_shellQuote(target)}'),
    );
    expect(rollback, contains('await afterTargetMove?.call();'));
    expect(rollback, contains('await afterBackupMove?.call();'));
    expect(rollback, isNot(contains(r'rm -rf ${_shellQuote(failed)}')));
  });

  test('standalone verifier JVM build cannot alter app native configuration',
      () {
    final app = File('android/app/build.gradle').readAsStringSync();
    final settings = File('android/settings.gradle').readAsStringSync();
    final verifier =
        File('android/verified-apk-jvm/build.gradle').readAsStringSync();
    final verifierSettings =
        File('android/verified-apk-jvm/settings.gradle').readAsStringSync();

    expect(app, contains('ndkVersion = flutter.ndkVersion'));
    expect(app, contains('externalNativeBuild'));
    expect(app, isNot(contains('unitTestOnly')));
    expect(app, isNot(contains('gradle.startParameter.taskNames')));
    expect(settings, isNot(contains('verified-apk-jvm')));
    expect(verifierSettings, contains("rootProject.name = 'verified-apk-jvm'"));
    expect(verifier, contains("srcDir '../app/src/main/kotlin'"));
    expect(verifier, contains("include '**/VerifiedApkUpdate.kt'"));
  });
}
