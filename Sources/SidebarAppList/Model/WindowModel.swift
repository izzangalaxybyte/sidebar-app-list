import AppKit
import ApplicationServices

struct WindowItem: Identifiable, Equatable {
    let id: String
    let pid: pid_t
    let title: String
    let element: AXUIElement
    let isMinimized: Bool
    var isFrontmost: Bool

    static func == (lhs: WindowItem, rhs: WindowItem) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.isMinimized == rhs.isMinimized
            && lhs.isFrontmost == rhs.isFrontmost
    }
}

/// One sidebar row: a window, or an app that has no windows on this Space.
/// Rows are a flat, user-ordered list; consecutive rows of the same app
/// render as a group.
struct SidebarRow: Identifiable, Equatable {
    let id: String
    let pid: pid_t
    let appName: String
    let icon: NSImage?
    let window: WindowItem?
    let isFrontmostApp: Bool

    var title: String {
        guard let window, !window.title.isEmpty else { return appName }
        return window.title
    }

    static func appRowID(_ pid: pid_t) -> String { "app:\(pid)" }

    static func == (lhs: SidebarRow, rhs: SidebarRow) -> Bool {
        lhs.id == rhs.id
            && lhs.appName == rhs.appName
            && lhs.window == rhs.window
            && lhs.isFrontmostApp == rhs.isFrontmostApp
    }
}
