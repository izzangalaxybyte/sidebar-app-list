import AppKit
import ScreenCaptureKit
import os

private let log = Logger(subsystem: "dev.disperse.SidebarAppList", category: "thumbnail")

/// Captures small still images of windows for the hover thumbnail.
/// Needs Screen Recording permission; without it every capture returns nil
/// and the thumbnail shows the app icon instead. We never prompt on our own:
/// the menu-bar item has an explicit "Enable Window Thumbnails" entry.
enum WindowThumbnailer {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system Screen Recording prompt (first time only) and opens
    /// the settings pane, since macOS only applies the grant after a relaunch.
    static func requestPermission() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// An image of the window fitting in `maxSize` points, at screen scale.
    static func capture(windowID: CGWindowID, maxSize: CGSize) async -> CGImage? {
        guard hasPermission else {
            log.notice("capture skipped: no Screen Recording permission")
            return nil
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }),
                  window.frame.width > 0, window.frame.height > 0
            else {
                log.notice("capture: window \(windowID) not in shareable content (\(content.windows.count) windows)")
                return nil
            }

            let scale = min(maxSize.width / window.frame.width, maxSize.height / window.frame.height, 1)
            let backing = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
            let config = SCStreamConfiguration()
            config.width = max(1, Int(window.frame.width * scale * backing))
            config.height = max(1, Int(window.frame.height * scale * backing))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true

            let filter = SCContentFilter(desktopIndependentWindow: window)
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            log.error("capture failed for \(windowID): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
