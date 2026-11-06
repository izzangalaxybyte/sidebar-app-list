import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = WindowStore()
    private var panelController: SidebarPanelController?
    private var statusItem: StatusItemController?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Mirrors LSUIElement for the bare `swift run` binary.
        NSApp.setActivationPolicy(.accessory)

        let controller = SidebarPanelController(store: store)
        panelController = controller
        statusItem = StatusItemController(showSidebar: { [weak controller] in controller?.show() })

        if AccessibilityPermission.isTrusted {
            store.start()
        } else {
            AccessibilityPermission.promptSystemDialog()
            waitForPermission()
            // First-run guide: slide the sidebar out so its permission notice is
            // visible next to the system prompt. It hides once the cursor leaves.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak controller] in controller?.show() }
        }
    }

    private func waitForPermission() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            guard AccessibilityPermission.isTrusted else { return }
            timer.invalidate()
            self?.permissionTimer = nil
            self?.store.start()
        }
        // .common so it keeps polling while the guide alert runs its modal loop.
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }
}
