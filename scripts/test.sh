#!/usr/bin/env bash
# Runs the Maiku test suite. Exits nonzero on failure.
#
# Equivalent to `xcodebuild -scheme Maiku -destination 'platform=macOS' test`
# when Xcode is available. Tests must not require LM Studio or downloaded
# multi-gigabyte speech models; those live behind opt-in integration tests
# gated on MAIKU_INTEGRATION_TESTS=1.
set -euo pipefail

cd "$(dirname "$0")/.."

# swift-testing ships inside the Command Line Tools, but SwiftPM only wires up
# its search paths when it is driven by Xcode. Without these, `swift test`
# fails to find the Testing module at compile time and lib_TestingInterop at
# load time. Harmless when a full Xcode is installed.
DEV="$(xcode-select -p)"
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"

EXTRA=()
if [[ -d "$FW" ]]; then
	EXTRA+=(-Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW" -Xlinker -rpath -Xlinker "$FW")
fi
if [[ -d "$LIB" ]]; then
	EXTRA+=(-Xlinker -rpath -Xlinker "$LIB")
fi

echo "==> swift test"
DYLD_FRAMEWORK_PATH="${FW}${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}" \
	DYLD_LIBRARY_PATH="${LIB}${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
	swift test "${EXTRA[@]}" "$@"
