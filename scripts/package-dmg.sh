#!/usr/bin/env bash
# Packages dist/Maiku.app into a drag-to-install dist/Maiku-<version>.dmg.
#
# The app is ad-hoc signed (see Docs/DISTRIBUTION.md) -- there is no Developer
# ID certificate to sign or notarize this build with. macOS Gatekeeper will
# quarantine-warn on a DMG downloaded from a browser; that is expected for an
# unsigned alpha build and is documented in the release notes, not worked
# around here.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="dist/Maiku.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="dist/Maiku-${VERSION}.dmg"

echo "==> scripts/build.sh release"
./scripts/build.sh release

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "==> staging DMG contents"
cp -R "$APP" "$STAGING/Maiku.app"
ln -s /Applications "$STAGING/Applications"

echo "==> hdiutil create $DMG"
rm -f "$DMG"
hdiutil create -volname Maiku -srcfolder "$STAGING" -ov -format UDZO "$DMG"

echo "==> built $DMG"
