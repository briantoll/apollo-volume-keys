#!/bin/bash
# Build "Apollo Volume Keys.app" into ./build.
#   ./build.sh            build only
#   ./build.sh install    build, copy to ~/Applications, and (re)launch
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Apollo Volume Keys.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/ApolloVolumeKeys"
cp Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature: macOS ties the Accessibility grant to it, so after a
# rebuild you must remove and re-add the app under Privacy & Security.
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = install ]; then
    DEST="$HOME/Applications/Apollo Volume Keys.app"
    pkill -x ApolloVolumeKeys 2>/dev/null || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "Installed and launched $DEST"
fi
