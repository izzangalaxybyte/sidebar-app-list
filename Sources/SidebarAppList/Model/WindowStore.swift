import AppKit
import ApplicationServices
import Combine

/// Source of truth for the sidebar. Owns the row order, the AXObservers,
/// and the latest window snapshot. Main-thread only, except for the AX
/// enumeration which runs on a private queue and posts back.
///
/// Ordering rules: the order is seeded once (frontmost app first, then by
/// any order saved from a previous run) and after that only the user
/// changes it, by dragging. Activating apps never reorders rows. New windows
/// appear next to their app's existing rows; new apps go to the end.
final class WindowStore: ObservableObject {
    @Published private(set) var rows: [SidebarRow] = []
    @Published private(set) var isTrusted = AccessibilityPermission.isTrusted

    private static let savedAppOrderKey = "appOrderBundleIDs"

    /// Order in which apps were first seen; decides where a brand-new app's
    /// rows are appended. Never reordered by activation.
    private var appOrder: [pid_t] = []
    private var rowOrder: [String] = []
    private var rowsByID: [String: SidebarRow] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var iconCache: [pid_t: NSImage] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []

    private let enumerationQueue = DispatchQueue(label: "SidebarAppList.enumerate", qos: .userInitiated)
    private var pendingRefresh: DispatchWorkItem?
    private var generation = 0
    private var started = false

    private static let appNotifications: [String] = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]

    // MARK: Lifecycle

    /// Call once Accessibility is granted. Safe to call again; later calls are no-ops.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { return }
        started = true
        isTrusted = true

        // Applies to every element this process creates, including window
        // elements acted on from the main thread, so a hung app can't stall us.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)

        seedAppOrder()
        subscribeToWorkspace()
        refreshNow()
    }

    /// Frontmost app first, then launch order, then stable-sorted by the
    /// order saved from the last run so a relaunch keeps your arrangement.
    private func seedAppOrder() {
        let apps = Self.regularApps()
        var ordered = apps
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let index = ordered.firstIndex(where: { $0.processIdentifier == front }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        let saved = UserDefaults.standard.stringArray(forKey: Self.savedAppOrderKey) ?? []
        let savedIndex = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let indexed = ordered.enumerated().map { (position: $0, app: $1) }
        appOrder = indexed
            .sorted { lhs, rhs in
                let l = lhs.app.bundleIdentifier.flatMap { savedIndex[$0] } ?? Int.max
                let r = rhs.app.bundleIdentifier.flatMap { savedIndex[$0] } ?? Int.max
                return l != r ? l < r : lhs.position < rhs.position
            }
            .map(\.app.processIdentifier)
    }

    private func subscribeToWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ handler: @escaping (NSRunningApplication?) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                handler(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            }
            workspaceTokens.append(token)
        }

        observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            if !self.appOrder.contains(app.processIdentifier) {
                self.appOrder.append(app.processIdentifier)
            }
            self.scheduleRefresh()
            // Freshly launched apps often reject AX registration for a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.scheduleRefresh() }
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            self.forget(app.processIdentifier)
            self.scheduleRefresh()
        }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] _ in self?.scheduleRefresh() }
        observe(NSWorkspace.didHideApplicationNotification) { [weak self] _ in self?.scheduleRefresh() }
        observe(NSWorkspace.didUnhideApplicationNotification) { [weak self] _ in self?.scheduleRefresh() }
        observe(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in self?.scheduleRefresh() }
    }

    private func forget(_ pid: pid_t) {
        appOrder.removeAll { $0 == pid }
        iconCache[pid] = nil
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    // MARK: Refresh

    func scheduleRefresh(after delay: TimeInterval = 0.05) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard started else { return }
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refreshNow() }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private struct AppInfo {
        let pid: pid_t
        let name: String
        let bundleID: String?
    }

    func refreshNow() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard started else { return }
        pendingRefresh?.cancel()
        pendingRefresh = nil

        let apps = Self.regularApps()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let requests = apps.map { WindowEnumerator.AppRequest(pid: $0.processIdentifier, isHidden: $0.isHidden) }

        // Keep appOrder in sync with reality (apps we never saw launch, etc.).
        let live = Set(apps.map(\.processIdentifier))
        for pid in appOrder where !live.contains(pid) { forget(pid) }
        for app in apps where !appOrder.contains(app.processIdentifier) {
            appOrder.append(app.processIdentifier)
        }
        for app in apps where iconCache[app.processIdentifier] == nil {
            if let icon = app.icon { iconCache[app.processIdentifier] = icon }
        }
        let infos = Dictionary(uniqueKeysWithValues: apps.map {
            ($0.processIdentifier, AppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? "Unknown", bundleID: $0.bundleIdentifier))
        })

        generation += 1
        let thisGeneration = generation

        enumerationQueue.async { [weak self] in
            let windows = WindowEnumerator.windows(for: requests, frontmostPID: frontmostPID)
            DispatchQueue.main.async {
                guard let self, self.generation == thisGeneration else { return }
                self.apply(windows: windows, infos: infos, frontmostPID: frontmostPID)
            }
        }
    }

    /// Merges a fresh snapshot into the existing order without disturbing it:
    /// vanished rows drop out, surviving rows keep their places, new rows go
    /// after their app's last row (or where its rows used to be), and rows of
    /// never-seen apps go to the end.
    private func apply(windows: [pid_t: [WindowItem]], infos: [pid_t: AppInfo], frontmostPID: pid_t?) {
        var desired: [String: SidebarRow] = [:]
        var desiredIDs: [pid_t: [String]] = [:]
        for pid in appOrder {
            guard let info = infos[pid] else { continue }
            let icon = iconCache[pid]
            let isFront = pid == frontmostPID
            let items = windows[pid] ?? []
            if items.isEmpty {
                let id = SidebarRow.appRowID(pid)
                desired[id] = SidebarRow(id: id, pid: pid, appName: info.name, icon: icon, window: nil, isFrontmostApp: isFront)
                desiredIDs[pid] = [id]
            } else {
                for item in items {
                    desired[item.id] = SidebarRow(id: item.id, pid: pid, appName: info.name, icon: icon, window: item, isFrontmostApp: isFront)
                }
                desiredIDs[pid] = items.map(\.id)
            }
        }

        var kept: [String] = []
        var anchors: [pid_t: Int] = [:]
        for id in rowOrder {
            if desired[id] != nil {
                kept.append(id)
            } else if let pid = rowsByID[id]?.pid {
                anchors[pid] = kept.count
            }
        }

        for pid in appOrder {
            guard let ids = desiredIDs[pid] else { continue }
            let fresh = ids.filter { !kept.contains($0) }
            guard !fresh.isEmpty else { continue }
            let insertAt: Int
            if let last = kept.lastIndex(where: { desired[$0]?.pid == pid }) {
                insertAt = last + 1
            } else if let anchor = anchors[pid] {
                insertAt = min(anchor, kept.count)
            } else {
                insertAt = kept.count
            }
            kept.insert(contentsOf: fresh, at: insertAt)
        }

        rowOrder = kept
        rowsByID = desired
        publishRows()
        ensureObservers(pids: Set(kept.compactMap { desired[$0]?.pid }), windows: windows)
    }

    private func publishRows() {
        let newRows = rowOrder.compactMap { rowsByID[$0] }
        if newRows != rows {
            rows = newRows
        }
        saveAppOrder()
    }

    private func saveAppOrder() {
        var seen = Set<String>()
        var bundleIDs: [String] = []
        for pid in rowOrder.compactMap({ rowsByID[$0]?.pid }) {
            guard let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                  seen.insert(bundleID).inserted else { continue }
            bundleIDs.append(bundleID)
        }
        if bundleIDs != (UserDefaults.standard.stringArray(forKey: Self.savedAppOrderKey) ?? []) {
            UserDefaults.standard.set(bundleIDs, forKey: Self.savedAppOrderKey)
        }
    }

    /// User drag: move the row at `from` so it lands at index `to` in `rows`.
    func moveRow(from: Int, to: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard from != to, rowOrder.indices.contains(from), rowOrder.indices.contains(to) else { return }
        let id = rowOrder.remove(at: from)
        rowOrder.insert(id, at: to)
        publishRows()
    }

    private static func regularApps() -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated
        }
    }

    // MARK: AXObserver

    private func ensureObservers(pids: Set<pid_t>, windows: [pid_t: [WindowItem]]) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for pid in pids {
            let observer: AXObserver
            if let existing = observers[pid] {
                observer = existing
            } else {
                guard let created = makeObserver(for: pid, refcon: refcon) else { continue }
                observers[pid] = created
                observer = created
            }
            // Destruction is only delivered when registered on the window
            // itself. Re-registering an already-registered pair is a cheap
            // no-op error, so no bookkeeping is needed.
            for window in windows[pid] ?? [] {
                AXObserverAddNotification(observer, window.element, kAXUIElementDestroyedNotification as CFString, refcon)
            }
        }
    }

    private func makeObserver(for pid: pid_t, refcon: UnsafeMutableRawPointer) -> AXObserver? {
        var observer: AXObserver?
        guard AXObserverCreate(pid, windowStoreObserverCallback, &observer) == .success, let observer else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        for name in Self.appNotifications {
            let error = AXObserverAddNotification(observer, appElement, name as CFString, refcon)
            // Not-yet-responsive apps fail here; returning nil makes the next
            // refresh try again rather than leaving a half-registered observer.
            if error != .success && error != .notificationAlreadyRegistered { return nil }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        return observer
    }

    fileprivate func handleAXNotification() {
        scheduleRefresh()
    }

    // MARK: Actions

    func activate(_ window: WindowItem) {
        if window.isMinimized {
            window.element.set(kAXMinimizedAttribute, to: false)
        }
        window.element.perform(kAXRaiseAction)
        bringAppForward(pid: window.pid)
        scheduleRefresh(after: 0.15)
    }

    /// Brings a window forward without un-minimizing it. Used for hover previews.
    func raise(_ window: WindowItem) {
        window.element.perform(kAXRaiseAction)
        bringAppForward(pid: window.pid)
        scheduleRefresh(after: 0.15)
    }

    /// What was in front before a preview started, so it can be put back.
    struct FocusSnapshot {
        let pid: pid_t
        let window: AXUIElement?
    }

    func captureFocus() -> FocusSnapshot? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        return FocusSnapshot(pid: pid, window: app.element(kAXFocusedWindowAttribute))
    }

    func restoreFocus(_ snapshot: FocusSnapshot) {
        guard let app = NSRunningApplication(processIdentifier: snapshot.pid), !app.isTerminated else { return }
        snapshot.window?.perform(kAXRaiseAction)
        bringAppForward(pid: snapshot.pid)
        scheduleRefresh(after: 0.15)
    }

    func activateApp(pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid), app.isHidden { app.unhide() }
        bringAppForward(pid: pid)
        scheduleRefresh(after: 0.15)
    }

    private func bringAppForward(pid: pid_t) {
        // Setting kAXFrontmost works from a background process, which
        // NSRunningApplication.activate() may not since macOS 14. Do both.
        AXUIElementCreateApplication(pid).set(kAXFrontmostAttribute, to: true)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    func close(_ window: WindowItem) {
        if let button = window.element.element(kAXCloseButtonAttribute) {
            button.perform(kAXPressAction)
        }
        scheduleRefresh(after: 0.2)
    }
}

/// C callback; `refcon` is the unretained store. AXObserver sources are
/// scheduled on the main run loop, so this already runs on the main thread.
private func windowStoreObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<WindowStore>.fromOpaque(refcon).takeUnretainedValue().handleAXNotification()
}
