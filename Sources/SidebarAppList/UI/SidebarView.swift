import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: WindowStore
    let onSelectWindow: (WindowItem) -> Void
    let onSelectApp: (pid_t) -> Void
    let onCloseWindow: (WindowItem) -> Void
    /// Called with the hovered window, or nil when the cursor leaves a row.
    let onHoverWindow: (WindowItem?) -> Void

    private static let listSpace = "sidebarList"

    @State private var rowFrames: [String: CGRect] = [:]
    @State private var draggingID: String?
    @State private var dragY: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
            if store.isTrusted {
                rowList
            } else {
                permissionNotice
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: SidebarPanelController.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
    }

    // MARK: Rows

    private var rowList: some View {
        ScrollView(.vertical) {
            let rows = store.rows
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 && rows[index - 1].pid != row.pid {
                        groupDivider
                    }
                    rowView(row)
                }
            }
            .padding(10)
            .coordinateSpace(name: Self.listSpace)
            .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
            .animation(.easeOut(duration: 0.15), value: store.rows)
        }
        .scrollIndicators(.never)
    }

    private var groupDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
    }

    private func rowView(_ row: SidebarRow) -> some View {
        let isDragging = draggingID == row.id
        return WindowRow(
            icon: row.icon,
            title: row.title,
            isFrontmost: row.window?.isFrontmost ?? false,
            isDimmed: row.window.map(\.isMinimized) ?? !row.isFrontmostApp,
            canClose: row.window != nil,
            onSelect: {
                if let window = row.window { onSelectWindow(window) } else { onSelectApp(row.pid) }
            },
            onClose: { if let window = row.window { onCloseWindow(window) } },
            onHover: { hovering in
                // Rows passing under a drag are not previews.
                guard draggingID == nil else { return }
                onHoverWindow(hovering ? row.window : nil)
            }
        )
        .offset(y: isDragging ? dragY - (rowFrames[row.id]?.midY ?? dragY) : 0)
        .zIndex(isDragging ? 1 : 0)
        .opacity(isDragging ? 0.85 : 1)
        // Measured outside the offset on purpose: this must be the row's layout
        // slot, not its displaced position, or the offset feeds back on itself.
        .background(GeometryReader { proxy in
            Color.clear.preference(key: RowFramesKey.self, value: [row.id: proxy.frame(in: .named(Self.listSpace))])
        })
        // The dragged row follows the cursor directly; only the others animate.
        .transaction { transaction in
            if isDragging { transaction.animation = nil }
        }
        .gesture(dragGesture(for: row))
    }

    private func dragGesture(for row: SidebarRow) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                // Not just when nil: a drag whose row vanished mid-gesture never
                // gets onEnded, and the next drag must take over cleanly.
                if draggingID != row.id {
                    draggingID = row.id
                    onHoverWindow(nil)
                }
                dragY = value.location.y
                // Midpoint rule: the slot is the count of other rows whose centre
                // is above the cursor. Stable while neighbours animate, since a
                // swapped neighbour's centre is already past the cursor.
                let to = store.rows.filter { $0.id != row.id && (rowFrames[$0.id]?.midY ?? .infinity) < dragY }.count
                guard let from = store.rows.firstIndex(where: { $0.id == row.id }), from != to else { return }
                store.moveRow(from: from, to: to)
            }
            .onEnded { _ in
                draggingID = nil
            }
    }

    // MARK: Permission

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.6))
            Text("Accessibility access needed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text("Windows are listed and raised through the Accessibility API. Enable SidebarAppList under Privacy & Security → Accessibility.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Text("Already on? The grant is tied to one build. Remove SidebarAppList from the list with −, then add it again.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                AccessibilityPermission.openSystemSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct RowFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct WindowRow: View {
    let icon: NSImage?
    let title: String
    let isFrontmost: Bool
    let isDimmed: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    @State private var hovering = false
    @State private var closeHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable()
                }
            }
            .frame(width: 18, height: 18)
            .opacity(isDimmed ? 0.5 : 1)

            Text(title)
                .font(.system(size: 13, weight: isFrontmost ? .medium : .regular))
                .foregroundStyle(.white.opacity(isDimmed ? 0.55 : (isFrontmost ? 1 : 0.85)))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if canClose && hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(closeHovering ? 1 : 0.65))
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(closeHovering ? 0.22 : 0))
                        )
                }
                .buttonStyle(.plain)
                .background(HoverTracker(isHovering: $closeHovering))
                .help("Close window")
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(backgroundOpacity))
        )
        .background(HoverTracker(isHovering: $hovering))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onChange(of: hovering) { _, isHovering in onHover(isHovering) }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var backgroundOpacity: Double {
        switch (isFrontmost, hovering) {
        case (true, true): return 0.22
        case (true, false): return 0.16
        case (false, true): return 0.08
        case (false, false): return 0
        }
    }
}
