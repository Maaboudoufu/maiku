#!/usr/bin/env bash
# Builds Maiku and assembles a launchable, signed Maiku.app bundle.
#
# Xcode is not required. If Xcode is installed, `xcodebuild -scheme Maiku
# -destination 'platform=macOS' build` is equivalent; this script performs the
# same checks using SwiftPM plus manual bundling, because the .app wrapper is
# what macOS requires before it will grant microphone (TCC) permission.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
APP="dist/Maiku.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product Maiku

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Maiku" "$APP/Contents/MacOS/Maiku"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM emits one .bundle per target that declares resources.
shopt -s nullglob
for bundle in ".build/$CONFIG"/*.bundle; do
	cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

# Clawd artwork is looked up at runtime from Bundle.main (see
# ClawdAssetManifest.url(for:in:)), not through SwiftPM's resource bundling, so
# it has to be copied explicitly. Only the asset-contract README ships until
# authorized artwork exists — see Resources/Clawd/README.md and plan.md §14.
if [[ -d Resources/Clawd ]]; then
	mkdir -p "$APP/Contents/Resources/Clawd"
	cp -R Resources/Clawd/. "$APP/Contents/Resources/Clawd/"
fi

# Ad-hoc signature. Enough for local development and for TCC to track the app
# identity; Developer ID signing and notarization require credentials we do not
# have here (see IMPLEMENTATION_STATUS.md "Known limitations").
echo "==> codesign (ad-hoc)"
codesign --force --sign - --entitlements Maiku.entitlements --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"

echo "==> built $APP"
