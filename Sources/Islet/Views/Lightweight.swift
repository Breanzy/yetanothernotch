import AppKit
import SwiftUI

/// A drawn on/off switch. The native `.switch` toggle hosts an AppKit NSSwitch per row and
/// costs ~3 MB the first time Settings opens; this is just two shapes.
struct MiniSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.accentColor : Color.white.opacity(0.18))
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                .padding(2)
        }
        .frame(width: 30, height: 18)
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.snappy(duration: 0.15)) { isOn.toggle() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Small, cached icons. `NSWorkspace.icon(forFile:)` returns multi-resolution icons (up to
/// 1024 px) that are expensive to keep around; we render each once at the size we show.
@MainActor
enum IconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 80
        return c
    }()
    private static var appPaths: [String: String] = [:]

    static func icon(forFile path: String, size: CGFloat) -> NSImage {
        let key = "\(path)#\(Int(size))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = downsample(NSWorkspace.shared.icon(forFile: path), to: size)
        cache.setObject(image, forKey: key)
        return image
    }

    static func appIcon(bundleID: String, size: CGFloat) -> NSImage? {
        let path: String
        if let cached = appPaths[bundleID] {
            path = cached
        } else {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            path = url.path
            appPaths[bundleID] = path
        }
        return icon(forFile: path, size: size)
    }

    static func appPath(bundleID: String) -> String? {
        if let cached = appPaths[bundleID] { return cached }
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
        if let path { appPaths[bundleID] = path }
        return path
    }

    static func purge() { cache.removeAllObjects() }

    private static func downsample(_ icon: NSImage, to size: CGFloat) -> NSImage {
        let px = Int(size * 2) // Retina
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return icon }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }
}
