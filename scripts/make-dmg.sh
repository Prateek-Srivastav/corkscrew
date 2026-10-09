#!/bin/bash
# Builds the Release app and packs it into dist/Corkscrew-<version>.dmg, with an Applications link to
# drag it to. Ad hoc signed: until there's a Developer ID, macOS asks to "Open Anyway" once.
# The app downloads its engine pack on first launch (EnginePackPin.swift), so that release has to
# be published first; this checks it is, unless CORKSCREW_TRY_DMG=1 (to try a DMG out locally).
# Usage: make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PIN=Packages/GameCore/Sources/GameCore/Engines/EnginePackPin.swift
PACK_URL=$(sed -nE 's/.*URL\(string: "([^"]+)"\).*/\1/p' "$PIN")
if ! curl -sfIL -o /dev/null "$PACK_URL"; then
  echo "The engine pack isn't published yet: $PACK_URL" >&2
  echo "Publish it first (scripts/package-engine.sh prints the command)." >&2
  [[ -n ${CORKSCREW_TRY_DMG:-} ]] || exit 1
fi

scripts/build-app.sh Release
APP=build/DerivedData/Build/Products/Release/Corkscrew.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
codesign --verify --deep --strict "$APP"

mkdir -p dist
DMG="dist/Corkscrew-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Corkscrew.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Corkscrew $VERSION" -srcfolder "$STAGE" -format ULFO -ov "$DMG"
(cd dist && shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG").sha256")
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
