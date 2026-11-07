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
BUILD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/digital-quicklook.XXXXXX")
trap 'rm -rf "$BUILD_TMP"' EXIT

mkdir -p "$BUILD_TMP/module-cache" "$OUT_DIR"
APPEX="$OUT_DIR/DigitalQuickLook.appex"
rm -rf "$APPEX"
mkdir -p "$APPEX/Contents/MacOS"

# 1. Compile arm64
swiftc -module-cache-path "$BUILD_TMP/module-cache" \
    -module-name DigitalQuickLook \
    -target arm64-apple-macos12.0 \
    -O \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -I "$DIR" \
    "$DIR/JniExporter.c" \
    "$DIR/PreviewProvider.swift" \
    -o "$BUILD_TMP/DigitalQuickLook_arm64"

# 2. Compile x86_64
swiftc -module-cache-path "$BUILD_TMP/module-cache" \
    -module-name DigitalQuickLook \
    -target x86_64-apple-macos14.0 \
    -O \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -I "$DIR" \
    "$DIR/JniExporter.c" \
    "$DIR/PreviewProvider.swift" \
    -o "$BUILD_TMP/DigitalQuickLook_x86_64"

# 3. Create Universal Binary
lipo -create -output "$APPEX/Contents/MacOS/DigitalQuickLook" \
    "$BUILD_TMP/DigitalQuickLook_arm64" \
    "$BUILD_TMP/DigitalQuickLook_x86_64"
chmod 755 "$APPEX/Contents/MacOS/DigitalQuickLook"

# 4. Process Info.plist
sed -e "s/DIGITAL_VERSION/$VERSION/g" "$DIR/Info.plist" > "$APPEX/Contents/Info.plist"
chmod 644 "$APPEX/Contents/Info.plist"

# 5. Apply reproducible touch timestamp if provided
if [ -n "$TOUCH_TIMESTAMP" ]; then
    touch -t "$TOUCH_TIMESTAMP" "$APPEX/Contents/Info.plist" "$APPEX/Contents/MacOS/DigitalQuickLook" "$APPEX/Contents/MacOS" "$APPEX/Contents" "$APPEX" 2>/dev/null || true
fi

# 6. Sign extension ad-hoc with entitlements
codesign --force --sign - --entitlements "$DIR/DigitalQuickLook.entitlements" "$APPEX"
codesign --verify --deep --strict "$APPEX" || die "signature verification failed for DigitalQuickLook.appex"
