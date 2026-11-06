#!/bin/bash
# Wraps build/SidebarAppList.app (from Scripts/bundle.sh) in a macOS Installer
# package that installs it to /Applications.
#
# Usage: Scripts/package.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
APP="build/SidebarAppList.app"
PKG="build/SidebarAppList-$VERSION.pkg"

[ -d "$APP" ] || { echo "error: $APP not found; run Scripts/bundle.sh first." >&2; exit 1; }

rm -f "$PKG"
productbuild \
    --component "$APP" /Applications \
    --identifier dev.disperse.SidebarAppList.pkg \
    --version "$VERSION" \
    "$PKG"
echo "Built $PKG"
