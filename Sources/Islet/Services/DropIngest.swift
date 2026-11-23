import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Turns whatever was dropped on the notch into real files the shelf can hold and drag back out:
///
/// - files → used as-is
/// - file promises (the screenshot thumbnail, Photos, Mail attachments, browser images…) → written into the shelf folder
/// - raw images → saved as PNG
/// - web links → saved as a `.webloc`
/// - text → saved as a `.txt`
@MainActor
enum DropIngest {
    /// Every pasteboard type the notch accepts.
    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string] + imageTypes.map(\.type)
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// Folder where Islet stores things it created itself (promised files, saved images/text).
    static let ownedFolder: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Islet/Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }()

    private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    static func receive(from pb: NSPasteboard, completion: @escaping @MainActor ([URL]) -> Void) {
        // 1. Real files.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            completion(urls)
            return
        }

        // 2. File promises — the file doesn't exist until we ask the source to write it.
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            let destination = uniqueSubfolder()
            nonisolated(unsafe) let pb = pb // only read again on the main thread
            let tracker = PromiseTracker(expected: receivers.reduce(0) { $0 + max(1, $1.fileNames.count) })
            // Runs once: when every promised file has arrived, or after a timeout if a source
            // never delivers (so a stuck drop can't leave the shelf waiting forever).
            let finish: @Sendable () -> Void = {
                guard let received = tracker.finish() else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if received.isEmpty {
                            try? FileManager.default.removeItem(at: destination)
                            // Some sources promise but also include plain data; fall back to that.
                            completion(saveNonFileContent(from: pb).map { [$0] } ?? [])
                        } else {
                            completion(received)
                        }
                    }
                }
            }
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: destination, options: [:],
                                              operationQueue: promiseQueue) { url, error in
                    // Sources sometimes deliver more files than they announced; counting by hand
                    // (instead of a DispatchGroup) means an extra callback can't crash Islet.
                    if tracker.deliver(error == nil ? url : nil) { finish() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { finish() }
            return
        }

        // 3–5. Images, links, text.
        completion(saveNonFileContent(from: pb).map { [$0] } ?? [])
    }

    private static func saveNonFileContent(from pb: NSPasteboard) -> URL? {
        let stamp = timestamp()

        // Images: common formats are saved byte-for-byte; TIFF (what most apps put on the
        // pasteboard) is re-encoded to PNG with ImageIO. No NSImage conversion, which can pull
        // in heavy frameworks for exotic pasteboard types.
        for (type, ext) in imageTypes {
            guard let data = pb.data(forType: type) else { continue }
            if type == .tiff {
                if let png = pngFromTIFF(data) { return write(png, name: "Image \(stamp).png") }
                continue
            }
            return write(data, name: "Image \(stamp).\(ext)")
        }

        // Web links → .webloc (opens in the browser when double-clicked or dragged to one).
        if let url = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first(where: { !$0.isFileURL }) {
            let plist = ["URL": url.absoluteString]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                let name = sanitized(url.host() ?? "Link")
                return write(data, name: "\(name) \(stamp).webloc")
            }
        }

        // Plain text → .txt named after its first words.
        if let text = pb.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let firstWords = text.split(whereSeparator: \.isNewline).first
                .map { String($0.prefix(40)) } ?? "Text"
            return write(Data(text.utf8), name: "\(sanitized(firstWords)).txt")
        }
        return nil
    }

    // MARK: - Helpers

    private static func uniqueSubfolder() -> URL {
        let dir = ownedFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func write(_ data: Data, name: String) -> URL? {
        // Each saved item gets its own folder so the visible file name stays clean and unique.
        let url = uniqueSubfolder().appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static let imageTypes: [(type: NSPasteboard.PasteboardType, ext: String)] = [
        (.png, "png"),
        (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
        (NSPasteboard.PasteboardType("public.heic"), "heic"),
        (NSPasteboard.PasteboardType("com.compuserve.gif"), "gif"),
        (.tiff, "png"),
    ]

    private static func pngFromTIFF(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(dest, source, 0, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }

    private static func sanitized(_ s: String) -> String {
        var cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot would make a hidden file that Finder doesn't show.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Text" : cleaned
    }

    /// A folder with nothing in it but Finder's hidden `.DS_Store` / `._` metadata files.
    nonisolated static func isEffectivelyEmpty(_ folder: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        return names.allSatisfy { $0 == ".DS_Store" || $0.hasPrefix("._") }
    }

    /// True if Islet created this file (so it may delete it when the item leaves the shelf).
    static func isOwned(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(ownedFolder.standardizedFileURL.path + "/")
    }
}

/// Counts promised files as they arrive (thread-safe; callbacks come on a background queue).
final class PromiseTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var received: [URL] = []
    private var done = false

    init(expected: Int) { remaining = max(1, expected) }

    /// Records one delivery; returns true when all expected files are in.
    func deliver(_ url: URL?) -> Bool {
        lock.withLock {
            if let url { received.append(url) }
            remaining -= 1
            return remaining <= 0
        }
    }

    /// The received files, the first time it's called; nil afterwards.
    func finish() -> [URL]? {
        lock.withLock {
            guard !done else { return nil }
            done = true
            return received
        }
    }
}
