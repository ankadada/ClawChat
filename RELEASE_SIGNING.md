# ClawChat release signing

This repository pins the public Android signing identity for production ClawChat APKs in [`release/signing-identity.json`](release/signing-identity.json). The file contains only public certificate/public-key digests and policy metadata; private keys, keystores, aliases, and passwords must not be committed.

## Official production identity

- Package: `com.anka.clawbot`
- Certificate SHA-256: `e718246ac9a0d973534bf686e1f9fd12254909609466bd041f49930721e6d57f`
- Public key SHA-256: `07f337ae9c83e7a055f70d9193c52070fe2b71e4d649b8933d8056103f8262db`
- Minimum SDK context: API 29+
- Accepted APK signature schemes for this lineage: v2 or v3 with exactly one signer

## Evidence and rationale

The production identity is selected from the established distributable upgrade lineage, not from whichever local keystore a checkout happens to reference.

- Historical 2.5.2+8 release artifacts under `ClawChat-release-artifacts` verify with certificate SHA-256 `e718246ac9a0d973534bf686e1f9fd12254909609466bd041f49930721e6d57f` and public key SHA-256 `07f337ae9c83e7a055f70d9193c52070fe2b71e4d649b8933d8056103f8262db`.
- The installed `com.anka.clawbot` 2.5.2+8 package on the upgrade-test device used the same `e718...` certificate.
- A 2.5.3+9 APK signed with a different `f014...` certificate could not be used for a data-preserving Android overlay update.
- Re-signing the already verified 2.5.3+9 APK with the `e718...` identity produced a data-preserving overlay update to 2.5.3+9 with the original first-install timestamp preserved.

## Release procedure

1. Build with the canonical entrypoint:

   ```bash
   bash scripts/build-apk.sh
   ```

2. The build script verifies the PRoot payload and then runs:

   ```bash
   python3 scripts/verify-release-signer.py \
     --apk flutter_app/build/app/outputs/flutter-apk/app-release.apk \
     --identity release/signing-identity.json \
     --pubspec flutter_app/pubspec.yaml
   ```

3. Treat any signer verifier failure as a release blocker. Do not publish, install, or rename a mismatched APK as a release artifact.

## Rotation policy

Changing the Android signing certificate normally breaks in-place updates: Android will reject an update when the installed package and replacement APK do not share a compatible signing lineage. A signing identity change is allowed only through a formally designed rotation plan that:

- documents the Android platform mechanism being used;
- preserves or intentionally migrates the supported installed base;
- updates `release/signing-identity.json` and this document in the same review;
- adds verifier coverage for the old and new lineage rules; and
- proves the upgrade path on a representative installed package before publication.
