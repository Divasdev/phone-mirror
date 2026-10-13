#!/bin/bash
# release.sh — makes the file other people download: dist/Phone-Mirror.dmg
# It contains the app with scrcpy + adb inside, so it works on a Mac without Homebrew.
#
# Usage:
#   ./release.sh
#       A preview build, signed "ad-hoc". It works on this Mac. On other Macs macOS will
#       refuse to open it, because Apple has not checked it.
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE="phone-mirror" ./release.sh
#       The real thing: signed with your Apple Developer ID and checked ("notarized") by
#       Apple, so it opens on any Mac with a normal double-click. This needs a paid Apple
#       Developer Program membership. One-time setup of the profile name used above:
#         xcrun notarytool store-credentials "phone-mirror" --apple-id you@example.com --team-id TEAMID
#       (it asks for an app-specific password and keeps it in your Keychain, not in this folder)

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Phone Mirror"
APP="build/$APP_NAME.app"
DIST="dist"
DMG="$DIST/Phone-Mirror.dmg"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

echo "==> Building the app with the engine inside…"
ENGINE=bundled INSTALL=0 SIGN_IDENTITY="$SIGN_IDENTITY" ./build.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

echo "==> Making the disk image…"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"   # so people can drag the app onto it
mkdir -p "$DIST"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [ "$SIGN_IDENTITY" != "-" ]; then
    echo "==> Signing the disk image…"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

if [ -n "$NOTARY_PROFILE" ]; then
    if [ "$SIGN_IDENTITY" = "-" ]; then
        echo "Apple only checks apps signed with a Developer ID. Set SIGN_IDENTITY too." >&2
        exit 1
    fi
    echo "==> Sending it to Apple to be checked (this takes a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "==> What macOS will say when someone opens it:"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" || true
fi

( cd "$DIST" && shasum -a 256 "Phone-Mirror.dmg" > SHA256SUMS.txt )

echo ""
echo "✅ $DMG  (version $VERSION, $(du -h "$DMG" | awk '{print $1}'))"
echo "   SHA-256: $(awk '{print $1}' "$DIST/SHA256SUMS.txt")"
if [ -z "$NOTARY_PROFILE" ]; then
    echo "   This is a PREVIEW build: not checked by Apple, so other Macs will refuse to open it."
fi
