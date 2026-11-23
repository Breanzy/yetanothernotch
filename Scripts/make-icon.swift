// Renders the Islet app icon into an .iconset folder: swift Scripts/make-icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let rect = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.30, blue: 0.96, alpha: 1),
                        NSColor(srgbRed: 0.93, green: 0.36, blue: 0.64, alpha: 1)])!.draw(in: bg, angle: -55)
    // The "island"
    let pw = rect.width * 0.62, ph = rect.width * 0.2
    let pill = NSRect(x: rect.midX - pw / 2, y: rect.maxY - rect.height * 0.36, width: pw, height: ph)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: pill, xRadius: ph / 2, yRadius: ph / 2).fill()
    // Album dot + equalizer bars
    let d = ph * 0.56
    NSColor(srgbRed: 1, green: 0.62, blue: 0.3, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: pill.minX + ph * 0.24, y: pill.midY - d / 2, width: d, height: d),
                 xRadius: d * 0.28, yRadius: d * 0.28).fill()
    NSColor(srgbRed: 0.45, green: 0.95, blue: 0.6, alpha: 1).setFill()
    let bw = ph * 0.1
    for (i, h) in [0.35, 0.6, 0.45, 0.25].enumerated() {
        let bh = ph * CGFloat(h)
        let x = pill.maxX - ph * 0.3 - CGFloat(3 - i) * bw * 1.8
        NSBezierPath(roundedRect: NSRect(x: x, y: pill.midY - bh / 2, width: bw, height: bh),
                     xRadius: bw / 2, yRadius: bw / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
