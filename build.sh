#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 KC2RGW Chris
#
# Build SimpleDesktopWidget.app (universal: Apple Silicon + Intel).
#
#   ./build.sh            build/SimpleDesktopWidget.app
#   ./build.sh install    ...and copy it to ~/Applications and (re)start it
#   ./build.sh dmg        ...and make build/SimpleDesktopWidget-<version>.dmg
#
# Signs with a local "Apple Development" identity when there is one (so macOS keeps
# the Calendar, Location, Screen Recording and Automation permissions across
# rebuilds); otherwise, and always on CI, ad hoc. No signing key is kept anywhere.
set -euo pipefail
cd "${0:A:h}"

VERSION=$(<VERSION)
ARCHS=(--arch arm64 --arch x86_64)

swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/SimpleDesktopWidget"

APP=build/SimpleDesktopWidget.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

ID=""
if [[ -z "${CI:-}" ]]; then
    ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
fi
codesign --force --sign "${ID:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP $VERSION ($(lipo -archs "$APP/Contents/MacOS/SimpleDesktopWidget"); signed: ${ID:-ad hoc})"

case "${1:-}" in
install)
    pkill -x SimpleDesktopWidget || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/SimpleDesktopWidget.app
    ditto "$APP" ~/Applications/SimpleDesktopWidget.app
    open ~/Applications/SimpleDesktopWidget.app
    echo "Installed and started ~/Applications/SimpleDesktopWidget.app"
    ;;
dmg)
    STAGE=build/dmg
    OUT=build/SimpleDesktopWidget-$VERSION.dmg
    rm -rf "$STAGE" "$OUT"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/SimpleDesktopWidget.app"
    ln -s /Applications "$STAGE/Applications"
    cp LICENSE "$STAGE/LICENSE.txt"
    xattr -cr "$STAGE" 2>/dev/null || true
    hdiutil create -volname "SimpleDesktopWidget $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$OUT" >/dev/null
    rm -rf "$STAGE"
    shasum -a 256 "$OUT"
    ;;
esac
