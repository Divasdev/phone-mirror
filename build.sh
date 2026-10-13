#!/bin/bash
# build.sh — builds Phone Mirror, packages it as a .app, signs it, installs it.
# Usage: ./build.sh
# No sudo needed. Installs to /Applications (or ~/Applications if that isn't writable).
#
# Choices (set them in front of the command, e.g.  ENGINE=bundled ./build.sh):
#   ENGINE=bundled    (default) scrcpy + adb are put inside the app, so it works on a Mac without Homebrew
#   ENGINE=homebrew   the app uses scrcpy + adb from Homebrew instead (the way it was before version 1.2)
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"   (default "-": ad-hoc)
#   INSTALL=0         build and sign only, don't copy to /Applications (release.sh uses this)

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Phone Mirror"
EXECUTABLE="PhoneMirror"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
ENGINE="${ENGINE:-bundled}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
INSTALL="${INSTALL:-1}"

echo "==> 1/5 Compiling (swift build -c release)…"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/$EXECUTABLE"

echo "==> 2/5 Creating the .app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ "$ENGINE" = "bundled" ]; then
    echo "    Putting the mirroring engine (scrcpy + adb) inside the app…"
    Scripts/fetch_engine.sh
    mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/Engine"
    cp Vendor/engine/scrcpy Vendor/engine/adb "$APP/Contents/Helpers/"
    cp Vendor/engine/scrcpy-server Vendor/engine/scrcpy.png Vendor/engine/disconnected.png \
       "$APP/Contents/Resources/Engine/"
    cp Vendor/engine/LICENSE "$APP/Contents/Resources/Engine/LICENSE-scrcpy.txt"
    cp Resources/THIRD-PARTY-NOTICES.txt "$APP/Contents/Resources/"
fi

echo "==> 3/5 Generating the app icon…"
ICON_WORK="$BUILD_DIR/icon"
ICONSET="$ICON_WORK/AppIcon.iconset"
rm -rf "$ICON_WORK"
mkdir -p "$ICONSET"
swift Scripts/make_icon.swift "$ICON_WORK/icon_1024.png"
for SIZE in 16 32 128 256 512; do
    sips -z $SIZE $SIZE "$ICON_WORK/icon_1024.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z $DOUBLE $DOUBLE "$ICON_WORK/icon_1024.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "==> 4/5 Signing (ad-hoc, hardened runtime)…"
    TIMESTAMP=""
else
    echo "==> 4/5 Signing as ${SIGN_IDENTITY} (hardened runtime)…"
    TIMESTAMP="--timestamp" # Apple's notary service requires a signed time
fi
if [ "$ENGINE" = "bundled" ]; then
    # From the inside out: scrcpy first, then the app around it. adb is left alone: it keeps
    # Google's own signature, which is checked here.
    codesign --force --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP "$APP/Contents/Helpers/scrcpy"
    codesign --verify --strict "$APP/Contents/Helpers/adb"
    codesign --force --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP "$APP"
else
    codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP "$APP"
fi
codesign --verify --strict --deep --verbose=1 "$APP"

if [ "$INSTALL" != "1" ]; then
    echo ""
    echo "✅ Built: $APP (not installed)"
    exit 0
fi

echo "==> 5/5 Installing…"
if [ -w /Applications ]; then
    DEST_DIR="/Applications"
else
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/$APP_NAME.app"

# Quit a running copy first so we can replace it. A normal "quit" lets the
# app clean up (stop scrcpy etc.); pkill is only a fallback.
if pgrep -x "$EXECUTABLE" >/dev/null; then
    echo "    Quitting the running copy of ${APP_NAME}…"
    osascript -e "quit app id \"in.phonemirror.app\"" >/dev/null 2>&1 || true
    sleep 2
    pkill -x "$EXECUTABLE" 2>/dev/null || true
fi

rm -rf "$DEST"
ditto "$APP" "$DEST"

echo ""
echo "✅ Installed: $DEST"
echo "   Open it with:  open \"$DEST\""
