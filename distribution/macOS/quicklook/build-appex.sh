#!/bin/bash
#
# Compiles the Swift Quick Look Extension (DigitalQuickLook.appex)
# as a Universal Binary (arm64 + x86_64) and packages it.
#
# Usage: build-appex.sh <output-dir> <version> [touch-timestamp]
#
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[ $# -ge 2 ] || die "usage: $0 <output-dir> <version> [touch-timestamp]"

OUT_DIR="$1"
VERSION="$2"
TOUCH_TIMESTAMP="${3:-}"

DIR=$(cd "$(dirname "$0")" && pwd)
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)}"
[ -n "$SDK_PATH" ] && [ -d "$SDK_PATH" ] || die "could not resolve macOS SDK path"

BUILD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/digital-quicklook.XXXXXX")
trap 'rm -rf "$BUILD_TMP"' EXIT

mkdir -p "$BUILD_TMP/module-cache" "$OUT_DIR"
APPEX="$OUT_DIR/DigitalQuickLook.appex"
rm -rf "$APPEX"
mkdir -p "$APPEX/Contents/MacOS"

# 1. Compile arm64
swiftc -sdk "$SDK_PATH" \
    -module-cache-path "$BUILD_TMP/module-cache" \
    -module-name DigitalQuickLook \
    -target arm64-apple-macos12.0 \
    -O \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -framework Foundation \
    -framework AppKit \
    -framework QuickLookUI \
    -I "$DIR" \
    "$DIR/JniExporter.c" \
    "$DIR/PreviewProvider.swift" \
    -o "$BUILD_TMP/DigitalQuickLook_arm64"

# 2. Compile x86_64
# Note: x86_64 target uses macos14.0 because modern Xcode/CLT toolchains drop
# x86_64 slices from libswiftCompatibility56.a (required for <14.0 on x86_64).
swiftc -sdk "$SDK_PATH" \
    -module-cache-path "$BUILD_TMP/module-cache" \
    -module-name DigitalQuickLook \
    -target x86_64-apple-macos14.0 \
    -O \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -framework Foundation \
    -framework AppKit \
    -framework QuickLookUI \
    -I "$DIR" \
    "$DIR/JniExporter.c" \
    "$DIR/PreviewProvider.swift" \
    -o "$BUILD_TMP/DigitalQuickLook_x86_64"

# 3. Create Universal Binary
lipo -create -output "$APPEX/Contents/MacOS/DigitalQuickLook" \
    "$BUILD_TMP/DigitalQuickLook_arm64" \
    "$BUILD_TMP/DigitalQuickLook_x86_64"
chmod 755 "$APPEX/Contents/MacOS/DigitalQuickLook"

# 4. Process Info.plist using native plutil
cp "$DIR/Info.plist" "$APPEX/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APPEX/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APPEX/Contents/Info.plist"
plutil -lint "$APPEX/Contents/Info.plist" >/dev/null || die "invalid Info.plist generated"
chmod 644 "$APPEX/Contents/Info.plist"

# 5. Sign extension with entitlements (ad-hoc by default, or with custom identity if configured in CI)
SIGN_IDENTITY="${CODESIGN_IDENTITY:-${SIGN_IDENTITY:--}}"
CODESIGN_FLAGS=(--force --sign "$SIGN_IDENTITY" --entitlements "$DIR/DigitalQuickLook.entitlements")
if [ "$SIGN_IDENTITY" = "-" ]; then
    CODESIGN_FLAGS+=(--timestamp=none)
else
    CODESIGN_FLAGS+=(--options runtime --timestamp)
fi
codesign "${CODESIGN_FLAGS[@]}" "$APPEX"
codesign --verify --deep --strict "$APPEX" || die "signature verification failed for DigitalQuickLook.appex"

# 6. Apply reproducible touch timestamp if provided
# Note: applied after codesigning so that _CodeSignature/CodeResources also receives the timestamp
if [ -n "$TOUCH_TIMESTAMP" ]; then
    find "$APPEX" -exec touch -h -t "$TOUCH_TIMESTAMP" {} + 2>/dev/null || true
fi
