#!/bin/bash
# Build the ClawChat Flutter APK
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
FLUTTER_DIR="$PROJECT_DIR/flutter_app"

echo "=== ClawChat APK Build ==="
echo ""

# Step 1: Exercise the verifier before it guards a release build.
echo "[1/7] Testing PRoot packaging verifier..."
python3 "$SCRIPT_DIR/test_verify_proot_packaging.py"
echo ""

# Step 2: Always restore the pinned payload. A structurally valid local matrix
# may still contain stale bytes and is not a reproducible release input.
echo "[2/7] Fetching pinned PRoot binaries..."
bash "$SCRIPT_DIR/fetch-proot-binaries.sh"
echo ""

# Step 3: Verify the complete native payload before Gradle runs. This catches
# clean/isolated checkouts where gitignored jniLibs were never fetched.
echo "[3/7] Verifying PRoot binaries..."
python3 "$SCRIPT_DIR/verify-proot-packaging.py" \
    --jni-dir "$FLUTTER_DIR/android/app/src/main/jniLibs" \
    --artifact-mode source
echo ""

# Step 4: Get Flutter dependencies
echo "[4/7] Getting Flutter dependencies..."
cd "$FLUTTER_DIR"
flutter pub get
echo ""

# Step 5: Build and verify the actual APK archive.
echo "[5/7] Building release APK..."
flutter build apk --release
echo ""

APK_PATH="$FLUTTER_DIR/build/app/outputs/flutter-apk/app-release.apk"
if [ -f "$APK_PATH" ]; then
    echo "[6/7] Verifying packaged PRoot payload..."
    python3 "$SCRIPT_DIR/verify-proot-packaging.py" \
        --apk "$APK_PATH" \
        --artifact-mode universal
    echo ""
    echo "[7/7] Verifying production release signer..."
    python3 "$SCRIPT_DIR/verify-release-signer.py" \
        --apk "$APK_PATH" \
        --identity "$PROJECT_DIR/release/signing-identity.json" \
        --pubspec "$FLUTTER_DIR/pubspec.yaml"
    echo ""
    echo "=== Build Successful ==="
    echo "APK: $APK_PATH"
    echo "Size: $(du -h "$APK_PATH" | cut -f1)"
    echo ""
    echo "Install (preserve app data): adb install -r $APK_PATH"
else
    echo "=== Build Failed ==="
    exit 1
fi
