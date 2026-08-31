#!/bin/bash
# Type-check every HermternalCore source against the iOS Simulator SDK, then
# type-check the platform palette Seam on its own.
#
# This intentionally invokes swiftc directly instead of `swift build`: the
# package's Hermternal executable target is macOS-only (AppKit/SwiftUI), while
# this gate must prove the Foundation/domain Core target is iOS-portable.
#
# The palette Seam is checked as its own module, never inside HermternalCore:
# Core must stay colour-free, and the Seam's iOS branch must compile against
# UIKit. Two invocations state both rules at once.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_NAME="iphonesimulator"
export LC_ALL=C

XCRUN=(xcrun --sdk "$SDK_NAME")
SDK_PATH="$("${XCRUN[@]}" --show-sdk-path)"
SDK_VERSION="$("${XCRUN[@]}" --show-sdk-version)"
TARGET="arm64-apple-ios${SDK_VERSION}-simulator"

SOURCES=()
while IFS= read -r source; do
	SOURCES+=("$source")
done < <(find "$ROOT/Sources/HermternalCore" -type f -name '*.swift' -print | sort)
if ((${#SOURCES[@]} == 0)); then
	echo "error: no HermternalCore Swift sources found" >&2
	exit 1
fi

echo "Type-checking ${#SOURCES[@]} HermternalCore sources for iOS Simulator ($TARGET)"
echo "SDK: $SDK_PATH"
"${XCRUN[@]}" swiftc \
	-typecheck \
	-parse-as-library \
	-module-name HermternalCore \
	-swift-version 6 \
	-sdk "$SDK_PATH" \
	-target "$TARGET" \
	"${SOURCES[@]}"

PALETTE="$ROOT/Sources/Hermternal/Support/PlatformPalette.swift"
if [[ ! -f "$PALETTE" ]]; then
	echo "error: platform palette source not found at $PALETTE" >&2
	exit 1
fi

echo "Type-checking the platform palette Seam for iOS Simulator ($TARGET)"
exec "${XCRUN[@]}" swiftc \
	-typecheck \
	-parse-as-library \
	-module-name HermternalPlatformPalette \
	-swift-version 6 \
	-sdk "$SDK_PATH" \
	-target "$TARGET" \
	"$PALETTE"
