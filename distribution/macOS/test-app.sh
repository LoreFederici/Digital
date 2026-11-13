#!/bin/bash
#
# Starts Digital.app from a disk image, to check that it runs on this processor
# type and macOS version:
#  - checks the content of the disk image and the code signature of the app,
#  - runs "digital test" and "digital svg" with a circuit of this repository,
#  - opens the circuit in the simulator with the same "open files" event as a double
#    click in the Finder, and waits until the simulator has loaded it.
#
# This runs code from the disk image, so only use it with a disk image you trust.
# A window is shown for a short time, and the circuit is added to the recent files
# of Digital until the next start, because it no longer exists then.
# The output of the simulator is written to the output folder, on a CI system
# also a screenshot.
#
# Usage: test-app.sh <Digital.dmg> <output folder>
#
set -euo pipefail

die() { echo "FAILED: $*" >&2; exit 1; }

[ $# -eq 2 ] || { echo "Usage: $0 <Digital.dmg> <output folder>" >&2; exit 1; }
DMG=$1
[ -f "$DMG" ] || die "$DMG not found"
mkdir -p "$2"
OUT=$(cd "$2" && pwd)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# Helper to execute a command with a maximum timeout (prevents hanging in headless environments)
run_with_timeout() {
    local timeout=$1
    shift
    "$@" &
    local cmd_pid=$!
    ( sleep "$timeout" && kill -9 "$cmd_pid" 2>/dev/null ) &
    local watcher_pid=$!
    wait "$cmd_pid" 2>/dev/null || true
    kill -9 "$watcher_pid" 2>/dev/null || true
}

# Resolve system language to match Digital's localized missing shape string
SYS_LANG=$(defaults read -g AppleLanguages 2>/dev/null | grep -Eo '"[a-z]{2}(-[A-Z]+)?"' | head -1 | tr -d '"' | cut -d'-' -f1 || echo "en")
LANG_XML="$ROOT/src/main/resources/lang/lang_${SYS_LANG}.xml"
[ -f "$LANG_XML" ] || LANG_XML="$ROOT/src/main/resources/lang/lang_en.xml"

MISSING_SHAPE_TMPL=$(xmllint --xpath 'normalize-space(/resources/string[@name="msg_missingShape_N"])' "$LANG_XML" 2>/dev/null || echo "missing")
# Remove placeholder {0} and extract all non-empty words
MISSING_WORDS=$(echo "$MISSING_SHAPE_TMPL" | sed 's/{0}//g' | xargs)

check_no_missing_shape() {
    local svg_file="$1"
    local desc="$2"
    for word in $MISSING_WORDS; do
        if [ -n "$word" ] && grep -qi "$word" "$svg_file"; then
            die "$desc contains missing shape error (matched '$word')"
        fi
    done
}

# pwd -P: the simulator is found by the real path of the app
WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/digital-test.XXXXXX")" && pwd -P)
MOUNT="$WORK/mount"
APP="$WORK/Digital.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
ATTACHED=
PID=
cleanup() {
    if [ -n "$PID" ]; then
        kill "$PID" 2>/dev/null || true
    fi
    if [ -n "$ATTACHED" ] && ! hdiutil detach -quiet "$MOUNT"; then
        echo "[WARNING] The disk image is still attached at $MOUNT" >&2
    fi
    # macOS must not remember the copy as an application for *.dig files
    pluginkit -r "$APP/Contents/PlugIns/DigitalQuickLook.appex" 2>/dev/null || true
    "$LSREGISTER" -u "$APP" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# The app is copied out of the disk image, like a user installs it.
mkdir "$MOUNT"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$DMG"
ATTACHED=1
# .fseventsd is created by macOS itself
CONTENT=$(cd "$MOUNT" && ls -A | grep -v '^\.fseventsd$' | LC_ALL=C sort | tr '\n' ' ')
[ "$CONTENT" = "Applications Digital.app " ] || die "Unexpected content of the disk image: $CONTENT"
ditto "$MOUNT/Digital.app" "$APP"
hdiutil detach -quiet "$MOUNT"
ATTACHED=
codesign --verify --deep --strict "$APP" || die "The signature of Digital.app is not valid"

CIRCUIT="$WORK/test circuit.dig"
cp "$ROOT/src/main/dig/combinatorial/FullAdder.dig" "$CIRCUIT"

echo "Command line interface"
[ -d "$APP/Contents/app/lib" ] || die "Contents/app/lib is missing in Digital.app"
"$APP/Contents/app/bin/digital" test -circ "$CIRCUIT" || die "digital test failed"
"$APP/Contents/app/bin/digital" svg -dig "$CIRCUIT" -svg "$WORK/circuit.svg" || die "digital svg failed"
grep -q '<svg' "$WORK/circuit.svg" || die "digital svg has not created an SVG file"

echo "Testing embedded standard library components"
CHIP_CIRCUIT="$WORK/74181-74182.dig"
cp "$ROOT/src/test/resources/dig/test/74xx/74181-74182.dig" "$CHIP_CIRCUIT"
"$APP/Contents/app/bin/digital" svg -dig "$CHIP_CIRCUIT" -svg "$WORK/chips.svg" || die "Chips SVG export failed"
check_no_missing_shape "$WORK/chips.svg" "Chips export"

echo "Testing embedded sibling components"
SIBLING_DIR="$WORK/siblings"
mkdir -p "$SIBLING_DIR"
cp "$ROOT/src/test/resources/dig/test/shapes/Adder.dig" "$SIBLING_DIR/"
cp "$ROOT/src/test/resources/dig/test/shapes/4BitAdder.dig" "$SIBLING_DIR/"
"$APP/Contents/app/bin/digital" svg -dig "$SIBLING_DIR/4BitAdder.dig" -svg "$WORK/adder.svg" || die "Adder SVG export failed"
check_no_missing_shape "$WORK/adder.svg" "Adder export"
grep -q 'Adder' "$WORK/adder.svg" || die "Adder export missing Adder shape label"

echo "Verifying document type localization"
IT_DOC_TYPE=$(xmllint --xpath 'normalize-space(/resources/string[@name="fileType_digitalCircuit"])' "$ROOT/src/main/resources/lang/lang_it.xml")
grep -q "$IT_DOC_TYPE" "$APP/Contents/Resources/it.lproj/InfoPlist.strings" || die "it.lproj/InfoPlist.strings missing $IT_DOC_TYPE"
grep -q "\"de.neemann.digital.gui.dig\" = \"$IT_DOC_TYPE\";" "$APP/Contents/Resources/it.lproj/InfoPlist.strings" || die "it.lproj/InfoPlist.strings missing de.neemann.digital.gui.dig"

echo "Quick Look extension"
APPEX="$APP/Contents/PlugIns/DigitalQuickLook.appex"
[ -d "$APPEX" ] || die "DigitalQuickLook.appex not found in $APP"
[ -x "$APPEX/Contents/MacOS/DigitalQuickLook" ] || die "DigitalQuickLook binary missing or not executable"
codesign --verify --deep --strict "$APPEX" || die "DigitalQuickLook.appex signature is not valid"
echo "Architectures: $(lipo -archs "$APPEX/Contents/MacOS/DigitalQuickLook")"

# Register plugin explicitly and query with pluginkit
pluginkit -a "$APPEX" 2>/dev/null || true
echo "Querying plugin registration with pluginkit"
pluginkit -m -p com.apple.quicklook.preview -i de.neemann.digital.quicklook 2>&1 || true

# Test Quick Look preview generation with qlmanage (non-blocking with timeout)
echo "Testing Quick Look preview with qlmanage"
run_with_timeout 3 qlmanage -p "$CIRCUIT" 2>&1 || true
run_with_timeout 3 qlmanage -t -s 500 -o "$OUT" "$CIRCUIT" 2>&1 || true

echo "Simulator"
LOG="$OUT/simulator-output.txt"
open -g -a "$APP" --stdout "$LOG" --stderr "$LOG" "$CIRCUIT"

for _ in $(seq 1 30); do
    PID=$(pgrep -n -f "^$APP/Contents/MacOS/Digital" || true)
    [ -z "$PID" ] || break
    sleep 1
done
[ -n "$PID" ] || die "The simulator has not started"

# Digital adds a circuit to its recent files after loading it.
LOADED=
for _ in $(seq 1 90); do
    kill -0 "$PID" 2>/dev/null || die "The simulator has stopped"
    if defaults read com.apple.java.util.prefs 2>/dev/null | grep -qF "$CIRCUIT"; then
        LOADED=1
        break
    fi
    sleep 1
done
[ -n "$LOADED" ] || die "The simulator has not loaded the circuit"

# gives the window time to be drawn, and shows a crash shortly after loading
sleep 5
kill -0 "$PID" 2>/dev/null || die "The simulator has stopped"
if [ -n "${CI:-}" ]; then
    screencapture -x "$OUT/screenshot.png" || echo "[WARNING] No screenshot" >&2
fi
echo "OK"
