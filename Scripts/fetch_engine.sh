#!/bin/bash
# fetch_engine.sh — gets the mirroring engine that is put INSIDE the app for other people:
# the official scrcpy release for Apple Silicon Macs, which also contains adb.
# The download is checked against a known SHA-256 fingerprint before it is unpacked.
# Nothing is installed on this Mac: the files only go into Vendor/ in this folder.
# To move to a newer scrcpy: change VERSION and SHA256 (from SHA256SUMS.txt on the release page).

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="5.0"
SHA256="7cb4e41c859b05b36e89dc9be6c353cc5980c00d7f7f6a763b5b355551b82e9c"
NAME="scrcpy-macos-aarch64-v${VERSION}"
URL="https://github.com/Genymobile/scrcpy/releases/download/v${VERSION}/${NAME}.tar.gz"
DEST="Vendor/engine"

if [ "$(uname -m)" != "arm64" ]; then
    echo "This script only knows the Apple Silicon build of scrcpy." >&2
    exit 1
fi

if [ -f "$DEST/VERSION" ] && [ "$(cat "$DEST/VERSION")" = "$VERSION" ] \
   && [ -x "$DEST/scrcpy" ] && [ -x "$DEST/adb" ] && [ -f "$DEST/scrcpy-server" ]; then
    echo "    Engine already here: scrcpy ${VERSION}"
    exit 0
fi

mkdir -p Vendor
ARCHIVE="Vendor/${NAME}.tar.gz"
echo "    Downloading scrcpy ${VERSION} from github.com/Genymobile/scrcpy…"
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 -o "$ARCHIVE" "$URL"

ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL" != "$SHA256" ]; then
    echo "The download does not match the expected fingerprint. It was deleted." >&2
    echo "  expected: $SHA256" >&2
    echo "  got:      $ACTUAL" >&2
    rm -f "$ARCHIVE"
    exit 1
fi

rm -rf "$DEST" "Vendor/${NAME}"
tar -xzf "$ARCHIVE" -C Vendor
mv "Vendor/${NAME}" "$DEST"
echo "$VERSION" > "$DEST/VERSION"
rm -f "$ARCHIVE"
echo "    Fingerprint OK. Engine unpacked to $DEST"
