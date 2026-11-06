import AppKit

/// Hover-to-preview: resting on a row raises that window; leaving the sidebar
/// without clicking puts the previously frontmost window back. Clicking a
/// row commits, so nothing is restored.
final class HoverPreview {
    static let delay: TimeInterval = 0.12

    private let store: WindowStore
    private var restorePoint: WindowStore.FocusSnapshot?
    private var pending: DispatchWorkItem?

    init(store: WindowStore) {
        self.store = store
    }

    /// `nil` when the cursor leaves a row. The current preview stays up until
    /// the sidebar hides; only a pending, not-yet-shown preview is cancelled.
    func hover(_ window: WindowItem?) {
        pending?.cancel()
        pending = nil
        // Previewing a minimized window would un-minimize it; leave those to clicks.
        guard let window, !window.isMinimized else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.restorePoint == nil {
                self.restorePoint = self.store.captureFocus()
            }
            self.store.raise(window)
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: item)
    }

    /// The user picked something: keep what is in front now.
    func commit() {
        pending?.cancel()
        pending = nil
        restorePoint = nil
    }

    /// The sidebar is closing without a pick: undo any preview.
    func end() {
        pending?.cancel()
        pending = nil
        if let restorePoint {
            store.restoreFocus(restorePoint)
        }
        restorePoint = nil
    }
}
