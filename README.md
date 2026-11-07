# Sidebar App List

A menu-bar-only macOS app that shows your open windows as a vertical tab
list, in the style of the Arc / Zen browser sidebar. Move the cursor to the
right edge of the screen and a dark, blurred panel slides out with one row
per window, grouped by app, in an order you control. Resting on a row
pops up a small thumbnail of that window beside the sidebar, like the
Windows taskbar; resting on the thumbnail previews the full window. Click
the row or the thumbnail to switch to it, or move away and the window you
were on comes back. Hover a row and click × to close it.

Requires macOS 14 or later. Swift, SwiftUI + AppKit, no third-party
dependencies, no private APIs.

## Install a release

Download `SidebarAppList-<version>.pkg` from the [releases page](https://github.com/izzangalaxybyte/sidebar-app-list/releases)
and open it; it installs `SidebarAppList.app` into Applications. The package
is not notarized with Apple, so if a plain double-click is refused,
right-click the .pkg and choose Open; on macOS 15 or later, open it once and
then click Open Anyway under System Settings → Privacy & Security. Launch the
app from Applications and grant Accessibility as described below.

## Build and run

```bash
make app
```

This runs `swift build -c release`, wraps the binary in
`build/SidebarAppList.app`, and ad-hoc signs it. Then:

```bash
open build/SidebarAppList.app
```

or `make run` to do both. A debug build is `Scripts/bundle.sh debug`.

`swift build` / `swift run` also work, but the bare binary has no
`Info.plist`, so it only approximates `LSUIElement` by setting the accessory
activation policy at launch, and Accessibility permission is granted to the
binary's path rather than to an app bundle. Use the `.app` for day-to-day use.

To open the package in Xcode: `open Package.swift`. Run the `SidebarAppList`
scheme; the same caveats as `swift run` apply.

## Cutting a release

```bash
make release
```

`Scripts/release.sh` builds the signed app, wraps it in an Installer package
with `productbuild` (`make pkg` does just that step), tags the current commit
as `v<version>` and publishes a GitHub release with the .pkg attached. The
package itself is unsigned: signing it needs a Developer ID Installer
certificate from Apple. The version comes from
`CFBundleShortVersionString` in `Resources/Info.plist`; bump it there before
releasing. Requires a clean working tree and an authenticated `gh`.

## Accessibility permission

Listing windows, raising them, and closing them all go through the
Accessibility API, which macOS gates behind a per-app permission.

On first launch without permission the app:

1. Asks macOS to show its standard "SidebarAppList would like to control this
   computer using accessibility features" prompt.
2. Slides the sidebar out with a short notice and an "Open System Settings"
   button.

Grant it under **System Settings → Privacy & Security → Accessibility** by
switching on `SidebarAppList`. The app polls for the change once a second and
starts listing windows as soon as it is granted, with no restart. The
menu-bar item also shows the current permission state and has a shortcut to
the settings pane.

**The toggle is on but the sidebar still asks for permission.** macOS ties
the grant to the exact code signature it saw when the app first prompted.
With an ad-hoc signature every rebuild changes that signature, so the entry
in System Settings stays switched on but no longer matches the binary. Clear
the stale entry and grant again:

```bash
tccutil reset Accessibility dev.disperse.SidebarAppList
```

(or remove SidebarAppList from the Accessibility list with − and add the
new build with +). To stop this recurring, sign every build with the same
identity. If you have no Apple Development certificate, create a
self-signed one once:

```bash
Scripts/make-signing-cert.sh
```

It asks for your login password twice: once in a dialog to trust the
certificate, once in the terminal so `codesign` can use the key without
prompting on every build. If a "codesign wants to use key" dialog still
appears, click Always Allow. `make app`
picks the identity up automatically; `CODESIGN_IDENTITY` overrides it. You
need to clear the stale ad-hoc entry one last time after switching.

## How it works

- **Menu-bar only.** `LSUIElement` in `Info.plist`; no Dock icon, no main
  window. The status item has Show Sidebar, the permission state, and Quit.
- **Edge trigger.** A 1pt-wide invisible, non-activating panel sits along the
  right edge of the primary display at status-bar level. Its `NSTrackingArea`
  (`activeAlways`) is the only trigger; there is no global event tap or mouse
  polling.
- **Sidebar panel.** A borderless `NSPanel` with `nonactivatingPanel`, so it
  takes clicks without ever activating this app or stealing focus from the
  frontmost one. Background is an `NSVisualEffectView` (sidebar material,
  dark appearance, behind-window blur) masked to a 12pt radius. Slide-in and
  slide-out are 150ms frame + alpha animations. It hides when the cursor
  leaves the panel and the strip between it and the screen edge, after a
  120ms grace period, and after you pick a window.
- **Window list.** `AXUIElementCreateApplication` + `kAXWindowsAttribute`
  for every app with a regular activation policy. Standard windows and
  titled dialogs are kept. Since the AX window list spans all Spaces, each
  window's frame is matched against the window server's on-screen list
  (`CGWindowListCopyWindowInfo` with `optionOnScreenOnly`, which does not
  need Screen Recording permission) to keep only the current Space.
  Minimized windows and windows of hidden apps can't be on screen but can be
  brought back, so they are listed too, dimmed.
- **Live updates.** `NSWorkspace` notifications for launch, quit, activate,
  hide, unhide and Space change; one `AXObserver` per app for window
  created, focused-window changed, title changed, minimize, deminimize, and
  app hidden/shown, plus `kAXUIElementDestroyed` registered on each window.
  Every event coalesces into one refresh ~50ms later; enumeration runs off
  the main thread with a 300ms per-app messaging timeout so an unresponsive
  app can't stall the UI.
- **Raise.** `kAXRaiseAction` on the window, then `kAXFrontmost` on the app
  and `NSRunningApplication.activate()`. Minimized windows are un-minimized
  first. **Close** presses the window's `kAXCloseButton`.
- **Hover thumbnail and preview.** Resting on a row for 120ms shows a
  small card to the left of the sidebar, centred on the row, with a live
  still of the window (ScreenCaptureKit, `SCScreenshotManager`). The window
  is matched to its window-server ID by the same frame matching used for
  the Space filter. Moving between rows switches the card at once. Resting
  on the card raises the full window the same way a click does; the first
  such preview records which app and window were in front, and leaving the
  card or closing the sidebar raises them again, while clicking the row or
  the card keeps it. The card and the gap beside it count as part of the
  sidebar for auto-hide. Minimized windows get a card but are not
  previewed, since that would un-minimize them. Window images need Screen
  Recording permission, which the app never asks for on its own: use
  **Enable Window Thumbnails…** in the menu-bar item (macOS applies it after
  a relaunch). Without it the card shows the app icon. The
  most-recently-used order is frozen while the sidebar is open so previews
  don't reorder rows under the cursor.
- **Ordering.** Rows are one flat list. The order is seeded once at start
  (frontmost app first, then launch order, then stable-sorted by the app
  order saved from the previous run) and after that only you change it.
  Switching apps never reorders rows. New windows appear right after their
  app's last row, or where its rows used to be; apps seen for the first time
  go to the end. Apps with no windows on this Space get a single row with
  the app name; clicking it activates the app. The app-level order is saved
  to user defaults, so a relaunch keeps your arrangement (window-level
  order can't persist, since window identities don't survive a restart).
- **Drag to rearrange.** Drag any row up or down; rows reorder live as the
  cursor crosses them. Consecutive rows of the same app form a group with a
  divider, so dragging a window between another app's windows splits it
  into its own group. Implemented with a plain `DragGesture` rather than
  system drag-and-drop, which keeps it working inside the non-activating
  panel; hover previews are suppressed while dragging.

## Layout

```
Package.swift                      SwiftPM manifest (macOS 14+, one executable target)
Resources/Info.plist               Bundle plist (LSUIElement)
Scripts/bundle.sh                  Build + wrap into build/SidebarAppList.app + codesign
Sources/SidebarAppList/
  main.swift                       NSApplication bootstrap
  AppDelegate.swift                Permission flow, wires store + panel + status item
  StatusItemController.swift       Menu-bar item
  Accessibility/AXHelpers.swift    Typed wrappers over AXUIElement attributes/actions
  Accessibility/AccessibilityPermission.swift
  Model/WindowModel.swift          WindowItem / AppGroup
  Model/WindowEnumerator.swift     AX + CGWindowList enumeration (background-safe)
  Model/WindowStore.swift          MRU order, AXObservers, refresh coalescing, actions
  Model/HoverPreview.swift         Row → thumbnail → full-window preview state machine
  Model/WindowThumbnailer.swift    ScreenCaptureKit window stills
  UI/EdgeTriggerWindow.swift       1pt edge strip with tracking area
  UI/SidebarPanel.swift            Floating panel, slide animation, hide logic
  UI/SidebarView.swift             SwiftUI list and rows
  UI/ThumbnailPanel.swift          Hover thumbnail card beside the sidebar
  UI/HoverTracker.swift            Hover detection that works in inactive windows
```

## Known limits

- Primary display only. The edge strip and panel follow `NSScreen.screens[0]`
  and re-layout on display changes.
- "Current Space" is inferred by matching AX window frames to on-screen
  window-server frames, since there is no public API that maps an
  `AXUIElement` to a window ID or Space. Two same-sized windows of one app
  stacked exactly on top of each other on different Spaces would both match.
- Apps that don't implement Accessibility (some cross-platform toolkits until
  AX is enabled) show as a single app row with no windows.
