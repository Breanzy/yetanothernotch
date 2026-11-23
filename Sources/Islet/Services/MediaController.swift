import AppKit
import CoreServices
import ImageIO
import SwiftUI

enum MediaSource: String, CaseIterable {
    case spotify, music

    var appName: String { self == .spotify ? "Spotify" : "Music" }
    var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
}

struct NowPlaying: Equatable {
    var source: MediaSource
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var duration: Double
    var position: Double
    var fetchedAt: Date
    var artworkURL: String

    var trackID: String { "\(source.rawValue)|\(title)|\(artist)|\(album)" }

    /// Same track and state, with the playhead where we'd expect it. Polls that only confirm
    /// what the progress bar already shows aren't published, so the UI doesn't redraw every second.
    func matches(_ other: NowPlaying) -> Bool {
        guard source == other.source, title == other.title, artist == other.artist, album == other.album,
              isPlaying == other.isPlaying, duration == other.duration, artworkURL == other.artworkURL
        else { return false }
        return abs(elapsed(at: other.fetchedAt) - other.position) < 1.5
    }

    func elapsed(at date: Date) -> Double {
        let e = position + (isPlaying ? date.timeIntervalSince(fetchedAt) : 0)
        return duration > 0 ? min(max(0, e), duration) : max(0, e)
    }
}

/// Reads now-playing info from Music and Spotify via Apple Events and controls playback.
/// (The private MediaRemote framework is locked down for third-party apps on current macOS,
/// so scripting the players directly is the reliable route.)
@MainActor
final class MediaController: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: Color = .white

    private let queue = DispatchQueue(label: "app.islet.media", qos: .userInitiated)
    private var timer: Timer?
    private var isPolling = false
    private var artworkTrackID: String?
    private var lastSource: MediaSource?
    private var pids: [MediaSource: pid_t] = [:]

    func start() {
        poll()
        setPanelOpen(false)
    }

    /// Poll every second while the panel is open (live progress), every 3 s while closed —
    /// the closed notch only needs play state and artwork, and progress is interpolated locally.
    func setPanelOpen(_ open: Bool) {
        timer?.invalidate()
        let t = Timer(timeInterval: open ? 1.0 : 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = open ? 0.1 : 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if open { poll() }
    }

    func poll() {
        guard !isPolling else { return }
        // Address players by process ID: an Apple Event sent by bundle ID launches the app if it
        // isn't running, which would reopen Spotify/Music right after you quit them.
        var targets: [(MediaSource, pid_t)] = []
        for source in MediaSource.allCases {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID)
                .first(where: { !$0.isTerminated }) {
                targets.append((source, app.processIdentifier))
            }
        }
        pids = Dictionary(uniqueKeysWithValues: targets.map { ($0.0, $0.1) })
        guard !targets.isEmpty else { apply(nil); return }

        isPolling = true
        let preferred = lastSource
        queue.async { [weak self] in
            let results = targets.compactMap { AppleEventBridge.fetch($0.0, pid: $0.1) }
            let best = results.first(where: \.isPlaying)
                ?? results.first(where: { $0.source == preferred })
                ?? results.first
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.isPolling = false
                    self?.apply(best)
                }
            }
        }
    }

    private func apply(_ info: NowPlaying?) {
        switch (nowPlaying, info) {
        case (nil, nil): break
        case let (old?, new?) where old.matches(new): break
        default: nowPlaying = info
        }
        guard let info else {
            artwork = nil; artworkTrackID = nil; accent = .white
            return
        }
        lastSource = info.source
        if info.trackID != artworkTrackID {
            artworkTrackID = info.trackID
            loadArtwork(for: info)
        }
    }

    private func loadArtwork(for info: NowPlaying) {
        let id = info.trackID
        let finish: @Sendable (Data?) -> Void = { [weak self] data in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.artworkTrackID == id else { return }
                    let image = data.flatMap(Self.thumbnail(from:))
                    self.artwork = image
                    self.accent = image.flatMap(Self.accentColor(for:)).map(Color.init(nsColor:)) ?? .white
                }
            }
        }
        switch info.source {
        case .spotify:
            guard let url = URL(string: info.artworkURL), !info.artworkURL.isEmpty else { finish(nil); return }
            Self.artworkSession.dataTask(with: url) { data, _, _ in finish(data) }.resume()
        case .music:
            guard let pid = pids[.music] else { finish(nil); return }
            queue.async { finish(AppleEventBridge.musicArtwork(pid: pid)) }
        }
    }

    // MARK: - Controls

    func togglePlayPause() {
        if var np = nowPlaying {
            np.position = np.elapsed(at: Date())
            np.fetchedAt = Date()
            np.isPlaying.toggle()
            nowPlaying = np
        }
        send(.playPause)
    }

    func nextTrack() { send(.next) }
    func previousTrack() { send(.previous) }

    func seek(toFraction fraction: Double) {
        guard var np = nowPlaying, np.duration > 0 else { return }
        let target = max(0, min(1, fraction)) * np.duration
        np.position = target
        np.fetchedAt = Date()
        nowPlaying = np
        send(.seek(target))
    }

    func launch(_ source: MediaSource) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    /// No HTTP cache: artwork is decoded to a small thumbnail once, so caching the
    /// full-size download would just hold memory.
    private static let artworkSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private func send(_ command: AppleEventBridge.Command) {
        guard let source = nowPlaying?.source, let pid = pids[source] else { return }
        queue.async { [weak self] in
            AppleEventBridge.perform(command, on: source, pid: pid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { self?.poll() }
            }
        }
    }

    // MARK: - Artwork helpers

    /// Decodes artwork straight to a ~200 px thumbnail instead of the full-size image.
    static func thumbnail(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 200,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }

    /// Average color by drawing the artwork into a single pixel (no Core Image / GPU context).
    static func accentColor(for image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        let base = NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                           blue: CGFloat(px[2]) / 255, alpha: 1)
        // Make it vivid enough to read on black.
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, s * 1.2), brightness: max(0.75, b), alpha: 1)
    }
}

/// Talks to Music and Spotify with raw Apple Events (`core/getd` + the apps' own commands).
/// Unlike NSAppleScript this never loads the AppleScript interpreter (~10 MB that stays resident),
/// and each query is a single cheap IPC round-trip. Codes come from the apps' .sdef dictionaries.
enum AppleEventBridge {
    static func code(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    /// `property <prop> of <container>`
    static func property(_ prop: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        specifier(want: "prop", form: "prop", key: NSAppleEventDescriptor(typeCode: code(prop)), from: container)
    }

    /// `<class> <index> of <container>` (1-based)
    static func element(_ cls: String, index: Int32, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: cls, form: "indx", key: NSAppleEventDescriptor(int32: index), from: container)
    }

    private static func specifier(want: String, form: String, key: NSAppleEventDescriptor,
                                  from container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        record.setDescriptor(key, forKeyword: code("seld"))
        record.setDescriptor(container, forKeyword: code("from"))
        return record.coerce(toDescriptorType: code("obj ")) ?? record
    }

    @discardableResult
    static func send(_ pid: pid_t, _ eventClass: String, _ eventID: String,
                     direct: NSAppleEventDescriptor? = nil,
                     params: [String: NSAppleEventDescriptor] = [:]) -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: code(eventClass), eventID: code(eventID),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: -1 /* kAutoGenerateReturnID */, transactionID: 0 /* kAnyTransactionID */)
        if let direct { event.setParam(direct, forKeyword: code("----")) }
        for (key, value) in params { event.setParam(value, forKeyword: code(key)) }
        guard let reply = try? event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 2),
              reply.paramDescriptor(forKeyword: code("errn")) == nil else { return nil }
        return reply.paramDescriptor(forKeyword: code("----"))
    }

    /// Asks macOS for Automation permission once per app per launch (shows the standard
    /// "Islet wants to control Spotify" prompt if it hasn't been answered yet). Runs on the
    /// media queue, so a pending prompt never blocks the UI.
    nonisolated(unsafe) private static var permissionChecked: Set<String> = []

    nonisolated(unsafe) private static var permissionGranted: Set<String> = []

    static func ensurePermission(_ bundleID: String) -> Bool {
        if permissionGranted.contains(bundleID) { return true }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return false }
        let ask = !permissionChecked.contains(bundleID)
        permissionChecked.insert(bundleID)
        let status = AEDeterminePermissionToAutomateTarget(desc, code("****"), code("****"), ask)
        if status == noErr { permissionGranted.insert(bundleID) }
        return status == noErr
    }

    static func get(_ pid: pid_t, _ spec: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        send(pid, "core", "getd", direct: spec)
    }

    // MARK: Player

    static func fetch(_ source: MediaSource, pid app: pid_t) -> NowPlaying? {
        guard ensurePermission(source.bundleID),
              let state = get(app, property("pPlS"))?.enumCodeValue,
              state != code("kPSS") /* stopped */ else { return nil }
        let track = property("pTrk")
        guard let title = get(app, property("pnam", of: track))?.stringValue, !title.isEmpty else { return nil }
        var duration = get(app, property("pDur", of: track))?.doubleValue ?? 0
        // Spotify documents seconds but actually reports milliseconds.
        if source == .spotify, duration > 10_000 { duration /= 1000 }
        return NowPlaying(
            source: source,
            title: title,
            artist: get(app, property("pArt", of: track))?.stringValue ?? "",
            album: get(app, property("pAlb", of: track))?.stringValue ?? "",
            isPlaying: state == code("kPSP"),
            duration: duration,
            position: get(app, property("pPos"))?.doubleValue ?? 0,
            fetchedAt: Date(),
            artworkURL: source == .spotify ? (get(app, property("aUrl", of: track))?.stringValue ?? "") : ""
        )
    }

    /// `raw data of artwork 1 of current track` (Music only).
    static func musicArtwork(pid: pid_t) -> Data? {
        let artwork = element("cArt", index: 1, of: property("pTrk"))
        return get(pid, property("pRaw", of: artwork))?.data
    }

    enum Command { case playPause, next, previous, seek(Double) }

    static func perform(_ command: Command, on source: MediaSource, pid: pid_t) {
        let suite = source == .spotify ? "spfy" : "hook"
        switch command {
        case .playPause: send(pid, suite, "PlPs")
        case .next: send(pid, suite, "Next")
        case .previous: send(pid, suite, "Prev")
        case .seek(let seconds):
            send(pid, "core", "setd", direct: property("pPos"),
                 params: ["data": NSAppleEventDescriptor(double: seconds)])
        }
    }
}
