import AppKit
import SwiftUI

/// Hover detection that works while the app is inactive. SwiftUI's own
/// `.onHover` is unreliable in non-key windows; an `.activeAlways` tracking
/// area is not. `hitTest` returns nil so clicks fall through to SwiftUI.
struct HoverTracker: NSViewRepresentable {
    @Binding var isHovering: Bool
    /// Called on enter with the view's frame in screen coordinates, and with
    /// nil on exit.
    var onHoverFrame: ((NSRect?) -> Void)? = nil

    func makeNSView(context: Context) -> HoverTrackingView { HoverTrackingView() }

    func updateNSView(_ view: HoverTrackingView, context: Context) {
        let onHoverFrame = onHoverFrame
        view.onChange = { hovering in
            if isHovering != hovering { isHovering = hovering }
        }
        view.onFrame = onHoverFrame
    }
}

final class HoverTrackingView: NSView {
    var onChange: ((Bool) -> Void)?
    var onFrame: ((NSRect?) -> Void)?
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

    override func mouseEntered(with event: NSEvent) {
        onChange?(true)
        if let window { onFrame?(window.convertToScreen(convert(bounds, to: nil))) }
    }

    override func mouseExited(with event: NSEvent) {
        onChange?(false)
        onFrame?(nil)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
