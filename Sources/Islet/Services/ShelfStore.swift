import AppKit

/// One file on the shelf.
struct ShelfItem: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Where the file is now.
    var path: String
    /// Set when the file was *moved* into the shelf — where it came from (for Put Back).
    var originalPath: String?
    /// Islet created this file itself (screenshot, image, text or link that was dropped).
    var isletMade: Bool
    var addedAt: Date

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
    /// The file lives in Islet's shelf folder (so Islet is responsible for tidying it up).
    var heldByIslet: Bool { isletMade || originalPath != nil }
}

/// Shelf behaviour switches (Settings → Shelf). Read directly so the store doesn't depend on the UI.
enum ShelfPrefs {
    static let moveInKey = "shelf.moveFilesIn"
    static let removeAfterDragKey = "shelf.removeAfterDragOut"
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [moveInKey: true, removeAfterDragKey: true])
    }
    static var moveFilesIn: Bool { UserDefaults.standard.bool(forKey: moveInKey) }
    static var removeAfterDragOut: Bool { UserDefaults.standard.bool(forKey: removeAfterDragKey) }
}

/// Files parked in the notch.
///
/// Safety rule: Islet never permanently deletes anything. Files leaving the shelf either go
/// back where they came from (your own moved-in files) or to the Trash (files Islet made, or
/// anything you explicitly delete).
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published var selection: Set<UUID> = []

    private var lastClicked: UUID?
    private var dragSource: ShelfDragSource?
    private var keyMonitor: Any?
    private let fm = FileManager.default

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Islet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("shelf.json")
    }()

    init() {
        ShelfPrefs.registerDefaults()
        load()
    }

    var urls: [URL] { items.map(\.url) }
    var selectedItems: [ShelfItem] { items.filter { selection.contains($0.id) } }

    // MARK: - Adding

    /// Adds dropped files. Real files are *moved* into the shelf (default) or referenced in place;
    /// files Islet created are already in its folder.
    func add(_ urls: [URL]) {
        let move = ShelfPrefs.moveFilesIn
        for url in urls where url.isFileURL {
            guard !items.contains(where: { $0.path == url.path }) else { continue }
            if DropIngest.isOwned(url) {
                items.append(ShelfItem(path: url.path, isletMade: true, addedAt: Date()))
            } else if move, let moved = moveIntoShelf(url) {
                items.append(ShelfItem(path: moved.path, originalPath: url.path, isletMade: false, addedAt: Date()))
            } else {
                // Couldn't move it (read-only location, in use…) or moving is off: keep it in place.
                items.append(ShelfItem(path: url.path, isletMade: false, addedAt: Date()))
            }
        }
        save()
    }

    private func moveIntoShelf(_ url: URL) -> URL? {
        let dir = DropIngest.ownedFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let destination = dir.appendingPathComponent(url.lastPathComponent)
            try fm.moveItem(at: url, to: destination)
            return destination
        } catch {
            try? fm.removeItem(at: dir)
            return nil
        }
    }

    // MARK: - Removing

    /// Takes items off the shelf: your moved-in files go back where they came from,
    /// files Islet made go to the Trash, in-place references are just dropped.
    func remove(_ ids: Set<UUID>) {
        let leaving = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        leaving.forEach { dispose($0, trash: false) }
        save()
    }

    /// Moves the items' files to the Trash (recoverable) and takes them off the shelf.
    func trash(_ ids: Set<UUID>) {
        let leaving = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        leaving.forEach { dispose($0, trash: true) }
        save()
    }

    func putBack(_ ids: Set<UUID>) {
        remove(Set(items.filter { ids.contains($0.id) && $0.originalPath != nil }.map(\.id)))
    }

    func clear() { remove(Set(items.map(\.id))) }

    /// Auto-clear: same as Remove (your files go back, Islet's go to the Trash).
    @discardableResult
    func purge(olderThanDays days: Int, now: Date = Date()) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let expired = Set(items.filter { $0.addedAt < cutoff }.map(\.id))
        if !expired.isEmpty { remove(expired) }
        return expired.count
    }

    private func dispose(_ item: ShelfItem, trash: Bool) {
        guard fm.fileExists(atPath: item.path) else { return }
        if trash || item.isletMade {
            try? fm.trashItem(at: item.url, resultingItemURL: nil)
        } else if let original = item.originalPath {
            putBackFile(item.url, to: URL(fileURLWithPath: original))
        }
        cleanUpFolder(of: item)
    }

    private func putBackFile(_ url: URL, to original: URL) {
        var folder = original.deletingLastPathComponent()
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: folder.path, isDirectory: &isDir) || !isDir.boolValue {
            folder = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0] // original folder is gone
        }
        let destination = uniqueURL(folder.appendingPathComponent(original.lastPathComponent))
        if (try? fm.moveItem(at: url, to: destination)) == nil {
            try? fm.trashItem(at: url, resultingItemURL: nil) // never lose it: worst case, Trash
        }
    }

    private func uniqueURL(_ url: URL) -> URL {
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 2... {
            let candidate = url.deletingLastPathComponent()
                .appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    /// Removes the per-item folder in Islet's shelf folder once it's empty.
    private func cleanUpFolder(of item: ShelfItem) {
        guard item.heldByIslet else { return }
        let folder = item.url.deletingLastPathComponent()
        guard DropIngest.isOwned(folder.appendingPathComponent("x")),
              folder.standardizedFileURL != DropIngest.ownedFolder.standardizedFileURL,
              DropIngest.isEffectivelyEmpty(folder) else { return }
        try? fm.removeItem(at: folder)
    }

    // MARK: - Selection

    func click(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if modifiers.contains(.shift), let anchor = lastClicked,
                  let a = items.firstIndex(where: { $0.id == anchor }),
                  let b = items.firstIndex(where: { $0.id == id }) {
            selection.formUnion(items[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [id]
        }
        lastClicked = id
    }

    func selectAll() { selection = Set(items.map(\.id)) }

    /// The item plus the rest of the selection if it's part of it.
    func targets(for id: UUID) -> Set<UUID> {
        selection.contains(id) ? selection : [id]
    }

    // MARK: - Opening / sharing

    func open(_ ids: Set<UUID>) {
        items.filter { ids.contains($0.id) }.forEach { NSWorkspace.shared.open($0.url) }
    }

    func reveal(_ ids: Set<UUID>) {
        NSWorkspace.shared.activateFileViewerSelecting(items.filter { ids.contains($0.id) }.map(\.url))
    }

    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    // MARK: - Dragging out

    /// Starts a native file drag for the item (and the rest of the selection if it's selected).
    /// Real file URLs are dragged, so destinations keep the original names, and Finder moves
    /// the file on the same disk.
    func beginDrag(from view: NSView, event: NSEvent, itemID: UUID) {
        if !selection.contains(itemID) { selection = [itemID]; lastClicked = itemID }
        let dragged = items.filter { selection.contains($0.id) && fm.fileExists(atPath: $0.path) }
        guard !dragged.isEmpty else { return }

        let point = view.convert(event.locationInWindow, from: nil)
        let draggingItems: [NSDraggingItem] = dragged.enumerated().map { index, item in
            let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let offset = CGFloat(min(index, 4)) * 5
            draggingItem.setDraggingFrame(NSRect(x: point.x - 24 + offset, y: point.y - 24 - offset, width: 48, height: 48),
                                          contents: IconCache.icon(forFile: item.path, size: 48))
            return draggingItem
        }
        let source = ShelfDragSource(ids: Set(dragged.map(\.id))) { [weak self] operation, ids in
            self?.finishDrag(ids: ids, operation: operation)
        }
        dragSource = source
        let session = view.beginDraggingSession(with: draggingItems, event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    private func finishDrag(ids: Set<UUID>, operation: NSDragOperation) {
        dragSource = nil
        var changed = false
        for id in ids {
            guard let item = items.first(where: { $0.id == id }) else { continue }
            if !fm.fileExists(atPath: item.path) {
                // The destination moved it (e.g. Finder on the same disk): it's gone from the shelf.
                items.removeAll { $0.id == id }
                selection.remove(id)
                cleanUpFolder(of: item)
                changed = true
                continue
            }
            guard !operation.isEmpty, ShelfPrefs.removeAfterDragOut else { continue }
            // The destination copied it (another disk, or an app like Mail): take it off the shelf,
            // then tidy up Islet's copy after a minute so the app has time to read the file.
            items.removeAll { $0.id == id }
            selection.remove(id)
            changed = true
            if item.heldByIslet {
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                    self?.dispose(item, trash: false)
                }
            }
        }
        if changed { save() }
    }

    // MARK: - Keyboard (while the shelf tab is open)

    /// ⌫ moves the selection to the Trash, ⌘A selects all, Esc clears the selection.
    func startKeyHandling() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
    }

    func stopKeyHandling() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        // (A `where` on `case 51, 117` would only guard 117, swallowing ⌫ with nothing selected.)
        switch event.keyCode {
        case 51 where !selection.isEmpty, 117 where !selection.isEmpty: // ⌫ / ⌦
            trash(selection)
            return true
        case _ where cmd && event.charactersIgnoringModifiers?.lowercased() == "a": // ⌘A, any layout
            selectAll()
            return true
        case 53 where !selection.isEmpty: // Esc
            selection = []
            return true
        default:
            return false
        }
    }

    // MARK: - Context menu

    func contextMenu(for id: UUID) -> NSMenu {
        if !selection.contains(id) { selection = [id]; lastClicked = id }
        let ids = selection
        let count = ids.count
        let suffix = count > 1 ? " (\(count) items)" : ""
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open\(suffix)") { [weak self] in self?.open(ids) })
        menu.addItem(ClosureMenuItem("Show in Finder") { [weak self] in self?.reveal(ids) })
        menu.addItem(ClosureMenuItem("AirDrop\(suffix)") { [weak self] in
            guard let self else { return }
            self.airDrop(self.items.filter { ids.contains($0.id) }.map(\.url))
        })
        if items.contains(where: { ids.contains($0.id) && $0.originalPath != nil }) {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Put Back") { [weak self] in self?.putBack(ids) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Remove from Shelf\(suffix)") { [weak self] in self?.remove(ids) })
        menu.addItem(ClosureMenuItem("Move to Trash\(suffix)") { [weak self] in self?.trash(ids) })
        return menu
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL) {
            guard let saved = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
            items = saved.filter { fm.fileExists(atPath: $0.path) }
            sweepOrphans()
            return
        }
        // Migrate the older format (a list of paths + added dates in UserDefaults).
        let d = UserDefaults.standard
        let paths = d.stringArray(forKey: "shelf.paths") ?? []
        let dates = d.dictionary(forKey: "shelf.addedAt") as? [String: Double] ?? [:]
        items = paths.filter { fm.fileExists(atPath: $0) }.map { path in
            ShelfItem(path: path, isletMade: DropIngest.isOwned(URL(fileURLWithPath: path)),
                      addedAt: dates[path].map(Date.init(timeIntervalSince1970:)) ?? Date())
        }
        d.removeObject(forKey: "shelf.paths")
        d.removeObject(forKey: "shelf.addedAt")
        save()
    }
}

extension ShelfStore {
    /// Files in Islet's shelf folder that no shelf item points to: left behind when Islet quit
    /// during the 1-minute tidy-up after a drag-out, or by a drop that failed halfway.
    /// They go to the Trash (recoverable, never deleted outright). Only runs after the shelf
    /// list loaded fine, and skips anything touched in the last 10 minutes.
    fileprivate func sweepOrphans() {
        let root = DropIngest.ownedFolder
        let referenced = Set(items.compactMap { item -> String? in
            guard DropIngest.isOwned(item.url) else { return nil }
            // Each item lives in <root>/<folder>/<name>; keep its top-level folder.
            let rel = item.url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)
            return rel.split(separator: "/").first.map(String.init)
        })
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-600)
        for entry in entries where !referenced.contains(entry.lastPathComponent) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            guard modified < cutoff else { continue }
            if DropIngest.isEffectivelyEmpty(entry) {
                try? fm.removeItem(at: entry) // just an empty folder Islet made (maybe with Finder's .DS_Store)
            } else {
                try? fm.trashItem(at: entry, resultingItemURL: nil)
            }
        }
    }
}

/// Reports how a shelf drag ended. Kept alive by the store (not the view), so the result
/// arrives even if the island closes mid-drag.
final class ShelfDragSource: NSObject, NSDraggingSource {
    let ids: Set<UUID>
    let onEnd: (NSDragOperation, Set<UUID>) -> Void

    init(ids: Set<UUID>, onEnd: @escaping (NSDragOperation, Set<UUID>) -> Void) {
        self.ids = ids
        self.onEnd = onEnd
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnd(operation, ids)
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() { handler() }
}
