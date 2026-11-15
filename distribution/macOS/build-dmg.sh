#!/bin/bash
#
# Builds the macOS application Digital.app, which contains its own Java runtime,
# and a disk image (DMG) to distribute it.
#
# Usage:   distribution/macOS/build-dmg.sh
# Needs:   macOS, git, Maven and a JDK >= 17 including jpackage (JAVA_HOME).
# Output:  target/macos/
#            Digital-<version>-macOS-<arch>.dmg             the disk image
#            Digital-<version>-macOS-<arch>.build-info.txt  commit and tools used
#            Digital-<version>-macOS-<arch>.sha256          checksums of the files above
#
# All timestamps are taken from the commit, so building the same commit with the same
# JDK build on the same macOS version creates an identical Digital.app.
#
# Environment:
#   JAVA_HOME     JDK used for compiling and packaging (default: /usr/libexec/java_home -v 17+)
#
set -euo pipefail
# the permissions of the files in Digital.app must not depend on the user's settings
umask 022

die() { echo "[ERROR] $*" >&2; exit 1; }

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MAC="$ROOT/distribution/macOS"
OUT="$ROOT/target/macos"
cd "$ROOT"

[ "$(uname -s)" = Darwin ] || die "This script has to run on macOS"

JAVA_HOME=${JAVA_HOME:-$(/usr/libexec/java_home -v 17+ 2>/dev/null || true)}
JPACKAGE="${JAVA_HOME}/bin/jpackage"

if [ -z "${JAVA_HOME}" ] || [ ! -x "$JPACKAGE" ]; then
    readonly ERR_JDK_REQ="JDK 17+"
    readonly ERR_ABORT="Build aborted"

    echo "[WARNING] jpackage not found in ${JAVA_HOME:-default} ($ERR_JDK_REQ required)" >&2

    custom_triggered=false
    if [ -t 0 ] && [ -z "${CI:-}" ]; then
        for i in {5..1}; do
            echo -ne "\rAuto-detecting a compatible JDK in ${i}s... (Press any key to cancel) "
            if read -t 1 -n 1 key; then
                echo
                read -rp "Enter a custom JAVA_HOME path? [y/N] " custom_choice
                custom_choice=${custom_choice:-n}
                if [[ "$custom_choice" =~ ^([yY]|[yY][eE][sS])$ ]]; then
                    read -rp "Enter path for valid JAVA_HOME ($ERR_JDK_REQ): " JAVA_HOME
                    [ -n "$JAVA_HOME" ] && [ -x "$JAVA_HOME/bin/jpackage" ] || die "The provided path does not contain a valid jpackage: $ERR_JDK_REQ required"
                    echo "Using custom JAVA_HOME: $JAVA_HOME"
                    custom_triggered=true
                else
                    die "$ERR_ABORT"
                fi
                break
            fi
        done
        echo
    fi

    if [ "$custom_triggered" = false ]; then
        VALID_JH=$(/usr/libexec/java_home -v 17+ 2>/dev/null || true)
        if [ -z "$VALID_JH" ] || [ ! -x "$VALID_JH/bin/jpackage" ]; then
            shopt -s nullglob
            candidates=(
                # System & user JDKs (official installers, IntelliJ IDEA, Android Studio)
                /Library/Java/JavaVirtualMachines/*/Contents/Home
                "$HOME/Library/Java/JavaVirtualMachines"/*/Contents/Home
                # Homebrew (Apple Silicon & Intel)
                /opt/homebrew/opt/openjdk*/libexec/openjdk.jdk/Contents/Home
                /usr/local/opt/openjdk*/libexec/openjdk.jdk/Contents/Home
                # SDKMAN (active symlink and installed candidates)
                "$HOME/.sdkman/candidates/java/current"
                "$HOME/.sdkman/candidates/java"/*
                # asdf / mise / jEnv (flat structure and bundled .jdk structure)
                "$HOME/.asdf/installs/java"/*
                "$HOME/.asdf/installs/java"/*/Contents/Home
                "$HOME/.local/share/mise/installs/java"/*
                "$HOME/.local/share/mise/installs/java"/*/Contents/Home
                "$HOME/.jenv/versions"/*
                "$HOME/.jenv/versions"/*/Contents/Home
            )
            shopt -u nullglob
            for candidate in "${candidates[@]+"${candidates[@]}"}"; do
                if [ -x "$candidate/bin/jpackage" ]; then
                    v=""
                    # Preferred method: direct check from the standard <JAVA_HOME>/release file
                    if [ -f "$candidate/release" ]; then
                        v=$(sed -nE 's/^JAVA_VERSION="?([0-9]+).*/\1/p' "$candidate/release" 2>/dev/null | head -n 1 || true)
                    elif [ -f "$candidate/../release" ]; then
                        v=$(sed -nE 's/^JAVA_VERSION="?([0-9]+).*/\1/p' "$candidate/../release" 2>/dev/null | head -n 1 || true)
                    fi
                    # Fallback via java binary if the release file is missing
                    if [ -z "$v" ] && [ -x "$candidate/bin/java" ]; then
                        v=$("$candidate/bin/java" -version 2>&1 | sed -nE '1s/.*version "([0-9]+).*/\1/p' || true)
                    fi
                    # Numeric check: ensure version is 17 or higher
                    if [ -n "$v" ] && [ "$v" -ge 17 ] 2>/dev/null; then
                        VALID_JH="$candidate"
                        break
                    fi
                fi
            done
        fi
        if [ -n "$VALID_JH" ] && [ -x "$VALID_JH/bin/jpackage" ]; then
            JAVA_HOME="$VALID_JH"
            echo "Using detected JDK 17+: $JAVA_HOME"
        else
            echo "No compatible local JDK found" >&2
            if [ -t 0 ] && [ -z "${CI:-}" ] && command -v brew >/dev/null 2>&1; then
                read -rp "Would you like to install Eclipse Temurin JDK via Homebrew and proceed with building? [Y/n] " brew_choice
                brew_choice=${brew_choice:-y}
                if [[ "$brew_choice" =~ ^([yY]|[yY][eE][sS])$ ]]; then
                    brew install --cask temurin
                    VALID_JH=$(/usr/libexec/java_home -v 17+ 2>/dev/null || true)
                    if [ -n "$VALID_JH" ] && [ -x "$VALID_JH/bin/jpackage" ]; then
                        JAVA_HOME="$VALID_JH"
                        echo "Successfully installed and configured JDK: $JAVA_HOME"
                    else
                        die "Temurin installed via Homebrew but jpackage could not be automatically located"
                    fi
                else
                    die "$ERR_ABORT"
                fi
            else
                die "$ERR_ABORT"
            fi
        fi
    fi
fi

export JAVA_HOME
JPACKAGE="$JAVA_HOME/bin/jpackage"
[ -x "$JPACKAGE" ] || die "jpackage not found in $JAVA_HOME (JDK 17 or newer required)"
command -v mvn >/dev/null || die "Maven (mvn) not found"

# Version from the last tag: v0.31 -> 0.31, 34 commits later -> 0.31.34
DESCRIBE=$(git describe --tags --match 'v[0-9]*' --long)
[[ $DESCRIBE =~ ^v([0-9]+(\.[0-9]+)*)-([0-9]+)-g[0-9a-f]+$ ]] || die "Unexpected git describe: $DESCRIBE"
VERSION=${BASH_REMATCH[1]}
COMMITS=${BASH_REMATCH[3]}
if [ "$COMMITS" != 0 ] && [ "$(echo "$VERSION" | tr -cd . | wc -c)" -lt 2 ]; then
    VERSION="$VERSION.$COMMITS"
fi

# All timestamps are taken from the commit, not from the clock.
COMMIT=$(git rev-parse HEAD)
COMMIT_EPOCH=$(git log -1 --format=%ct)
OUTPUT_TIMESTAMP=$(date -u -r "$COMMIT_EPOCH" +%Y-%m-%dT%H:%M:%SZ)
BUILD_TIME=$(date -u -r "$COMMIT_EPOCH" '+%Y-%m-%d %H:%M')
YEAR=$(date -u -r "$COMMIT_EPOCH" +%Y)
TOUCH_TIMESTAMP=$(date -u -r "$COMMIT_EPOCH" +%Y%m%d%H%M.%S)

echo "Building Digital $VERSION ($DESCRIBE) with $("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"

MVN_GOAL=package
MVN_SKIP=(-DskipTests -Djacoco.skip=true)
if [ "${RUN_TESTS:-}" = 1 ]; then
    MVN_GOAL=verify
    MVN_SKIP=()
fi
mvn -B -ntp "${MVN_SKIP[@]+"${MVN_SKIP[@]}"}" \
    -Pno-git-rev -Dgit.commit.id.describe="$DESCRIBE" \
    -Dproject.build.outputTimestamp="$OUTPUT_TIMESTAMP" \
    -DbuildTimestamp="$BUILD_TIME" \
    clean "$MVN_GOAL"
[ -f target/Digital.jar ] || die "target/Digital.jar was not built"

# The app is created in a temporary folder: codesign refuses bundles with extended
# attributes, which are added e.g. by iCloud Drive if the repository is synced.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/digital-macos.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT" "$WORK/input/bin" "$WORK/resources"
cp target/Digital.jar src/main/resources/icons/splash.png "$WORK/input/"
cp -R "$ROOT/src/main/dig/lib" "$WORK/input/lib"
find "$WORK/input/lib" -name ".DS_Store" -delete 2>/dev/null || true
chmod -R u=rwX,go=rX "$WORK/input/lib"
find "$WORK/input/lib" -exec touch -t "$TOUCH_TIMESTAMP" {} + 2>/dev/null || true
# the command "digital", Contents/app/bin/digital in the bundle
cp "$MAC/digital" "$WORK/input/bin/digital"
chmod 755 "$WORK/input/bin/digital"

# jpackage only accepts versions starting with a number > 0, so the real version is
# written to Info.plist directly and jpackage gets a placeholder, which is used only
# in its internal files (.jpackage.xml and Digital.cfg).
DOC_TYPE=$(xmllint --xpath 'normalize-space(/resources/string[@name="fileType_digitalCircuit"])' \
    src/main/resources/lang/lang_en.xml)
[ -n "$DOC_TYPE" ] || die "fileType_digitalCircuit not found in src/main/resources/lang/lang_en.xml"
DOC_TYPE_SED=$(printf '%s' "$DOC_TYPE" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/[\\|&]/\\&/g')
sed -e "s/DIGITAL_VERSION/$VERSION/g" -e "s|DIGITAL_DOCUMENT_TYPE|$DOC_TYPE_SED|g" \
    "$MAC/resources/Info.plist" > "$WORK/resources/Info.plist"

# Second launcher Contents/MacOS/digital-cli for the command line interface,
# like "java -cp Digital.jar CLI". Headless, so no window or dock icon appears.
printf 'main-class=CLI\njava-options=-Djava.awt.headless=true\n' > "$WORK/digital-cli.properties"

# The document type itself is declared in Info.plist. The file association is
# passed to jpackage so that it registers the .dig extension. The document icon
# is system-generated at runtime from the asset catalog (see below).
printf 'extension=dig\nmime-type=text/x-digital\n' > "$WORK/file-association.properties"

# Modules of the bundled runtime, as determined by
#   jdeps --print-module-deps --ignore-missing-deps target/Digital.jar
# (this covers the simulator, the command line interface and all libraries),
# plus the EC crypto provider needed for https (release check) in JDK 21 and the
# locale data of the languages supported by Digital (e.g. decimal separators).
MODULES=java.base,java.desktop,java.prefs,java.sql,jdk.unsupported,jdk.crypto.ec,jdk.localedata
LOCALES=en,de,es,fr,it,pt,zh

# Info.plist is taken from resources/ (see comment there). jpackage signs the
# bundle (ad hoc, if no certificate is given), so nothing must be changed afterwards.
"$JPACKAGE" --type app-image \
    --dest "$WORK" \
    --name Digital \
    --input "$WORK/input" \
    --main-jar Digital.jar \
    --main-class de.neemann.digital.gui.Main \
    --java-options '-splash:$APPDIR/splash.png' \
    --app-version 1.0 \
    --copyright "Copyright (c) 2016-$YEAR Helmut Neemann" \
    --vendor "Helmut Neemann" \
    --icon "$MAC/resources/Digital.icns" \
    --resource-dir "$WORK/resources" \
    --mac-package-identifier de.neemann.digital \
    --mac-package-name Digital \
    --add-launcher digital-cli="$WORK/digital-cli.properties" \
    --file-associations "$WORK/file-association.properties" \
    --add-modules "$MODULES" \
    --jlink-options "--strip-debug --no-man-pages --no-header-files --strip-native-commands --include-locales=$LOCALES"

APP="$WORK/Digital.app"

# Compile the modern macOS app icon and document icon assets into Assets.car
# and copy it into the app bundle. The app icon is compiled from Digital.icon.
# The icon for .dig files is system-generated at runtime by macOS (iconservicesd):
# the system draws the standard folded-page document base, overlays the
# DigitalCircuitDocumentBackground image from the asset catalog, and renders
# "DIG" at the bottom. This is configured via CFBundleTypeIconSystemGenerated
# and UTTypeIcons in Info.plist.
ACTOOL="${ACTOOL:-$(xcrun --find actool 2>/dev/null || true)}"
if [ -z "$ACTOOL" ] || [ ! -x "$ACTOOL" ]; then
    for xcode in /Applications/Xcode*.app; do
        if [ -x "$xcode/Contents/Developer/usr/bin/actool" ]; then
            ACTOOL="$xcode/Contents/Developer/usr/bin/actool"
            export DEVELOPER_DIR="$xcode/Contents/Developer"
            break
        fi
    done
fi
[ -n "$ACTOOL" ] && [ -x "$ACTOOL" ] || die "actool not found: Xcode or Command Line Tools required"

DOC_ASSETS="$WORK/DigitalDocumentAssets.xcassets"
mkdir -p "$DOC_ASSETS/DigitalCircuitDocumentBackground.iconset"
mkdir -p "$DOC_ASSETS/DigitalCircuitDocumentBadge.iconset"
cat << 'EOF' > "$DOC_ASSETS/Contents.json"
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF
DOC_SRC="$MAC/resources/DigitalCircuitDocument.png"
[ -f "$DOC_SRC" ] || die "Document icon source $DOC_SRC is missing"

# macOS document icons at <= 32pt (Finder list, column and sidebar views) omit
# the bottom extension text banner ("DIG"). Following Apple Human Interface
# Guidelines, the artwork for small sizes (16x16 and 32x32, including their
# @2x renditions) is scaled up by 1.28x (1024/800 = 1.28) by cropping an
# 800x800 square centered in the 1024x1024 canvas. This ensures the gate
# graphic remains prominent, legible and balanced next to system icons.
DOC_SRC_SMALL="$WORK/DigitalCircuitDocument-small.png"
sips -c 800 800 "$DOC_SRC" --out "$DOC_SRC_SMALL" >/dev/null

for size in 16 32; do
    sips -z "$size" "$size" "$DOC_SRC_SMALL" --out "$DOC_ASSETS/DigitalCircuitDocumentBackground.iconset/icon_${size}x${size}.png" >/dev/null
    size2=$((size * 2))
    sips -z "$size2" "$size2" "$DOC_SRC_SMALL" --out "$DOC_ASSETS/DigitalCircuitDocumentBackground.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
for size in 128 256 512; do
    sips -z "$size" "$size" "$DOC_SRC" --out "$DOC_ASSETS/DigitalCircuitDocumentBackground.iconset/icon_${size}x${size}.png" >/dev/null
    size2=$((size * 2))
    sips -z "$size2" "$size2" "$DOC_SRC" --out "$DOC_ASSETS/DigitalCircuitDocumentBackground.iconset/icon_${size}x${size}@2x.png" >/dev/null
done

# Provide a transparent badge image set so that macOS iconservicesd renders
# the background image cleanly without a secondary badge overlay.
swift -e '
import AppKit
let dir = URL(fileURLWithPath: "'"$DOC_ASSETS"'/DigitalCircuitDocumentBadge.iconset")
let targetFiles: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]
for (s, f) in targetFiles {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: s, pixelsHigh: s, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: dir.appendingPathComponent(f))
}
'

"$ACTOOL" \
    --compile "$APP/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 11.0 \
    --app-icon Digital \
    --output-partial-info-plist "$WORK/actool-partial.plist" \
    "$MAC/resources/Digital.icon" \
    "$DOC_ASSETS" > /dev/null
[ -f "$APP/Contents/Resources/Assets.car" ] || die "actool did not produce Assets.car"
cp "$MAC/resources/Digital.icns" "$APP/Contents/Resources/Digital.icns"
touch -t "$TOUCH_TIMESTAMP" "$APP/Contents/Resources/Assets.car" "$APP/Contents/Resources/Digital.icns" 2>/dev/null || true

# Generate localized InfoPlist.strings from lang_*.xml directly into Digital.app/Contents/Resources/<lang>.lproj/
for lang_file in src/main/resources/lang/lang_*.xml; do
    [[ "$lang_file" == *_ref.xml ]] && continue
    [[ "$lang_file" =~ lang_([a-z]{2})(_[a-zA-Z]+)?\.xml$ ]] || continue
    lang="${BASH_REMATCH[1]}"
    [ "$lang" = "zh" ] && lproj="zh-Hans.lproj" || lproj="${lang}.lproj"

    localized_type=$(xmllint --xpath 'normalize-space(/resources/string[@name="fileType_digitalCircuit"])' "$lang_file" 2>/dev/null || true)
    if [ -n "$localized_type" ]; then
        escaped_type=$(printf '%s' "$localized_type" | sed 's/\\/\\\\/g; s/"/\\"/g')
        target_dir="$APP/Contents/Resources/$lproj"
        mkdir -p "$target_dir"
        cat <<EOF > "$target_dir/InfoPlist.strings"
"Digital Circuit" = "$escaped_type";
"de.neemann.digital.dig" = "$escaped_type";
"de.neemann.digital.gui.dig" = "$escaped_type";
"CFBundleTypeName" = "$escaped_type";
"UTTypeDescription" = "$escaped_type";
EOF
        touch -t "$TOUCH_TIMESTAMP" "$target_dir/InfoPlist.strings" "$target_dir" 2>/dev/null || true
    fi
done

# Build and integrate the native Swift Quick Look App Extension (.appex)
mkdir -p "$APP/Contents/PlugIns"
"$MAC/quicklook/build-appex.sh" "$APP/Contents/PlugIns" "$VERSION" "$TOUCH_TIMESTAMP"

# Re-sign the main bundle ad-hoc without --deep to preserve extension entitlements
codesign --force --sign - "$APP"

codesign --verify --deep --strict "$APP" || die "The signature of Digital.app is not valid"
for f in MacOS/Digital MacOS/digital-cli app/bin/digital PlugIns/DigitalQuickLook.appex/Contents/MacOS/DigitalQuickLook; do
    [ -x "$APP/Contents/$f" ] || die "Contents/$f is missing in Digital.app"
done
[ -d "$APP/Contents/app/lib" ] || die "Contents/app/lib is missing in Digital.app"
[ -f "$APP/Contents/Resources/Assets.car" ] || die "The asset catalog Assets.car is missing in Digital.app"
[ -f "$APP/Contents/Resources/Digital.icns" ] || die "The application icon Digital.icns is missing in Digital.app"

ARCH=$(lipo -archs "$APP/Contents/MacOS/Digital")
NAME="Digital-$VERSION-macOS-$ARCH"

{
    echo "Commit:      $COMMIT"
    echo "Describe:    $DESCRIBE"
    echo "Version:     $VERSION"
    echo "Commit time: $OUTPUT_TIMESTAMP"
    echo "JDK:         $(grep -E '^(IMPLEMENTOR|JAVA_RUNTIME_VERSION)=' "$JAVA_HOME/release" | cut -d= -f2 | tr -d '"' | tr '\n' ' ')($("$JAVA_HOME/bin/java" -XshowSettings:properties -version 2>&1 | awk '/os.arch =/{print $3}'))"
    echo "Maven:       $(mvn -v | head -1)"
    echo "macOS:       $(sw_vers -productVersion) ($(uname -m))"
    echo "Dirty:       $([ -n "$(git status --porcelain)" ] && echo yes || echo no)"
} > "$OUT/$NAME.build-info.txt"

# Disk image with the app and a link to /Applications for installing by drag and drop.
# The manual of hdiutil in recent macOS versions recommends "diskutil image" instead.
# hdiutil is still used: it works, and "diskutil image" is missing on older systems
# (create needs macOS 14) and offers no replacement for "hdiutil verify".
STAGE="$WORK/dmg"
mkdir "$STAGE"
mv "$APP" "$STAGE/Digital.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname Digital -srcfolder "$STAGE" -fs APFS -format UDZO -ov "$OUT/$NAME.dmg"

(cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.build-info.txt" > "$NAME.sha256")
cat "$OUT/$NAME.build-info.txt"
cat "$OUT/$NAME.sha256"
