import AppKit
import SwiftUI

/// The shelf: files parked in the notch.
/// Click to select (⌘/⇧ to add), drag on empty space to box-select, ⌫ to move the selection to
/// the Trash, ⌘A to select all, double-click to open, drag items out to move/copy them.
struct ShelfView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var shelf: ShelfStore
    /// Item frames for box selection. Kept outside view state: they change on every scroll
    /// frame, and storing them as state would redraw the whole shelf each time.
    @ViewState private var frames = FrameStore()
    @ViewState private var marquee: CGRect?
    @ViewState private var marqueeBase: Set<UUID> = []

    private static let space = "shelfArea"

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if shelf.items.isEmpty {
                    dropHint
                } else {
                    files
                }
            }
            AirDropZone()
                .frame(width: 100)
        }
        .onAppear { shelf.startKeyHandling() }
        .onDisappear {
            shelf.stopKeyHandling()
            shelf.selection = []
        }
    }

    // MARK: Files + box selection

    private var files: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(shelf.items) { item in
                        ShelfItemView(item: item, selected: shelf.selection.contains(item.id))
                            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) {
                                frames.rects[item.id] = $0
                            }
                    }
                }
                .padding(.horizontal, 6)
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .leading)
                // Empty space: click clears the selection, drag draws a selection box.
                .background(
                    Color.white.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { shelf.selection = [] }
                        .gesture(marqueeGesture)
                )
            }
        }
        .coordinateSpace(.named(Self.space))
        .overlay {
            if let rect = marquee {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.15))
                    .overlay(Rectangle().stroke(Color.accentColor.opacity(0.8), lineWidth: 1))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !shelf.selection.isEmpty {
                SelectionBar()
                    .padding(6)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(vm.isDropTargeted ? 0.08 : 0.04))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(Animation.snappy(duration: 0.15).scaled, value: shelf.selection.isEmpty)
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if marquee == nil {
                    // ⌘/⇧ while box-selecting adds to the current selection.
                    let additive = !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty
                    marqueeBase = additive ? shelf.selection : []
                }
                let rect = CGRect(x: min(value.startLocation.x, value.location.x),
                                  y: min(value.startLocation.y, value.location.y),
                                  width: abs(value.location.x - value.startLocation.x),
                                  height: abs(value.location.y - value.startLocation.y))
                marquee = rect
                let hit = frames.rects.filter { $0.value.intersects(rect) }.map(\.key)
                shelf.selection = marqueeBase.union(hit)
            }
            .onEnded { _ in marquee = nil }
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(.white.opacity(vm.isDropTargeted ? 0.6 : 0.22))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 22))
                    Text("Drop files, screenshots, images or text here")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.5))
            }
    }
}

private final class FrameStore {
    var rects: [UUID: CGRect] = [:]
}

/// Shown while items are selected: count + batch actions.
private struct SelectionBar: View {
    @EnvironmentObject var shelf: ShelfStore

    var body: some View {
        HStack(spacing: 5) {
            Text("\(shelf.selection.count) selected")
                .font(.system(size: 10, weight: .semibold))
                .padding(.leading, 6)
            SmallButton(title: "Move to Trash") { withAnimation(Animation.default.scaled) { shelf.trash(shelf.selection) } }
                .help("Move the selected files to the Trash (⌫)")
            SmallButton(title: "Remove") { withAnimation(Animation.default.scaled) { shelf.remove(shelf.selection) } }
                .help("Take them off the shelf. Your own files go back where they came from.")
            SmallButton(title: "AirDrop") { shelf.airDrop(shelf.selectedItems.map(\.url)) }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.8)))
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

struct ShelfItemView: View {
    @EnvironmentObject var shelf: ShelfStore
    let item: ShelfItem
    let selected: Bool
    @ViewState private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: IconCache.icon(forFile: item.path, size: 44))
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
            Text(item.name)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(width: 68, height: 26, alignment: .top)
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor.opacity(0.45) : Color.white.opacity(hovering ? 0.1 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(selected ? 0.9 : 0), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        // Clicks, double-clicks, right-clicks and drags are handled natively (see below).
        .overlay(ShelfItemInteraction(itemID: item.id, store: shelf))
        .overlay(alignment: .topTrailing) {
            if hovering && !selected {
                Button { withAnimation(Animation.default.scaled) { shelf.remove([item.id]) } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(white: 0.3))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: -2)
                .help(item.originalPath != nil ? "Remove (puts the file back where it came from)"
                                               : "Remove from shelf")
            }
        }
        .hoverState($hovering)
        .help(tooltip)
    }

    private var tooltip: String {
        if let original = item.originalPath {
            return "\(item.name)\nMoved here from \((original as NSString).deletingLastPathComponent)"
        }
        return item.isletMade ? "\(item.name)\nSaved by Islet" : item.path
    }
}

/// AppKit layer over each shelf item. SwiftUI's `onDrag` can't tell us whether a drop
/// succeeded or keep the real file name, so drags, clicks and menus are handled here.
private struct ShelfItemInteraction: NSViewRepresentable {
    let itemID: UUID
    let store: ShelfStore

    func makeNSView(context: Context) -> InteractionView {
        InteractionView(itemID: itemID, store: store)
    }

    func updateNSView(_ view: InteractionView, context: Context) {
        view.itemID = itemID
    }

    final class InteractionView: NSView {
        var itemID: UUID
        let store: ShelfStore
        private var mouseDownEvent: NSEvent?

        init(itemID: UUID, store: ShelfStore) {
            self.itemID = itemID
            self.store = store
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            MainActor.assumeIsolated {
                if event.clickCount == 2 {
                    store.open(store.targets(for: itemID))
                } else if !(store.selection.contains(itemID) && event.modifierFlags.intersection([.command, .shift]).isEmpty) {
                    // Clicking an already-selected item keeps the group selected (so it can be dragged).
                    store.click(itemID, modifiers: event.modifierFlags)
                }
            }
        }

        override func mouseUp(with event: NSEvent) {
            // A plain click (no drag) on an item inside a group selects just that item.
            if let down = mouseDownEvent, down.clickCount == 1,
               down.modifierFlags.intersection([.command, .shift]).isEmpty {
                MainActor.assumeIsolated {
                    if store.selection.count > 1 && store.selection.contains(itemID) {
                        store.click(itemID, modifiers: [])
                    }
                }
            }
            mouseDownEvent = nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = mouseDownEvent else { return }
            let dx = event.locationInWindow.x - down.locationInWindow.x
            let dy = event.locationInWindow.y - down.locationInWindow.y
            guard dx * dx + dy * dy > 9 else { return }
            mouseDownEvent = nil
            MainActor.assumeIsolated { store.beginDrag(from: self, event: down, itemID: itemID) }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            store.contextMenu(for: itemID) // NSView methods already run on the main actor
        }
    }
}

struct AirDropZone: View {
    @EnvironmentObject var shelf: ShelfStore
    @EnvironmentObject var vm: NotchViewModel
    @ViewState private var hovering = false

    var body: some View {
        let targeted = vm.isAirDropTargeted
        let targets = shelf.selection.isEmpty ? shelf.urls : shelf.selectedItems.map(\.url)
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.blue.opacity(targeted ? 0.45 : (hovering ? 0.25 : 0.16)))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "airplayaudio")
                        .font(.system(size: 22, weight: .medium))
                        .symbolEffect(.pulse, isActive: targeted)
                    Text("AirDrop")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.9))
            }
            .contentShape(Rectangle())
            .hoverState($hovering)
            .onTapGesture { shelf.airDrop(targets) }
            // Drops are handled by DropContainerView; it needs to know where this zone is.
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { vm.airDropFrame = $0 }
            .onDisappear { vm.airDropFrame = .zero }
            .help(shelf.items.isEmpty ? "Drop files here to AirDrop them"
                  : (shelf.selection.isEmpty ? "Click to AirDrop everything on the shelf"
                                             : "Click to AirDrop the selected files"))
    }
}
