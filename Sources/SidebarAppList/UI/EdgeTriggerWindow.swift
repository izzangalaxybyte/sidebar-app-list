import AppKit

/// A 1pt-wide, invisible, always-on-top strip along the right screen edge.
/// Its tracking area is the only thing that reveals the sidebar; there is
/// no global event tap or mouse polling.
final class EdgeTriggerWindow: NSPanel {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Explicitly false: transparent windows otherwise pass events through.
        ignoresMouseEvents = false

        let view = EdgeTrackingView()
        view.onEnter = { [weak self] in self?.onEnter?() }
        view.onExit = { [weak self] in self?.onExit?() }
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func layout(on screen: NSScreen) {
        let frame = screen.frame
        setFrame(NSRect(x: frame.maxX - 1, y: frame.minY, width: 1, height: frame.height), display: false)
    }
}

private final class EdgeTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
