#!/bin/bash
# Builds a signed release .app, wraps it in a macOS Installer package that
# installs to /Applications, and publishes a GitHub release with the .pkg
# attached. Tags the current commit as v<version>.
#
# Usage: Scripts/release.sh [version]
#        version defaults to CFBundleShortVersionString in Resources/Info.plist.
# Needs: gh (authenticated), a clean working tree, a signing identity for the
#        app (see Scripts/make-signing-cert.sh). The package itself is unsigned:
#        signing it needs a Developer ID Installer certificate from Apple.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
TAG="v$VERSION"
PKG="build/SidebarAppList-$VERSION.pkg"

if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree has uncommitted changes; commit or stash them first." >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "error: tag $TAG already exists; bump CFBundleShortVersionString in Resources/Info.plist." >&2
    exit 1
fi

Scripts/bundle.sh release
Scripts/package.sh "$VERSION"

gh release create "$TAG" "$PKG" --title "SidebarAppList $VERSION" --notes-file - <<NOTES
## Install

1. Download \`SidebarAppList-$VERSION.pkg\` below.
2. Open it. It installs \`SidebarAppList.app\` into your Applications folder. The package is not notarized with Apple, so if a plain double-click is refused, right-click the .pkg and choose **Open**; on macOS 15 or later, open it once, then click **Open Anyway** under System Settings → Privacy & Security.
3. Launch SidebarAppList from Applications. It lives in the menu bar only.
4. Move the cursor to the right edge of the screen. The sidebar slides out asking for Accessibility access; grant it under System Settings → Privacy & Security → Accessibility. The app picks the grant up within a second.

Quit it from its menu-bar icon.
NOTES

echo "Published $TAG: $(gh release view "$TAG" --json url -q .url)"
