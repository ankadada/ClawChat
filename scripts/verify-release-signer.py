#!/usr/bin/env python3
"""Fail-closed validation for the ClawChat production APK signing identity."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


HEX_DIGEST = re.compile(r"^[0-9a-f]{64}$")
PACKAGE_LINE = re.compile(
    r"package: name='(?P<package>[^']+)' "
    r"versionCode='(?P<version_code>[^']+)' "
    r"versionName='(?P<version_name>[^']+)'"
)
PUBSPEC_VERSION = re.compile(
    r"(?m)^version:\s*(?P<version_name>[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)"
    r"\+(?P<version_code>[0-9]+)\s*$"
)


class VerificationError(Exception):
    """The APK signer cannot be proven to match the production identity."""


def normalize_digest(value: str, *, field: str = "digest") -> str:
    """Normalize a SHA-256 digest and reject malformed values."""

    if re.search(r"[^0-9A-Fa-f\s:-]", value):
        raise VerificationError(f"{field} contains non-hex characters")
    normalized = re.sub(r"[\s:-]", "", value).lower()
    if not HEX_DIGEST.fullmatch(normalized):
        raise VerificationError(f"{field} must be a 64-character SHA-256 hex digest")
    return normalized


def load_identity(path: Path) -> dict[str, object]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise VerificationError(f"cannot read identity file {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise VerificationError(f"identity file is not valid JSON: {error}") from error

    required = {
        "schemaVersion",
        "packageName",
        "certificateSha256",
        "publicKeySha256",
        "acceptedSignatureSchemes",
    }
    missing = sorted(required - set(data))
    if missing:
        raise VerificationError(f"identity file missing required fields: {', '.join(missing)}")
    if data["schemaVersion"] != 1:
        raise VerificationError(f"unsupported signing identity schemaVersion: {data['schemaVersion']!r}")
    if not isinstance(data["packageName"], str) or not data["packageName"]:
        raise VerificationError("identity packageName must be a non-empty string")
    data["certificateSha256"] = normalize_digest(str(data["certificateSha256"]), field="certificateSha256")
    data["publicKeySha256"] = normalize_digest(str(data["publicKeySha256"]), field="publicKeySha256")
    schemes = data["acceptedSignatureSchemes"]
    if not isinstance(schemes, list) or not schemes:
        raise VerificationError("acceptedSignatureSchemes must be a non-empty list")
    normalized_schemes = []
    for scheme in schemes:
        if scheme not in {"v1", "v2", "v3", "v3.1", "v4"}:
            raise VerificationError(f"unsupported accepted signature scheme: {scheme!r}")
        normalized_schemes.append(str(scheme))
    data["acceptedSignatureSchemes"] = normalized_schemes
    return data


def run_tool(command: list[str]) -> str:
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise VerificationError(f"{Path(command[0]).name} failed with exit {result.returncode}: {detail}")
    return result.stdout


def parse_pubspec_version(path: Path) -> tuple[str, str]:
    try:
        source = path.read_text(encoding="utf-8")
    except OSError as error:
        raise VerificationError(f"cannot read pubspec {path}: {error}") from error
    match = PUBSPEC_VERSION.search(source)
    if not match:
        raise VerificationError(f"pubspec {path} does not contain versionName+versionCode")
    return match.group("version_name"), match.group("version_code")


def parse_badging(output: str) -> dict[str, str]:
    first_line = output.splitlines()[0] if output.splitlines() else ""
    match = PACKAGE_LINE.search(first_line)
    if not match:
        raise VerificationError("aapt badging output does not contain a parseable package line")
    return {
        "packageName": match.group("package"),
        "versionCode": match.group("version_code"),
        "versionName": match.group("version_name"),
    }


def _verified_scheme_key(label: str) -> str:
    match = re.match(r"^(v3\.1|v[1234])\b", label)
    if match:
        return match.group(1)
    return label


def parse_apksigner_output(output: str) -> dict[str, object]:
    if not any(line.strip() == "Verifies" for line in output.splitlines()):
        raise VerificationError("apksigner output does not prove the APK verifies")

    signer_count_match = re.search(r"^Number of signers:\s*([0-9]+)\s*$", output, flags=re.MULTILINE)
    if not signer_count_match:
        raise VerificationError("apksigner output is missing signer count")
    signer_count = int(signer_count_match.group(1))
    if signer_count != 1:
        raise VerificationError(f"expected exactly one APK signer, found {signer_count}")

    certs = re.findall(
        r"^Signer #[0-9]+ certificate SHA-256 digest:\s*([0-9A-Fa-f:]+)\s*$",
        output,
        flags=re.MULTILINE,
    )
    public_keys = re.findall(
        r"^Signer #[0-9]+ public key SHA-256 digest:\s*([0-9A-Fa-f:]+)\s*$",
        output,
        flags=re.MULTILINE,
    )
    if len(certs) != 1:
        raise VerificationError(f"expected one signer certificate digest, found {len(certs)}")
    if len(public_keys) != 1:
        raise VerificationError(f"expected one signer public-key digest, found {len(public_keys)}")

    schemes: dict[str, bool] = {}
    for line in output.splitlines():
        match = re.match(r"^Verified using (?P<label>.+):\s*(?P<value>true|false)\s*$", line.strip())
        if match:
            schemes[_verified_scheme_key(match.group("label"))] = match.group("value") == "true"

    return {
        "certificateSha256": normalize_digest(certs[0], field="APK certificate SHA-256"),
        "publicKeySha256": normalize_digest(public_keys[0], field="APK public-key SHA-256"),
        "signatureSchemes": schemes,
    }


def verify(
    *,
    apk: Path,
    identity_path: Path,
    apksigner: str,
    aapt: str,
    expected_version_name: str | None = None,
    expected_version_code: str | None = None,
    pubspec: Path | None = None,
) -> dict[str, object]:
    if pubspec is not None:
        if expected_version_name is not None or expected_version_code is not None:
            raise VerificationError("--pubspec cannot be combined with explicit version expectations")
        expected_version_name, expected_version_code = parse_pubspec_version(pubspec)

    if not apk.is_file():
        raise VerificationError(f"APK does not exist: {apk}")

    identity = load_identity(identity_path)
    badging = parse_badging(run_tool([aapt, "dump", "badging", str(apk)]))
    if badging["packageName"] != identity["packageName"]:
        raise VerificationError(
            f"package mismatch: expected {identity['packageName']}, got {badging['packageName']}"
        )
    if expected_version_name is not None and badging["versionName"] != expected_version_name:
        raise VerificationError(
            f"versionName mismatch: expected {expected_version_name}, got {badging['versionName']}"
        )
    if expected_version_code is not None and badging["versionCode"] != str(expected_version_code):
        raise VerificationError(
            f"versionCode mismatch: expected {expected_version_code}, got {badging['versionCode']}"
        )

    signer = parse_apksigner_output(
        run_tool([apksigner, "verify", "--verbose", "--print-certs", str(apk)])
    )
    if signer["certificateSha256"] != identity["certificateSha256"]:
        raise VerificationError(
            "certificate SHA-256 mismatch: "
            f"expected {identity['certificateSha256']}, got {signer['certificateSha256']}"
        )
    if signer["publicKeySha256"] != identity["publicKeySha256"]:
        raise VerificationError(
            "public-key SHA-256 mismatch: "
            f"expected {identity['publicKeySha256']}, got {signer['publicKeySha256']}"
        )

    accepted = identity["acceptedSignatureSchemes"]
    schemes = signer["signatureSchemes"]
    if not any(schemes.get(scheme) for scheme in accepted):
        raise VerificationError(
            "APK did not verify with an accepted signature scheme: "
            f"accepted={accepted}, observed={schemes}"
        )

    return {
        "packageName": badging["packageName"],
        "versionName": badging["versionName"],
        "versionCode": badging["versionCode"],
        "certificateSha256": signer["certificateSha256"],
        "publicKeySha256": signer["publicKeySha256"],
        "signatureSchemes": schemes,
    }


def _default_android_tool(name: str) -> str:
    candidates: list[Path] = []
    for env_name in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        value = os.environ.get(env_name)
        if value:
            candidates.extend(sorted(Path(value).glob(f"build-tools/*/{name}"), reverse=True))
    candidates.extend(sorted((Path.home() / "Library/Android/sdk/build-tools").glob(f"*/{name}"), reverse=True))
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    return name


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", required=True, type=Path, help="APK to validate")
    parser.add_argument(
        "--identity",
        default=Path(__file__).resolve().parents[1] / "release/signing-identity.json",
        type=Path,
        help="Machine-readable signing identity JSON",
    )
    parser.add_argument("--pubspec", type=Path, help="Read expected versionName+versionCode from pubspec.yaml")
    parser.add_argument("--expected-version-name", help="Expected APK versionName")
    parser.add_argument("--expected-version-code", help="Expected APK versionCode")
    parser.add_argument("--apksigner", default=_default_android_tool("apksigner"))
    parser.add_argument("--aapt", default=_default_android_tool("aapt"))
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        result = verify(
            apk=args.apk,
            identity_path=args.identity,
            apksigner=args.apksigner,
            aapt=args.aapt,
            expected_version_name=args.expected_version_name,
            expected_version_code=args.expected_version_code,
            pubspec=args.pubspec,
        )
    except VerificationError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1

    schemes = ", ".join(
        f"{scheme}={str(value).lower()}"
        for scheme, value in sorted(result["signatureSchemes"].items())
    )
    print(
        "PASS: verified ClawChat release signer "
        f"{result['certificateSha256']} for {result['packageName']} "
        f"{result['versionName']}+{result['versionCode']} ({schemes})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
