import AppKit
import SwiftUI

/// What the thumbnail is showing. Published so the SwiftUI card updates in
/// place when the captured image arrives.
final class ThumbnailModel: ObservableObject {
    @Published var title = ""
    @Published var icon: NSImage?
    @Published var image: NSImage?
    @Published var note: String?
    @Published var imageSize = ThumbnailPanelController.placeholderSize
}

/// The small floating card shown beside the sidebar when resting on a row,
/// like the taskbar thumbnails on Windows. Resting on the card previews the
/// full window; clicking it switches to that window.
final class ThumbnailPanelController {
    static let maxImageSize = CGSize(width: 240, height: 170)
    static let placeholderSize = CGSize(width: 240, height: 110)
    static let padding: CGFloat = 8
    static let headerHeight: CGFloat = 18
    static let spacing: CGFloat = 6
    static let gap: CGFloat = 8
    static let cornerRadius: CGFloat = 10

    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onClick: (() -> Void)?

    private let panel: SidebarPanel
    private let contentView: TrackingEffectView
    private let model = ThumbnailModel()
    private var anchor: NSRect = .zero
    private var sidebarMinX: CGFloat = 0
    private var captureTask: Task<Void, Never>?
    private(set) var windowID: String?
    private(set) var isShown = false

    init() {
        panel = SidebarPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize(for: Self.placeholderSize)),
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
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)

        contentView = TrackingEffectView()
        contentView.material = .hudWindow
        contentView.blendingMode = .behindWindow
        contentView.state = .active
        contentView.maskImage = SidebarPanelController.roundedMask(radius: Self.cornerRadius)
        panel.contentView = contentView

        let hosting = NSHostingView(rootView: ThumbnailCard(model: model, onClick: { [weak self] in self?.onClick?() }))
        hosting.sizingOptions = []
        hosting.frame = contentView.bounds
        hosting.autoresizingMask = [.width, .height]
        contentView.addSubview(hosting)

        contentView.onEnter = { [weak self] in self?.onEnter?() }
        contentView.onExit = { [weak self] in self?.onExit?() }
    }

    /// The card plus the strip between it and the sidebar, so crossing that
    /// gap does not count as leaving. Nil while hidden.
    var hotFrame: NSRect? {
        guard isShown else { return nil }
        let frame = panel.frame
        return NSRect(x: frame.minX, y: frame.minY, width: sidebarMinX - frame.minX, height: frame.height)
    }

    var frame: NSRect? { isShown ? panel.frame : nil }

    /// Shows the card for `row`, vertically centred on `rowFrame` (screen
    /// coordinates) and just left of the sidebar.
    func show(_ row: SidebarRow, rowFrame: NSRect, sidebarMinX: CGFloat) {
        guard let window = row.window else { return hide() }
        anchor = rowFrame
        self.sidebarMinX = sidebarMinX

        if windowID != window.id {
            windowID = window.id
            captureTask?.cancel()
            model.title = row.title
            model.icon = row.icon
            model.image = nil
            model.imageSize = Self.placeholderSize
            model.note = window.isMinimized ? "Minimized" : (window.windowID == nil ? "Hidden" : nil)
            if let cgID = window.windowID, WindowThumbnailer.hasPermission {
                startCapture(cgID, for: window.id)
            }
        }
        panel.setFrame(placedFrame(), display: true)
        if !isShown {
            isShown = true
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        captureTask?.cancel()
        captureTask = nil
        windowID = nil
        guard isShown else { return }
        isShown = false
        panel.orderOut(nil)
    }

    private func startCapture(_ cgID: CGWindowID, for id: String) {
        captureTask = Task { @MainActor [weak self] in
            guard let cgImage = await WindowThumbnailer.capture(windowID: cgID, maxSize: Self.maxImageSize),
                  let self, !Task.isCancelled, self.windowID == id
            else { return }
            let backing = NSScreen.main?.backingScaleFactor ?? 2
            let size = CGSize(width: CGFloat(cgImage.width) / backing, height: CGFloat(cgImage.height) / backing)
            self.model.image = NSImage(cgImage: cgImage, size: size)
            self.model.imageSize = size
            if self.isShown { self.panel.setFrame(self.placedFrame(), display: true) }
        }
    }

    private func placedFrame() -> NSRect {
        let size = Self.panelSize(for: model.imageSize)
        var origin = CGPoint(x: sidebarMinX - Self.gap - size.width, y: anchor.midY - size.height / 2)
        if let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.screens.first)?.visibleFrame {
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        return NSRect(origin: origin, size: size)
    }

    static func panelSize(for imageSize: CGSize) -> CGSize {
        let width = max(imageSize.width, 160) + padding * 2
        return CGSize(width: width, height: padding * 2 + headerHeight + spacing + imageSize.height)
    }
}

private struct ThumbnailCard: View {
    @ObservedObject var model: ThumbnailModel
    let onClick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ThumbnailPanelController.spacing) {
            HStack(spacing: 6) {
                if let icon = model.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 14, height: 14)
                }
                Text(model.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(height: ThumbnailPanelController.headerHeight)

            Group {
                if let image = model.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: model.imageSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(ThumbnailPanelController.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.2))
        .overlay(
            RoundedRectangle(cornerRadius: ThumbnailPanelController.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06))
            VStack(spacing: 6) {
                if let icon = model.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 40, height: 40)
                }
                if let note = model.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }
}
