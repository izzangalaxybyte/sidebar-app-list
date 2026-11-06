import AppKit
import ApplicationServices

/// Reads window lists through the Accessibility API. Safe to call off the
/// main thread; every AX call here is a synchronous mach message with a
/// short timeout so an unresponsive app cannot stall the UI.
enum WindowEnumerator {
    struct AppRequest {
        let pid: pid_t
        let isHidden: Bool
    }

    private static let messagingTimeout: Float = 0.3
    private static let frameTolerance: CGFloat = 2

    static func windows(for apps: [AppRequest], frontmostPID: pid_t?) -> [pid_t: [WindowItem]] {
        let onScreen = onScreenFrames()
        var result: [pid_t: [WindowItem]] = [:]

        for app in apps {
            let appElement = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

            let focused = app.pid == frontmostPID ? appElement.element(kAXFocusedWindowAttribute) : nil
            var items: [WindowItem] = []

            for window in appElement.elements(kAXWindowsAttribute) {
                let subrole = window.string(kAXSubroleAttribute) ?? kAXStandardWindowSubrole
                let title = window.string(kAXTitleAttribute) ?? ""
                let isMinimized = window.bool(kAXMinimizedAttribute) ?? false

                switch subrole {
                case kAXStandardWindowSubrole:
                    break
                case kAXDialogSubrole where !title.isEmpty:
                    break
                default:
                    continue
                }

                // "Current Space only": AX lists windows on every Space, so
                // keep only those the window server reports as on screen.
                // Minimized windows and hidden apps are never on screen but
                // can be brought back here, so they pass through.
                if !isMinimized && !app.isHidden {
                    guard let frame = window.frame, matches(frame, onScreen[app.pid] ?? []) else { continue }
                }

                let isFrontmost = focused.map { CFEqual($0, window) } ?? false
                items.append(WindowItem(
                    id: "\(app.pid):\(window.stableHash)",
                    pid: app.pid,
                    title: title,
                    element: window,
                    isMinimized: isMinimized,
                    isFrontmost: isFrontmost
                ))
            }
            result[app.pid] = items
        }
        return result
    }

    /// Frames of normal-layer windows on the current Space, keyed by owner pid.
    /// `kCGWindowBounds` does not need Screen Recording permission (window
    /// titles would, which is why we never read `kCGWindowName`).
    private static func onScreenFrames() -> [pid_t: [CGRect]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [:] }

        var frames: [pid_t: [CGRect]] = [:]
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let owner = info[kCGWindowOwnerPID as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            frames[pid_t(owner), default: []].append(bounds)
        }
        return frames
    }

    private static func matches(_ frame: CGRect, _ candidates: [CGRect]) -> Bool {
        candidates.contains { candidate in
            abs(candidate.minX - frame.minX) <= frameTolerance
                && abs(candidate.minY - frame.minY) <= frameTolerance
                && abs(candidate.width - frame.width) <= frameTolerance
                && abs(candidate.height - frame.height) <= frameTolerance
        }
    }
}
