#!/bin/bash
# Builds the Swift package and wraps the binary in a minimal .app bundle
# (LSUIElement needs a bundle to take effect, and Accessibility permission
# is keyed to the bundle's code signature).
#
# Usage: Scripts/bundle.sh [debug|release]
# Env:   CODESIGN_IDENTITY  signing identity. Default: the first code-signing
#                           identity in your keychain, else "-" (ad-hoc).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/SidebarAppList.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/SidebarAppList"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SidebarAppList"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/^ *1) [0-9A-F]* "\(.*\)"$/\1/p' || true)"
fi
if [ -z "$CODESIGN_IDENTITY" ]; then
    CODESIGN_IDENTITY="-"
    echo "note: no code-signing identity found; signing ad-hoc." >&2
    echo "      macOS ties the Accessibility grant to this exact build, so you will" >&2
    echo "      have to re-grant after every rebuild. Run Scripts/make-signing-cert.sh once to fix." >&2
fi

codesign --force --sign "$CODESIGN_IDENTITY" "$APP"
echo "Built $APP (signed: $CODESIGN_IDENTITY)"
