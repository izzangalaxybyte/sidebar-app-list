import AppKit

/// Menu-bar item: the only persistent UI. Shows permission state and offers
/// a manual way to reveal the sidebar.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let permissionItem = NSMenuItem()
    private let showSidebar: () -> Void

    init(showSidebar: @escaping () -> Void) {
        self.showSidebar = showSidebar
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        item.button?.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Sidebar App List")
        item.button?.image?.isTemplate = true

        let hint = NSMenuItem(title: "Move the cursor to the right screen edge", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(NSMenuItem(title: "Show Sidebar", action: #selector(showSidebarAction), keyEquivalent: "s"))
        menu.addItem(.separator())
        permissionItem.action = #selector(openAccessibilitySettings)
        permissionItem.target = self
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Sidebar App List", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for entry in menu.items where entry.target == nil && entry.action != nil && entry.action != #selector(NSApplication.terminate(_:)) {
            entry.target = self
        }
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if AccessibilityPermission.isTrusted {
            permissionItem.title = "Accessibility access granted"
            permissionItem.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        } else {
            permissionItem.title = "Grant Accessibility Access…"
            permissionItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        }
    }

    @objc private func showSidebarAction() { showSidebar() }
    @objc private func openAccessibilitySettings() { AccessibilityPermission.openSystemSettings() }
}
