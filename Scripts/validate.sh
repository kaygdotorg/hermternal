#!/bin/bash
# Compile every SwiftPM target before running tests.
#
# The optional argument is the package root, which makes this usable against a
# tree synchronized to a Mac over SSH:
#   ssh mbp /tmp/herm-current-final/Scripts/validate.sh
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [[ ! -f "$ROOT/Package.swift" ]]; then
    printf 'error: no Package.swift in package root: %s\n' "$ROOT" >&2
    exit 1
fi

cd "$ROOT"
printf '[gate] compiling all package targets (including tests)\n'
printf '+ xcrun swift build --build-tests\n'
/usr/bin/xcrun swift build --build-tests

printf '[gate] running tests after successful compilation\n'
printf '+ xcrun swift test --skip-build\n'
/usr/bin/xcrun swift test --skip-build
