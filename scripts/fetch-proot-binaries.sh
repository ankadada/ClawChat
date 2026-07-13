#!/bin/bash
# Restore the known-good PRoot payload from the published v2.0.0 APKs.
# Exact release asset names and SHA-256 digests pin the binary identity;
# extracting their JNI entries avoids a moving Termux stable repository.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
JNILIBS_DIR="$PROJECT_DIR/flutter_app/android/app/src/main/jniLibs"
TMP_DIR=$(mktemp -d)
STAGE_DIR="$TMP_DIR/jniLibs"

trap 'rm -rf "$TMP_DIR"' EXIT

PINNED_RELEASE_TAG="v2.0.0"
PINNED_RELEASE_BASE="https://github.com/ankadada/ClawChat/releases/download/$PINNED_RELEASE_TAG"

fetch_for_abi() {
    local abi="$1"
    local asset="$2"
    local expected_sha256="$3"
    shift 3
    local libraries=("$@")
    local apk="$TMP_DIR/$asset"
    local out_dir="$STAGE_DIR/$abi"

    echo "  [$abi] Fetching pinned $asset..."
    curl -fsSL --retry 3 "$PINNED_RELEASE_BASE/$asset" -o "$apk"

    python3 - "$apk" "$expected_sha256" "$abi" "$out_dir" "${libraries[@]}" <<'PY'
import hashlib
import os
from pathlib import Path
import stat
import sys
import zipfile

apk = Path(sys.argv[1])
expected_sha256 = sys.argv[2]
abi = sys.argv[3]
out_dir = Path(sys.argv[4])
libraries = sys.argv[5:]

actual_sha256 = hashlib.sha256(apk.read_bytes()).hexdigest()
if actual_sha256 != expected_sha256:
    raise SystemExit(
        f"ERROR: {apk.name} SHA-256 mismatch: "
        f"expected {expected_sha256}, got {actual_sha256}"
    )

out_dir.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(apk) as archive:
    names = archive.namelist()
    for library in libraries:
        entry = f"lib/{abi}/{library}"
        if names.count(entry) != 1:
            raise SystemExit(
                f"ERROR: {apk.name} expected exactly one {entry}, "
                f"found {names.count(entry)}"
            )
        info = archive.getinfo(entry)
        mode = (info.external_attr >> 16) & 0xFFFF
        file_type = stat.S_IFMT(mode)
        if info.is_dir() or file_type not in (0, stat.S_IFREG):
            raise SystemExit(f"ERROR: {apk.name} {entry} is not a regular file")
        target = out_dir / library
        target.write_bytes(archive.read(info))
        os.chmod(target, 0o755)
PY

    echo "  [$abi] OK — ${libraries[*]}"
}

echo "=== Restoring pinned PRoot payload from ClawChat $PINNED_RELEASE_TAG ==="
echo ""

# jniLibs is gitignored and owned by this fetch step. Download into a staging
# tree and run the shared structural verifier before replacing the current
# payload, so a network or upstream failure cannot leave a partial matrix.
if [[ "$JNILIBS_DIR" != "$PROJECT_DIR/flutter_app/android/app/src/main/jniLibs" ]]; then
    echo "ERROR: refusing to clear unexpected jniLibs path: $JNILIBS_DIR" >&2
    exit 1
fi
mkdir -p "$STAGE_DIR"

fetch_for_abi \
    "arm64-v8a" \
    "OpenClaw-v2.0.0-arm64-v8a.apk" \
    "2e176888652afd51ffa02b3a63e667be188e5b0191ffccab1a935d72eb14a5f1" \
    libproot.so libprootloader.so libprootloader32.so libtalloc.so

fetch_for_abi \
    "armeabi-v7a" \
    "OpenClaw-v2.0.0-armeabi-v7a.apk" \
    "159ba0486a4863f2d41228477e616261fc2a91e6449e7be62ca9900f80757de1" \
    libproot.so libprootloader.so libtalloc.so

fetch_for_abi \
    "x86_64" \
    "OpenClaw-v2.0.0-x86_64.apk" \
    "f52b64191e250b4d3a9d3285f47df4e163aa349e9f31384c9ce2a1b6621c33e1" \
    libproot.so libprootloader.so libprootloader32.so libtalloc.so

python3 "$SCRIPT_DIR/verify-proot-packaging.py" \
    --jni-dir "$STAGE_DIR" \
    --artifact-mode source

# The target is hard-coded above. Refuse symlinks and re-check the cleanup
# boundary immediately before installing the fully verified staged matrix.
if [[ -L "$JNILIBS_DIR" ]]; then
    echo "ERROR: refusing to replace symlinked jniLibs: $JNILIBS_DIR" >&2
    exit 1
fi
if [[ "$JNILIBS_DIR" != "$PROJECT_DIR/flutter_app/android/app/src/main/jniLibs" ]]; then
    echo "ERROR: cleanup guard changed unexpectedly: $JNILIBS_DIR" >&2
    exit 1
fi
JNILIBS_PARENT="$(cd "$(dirname "$JNILIBS_DIR")" && pwd -P)"
if [[ "$JNILIBS_PARENT" != "$PROJECT_DIR/flutter_app/android/app/src/main" ]]; then
    echo "ERROR: refusing cleanup through unexpected parent: $JNILIBS_PARENT" >&2
    exit 1
fi
rm -rf "$JNILIBS_DIR"
mkdir -p "$(dirname "$JNILIBS_DIR")"
mv "$STAGE_DIR" "$JNILIBS_DIR"

echo ""
echo "=== Restored 11/11 pinned PRoot files ==="
find "$JNILIBS_DIR" -type f -name 'lib*.so' -print | LC_ALL=C sort
