#!/bin/zsh
# Build SimpleDesktopWidget.app. "./build.sh install" also copies it to ~/Applications and restarts it.
set -euo pipefail
cd "${0:A:h}"

swift build -c release
APP=build/SimpleDesktopWidget.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SimpleDesktopWidget "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Sign with the local Apple Development identity if there is one, so Calendar/Location
# permissions survive rebuilds; otherwise ad hoc.
ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${ID:--}" "$APP"
echo "Built $APP (signed: ${ID:-ad hoc})"

if [[ "${1:-}" == install ]]; then
    pkill -x SimpleDesktopWidget || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/SimpleDesktopWidget.app
    ditto "$APP" ~/Applications/SimpleDesktopWidget.app
    open ~/Applications/SimpleDesktopWidget.app
    echo "Installed and started ~/Applications/SimpleDesktopWidget.app"
fi
