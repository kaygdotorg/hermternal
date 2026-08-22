#!/bin/bash
# Build Hermternal and assemble a launchable .app bundle.
#
# SwiftPM emits a bare executable; AppKit/SwiftUI needs a bundle with an
# Info.plist to get a Dock icon, activation policy, and a stable app identity.
# Assemble one rather than carrying an .xcodeproj.
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
cp "$ROOT/Resources/HermesIcon.png" "$APP/Contents/Resources/HermesIcon.png"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Prefer a real codesigning identity when one is installed. A real identity
# gives the bundle a designated requirement based on the certificate, which is
# stable across rebuilds -- so Keychain grants and TCC approvals persist.
#
# Ad-hoc (`--sign -`) is the fallback and gets a fresh cdhash on every build,
# which is why credentials live in CredentialStore rather than the Keychain:
# an ad-hoc binary cannot hold a durable "Always Allow" grant.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f "$ROOT/.env" ]]; then
	IDENTITY="$(sed -n 's/^CODESIGN_IDENTITY=//p' "$ROOT/.env" | tail -1)"
fi
if [[ -z "$IDENTITY" ]]; then
	IDENTITY="$(
		security find-identity -v -p codesigning 2>/dev/null |
			sed -n 's/.*"\(.*\)".*/\1/p' | head -1
	)"
fi
if [[ -z "$IDENTITY" ]]; then
	IDENTITY="-"
	echo "note: no codesigning identity found; signing ad-hoc" >&2
fi

# Hardened runtime and a trusted timestamp are both prerequisites for
# notarization, and harmless for local ad-hoc builds. `--timestamp` needs the
# network, so fall back to an untrusted signature when offline rather than
# failing a local build.
SIGN_ARGS=(--force --options runtime
	--entitlements "$ROOT/Resources/Hermternal.entitlements")
if [[ "$IDENTITY" == "-" ]]; then
	codesign "${SIGN_ARGS[@]}" --sign - "$APP" >/dev/null
else
	codesign "${SIGN_ARGS[@]}" --timestamp --sign "$IDENTITY" "$APP" >/dev/null ||
		codesign "${SIGN_ARGS[@]}" --sign "$IDENTITY" "$APP" >/dev/null
fi

echo "$APP"
