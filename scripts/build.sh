#!/usr/bin/env bash
# Builds "Classic Paint.app" (Apple Silicon only) and a .dmg into dist/.
#
#   scripts/build.sh                        release build + dmg
#   CONFIGURATION=debug scripts/build.sh    debug build (with the self-test), no dmg
#   VERSION=1.2.3 scripts/build.sh          override the version in Info.plist
#   INSTALL=1 scripts/build.sh              also copy the app to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Classic Paint"
EXECUTABLE="ClassicPaint"
CONFIGURATION="${CONFIGURATION:-release}"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)}"
DIST="dist"
APP="$DIST/$APP_NAME.app"

# Command Line Tools without Xcode can't run SwiftPM's default build system.
BUILD_FLAGS=(-c "$CONFIGURATION" --arch arm64)
if ! xcodebuild -version >/dev/null 2>&1; then
  BUILD_FLAGS+=(--build-system native)
fi

swift build "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"

# The app draws its own pixel-art icon.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ICON_TMP="$TMP/icon"
"$BIN_DIR/$EXECUTABLE" --render-icon "$ICON_TMP/AppIcon.iconset"
iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

if [ "$CONFIGURATION" = "release" ]; then
  strip -x "$APP/Contents/MacOS/$EXECUTABLE"
fi

# Ad-hoc signature; Apple Silicon refuses to run unsigned code.
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"

if [ "$CONFIGURATION" = "release" ]; then
  STAGING="$TMP/dmg"
  mkdir -p "$STAGING"
  cp -R "$APP" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format ULMO -ov \
    "$DIST/Classic-Paint-$VERSION-arm64.dmg"
fi

if [ "${INSTALL:-0}" = "1" ]; then
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/$APP_NAME.app"
fi

du -sh "$DIST"/*
