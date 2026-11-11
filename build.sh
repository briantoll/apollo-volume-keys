#!/bin/bash
# Build "Apollo Volume Keys.app" into ./build.
#   ./build.sh            build only
#   ./build.sh install    build, copy to ~/Applications, (re)launch, and put
#                         the apollo-volume-keys command in ~/.local/bin
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Apollo Volume Keys.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/ApolloVolumeKeys"
cp Info.plist "$APP/Contents/Info.plist"
# AppIcon.icns is checked in; regenerate it with `swift make-icon.swift`.
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
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
    # Launch Services can still be tearing down the instance killed above.
    open "$DEST" || { sleep 2; open "$DEST"; }
    # The same binary is the command-line tool; run it for the commands.
    mkdir -p "$HOME/.local/bin"
    # A wrapper, not a symlink: through a symlink the binary can't find its bundle.
    CLI="$HOME/.local/bin/apollo-volume-keys"
    rm -f "$CLI"
    printf '#!/bin/sh\nexec "%s/Contents/MacOS/ApolloVolumeKeys" "$@"\n' "$DEST" > "$CLI"
    chmod +x "$CLI"
    echo "Installed and launched $DEST"
    echo "Installed the apollo-volume-keys command in ~/.local/bin"
fi
