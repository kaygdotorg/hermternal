#!/bin/bash
# Build Hermternal and assemble a launchable .app bundle.
#
# SwiftPM emits a bare executable; AppKit/SwiftUI needs a bundle with an
# Info.plist to get a Dock icon, activation policy, and a usable Keychain
# identity. Assemble one rather than carrying an .xcodeproj.
set -euo pipefail

CONFIG="${CONFIG:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/Hermternal.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Hermternal" "$APP/Contents/MacOS/Hermternal"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signing is required for a stable Keychain ACL: an unsigned binary
# gets a new identity on every rebuild and re-prompts for access.
codesign --force --sign - \
	--entitlements "$ROOT/Resources/Hermternal.entitlements" \
	"$APP" >/dev/null 2>&1 ||
	codesign --force --sign - "$APP" >/dev/null

echo "$APP"
