#!/usr/bin/env python3
"""Unit and source tests for the ClawChat release signer verifier."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import textwrap
import unittest


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
VERIFIER_PATH = SCRIPT_DIR / "verify-release-signer.py"

spec = importlib.util.spec_from_file_location("verify_release_signer", VERIFIER_PATH)
VERIFIER = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(VERIFIER)


CERT = "e718246ac9a0d973534bf686e1f9fd12254909609466bd041f49930721e6d57f"
PUBLIC_KEY = "07f337ae9c83e7a055f70d9193c52070fe2b71e4d649b8933d8056103f8262db"


def _apksigner_output(
    *,
    signer_count: int = 1,
    certificate: str = CERT,
    public_key: str = PUBLIC_KEY,
    verifies: bool = True,
    scheme: str = "v3",
) -> str:
    lines = []
    if verifies:
        lines.append("Verifies")
    for candidate in ("v1", "v2", "v3", "v3.1", "v4"):
        label = {
            "v1": "v1 scheme (JAR signing)",
            "v2": "v2 scheme (APK Signature Scheme v2)",
            "v3": "v3 scheme (APK Signature Scheme v3)",
            "v3.1": "v3.1 scheme (APK Signature Scheme v3.1)",
            "v4": "v4 scheme (APK Signature Scheme v4)",
        }[candidate]
        lines.append(f"Verified using {label}: {str(candidate == scheme).lower()}")
    lines.append(f"Number of signers: {signer_count}")
    for index in range(1, signer_count + 1):
        lines.append(f"Signer #{index} certificate SHA-256 digest: {certificate}")
        lines.append(f"Signer #{index} public key SHA-256 digest: {public_key}")
    return "\n".join(lines)


class VerifierUnitTest(unittest.TestCase):
    def test_normalize_digest_accepts_uppercase_and_separators(self) -> None:
        formatted = ":".join(CERT.upper()[index : index + 2] for index in range(0, len(CERT), 2))
        self.assertEqual(VERIFIER.normalize_digest(formatted), CERT)

    def test_normalize_digest_rejects_non_sha256(self) -> None:
        with self.assertRaises(VERIFIER.VerificationError):
            VERIFIER.normalize_digest("abcd")
        with self.assertRaises(VERIFIER.VerificationError):
            VERIFIER.normalize_digest("z" * 64)

    def test_parse_matching_signer_output(self) -> None:
        parsed = VERIFIER.parse_apksigner_output(_apksigner_output())
        self.assertEqual(parsed["certificateSha256"], CERT)
        self.assertEqual(parsed["publicKeySha256"], PUBLIC_KEY)
        self.assertTrue(parsed["signatureSchemes"]["v3"])

    def test_mismatched_signer_fails_identity_check(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            apk = root / "app.apk"
            apk.write_bytes(b"synthetic")
            identity = root / "identity.json"
            identity.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "packageName": "com.anka.clawbot",
                        "certificateSha256": CERT,
                        "publicKeySha256": PUBLIC_KEY,
                        "acceptedSignatureSchemes": ["v3"],
                    }
                ),
                encoding="utf-8",
            )
            aapt = root / "aapt"
            aapt.write_text(
                "#!/bin/sh\n"
                "echo \"package: name='com.anka.clawbot' versionCode='9' versionName='2.5.3'\"\n",
                encoding="utf-8",
            )
            aapt.chmod(0o755)
            apksigner = root / "apksigner"
            apksigner.write_text(
                "#!/bin/sh\n"
                "cat <<'OUT'\n"
                + _apksigner_output(certificate="0" * 64)
                + "\nOUT\n",
                encoding="utf-8",
            )
            apksigner.chmod(0o755)

            with self.assertRaisesRegex(VERIFIER.VerificationError, "certificate SHA-256 mismatch"):
                VERIFIER.verify(
                    apk=apk,
                    identity_path=identity,
                    apksigner=str(apksigner),
                    aapt=str(aapt),
                    expected_version_name="2.5.3",
                    expected_version_code="9",
                )

    def test_missing_signer_fails_closed(self) -> None:
        output = textwrap.dedent(
            """
            Verifies
            Verified using v3 scheme (APK Signature Scheme v3): true
            """
        )
        with self.assertRaisesRegex(VERIFIER.VerificationError, "missing signer count"):
            VERIFIER.parse_apksigner_output(output)

    def test_multiple_signers_fail_closed(self) -> None:
        with self.assertRaisesRegex(VERIFIER.VerificationError, "exactly one APK signer"):
            VERIFIER.parse_apksigner_output(_apksigner_output(signer_count=2))


class VerifierSourceTest(unittest.TestCase):
    def test_signing_identity_docs_and_readme_are_consistent(self) -> None:
        identity = json.loads((PROJECT_DIR / "release/signing-identity.json").read_text(encoding="utf-8"))
        release_doc = (PROJECT_DIR / "RELEASE_SIGNING.md").read_text(encoding="utf-8")
        readme = (PROJECT_DIR / "README.md").read_text(encoding="utf-8")

        self.assertEqual(identity["schemaVersion"], 1)
        self.assertEqual(identity["packageName"], "com.anka.clawbot")
        self.assertEqual(VERIFIER.normalize_digest(identity["certificateSha256"]), CERT)
        self.assertEqual(VERIFIER.normalize_digest(identity["publicKeySha256"]), PUBLIC_KEY)
        self.assertIn("v2", identity["acceptedSignatureSchemes"])
        self.assertIn("v3", identity["acceptedSignatureSchemes"])
        self.assertIn(CERT, release_doc)
        self.assertIn(PUBLIC_KEY, release_doc)
        self.assertIn("[release signing contract](RELEASE_SIGNING.md)", readme)

    def test_build_script_runs_release_signer_after_packaged_proot_verifier(self) -> None:
        source = (PROJECT_DIR / "scripts/build-apk.sh").read_text(encoding="utf-8")
        proot = 'python3 "$SCRIPT_DIR/verify-proot-packaging.py"'
        signer = 'python3 "$SCRIPT_DIR/verify-release-signer.py"'
        self.assertIn(signer, source)
        self.assertLess(source.rindex(proot), source.index(signer))
        self.assertIn("--identity", source)
        self.assertIn("release/signing-identity.json", source)
        self.assertIn("--pubspec", source)
        for step in range(1, 8):
            self.assertIn(f"[{step}/7]", source)
        self.assertNotRegex(source, r"\[[1-7]/6\]")
        self.assertIn("Install (preserve app data): adb install -r $APK_PATH", source)

    def test_gradle_release_signing_is_root_relative_and_fail_closed(self) -> None:
        source = (PROJECT_DIR / "flutter_app/android/app/build.gradle").read_text(encoding="utf-8")
        self.assertIn("def releaseStoreFile = storeFileValue ? rootProject.file(storeFileValue) : null", source)
        self.assertIn("storeFile releaseStoreFile", source)
        self.assertIn('tasks.register("validateOfficialReleaseSigning")', source)
        self.assertIn("Release signing configuration is missing or invalid", source)
        self.assertIn("validateSigningRelease", source)

        release_block = source[source.index("release {", source.index("buildTypes {")) :]
        release_block = release_block[: release_block.index("        }") + len("        }")]
        self.assertIn("signingConfig signingConfigs.release", release_block)
        self.assertNotIn("signingConfigs.debug", release_block)


if __name__ == "__main__":
    unittest.main(verbosity=2)
