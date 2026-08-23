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
CODESIGN_KEYCHAIN="${CODESIGN_KEYCHAIN:-}"
if [[ -n "$CODESIGN_KEYCHAIN" && ! -f "$CODESIGN_KEYCHAIN" ]]; then
	echo "error: CODESIGN_KEYCHAIN does not point to a keychain file" >&2
	exit 1
fi

IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f "$ROOT/.env" ]]; then
	IDENTITY="$(sed -n 's/^CODESIGN_IDENTITY=//p' "$ROOT/.env" | tail -1)"
fi
if [[ -z "$IDENTITY" ]]; then
	if [[ -n "$CODESIGN_KEYCHAIN" ]]; then
		IDENTITY="$(
			security find-identity -v -p codesigning "$CODESIGN_KEYCHAIN" 2>/dev/null |
				sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*\([[:xdigit:]]\{40\}\).*/\1/p' | head -1
		)"
	else
		IDENTITY="$(
			security find-identity -v -p codesigning 2>/dev/null |
				sed -n 's/.*"\(.*\)".*/\1/p' | head -1
		)"
	fi
fi
if [[ -z "$IDENTITY" ]]; then
	if [[ "${ALLOW_ADHOC:-0}" != 1 ]]; then
		cat >&2 <<-'HINT'
		error: no codesigning identity found; refusing to create an ad-hoc build.
		Local ad-hoc builds require the explicit ALLOW_ADHOC=1 opt-in.
		HINT
		exit 1
	fi
	IDENTITY="-"
	echo "warning: ALLOW_ADHOC=1; signing an ad-hoc build (not publishable)" >&2
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
	CODESIGN_KEYCHAIN_ARGS=()
	if [[ -n "$CODESIGN_KEYCHAIN" ]]; then
		CODESIGN_KEYCHAIN_ARGS=(--keychain "$CODESIGN_KEYCHAIN")
	fi
	# Try with a trusted timestamp, then without: `--timestamp` needs the
	# network and should not break an offline local build.
	if ! ERR="$(codesign "${SIGN_ARGS[@]}" "${CODESIGN_KEYCHAIN_ARGS[@]}" \
		--timestamp --sign "$IDENTITY" "$APP" 2>&1)" &&
	   ! ERR="$(codesign "${SIGN_ARGS[@]}" "${CODESIGN_KEYCHAIN_ARGS[@]}" \
		--sign "$IDENTITY" "$APP" 2>&1)"; then
		printf '%s\n' "$ERR" >&2
		# errSecInternalComponent identifies private-key access failure; the recovery
		# differs for the temporary portable keychain and the installed login keychain.
		if [[ "$ERR" == *errSecInternalComponent* ]]; then
			if [[ -n "$CODESIGN_KEYCHAIN" ]]; then
				cat >&2 <<-'HINT'

				codesign could not use the private key from the temporary portable
				keychain. This usually means the imported key lacks the codesign
				partition grant or the ephemeral keychain was not first in the
				search list. It is a portable-keychain failure, not a login ACL
				failure.

				A person at the Mac must repair the portable .p12/password setup
				and rerun the release. This cannot be automated by an agent.
				Do not open or drive Terminal.app.
				HINT
			else
				cat >&2 <<-'HINT'

				codesign could not use the private key. This is the usual result of
				signing from a shell with no window server -- an SSH session -- since
				the login key's ACL wants a confirmation dialog it cannot draw.

				This recovery step requires a human at the Mac's physical keyboard.
				It cannot be automated or scripted. An automated caller must stop
				and report this failure; do not open or drive Terminal.app.

				A human at the Mac can either run this from Terminal.app, or grant
				codesign non-interactive access to the key once:

				  security unlock-keychain ~/Library/Keychains/login.keychain-db
				  security set-key-partition-list \
				      -S apple-tool:,apple:,codesign: -s \
				      -k "<your login password>" \
				      ~/Library/Keychains/login.keychain-db
				HINT
			fi
		fi
		exit 1
	fi
	# Verify the produced Developer ID signature immediately, before callers
	# proceed to packaging or notarization.
	SIGNATURE_INFO="$(codesign -d --verbose=2 "$APP" 2>&1)" ||
		{ printf '%s\n' "$SIGNATURE_INFO" >&2; exit 1; }
	SIGNATURE_LINES="$(grep -E '^(CodeDirectory|Signature=|TeamIdentifier)' \
		<<<"$SIGNATURE_INFO" || true)"
	if grep -q '^Signature=adhoc$' <<<"$SIGNATURE_INFO" ||
		! grep -q '^TeamIdentifier=.' <<<"$SIGNATURE_INFO" ||
		! grep -Eq '^CodeDirectory.*flags=.*\([^)]*runtime[^)]*\)' \
			<<<"$SIGNATURE_INFO"; then
		printf '%s\n' "$SIGNATURE_LINES" >&2
		echo "error: Developer ID signature is ad-hoc, lacks TeamIdentifier, or lacks hardened runtime" >&2
		exit 1
	fi
fi

echo "$APP"
