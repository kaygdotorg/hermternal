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

APP="$ROOT/build/Hermternal.app"
LOCK_DIR="$ROOT/build/.Hermternal-build.lock"
STAGE_ROOT=""
OUTPUT_PUBLISHED=0
LOCK_HELD=0
cleanup_build() {
	local status=$?
	if (( status != 0 && OUTPUT_PUBLISHED )); then
		# Quarantine this invocation's published output before staging cleanup;
		# never recursively delete the live output in place.
		if [[ -e "$APP" || -L "$APP" ]]; then
			mv -- "$APP" "$STAGE_ROOT/Failed.app" 2>/dev/null || true
		fi
	fi
	if [[ -n "$STAGE_ROOT" ]]; then
		rm -rf -- "$STAGE_ROOT" || true
	fi
	if (( LOCK_HELD )); then
		rm -rf -- "$LOCK_DIR" || true
	fi
	exit "$status"
}
trap cleanup_build EXIT
mkdir -p "$ROOT/build"
# Refuse concurrent builds without disturbing the last good stamped bundle.
if ! mkdir -- "$LOCK_DIR" 2>/dev/null; then
	owner_pid="<missing>"
	if [[ -f "$LOCK_DIR/pid" ]]; then
		IFS= read -r owner_pid <"$LOCK_DIR/pid"
		[[ -n "$owner_pid" ]] || owner_pid="<empty>"
	fi
	if [[ "$owner_pid" =~ ^[0-9]+$ ]] &&
		kill -0 "$owner_pid" 2>/dev/null; then
		echo "error: build lock exists at $LOCK_DIR (recorded pid $owner_pid is alive); stop that build before retrying" >&2
	else
		echo "error: build lock exists at $LOCK_DIR (recorded pid $owner_pid is not running); after confirming no build is active, clear it with: rm -rf -- '$LOCK_DIR'" >&2
	fi
	exit 1
fi
LOCK_HELD=1
printf '%s\n' "$$" >"$LOCK_DIR/pid"
if ! STAGE_ROOT="$(mktemp -d "$ROOT/build/.Hermternal-staging.XXXXXX")"; then
	rm -rf -- "$APP" || true
	echo "error: could not create a staging directory" >&2
	exit 1
fi
if [[ -e "$APP" || -L "$APP" ]] &&
	! mv -- "$APP" "$STAGE_ROOT/Previous.app"; then
	rm -rf -- "$APP" || true
	echo "error: could not quarantine previous app bundle at $APP" >&2
	exit 1
fi
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)"
STAGE_APP="$STAGE_ROOT/Hermternal.app"
mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"
cp "$BIN/Hermternal" "$STAGE_APP/Contents/MacOS/Hermternal"
# The new-chat mark, one drawing per appearance; ChatView loads them by name.
cp "$ROOT/Resources/HermternalMarkLight.png" \
	"$STAGE_APP/Contents/Resources/HermternalMarkLight.png"
cp "$ROOT/Resources/HermternalMarkDark.png" \
	"$STAGE_APP/Contents/Resources/HermternalMarkDark.png"
BUILD_COMMIT="$(git rev-parse HEAD 2>/dev/null || printf 'unknown')"
if [[ "$BUILD_COMMIT" == unknown ]]; then
	BUILD_TREE_CLEAN=false
else
	BUILD_TREE_CLEAN=true
	[[ -z "$(git status --porcelain=v1 2>/dev/null)" ]] || BUILD_TREE_CLEAN=false
fi
BUILD_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'commit=%s\ntree_clean=%s\nconfiguration=%s\nbuild_time=%s\n' \
	"$BUILD_COMMIT" "$BUILD_TREE_CLEAN" "$CONFIG" "$BUILD_TIME" \
	> "$STAGE_APP/Contents/Resources/HermternalBuildInfo"
cp "$ROOT/Resources/Info.plist" "$STAGE_APP/Contents/Info.plist"

# The app icon is an Icon Composer package: two stacked 1024px drawings whose
# per-appearance visibility is specialized, so macOS picks the light or the dark
# artwork itself and keeps ownership of the squircle, the material, the specular
# highlight and the shadow -- none of which is baked into the sources. Only
# `actool` can lower that package into the Assets.car the system reads; a static
# .icns has no appearance axis, so there is no fallback worth shipping. A failure
# here is fatal rather than silently producing a bundle with a generic icon.
ICON_BUILD="$ROOT/build/icon"
rm -rf "$ICON_BUILD"
mkdir -p "$ICON_BUILD"
# Match the deployment floor the bundle itself advertises instead of repeating it.
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
	"$ROOT/Resources/Info.plist" 2>/dev/null)" ||
	{ echo "error: Resources/Info.plist has no LSMinimumSystemVersion" >&2; exit 1; }
if ! ICON_LOG="$(xcrun actool "$ROOT/Resources/AppIcon.icon" \
	--compile "$ICON_BUILD" \
	--app-icon AppIcon \
	--output-partial-info-plist "$ICON_BUILD/partial.plist" \
	--platform macosx \
	--minimum-deployment-target "$MIN_MACOS" \
	--target-device mac \
	--errors --warnings --notices \
	--output-format human-readable-text 2>&1)"; then
	printf '%s\n' "$ICON_LOG" >&2
	echo "error: actool failed to compile Resources/AppIcon.icon" >&2
	exit 1
fi
printf '%s\n' "$ICON_LOG"
if [[ ! -f "$ICON_BUILD/Assets.car" ]]; then
	printf '%s\n' "$ICON_LOG" >&2
	echo "error: actool reported success but produced no Assets.car" >&2
	exit 1
fi
cp "$ICON_BUILD/Assets.car" "$STAGE_APP/Contents/Resources/Assets.car"

# actool names the compiled icon in a partial plist; read the name from there
# rather than hardcoding it, so the bundle can never advertise an icon the
# catalog does not contain. The partial plist's CFBundleIconFile is dropped on
# purpose: it names the legacy light-only AppIcon.icns that actool also writes
# into the staging directory. That file stays there -- the bundle ships only
# Assets.car, and a dangling CFBundleIconFile outranks nothing but confuses
# icon services.
ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' \
	"$ICON_BUILD/partial.plist" 2>/dev/null)" ||
	{ echo "error: actool's partial plist has no CFBundleIconName" >&2; exit 1; }
[[ "$ICON_NAME" == AppIcon ]] ||
	{ echo "error: actool compiled icon '$ICON_NAME', expected AppIcon" >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Add :CFBundleIconName string $ICON_NAME" \
	"$STAGE_APP/Contents/Info.plist" >/dev/null

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
if [[ -n "$CODESIGN_KEYCHAIN" ]]; then
	SIGN_ARGS+=(--keychain "$CODESIGN_KEYCHAIN")
fi
if [[ "$IDENTITY" == "-" ]]; then
	codesign "${SIGN_ARGS[@]}" --sign - "$STAGE_APP" >/dev/null
else
	# Try with a trusted timestamp, then without: `--timestamp` needs the
	# network and should not break an offline local build.
	if ! ERR="$(codesign "${SIGN_ARGS[@]}" \
		--timestamp --sign "$IDENTITY" "$STAGE_APP" 2>&1)" &&
	   ! ERR="$(codesign "${SIGN_ARGS[@]}" \
		--sign "$IDENTITY" "$STAGE_APP" 2>&1)"; then
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
	SIGNATURE_INFO="$(codesign -d --verbose=2 "$STAGE_APP" 2>&1)" ||
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

[[ -s "$STAGE_APP/Contents/MacOS/Hermternal" ]] ||
	{ echo "error: bundle executable is missing or empty" >&2; exit 1; }
[[ -s "$STAGE_APP/Contents/Info.plist" ]] ||
	{ echo "error: bundle Info.plist is missing or empty" >&2; exit 1; }
[[ -s "$STAGE_APP/Contents/Resources/Assets.car" ]] ||
	{ echo "error: bundle Assets.car is missing or empty" >&2; exit 1; }
[[ -s "$STAGE_APP/Contents/Resources/HermternalMarkLight.png" ]] ||
	{ echo "error: bundle light mark is missing or empty" >&2; exit 1; }
[[ -s "$STAGE_APP/Contents/Resources/HermternalMarkDark.png" ]] ||
	{ echo "error: bundle dark mark is missing or empty" >&2; exit 1; }

if ! VERIFY_OUTPUT="$(codesign --verify --deep --strict "$STAGE_APP" 2>&1)"; then
	printf '%s\n' "$VERIFY_OUTPUT" >&2
	echo "error: codesign verification failed" >&2
	exit 1
fi
OUTPUT_PUBLISHED=1
mv "$STAGE_APP" "$APP"
echo "$APP"
