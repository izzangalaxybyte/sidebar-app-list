import AppKit
import SwiftUI

/// Borderless floating panel that can take key (needed for clicks to land)
/// but never activates the app.
final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the sidebar panel and the edge trigger, and decides when to slide
/// in and out.
final class SidebarPanelController {
    static let width: CGFloat = 280
    static let margin: CGFloat = 8
    static let cornerRadius: CGFloat = 12
    static let animationDuration: TimeInterval = 0.15
    static let hideGrace: TimeInterval = 0.12

    private let store: WindowStore
    private let panel: SidebarPanel
    private let edge: EdgeTriggerWindow
    private let contentView: TrackingEffectView
    private let preview: HoverPreview
    private var hideCheck: DispatchWorkItem?
    private var screenToken: NSObjectProtocol?
    private(set) var isShown = false

    init(store: WindowStore) {
        self.store = store
        preview = HoverPreview(store: store, thumbnail: ThumbnailPanelController())

        panel = SidebarPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // Must come after isFloatingPanel, which resets the level to .floating.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)

        contentView = TrackingEffectView()
        contentView.material = .sidebar
        contentView.blendingMode = .behindWindow
        contentView.state = .active
        contentView.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        panel.contentView = contentView

        edge = EdgeTriggerWindow()

        let sidebar = SidebarView(
            store: store,
            onSelectWindow: { [weak self] window in
                self?.preview.commit()
                self?.store.activate(window)
                self?.hide()
            },
            onSelectApp: { [weak self] pid in
                self?.preview.commit()
                self?.store.activateApp(pid: pid)
                self?.hide()
            },
            onCloseWindow: { [weak self] window in
                self?.store.close(window)
            },
            onHoverRow: { [weak self] row, frame in
                self?.preview.hoverRow(row, frame: frame)
            }
        )
        let hosting = NSHostingView(rootView: sidebar)
        // The panel frame is ours to control; never let SwiftUI content resize it.
        hosting.sizingOptions = []
        hosting.frame = contentView.bounds
        hosting.autoresizingMask = [.width, .height]
        contentView.addSubview(hosting)

        preview.sidebarMinX = { [weak self] in self?.panel.frame.minX ?? 0 }
        preview.thumbnail.onEnter = { [weak self] in
            self?.cancelHideCheck()
            self?.preview.thumbnailEntered()
        }
        preview.thumbnail.onExit = { [weak self] in
            self?.preview.thumbnailExited()
            self?.scheduleHideCheck()
        }
        preview.thumbnail.onClick = { [weak self] in
            guard let self, let window = self.preview.current?.window else { return }
            self.preview.commit()
            self.store.activate(window)
            self.hide()
        }

        contentView.onEnter = { [weak self] in self?.cancelHideCheck() }
        contentView.onExit = { [weak self] in self?.scheduleHideCheck() }
        edge.onEnter = { [weak self] in self?.show() }
        edge.onExit = { [weak self] in self?.scheduleHideCheck() }

        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.layout() }

        layout()
        edge.orderFrontRegardless()
    }

    // MARK: Geometry

    private var screen: NSScreen? { NSScreen.screens.first }

    private var restingFrame: NSRect {
        guard let screen else { return .zero }
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.maxX - Self.width - Self.margin,
            y: visible.minY + Self.margin,
            width: Self.width,
            height: visible.height - Self.margin * 2
        )
    }

    private var hiddenFrame: NSRect {
        guard let screen else { return .zero }
        var frame = restingFrame
        frame.origin.x = screen.frame.maxX
        return frame
    }

    /// Region in which the cursor counts as "still on the sidebar": the panel
    /// plus the gap between it and the screen edge, so crossing the margin
    /// does not flicker the panel.
    private var hotRect: NSRect {
        guard let screen else { return .zero }
        let frame = restingFrame
        return NSRect(x: frame.minX, y: frame.minY, width: screen.frame.maxX - frame.minX + 1, height: frame.height)
    }

    private func layout() {
        guard let screen else { return }
        edge.layout(on: screen)
        if isShown {
            panel.setFrame(restingFrame, display: true)
        }
    }

    // MARK: Show / hide

    func show() {
        cancelHideCheck()
        guard !isShown else { return }
        isShown = true
        store.refreshNow()

        panel.alphaValue = 0
        panel.setFrame(hiddenFrame, display: false)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(restingFrame, display: true)
            panel.animator().alphaValue = 1
        }
        // Covers shows where the cursor never enters the panel (first run,
        // menu item, cursor resting in the gap).
        scheduleHideCheck()
    }

    func hide() {
        cancelHideCheck()
        guard isShown else { return }
        isShown = false
        // No-op if a click committed; otherwise puts the pre-preview window back.
        preview.end()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(hiddenFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isShown else { return }
            self.panel.orderOut(nil)
        })
    }

    private func scheduleHideCheck() {
        cancelHideCheck()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            let onThumbnail = self.preview.thumbnail.hotFrame?.contains(mouse) ?? false
            if !self.hotRect.contains(mouse) && !onThumbnail {
                self.hide()
            } else if !self.panel.frame.contains(mouse) && !(self.preview.thumbnail.frame?.contains(mouse) ?? false) {
                // In the strip or a gap beside the panel or thumbnail, where no
                // tracking area will report an exit: keep checking until it moves on.
                self.scheduleHideCheck()
            }
        }
        hideCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideGrace, execute: item)
    }

    private func cancelHideCheck() {
        hideCheck?.cancel()
        hideCheck = nil
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Visual-effect background that also reports when the cursor leaves the panel.
final class TrackingEffectView: NSVisualEffectView {
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
