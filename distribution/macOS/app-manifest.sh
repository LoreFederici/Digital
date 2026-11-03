#!/bin/bash
#
# Prints a manifest of an app bundle: one line per file with its SHA-256
# hash and permissions, one line per symbolic link with its target.
# Two app bundles have the same content if their manifests are identical.
#
# Usage: app-manifest.sh <path/to/Digital.app>
#
set -euo pipefail

if [ $# -ne 1 ] || [ ! -d "$1" ] || [ -L "$1" ]; then
    echo "usage: $0 <path/to/Digital.app>" >&2
    exit 1
fi

# Names or link targets containing control characters like line breaks are
# rejected, because they could be used to forge lines of the manifest.
has_control_chars() { [ "$1" != "$(printf '%s' "$1" | tr -d '[:cntrl:]')" ]; }

cd "$1"
export LC_ALL=C
find . \( -type f -o -type l \) -print0 | sort -z | while IFS= read -r -d '' f; do
    if has_control_chars "$f"; then
        echo "error: unsupported file name in bundle" >&2
        exit 1
    fi
    if [ -L "$f" ]; then
        target=$(readlink "$f"; echo .)
        target=${target%.}
        target=${target%$'\n'}
        if has_control_chars "$target"; then
            echo "error: unsupported link target in bundle: ${f#./}" >&2
            exit 1
        fi
        echo "link $target ${f#./}"
    else
        echo "$(shasum -a 256 "$f" | cut -d' ' -f1) $(stat -f %Lp "$f") ${f#./}"
    fi
done
