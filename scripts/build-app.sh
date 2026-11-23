#!/bin/bash
#
# Builds Schnitzel.app into ./build/
#
# This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
#
# Usage:
#   scripts/build-app.sh            release build (default)
#   scripts/build-app.sh debug      debug build
#
# Needs only the Xcode Command Line Tools (`xcode-select --install`), not full Xcode.
# The app is signed ad hoc, which is enough to run it on the Mac that built it.

set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
    echo "error: configuration must be 'release' or 'debug', got '$configuration'" >&2
    exit 1
fi

version="$(tr -d '[:space:]' < VERSION)"
# Build number: commit count, so every commit gets a higher number.
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> Building Schnitzel $version ($build_number), $configuration"
swift build -c "$configuration" --arch arm64
bin_dir="$(swift build -c "$configuration" --arch arm64 --show-bin-path)"

app="build/Schnitzel.app"
echo "==> Assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$bin_dir/Schnitzel" "$app/Contents/MacOS/Schnitzel"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp LICENSE "$app/Contents/Resources/LICENSE"
sed -e "s/@VERSION@/$version/" -e "s/@BUILD@/$build_number/" \
    Resources/Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" > /dev/null

echo "==> Signing (ad hoc)"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"

echo "==> Done: $(pwd)/$app"
