import AppKit

/// Two-stage hover, like the Windows taskbar: resting on a row shows a small
/// thumbnail of that window beside the sidebar; resting on the thumbnail
/// previews the full window by raising it. Leaving the thumbnail, or the
/// sidebar closing without a pick, puts the previously frontmost window back.
/// Clicking a row or the thumbnail commits, so nothing is restored.
final class HoverPreview {
    static let thumbnailDelay: TimeInterval = 0.12
    static let thumbnailHideDelay: TimeInterval = 0.25
    static let peekDelay: TimeInterval = 0.1

    private let store: WindowStore
    let thumbnail: ThumbnailPanelController
    /// Where the sidebar's left edge is, for placing the thumbnail.
    var sidebarMinX: () -> CGFloat = { 0 }

    private var restorePoint: WindowStore.FocusSnapshot?
    private var pendingShow: DispatchWorkItem?
    private var pendingHide: DispatchWorkItem?
    private var pendingPeek: DispatchWorkItem?
    /// The row whose thumbnail is up (or about to be).
    private(set) var current: SidebarRow?

    init(store: WindowStore, thumbnail: ThumbnailPanelController) {
        self.store = store
        self.thumbnail = thumbnail
    }

    /// Cursor entered a row (with its screen frame) or left it (`nil`).
    func hoverRow(_ row: SidebarRow?, frame: NSRect?) {
        cancel(&pendingShow)
        guard let row, row.window != nil, let frame else {
            // Leave time to cross the gap onto the thumbnail before it goes.
            scheduleThumbnailHide()
            return
        }
        cancel(&pendingHide)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.current = row
            self.thumbnail.show(row, rowFrame: frame, sidebarMinX: self.sidebarMinX())
        }
        pendingShow = item
        // Once a thumbnail is up, moving between rows switches it at once.
        if thumbnail.isShown {
            item.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.thumbnailDelay, execute: item)
        }
    }

    func thumbnailEntered() {
        cancel(&pendingHide)
        cancel(&pendingPeek)
        // Previewing a minimized window would un-minimize it; leave those to clicks.
        guard let window = current?.window, !window.isMinimized else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.restorePoint == nil {
                self.restorePoint = self.store.captureFocus()
            }
            self.store.raise(window)
        }
        pendingPeek = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekDelay, execute: item)
    }

    func thumbnailExited() {
        cancel(&pendingPeek)
        restore()
        scheduleThumbnailHide()
    }

    /// The user picked something: keep what is in front now.
    func commit() {
        cancelAll()
        restorePoint = nil
        hideThumbnail()
    }

    /// The sidebar is closing without a pick: undo any preview.
    func end() {
        cancelAll()
        restore()
        hideThumbnail()
    }

    private func restore() {
        if let restorePoint {
            store.restoreFocus(restorePoint)
        }
        restorePoint = nil
    }

    private func scheduleThumbnailHide() {
        cancel(&pendingHide)
        guard thumbnail.isShown else { return }
        let item = DispatchWorkItem { [weak self] in self?.hideThumbnail() }
        pendingHide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.thumbnailHideDelay, execute: item)
    }

    private func hideThumbnail() {
        current = nil
        thumbnail.hide()
    }

    private func cancelAll() {
        cancel(&pendingShow)
        cancel(&pendingHide)
        cancel(&pendingPeek)
    }

    private func cancel(_ item: inout DispatchWorkItem?) {
        item?.cancel()
        item = nil
    }
}
