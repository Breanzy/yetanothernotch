import SwiftUI

/// Clipboard history: a searchable list on the left and a large preview of the selected item
/// on the right. Type to search, ↑/↓ to move, ↩ or ⌘1–⌘9 to copy, ⌘⌫ to delete.
struct ClipboardView: View {
    @EnvironmentObject var clipboard: ClipboardStore
    @EnvironmentObject var vm: NotchViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = clipboard.filteredItems
        let selected = clipboard.selectedItem

        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    searchField
                    controls
                }
                if items.isEmpty {
                    emptyState
                } else {
                    ClipList(items: items, selectedID: selected?.id)
                }
            }
            .frame(width: vm.isEnlarged ? 320 : 250)

            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1)

            ClipPreview(item: selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            clipboard.startKeyHandling()
            searchFocused = true
        }
        .onDisappear {
            clipboard.stopKeyHandling()
            clipboard.query = ""
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            TextField("Search clipboard", text: $clipboard.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !clipboard.query.isEmpty {
                Button { clipboard.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.1)))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            SymbolImage(clipboard.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 22))
            Text(clipboard.query.isEmpty
                 ? "Copy something and it shows up here"
                 : "No matches for “\(clipboard.query)”")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.45))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Clear and enlarge, next to the search field.
    private var controls: some View {
        HStack(spacing: 4) {
            FooterButton(title: "Clear", tint: .white) {
                withAnimation { clipboard.clearUnpinned() }
            }
            .help("Remove everything except pinned items (\(clipboard.items.count) items now)")
            EnlargeButton()
        }
    }
}

private struct FooterButton: View {
    let title: String
    let tint: Color
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint == .white ? Color.white.opacity(0.75) : tint.opacity(0.9))
                .padding(.horizontal, 8)
                .frame(height: 18)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain)
        .hoverState($hovering)
    }
}

/// The scrolling list. Kept separate so the snapshot tool can render rows without a ScrollView.
struct ClipList: View {
    @EnvironmentObject var clipboard: ClipboardStore
    let items: [ClipItem]
    let selectedID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                ClipRows(items: items, selectedID: selectedID, copiedID: clipboard.lastCopiedID)
            }
            // Only keyboard navigation scrolls; hovering never moves the list under the pointer.
            .onChange(of: clipboard.scrollTarget) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }
}

struct ClipRows: View {
    @EnvironmentObject var clipboard: ClipboardStore
    @EnvironmentObject var vm: NotchViewModel
    let items: [ClipItem]
    let selectedID: UUID?
    var copiedID: UUID? = nil

    /// Row height + spacing. Hover picks the row straight from the pointer position.
    static let rowHeight: CGFloat = 24
    static let spacing: CGFloat = 1

    var body: some View {
        LazyVStack(spacing: Self.spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ClipRow(item: item, index: index, selected: item.id == selectedID,
                        copied: item.id == copiedID, store: clipboard, vm: vm)
                    .equatable()
                    .id(item.id)
            }
        }
        .contentShape(Rectangle())
        // One hover handler for the whole list instead of one per row: it reacts on every
        // mouse move, never misses a row when moving fast, and has no per-row tracking areas.
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard case .active(let point) = phase else { return }
            let index = Int(point.y / (Self.rowHeight + Self.spacing))
            if items.indices.contains(index) { clipboard.hover(items[index].id) }
        }
    }
}

/// One row. It doesn't observe the store, so hovering only re-renders the two rows whose
/// highlight changes instead of the whole list.
struct ClipRow: View, Equatable {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let copied: Bool
    let store: ClipboardStore
    let vm: NotchViewModel

    nonisolated static func == (a: ClipRow, b: ClipRow) -> Bool {
        a.item.id == b.item.id && a.item.pinned == b.item.pinned && a.index == b.index
            && a.selected == b.selected && a.copied == b.copied
    }

    var body: some View {
        HStack(spacing: 8) {
            ClipSourceIcon(item: item, size: 16)
            Text(item.listTitle)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            if copied {
                Label("Copied", systemImage: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            } else if selected {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            } else if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 7)
        .frame(height: ClipRows.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.55) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { store.copy(item) }
        .onDrag {
            vm.isDraggingOut = true
            return store.itemProvider(for: item)
        }
        .contextMenu {
            Button("Copy") { store.copy(item) }
            Button(item.pinned ? "Unpin" : "Pin") { store.togglePin(item) }
            if item.kind == .link, let text = item.text, let url = URL(string: text) {
                Button("Open Link") { NSWorkspace.shared.open(url) }
            }
            if item.kind == .file {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.fileURLs) }
            }
            Divider()
            Button("Delete") { store.delete(item) }
        }
        .animation(.easeOut(duration: 0.15), value: copied)
    }
}

/// Source app icon, falling back to a symbol for the item's type.
struct ClipSourceIcon: View {
    let item: ClipItem
    let size: CGFloat

    var body: some View {
        if let id = item.sourceBundleID, let icon = IconCache.appIcon(bundleID: id, size: size) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.7))
                .frame(width: size, height: size)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var symbol: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }
}

// MARK: - Preview

struct ClipPreview: View {
    @EnvironmentObject var clipboard: ClipboardStore
    let item: ClipItem?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 8) {
                content(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HStack(spacing: 5) {
                    ClipSourceIcon(item: item, size: 12)
                    Text(sourceName(item))
                    Spacer(minLength: 6)
                    Text(Self.dateFormatter.string(from: item.date))
                }
                .help("\(sourceName(item)) · \(detail(item)) · Copied \(Self.dateFormatter.string(from: item.date))")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            }
        } else {
            Text("Nothing selected")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func content(_ item: ClipItem) -> some View {
        switch item.kind {
        case .text:
            ScrollView(.vertical, showsIndicators: false) {
                Text(Self.previewText(item))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .link:
            VStack(alignment: .leading, spacing: 8) {
                if let host = URL(string: item.text ?? "")?.host() {
                    Text(host)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(item.text ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.45, green: 0.7, blue: 1))
                if let url = URL(string: item.text ?? "") {
                    PillButton(title: "Open in Browser") { NSWorkspace.shared.open(url) }
                }
            }
        case .image:
            PreviewImage(item: item, store: clipboard)
        case .file:
            HStack(alignment: .top, spacing: 14) {
                if let first = item.fileURLs.first {
                    Image(nsImage: IconCache.icon(forFile: first.path, size: 44))
                        .resizable()
                        .frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(item.fileURLs.prefix(6), id: \.self) { url in
                        Text(url.lastPathComponent)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(url.deletingLastPathComponent().path)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    PillButton(title: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(item.fileURLs)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    /// Laying out a 50,000-character text on every hover is what made long clips feel sticky.
    /// The preview shows the first few thousand characters; copying still copies everything.
    private static let previewLimit = 4000

    private static func previewText(_ item: ClipItem) -> String {
        let text = item.text ?? ""
        guard text.utf8.count > previewLimit else { return text }
        let head = text.prefix(previewLimit)
        return head.count < text.count ? head + "\n…" : text
    }

    private static var sourceNames: [String: String] = [:]

    private func sourceName(_ item: ClipItem) -> String {
        guard let id = item.sourceBundleID else { return "Unknown app" }
        if let cached = Self.sourceNames[id] { return cached }
        guard let path = IconCache.appPath(bundleID: id) else { return "Unknown app" }
        let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        Self.sourceNames[id] = name
        return name
    }

    private static var textDetails: [UUID: String] = [:]

    private func detail(_ item: ClipItem) -> String {
        switch item.kind {
        case .text:
            // Counted once per item and remembered (this runs on every render for the tooltip).
            if let cached = Self.textDetails[item.id] { return cached }
            let text = item.text ?? ""
            let lines = text.split(whereSeparator: \.isNewline).count
            let result = "\(text.count) characters" + (lines > 1 ? ", \(lines) lines" : "")
            if Self.textDetails.count > 200 { Self.textDetails.removeAll() }
            Self.textDetails[item.id] = result
            return result
        case .link:
            return "Link"
        case .image:
            if let w = item.imageWidth, let h = item.imageHeight {
                let size = item.imageBytes.map { ", " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
                return "\(w)×\(h)\(size)"
            }
            return "Image"
        case .file:
            let n = item.fileURLs.count
            return n == 1 ? "1 file" : "\(n) files"
        }
    }
}

/// The image preview. Decoding happens in the background; the previous image stays up until the
/// next one is ready, so moving across image rows doesn't flash.
private struct PreviewImage: View {
    let item: ClipItem
    let store: ClipboardStore
    @ViewState private var image: NSImage?

    var body: some View {
        let shown = store.cachedPreview(for: item) ?? image
        Group {
            if let shown {
                Image(nsImage: shown)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            if let cached = store.cachedPreview(for: item) { image = cached; return }
            // A tiny pause skips decoding images the pointer just passes over.
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            let loaded = await store.loadPreview(for: item)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
